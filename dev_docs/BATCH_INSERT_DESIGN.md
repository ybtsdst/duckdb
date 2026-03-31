# PhysicalBatchInsert 设计文档

## 概述

本文档整理了 `PhysicalBatchInsert` 的设计目标、核心数据结构、基本执行流程，以及与 `PhysicalInsert` 的对比分析，为理解 DuckDB 批量高性能写入路径提供参考。

---

## 一、源码文件总览

| 文件 | 说明 |
|------|------|
| `src/include/duckdb/execution/operator/persistent/physical_batch_insert.hpp` | `PhysicalBatchInsert` 类声明 |
| `src/execution/operator/persistent/physical_batch_insert.cpp` | `PhysicalBatchInsert` 实现（含 `CollectionMerger`、`BatchInsertGlobalState`、`BatchInsertLocalState`、`MergeCollectionTask`） |
| `src/include/duckdb/execution/operator/persistent/physical_insert.hpp` | `PhysicalInsert` 及 `InsertGlobalState`、`InsertLocalState` 声明 |
| `src/execution/operator/persistent/physical_insert.cpp` | `PhysicalInsert` 实现 |
| `src/include/duckdb/execution/operator/persistent/batch_memory_manager.hpp` | `BatchMemoryManager` — 批量写入的内存配额与背压管理 |
| `src/include/duckdb/execution/operator/persistent/batch_task_manager.hpp` | `BatchTaskManager<T>` — 线程安全的任务队列 |

---

## 二、设计目标与适用场景

`PhysicalBatchInsert` 专为**高吞吐、大批量数据写入**场景设计，典型用例包括：

- `COPY <file> INTO <table>`（大规模文件导入）
- `CREATE TABLE AS SELECT …`（大结果集落盘）

其核心设计理念是：

1. **批次感知（Batch-Aware）**：利用 Pipeline 的 `BatchIndex` 机制，每个线程处理一段连续的批次（Batch），彼此互不干扰，从而实现完全并行写入。
2. **Row Group 对齐合并**：在写入过程中按 Row Group 边界智能合并小批次，使最终落盘的 Row Group 尽量填满，减少碎片。
3. **内存背压（Memory Backpressure）**：通过 `BatchMemoryManager` 控制内存中未落盘数据量，防止 OOM，并在内存紧张时主动阻塞高批次写入线程，优先让低批次线程推进合并。
4. **乐观写入（Optimistic Write）**：数据先写入事务本地的 `OptimisticDataWriter`，所有批次写完后再统一合并进本地存储，提交后才对其他事务可见。

---

## 三、核心数据结构

### 3.1 BatchInsertGlobalState（全局状态，所有线程共享）

```cpp
class BatchInsertGlobalState : public GlobalSinkState {
    BatchMemoryManager  memory_manager;       // 内存配额与背压控制
    BatchTaskManager<BatchInsertTask> task_manager; // 合并任务队列
    mutex               lock;
    DuckTableEntry     &table;
    idx_t               row_group_size;       // 目标 Row Group 大小（默认 122880 行）
    idx_t               insert_count;         // 已插入总行数
    vector<RowGroupBatchEntry> collections;   // 已注册的批次集合，按 batch_idx 有序排列
    idx_t               next_start;           // 合并扫描的起始游标（避免重复扫描）
    atomic<bool>        optimistically_written; // 是否已有数据乐观刷盘
    idx_t               minimum_memory_per_thread; // 每线程最低内存需求（列数 × 4 MB）
};
```

**关键方法：**

| 方法 | 说明 |
|------|------|
| `MaxThreads(source_max_threads)` | 根据可用内存动态限制并发线程数 |
| `ReadyToMerge(count)` | 判断累计行数是否达到合并阈值（见§五） |
| `ScheduleMergeTasks(context, min_batch_index)` | 扫描 `collections`，将满足合并条件的批次组装成 `MergeCollectionTask` 加入队列 |
| `MergeCollections(context, merge_list, writer)` | 实际执行多个 Collection 的合并，返回合并后的 Collection 索引 |
| `AddCollection(context, batch_idx, min_batch_idx, coll_idx, writer)` | 将一个完成的批次注册到 `collections`，并触发合并任务调度 |

---

### 3.2 BatchInsertLocalState（线程本地状态，每线程独占）

```cpp
class BatchInsertLocalState : public LocalSinkState {
    idx_t                          current_index;         // 当前批次索引
    TableAppendState               current_append_state;  // Append 状态（行偏移等）
    PhysicalIndex                  collection_index;      // 当前线程的 OptimisticCollection 索引
    unique_ptr<OptimisticDataWriter> optimistic_writer;   // 乐观刷盘写入器
    unique_ptr<ConstraintState>    constraint_state;      // 约束校验状态
};
```

每个线程在处理第一个 Chunk 时懒初始化 `CreateNewCollection()`，为自己分配一个独立的 `RowGroupCollection`。

---

### 3.3 RowGroupBatchEntry（批次元数据条目）

```cpp
struct RowGroupBatchEntry {
    idx_t         batch_idx;          // 对应的批次索引
    idx_t         total_rows;         // 该批次的总行数
    idx_t         unflushed_memory;   // 未落盘数据的内存占用（字节）
    PhysicalIndex collection_index;   // 在 DataTable 中的 OptimisticCollection 索引
    RowGroupBatchType type;           // NOT_FLUSHED（内存中）或 FLUSHED（已乐观刷盘）
};
```

`BatchInsertGlobalState::collections` 是一个按 `batch_idx` 升序排列的 `RowGroupBatchEntry` 向量，是合并调度的核心数据结构。

---

### 3.4 CollectionMerger（Collection 合并器）

```cpp
class CollectionMerger {
    ClientContext              &context;
    DataTable                  &data_table;
    vector<PhysicalIndex>       collection_indexes; // 待合并的 Collection 列表
    RowGroupBatchType           batch_type;         // 合并结果的类型
};
```

`CollectionMerger::Flush(writer)` 将 `collection_indexes` 中的所有 Collection 顺序扫描后追加到第一个 Collection，然后调用 `writer.WriteUnflushedRowGroups()` 将未落盘的 Row Group 刷出，返回合并后的 Collection 索引。

---

### 3.5 MergeCollectionTask（后台合并任务）

`MergeCollectionTask` 实现 `BatchInsertTask` 接口，持有待合并的 `RowGroupBatchEntry` 列表和目标 `batch_idx`。任务执行时调用 `BatchInsertGlobalState::MergeCollections()` 完成合并，并将结果写回 `collections` 对应位置。

---

### 3.6 BatchMemoryManager（内存配额与背压）

```
BatchMemoryManager
  ├── unflushed_memory_usage  原子计数，当前内存中未落盘数据字节数
  ├── available_memory        当前已向 TemporaryMemoryManager 申请的配额
  ├── min_batch_index         当前所有活跃线程中最小的 batch_index
  └── StateWithBlockableTasks 继承自此类，支持阻塞/唤醒等待任务
```

核心逻辑：

- 每个线程写入前检查 `OutOfMemory(batch_index)`；若当前内存超限且该线程不是最小批次索引，则阻塞该线程（`BlockSink()`），让最小批次的线程优先推进数据落盘。
- `UpdateMinBatchIndex()` 在批次切换时更新全局最小批次索引，并唤醒所有阻塞线程。
- 内存配额最多不超过系统可用查询内存的 1/4，不足时自动尝试翻倍（`IncreaseMemory()`）。

---

## 四、基本执行流程

整体流程嵌入在 DuckDB 的 Pipeline Sink 框架中，各阶段调用顺序如下：

```
GetGlobalSinkState()         ← Pipeline 初始化阶段，每条 Pipeline 调用一次
GetLocalSinkState()          ← 每线程调用一次，分配线程本地状态

[每线程并行执行以下循环]
  Sink(chunk)                ← 接收一个 DataChunk，写入本地 OptimisticCollection
  NextBatch()                ← 批次索引变化时调用，将当前批次提交到全局状态
  Sink(chunk)
  NextBatch()
  ...

Combine()                    ← 每线程所有批次处理完后调用，提交最后一个批次并合并 writer

Finalize()                   ← 所有线程 Combine 完成后调用一次，执行最终合并与落盘
GetDataInternal()            ← Source 阶段，返回 insert_count
```

### 4.1 GetGlobalSinkState

1. 若为 `CREATE TABLE AS`，先调用 `catalog.CreateTable()` 创建目标表。
2. 按列数计算 `minimum_memory_per_thread`（每列 4 MB）。
3. 调用 `table.GetStorage().BindIndexes(context)` 绑定索引，以便后续约束校验。
4. 创建 `BatchInsertGlobalState`，初始化 `BatchMemoryManager`。

### 4.2 GetLocalSinkState

创建 `BatchInsertLocalState`，`collection_index` 初始化为无效值（懒创建 Collection）。

### 4.3 Sink（核心写入）

```
Sink(chunk)
├─ 判断 memory_manager.IsMinimumBatchIndex(batch_index)
│   ├─ 否 → 检查 OutOfMemory(batch_index)
│   │        ├─ 是 → ExecuteTasks() 消化合并任务，再检查内存
│   │        │       仍不足 → BlockSink() 阻塞当前线程（返回 BLOCKED）
│   │        └─ 否 → 继续
│   └─ 是（最小批次） → 直接继续
├─ 若 collection_index 无效 → CreateNewCollection() 懒初始化本地 Collection
├─ 初始化 ConstraintState（懒创建）
├─ VerifyAppendConstraints() 约束校验
└─ collection.Append(chunk, append_state)
   └─ 若产生新 Row Group → optimistic_writer.WriteNewRowGroup() 乐观刷盘
```

### 4.4 NextBatch（批次切换）

当 Pipeline 框架通知批次索引变化时调用：

```
NextBatch()
├─ 若 collection_index 有效（当前批次有数据）
│   ├─ collection.FinalizeAppend()           终止当前批次的追加状态
│   ├─ gstate.AddCollection(batch_idx, ...)  注册到全局 collections
│   │   └─ ScheduleMergeTasks()              尝试调度合并任务
│   └─ 尝试唤醒阻塞任务 / 自行执行合并任务
├─ 更新 lstate.current_index = 新 batch_index
└─ 解锁内存管理器，唤醒阻塞任务
```

### 4.5 Combine（线程收尾）

每个线程完成所有批次后调用：

```
Combine()
├─ 若 collection_index 有效 → 提交最后一个批次到 gstate.AddCollection()
├─ 将本地 optimistic_writer 合并进全局 writer
└─ 唤醒所有阻塞任务
```

### 4.6 Finalize（全局收尾与落盘）

所有线程 `Combine()` 完成后，Pipeline 框架调用一次 `Finalize()`：

**大数据路径**（`optimistically_written == true` 或 `insert_count >= row_group_size`）：

```
Finalize() - 大数据路径
├─ 遍历 collections，将 NOT_FLUSHED 的批次收集到 CollectionMerger
│   遇到 FLUSHED 批次则另建独立 CollectionMerger（不可合并已刷盘批次）
├─ 对每个 CollectionMerger 调用 Flush(writer) → 执行内存内合并并落盘
├─ 对每个合并结果调用 data_table.LocalMerge() → 归并进事务本地存储
├─ optimistic_writer.FinalFlush()   将乐观写入的 Row Group 最终落盘
└─ memory_manager.FinalCheck()      断言未落盘内存归零
```

**小数据路径**（全部数据仍在内存中且总量 < row_group_size）：

```
Finalize() - 小数据路径
├─ data_table.InitializeLocalAppend()
├─ 遍历 collections → 逐块 LocalAppend 到事务本地存储（无需合并）
└─ data_table.FinalizeLocalAppend()
```

### 4.7 GetDataInternal（Source 阶段）

返回包含 `insert_count`（`BIGINT` 类型）的单行结果，供上层算子读取插入行数。

---

## 五、Row Group 合并策略

`BatchInsertGlobalState::ReadyToMerge(count)` 定义了触发合并的行数阈值，目标是使合并后的 Row Group 尽量填满（行数接近 row_group_size 的整数倍）：

| 条件 | 含义 | 允许偏差窗口（相对于目标倍数下界的范围） |
|------|------|----------------------------------------|
| `count ∈ [90%, 100%] × row_group_size` | 接近 1 个 Row Group，合并 | 10% |
| `count ∈ [180%, 200%] × row_group_size` | 接近 2 个 Row Group，合并 | 20% |
| `count ∈ [270%, 300%] × row_group_size` | 接近 3 个 Row Group，合并 | 30% |
| `count ≥ 360% × row_group_size` | 超过 3 个 Row Group，合并 | 无上限 |

> **注**：允许偏差窗口随目标 Row Group 数量（N）成比例增大（N × 10%）。这是有意设计：数据量越大，对填充率的容忍度越高；而绝对偏差行数（每档约 1 个 Row Group）保持不变，因此对存储空间利用率的影响相对更小。

**合并任务调度（ScheduleMergeTasks）流程：**

```
遍历 collections[next_start .. min_batch_index]
├─ 跳过 FLUSHED 批次（已落盘，不可合并），并推进 next_start
├─ 累加 NOT_FLUSHED 批次的 total_rows
├─ 若 ReadyToMerge(累计行数) → 生成 MergeCollectionTask 并加入 task_manager 队列
│   ├─ 将被合并批次的 type 标记为 FLUSHED
│   └─ 从 collections 中删除多余条目（保留首个作为占位）
└─ 继续扫描下一段
```

合并任务由工作线程在 `Sink()` 内存不足时（`ExecuteTasks()`）或 `NextBatch()` / `Combine()` 时消费执行，实现**写入与合并的流水线化**。

---

## 六、与 PhysicalInsert 的对比

### 6.1 特性对比表

| 特性 | PhysicalBatchInsert | PhysicalInsert |
|------|---------------------|----------------|
| **PhysicalOperatorType** | `BATCH_INSERT` / `BATCH_CREATE_TABLE_AS` | `INSERT` / `CREATE_TABLE_AS` |
| **并行写入** | 始终并行（`ParallelSink() = true`） | 可配置（`parallel` 字段，默认 false） |
| **批次感知** | 是，`RequiredPartitionInfo()` 返回 `BatchIndex` | 否，无 `NextBatch()` 方法 |
| **ON CONFLICT 支持** | 不支持（无冲突处理逻辑） | 完整支持（`THROW` / `NOTHING` / `UPDATE` / `REPLACE`） |
| **RETURNING 子句** | 不支持（`return_chunk = false`） | 支持（`return_chunk` 字段） |
| **顺序保证** | 不保序（`SinkOrderDependent() = false`） | 顺序依赖（`SinkOrderDependent() = true`） |
| **内存管理** | `BatchMemoryManager`：按批次索引背压，动态扩容 | 无专门管理，通过行数阈值决定路径 |
| **合并调度** | `BatchTaskManager` + `MergeCollectionTask`（异步合并） | `Combine()` 内同步合并（小数据直接 Append，大数据 LocalMerge） |
| **Finalize 工作量** | 大：执行全局 CollectionMerger 合并与最终刷盘 | 极小：直接返回 `READY` |
| **约束校验时机** | `Sink()` 阶段（`VerifyAppendConstraints`） | `Sink()` 阶段（`OnConflictHandling` 内含校验） |
| **适用数据量** | 大批量（≥ 1 个 Row Group，通常 > 10 万行） | 小批量或含冲突处理的任意写入 |

### 6.2 执行路径对比

```
PhysicalInsert（非并行）
  Sink(): OnConflictHandling() → LocalAppend()   (直接写入本地存储)
  Combine(): 无操作
  Finalize(): 直接返回 READY

PhysicalInsert（并行）
  Sink(): OnConflictHandling() → Collection.Append()
  Combine(): FinalizeAppend() → (小) LocalAppend / (大) LocalMerge
  Finalize(): 直接返回 READY

PhysicalBatchInsert（始终并行，按批次）
  Sink(): MemoryCheck → Collection.Append() → [后台 MergeTask]
  NextBatch(): FinalizeAppend() → AddCollection() → ScheduleMergeTasks()
  Combine(): 提交最后批次 → 合并 writer
  Finalize(): CollectionMerger 全局合并 → LocalMerge → FinalFlush
```

### 6.3 数据结构对比

| 数据结构 | PhysicalBatchInsert | PhysicalInsert |
|---------|---------------------|----------------|
| 全局状态 | `BatchInsertGlobalState`（含 `BatchMemoryManager`、`BatchTaskManager`、`collections` 向量） | `InsertGlobalState`（含 `return_collection`） |
| 线程本地状态 | `BatchInsertLocalState`（只含写入状态，无冲突处理字段） | `InsertLocalState`（含 `update_chunk`、`updated_rows`、`delete_state`、`append_chunk` 等冲突处理字段） |
| 合并机制 | `CollectionMerger` + `MergeCollectionTask`（后台异步合并） | `Combine()` 中直接合并（同步） |
| 内存控制 | `BatchMemoryManager`（动态配额 + 背压阻塞） | 无 |

### 6.4 选择建议

| 场景 | 推荐算子 |
|------|---------|
| 大规模 COPY 文件导入 | `PhysicalBatchInsert` |
| CREATE TABLE AS SELECT（大结果集） | `PhysicalBatchInsert` |
| INSERT INTO … VALUES（少量行） | `PhysicalInsert` |
| INSERT INTO … ON CONFLICT DO UPDATE | `PhysicalInsert` |
| INSERT INTO … RETURNING … | `PhysicalInsert` |
| 含唯一约束冲突处理的写入 | `PhysicalInsert` |

在 DuckDB 的物理计划生成阶段（`physical_plan_generator.cpp`），规划器会根据数据源特征、是否含 ON CONFLICT 子句等条件选择相应的物理算子。

---

## 七、关键设计决策总结

1. **批次索引隔离写入**：每个线程只写自己的批次，完全避免了多线程并发写入同一 Collection 的锁竞争，是 `PhysicalBatchInsert` 高吞吐的根本原因。

2. **乐观写入 + 事后合并**：数据先写入事务本地 `OptimisticDataWriter`，`Finalize()` 阶段通过 `CollectionMerger` 将碎片 Row Group 合并对齐后再通过 `LocalMerge()` 归并进存储引擎，保证 Row Group 填充率。

3. **内存感知调度**：`BatchMemoryManager` 结合 `min_batch_index` 实现了一种"低批次优先"的背压策略，确保数据按批次顺序推进落盘，同时限制系统整体内存占用。

4. **写入与合并流水线化**：合并任务（`MergeCollectionTask`）被推入 `BatchTaskManager` 队列，写入线程在内存紧张时主动消费合并任务，实现 I/O 与计算的重叠执行。

5. **不支持 ON CONFLICT 和 RETURNING**：为换取最大写入吞吐，`PhysicalBatchInsert` 放弃了这两个特性，因为冲突检测要求跨线程查询已有数据，会打破批次隔离假设。
