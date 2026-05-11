# PhysicalInsert 执行设计文档

## 概述

本文档梳理 `PhysicalInsert` 算子的完整执行流程，重点说明 Sink / Combine / Finalize 三个阶段的调用路径、并行与串行 Combine 的判定逻辑、`Combine()` 在 `preserve_insertion_order = false` 时触发的串行慢路径，以及计划器如何在 `PhysicalInsert` 与 `PhysicalBatchInsert` 之间做出选择。`PhysicalBatchInsert` 的详细设计参见 `dev_docs/BATCH_INSERT_DESIGN.md`，本文不重复。

---

## 一、源码文件总览

| 文件 | 说明 |
|------|------|
| `src/include/duckdb/execution/operator/persistent/physical_insert.hpp` | `PhysicalInsert`、`InsertGlobalState`、`InsertLocalState` 类声明 |
| `src/execution/operator/persistent/physical_insert.cpp` | `PhysicalInsert` 完整实现，含 `Sink`、`Combine`、`Finalize`、`OnConflictHandling` 等 |
| `src/execution/physical_plan/plan_insert.cpp` | 计划器入口：`DuckCatalog::PlanInsert()`、`PreserveInsertionOrder()`、`UseBatchIndex()` |
| `src/include/duckdb/execution/physical_plan_generator.hpp` | `PhysicalPlanGenerator` 声明，含 `PreserveInsertionOrder`、`UseBatchIndex` 静态方法 |
| `src/include/duckdb/execution/operator/persistent/physical_batch_insert.hpp` | `PhysicalBatchInsert` 声明（对比参考） |
| `src/execution/operator/persistent/physical_batch_insert.cpp` | `PhysicalBatchInsert` 实现（对比参考） |
| `src/storage/optimistic_data_writer.cpp` | `OptimisticDataWriter`：乐观写入器，用于并行路径的 Row Group 预刷盘 |
| `src/transaction/local_storage.cpp` | `LocalStorage`：事务本地存储，`LocalAppend`/`LocalMerge` 的实现 |

---

## 二、类层次与核心字段

### 2.1 PhysicalInsert（`physical_insert.hpp:66`）

```cpp
class PhysicalInsert : public PhysicalOperator {
    optional_ptr<TableCatalogEntry> insert_table; // 目标表
    vector<LogicalType>             insert_types;  // 目标表列类型
    vector<unique_ptr<BoundConstraint>> bound_constraints;
    bool return_chunk;          // 是否有 RETURNING 子句
    bool parallel;              // 是否启用并行写入路径（由计划器在构造时注入）
    OnConflictAction action_type; // THROW / NOTHING / UPDATE / REPLACE
    // ON CONFLICT 相关字段（条件表达式、目标列、SET 表达式等）
    unique_ptr<Expression>      on_conflict_condition;
    unique_ptr<Expression>      do_update_condition;
    unordered_set<column_t>     conflict_target;
    vector<unique_ptr<Expression>> set_expressions;
    vector<PhysicalIndex>       set_columns;
    vector<LogicalType>         set_types;
    bool update_is_del_and_insert; // INSERT OR REPLACE 需要先删后插时为 true
};
```

`parallel` 字段由 `DuckCatalog::PlanInsert()` 在生成物理计划时注入，运行期不变（见第六节）。

### 2.2 InsertGlobalState（`physical_insert.hpp:26`）

```cpp
class InsertGlobalState : public GlobalSinkState {
    mutex                lock;            // 保护 insert_count 和 Combine 阶段的并发合并
    DuckTableEntry      &table;
    idx_t                insert_count;   // 累计插入行数
    ColumnDataCollection return_collection; // RETURNING 子句的结果集（非并行路径）
};
```

`InsertGlobalState` 构造时调用 `table.GetStorage().BindIndexes(context)`，将表上的所有索引绑定到当前事务，为后续约束校验做准备（`physical_insert.cpp:78`）。

### 2.3 InsertLocalState（`physical_insert.hpp:37`）

```cpp
class InsertLocalState : public LocalSinkState {
    DataChunk            update_chunk;       // DO UPDATE 冲突处理的暂存块
    DataChunk            append_chunk;       // INSERT OR REPLACE 的插入块
    TableAppendState     local_append_state; // 并行路径 Append 状态（行偏移等）
    PhysicalIndex        collection_index;   // 并行路径：本线程 OptimisticCollection 的索引
    unique_ptr<OptimisticDataWriter> optimistic_writer; // 并行路径：乐观刷盘写入器
    unordered_set<row_t> updated_rows;       // DO UPDATE 已处理行集合（防重复更新）
    unique_ptr<ConstraintState>  constraint_state; // 约束校验状态（懒创建）
    unique_ptr<TableDeleteState> delete_state;     // DELETE+INSERT 模式的删除状态
    const vector<unique_ptr<BoundConstraint>> &bound_constraints;
};
```

`collection_index` 初始值为 `DConstants::INVALID_INDEX`（`physical_insert.cpp:83`），非并行路径不写入 `OptimisticCollection`，故该字段始终无效；并行路径在首次 `Sink()` 调用时懒初始化。

---

## 三、完整执行流程

整体调用顺序由 Pipeline 执行框架驱动（参见 `PIPELINE_EXECUTION_DESIGN.md`）：

```
GetGlobalSinkState()   ─── Pipeline 初始化阶段（每条 Pipeline 一次）
GetLocalSinkState()    ─── 每线程一次

[每线程并发执行]
  Sink(chunk)          ─── 处理每个输入 DataChunk
  ...

Combine()              ─── 每线程完成所有 Sink 调用后执行一次
                            （所有线程的 Combine 并发执行，但内部有锁）

Finalize()             ─── 所有线程 Combine 完成后执行一次

GetDataInternal()      ─── Source 阶段，返回 insert_count 或 RETURNING 结果集
```

### 3.1 GetGlobalSinkState（`physical_insert.cpp:104`）

若为 `CREATE TABLE AS`，先调用 `catalog.CreateTable()` 创建目标表，再构造 `InsertGlobalState`。`InsertGlobalState` 构造函数中会调用 `BindIndexes(context)` 将表索引绑定到当前事务，以便 `Sink()` 阶段进行约束校验。

### 3.2 GetLocalSinkState（`physical_insert.cpp:121`）

分配 `InsertLocalState`，初始化 `update_chunk`、`append_chunk` 的列类型，`collection_index` 设为无效值。

### 3.3 Sink — 非并行路径（`physical_insert.cpp:618`）

当 `parallel == false` 时走此路径：

```
Sink(insert_chunk)
├─ insert_chunk.Flatten()
├─ OnConflictHandling()               // 约束校验 + 冲突处理（见 3.5）
├─ gstate.insert_count += chunk.size() + updated_tuples
├─ 若 return_chunk → gstate.return_collection.Append(insert_chunk)
├─ storage.LocalAppend(table, client, insert_chunk, bound_constraints)
│      // 直接追加到事务本地存储，无 OptimisticCollection
└─ 若 action_type == UPDATE && lstate.update_chunk 非空
       → HandleInsertConflicts<true>() + HandleInsertConflicts<false>()
         // 将 update_chunk 中的行触发 DO UPDATE 处理，处理后 chunk 应归零
```

非并行路径的所有数据直接写入事务本地存储（`LocalStorage`），`collection_index` 始终无效，`Combine()` 只做性能统计后直接返回（见 3.6）。

### 3.4 Sink — 并行路径（`physical_insert.cpp:644`）

当 `parallel == true` 时走此路径（此路径不支持 `RETURNING`，`D_ASSERT(!return_chunk)`）：

```
Sink(insert_chunk)
├─ insert_chunk.Flatten()
├─ 若 !lstate.collection_index.IsValid()  // 懒初始化
│   ├─ lock_guard(gstate.lock)
│   ├─ lstate.optimistic_writer = make_uniq<OptimisticDataWriter>(client, data_table)
│   ├─ 创建 OptimisticCollection 并调用 InitializeAppend()
│   └─ lstate.collection_index = data_table.CreateOptimisticCollection(...)
├─ OnConflictHandling()
│      // 并行路径不支持 action_type == UPDATE（D_ASSERT）
├─ collection.Append(insert_chunk, lstate.local_append_state)
└─ 若产生新 Row Group → lstate.optimistic_writer->WriteNewRowGroup(collection)
       // 乐观预刷盘：将已满的 Row Group 写入磁盘，不影响其他事务可见性
```

并行路径为每个线程分配独立的 `RowGroupCollection`（通过 `OptimisticDataWriter` 管理），线程间写入互不干扰，锁仅在初始化阶段使用，Append 阶段完全无锁。

### 3.5 OnConflictHandling（`physical_insert.cpp:517`）

两条路径的 `Sink()` 均调用此方法。核心逻辑如下：

```
OnConflictHandling(insert_chunk)
├─ action_type == THROW
│   └─ VerifyAppendConstraints()  // 校验失败则抛异常，insert_chunk 不变
├─ action_type == NOTHING / UPDATE
│   ├─ CheckDistinctness()        // 检测 insert_chunk 内部的重复键
│   ├─ 过滤重复行，保留唯一行
│   ├─ HandleInsertConflicts<true>()   // 与全局存储对比冲突
│   └─ HandleInsertConflicts<false>()  // 与事务本地存储对比冲突
│       ├─ VerifyAppendConstraints / VerifyUniqueIndexes → ConflictManager
│       ├─ 扫描冲突行的现有值（Fetch）
│       ├─ VerifyOnConflictCondition（WHERE 子句）
│       ├─ PerformOnConflictAction：Update / Delete+Insert
│       └─ 从 insert_chunk 中移除冲突行（Slice）
└─ 返回 updated_tuples 数量
```

完成后 `insert_chunk` 只包含需要真正插入的新行（冲突行已被处理或丢弃）。

### 3.6 Combine（`physical_insert.cpp:673`）

`Combine()` 由 Pipeline 框架在每个线程完成所有 `Sink()` 调用后触发，多个线程的 `Combine()` 调用并发执行，但内部以互斥锁串行化关键合并操作。

```
Combine()
├─ 刷新线程 profiler 到 client_profiler
├─ [line 680] if (!parallel || !lstate.collection_index.IsValid())
│       return FINISHED    // ← 快速返回（见第四节）
│
├─ collection.FinalizeAppend(tdata, lstate.local_append_state)
│       // 提交本线程 OptimisticCollection 的 Append 状态，固定行数
├─ append_count = collection.GetTotalRows()
├─ lock_guard(gstate.lock)             // ← 串行化临界区
├─ gstate.insert_count += append_count
├─ if append_count < row_group_size    // 小数据路径
│   ├─ storage.InitializeLocalAppend()
│   ├─ for chunk in collection.Chunks() → storage.LocalAppend()
│   └─ storage.FinalizeLocalAppend()
└─ else                                // 大数据路径
    ├─ lstate.optimistic_writer->WriteUnflushedRowGroups(collection)
    ├─ lstate.optimistic_writer->FinalFlush()
    ├─ data_table.LocalMerge(client, collection)
    └─ GetOptimisticWriter(client).Merge(*lstate.optimistic_writer)
```

### 3.7 Finalize（`physical_insert.cpp:720`）

```cpp
SinkFinalizeType PhysicalInsert::Finalize(...) const {
    return SinkFinalizeType::READY;
}
```

`PhysicalInsert` 的 `Finalize()` 是空实现，直接返回 `READY`。所有实质性的数据落盘工作均在 `Sink()`（非并行路径）或 `Combine()`（并行路径）中完成，`Finalize()` 无需额外处理。这与 `PhysicalBatchInsert` 的重量级 `Finalize()`（全局 `CollectionMerger` 合并 + 最终刷盘）形成鲜明对比。

### 3.8 GetDataInternal（`physical_insert.cpp:745`）

```
GetDataInternal()
├─ 若 !return_chunk
│   └─ chunk[0] = BIGINT(insert_gstate.insert_count)  → FINISHED
└─ 若 return_chunk
    └─ return_collection.Scan(scan_state, chunk)
       → HAVE_MORE_OUTPUT（直到扫描完毕 → FINISHED）
```

---

## 四、并行与串行 Combine 的判定

`Combine()` 在第 680 行的条件决定了是走快速返回还是走实际合并逻辑：

```cpp
// physical_insert.cpp:680
if (!parallel || !lstate.collection_index.IsValid()) {
    return SinkCombineResultType::FINISHED;
}
```

满足以下任一条件时快速返回，不执行合并：

| 条件 | 原因 |
|------|------|
| `!parallel` | 非并行路径：所有数据已在 `Sink()` 中直接写入 `LocalStorage`，`Combine()` 无事可做 |
| `!lstate.collection_index.IsValid()` | 并行路径但该线程未收到任何数据（如空表或分区后某线程无数据），无需合并 |

只有当 `parallel == true` 且线程确实写入了数据时，`Combine()` 才执行实际的合并操作。

`parallel` 字段由计划器在构造 `PhysicalInsert` 时注入（`plan_insert.cpp:132`）：

```cpp
parallel_streaming_insert && num_threads > 1
```

其中 `parallel_streaming_insert = !PreserveInsertionOrder(context, *plan)`。换言之，只有在以下全部条件成立时，`parallel` 才为 `true`：

1. `preserve_insertion_order` 配置为 `false`，且数据源的顺序类型为 `INSERTION_ORDER`（既不是 `FIXED_ORDER` 也不是 `NO_ORDER`）；或者数据源本身为 `NO_ORDER`（始终允许乱序）。
2. 线程数 > 1。
3. `action_type != UPDATE`（`DO UPDATE` 需要防止同一行被更新两次，不支持并行流式写入）。
4. `return_chunk == false`（`RETURNING` 子句当前不支持并行路径）。

---

## 五、Combine 慢路径详解（`parallel == true` 时的串行合并）

当 `parallel == true`（即 `preserve_insertion_order = false` 且满足其余条件）时，`Combine()` 的 `!parallel` 条件不成立，不再快速返回，而是执行如下串行化合并——这正是"慢路径"的含义。`parallel == true` 的完整前置条件参见第四节：除 `preserve_insertion_order = false` 外，还要求线程数 > 1、无 `DO UPDATE` 子句、无 `RETURNING` 子句。

### 5.1 为什么串行

第 697 行的 `lock_guard<mutex> lock(gstate.lock)` 使所有线程的合并操作串行化执行。尽管各线程的 `Append` 阶段（在 `Sink()` 内）是完全并行的，但最终将线程本地 `RowGroupCollection` 归并进事务本地存储时，必须串行，原因有二：

1. `gstate.insert_count` 是共享计数器，需要互斥保护。
2. `storage.InitializeLocalAppend()` / `LocalAppend()` / `FinalizeLocalAppend()` 以及 `LocalMerge()` / `OptimisticWriter.Merge()` 均操作事务本地存储的共享数据结构，不支持并发写入。

### 5.2 慢路径的两个子分支

**小数据路径**（`append_count < row_group_size`，默认阈值 122880 行，由 `DataTable::GetRowGroupSize()` 返回）：

所有数据仍在内存中，尚未乐观刷盘。直接通过 `LocalAppend` 逐 Chunk 写入事务本地存储，开销较低，不需要合并 Row Group。

**大数据路径**（`append_count >= row_group_size`）：

该线程已通过 `OptimisticDataWriter` 乐观地将部分 Row Group 刷到磁盘。此时需要：

1. `WriteUnflushedRowGroups`：将尚未刷盘的末尾 Row Group 写出。
2. `FinalFlush`：完成所有乐观写入。
3. `LocalMerge`：将整个 `OptimisticCollection` 归并进事务本地存储。
4. `OptimisticWriter.Merge`：将本线程的 `OptimisticDataWriter` 合并入全局的 `OptimisticWriter`，以便事务提交时统一处理。

### 5.3 并行替代方案：PhysicalBatchInsert

在相同数据量和多线程环境下，若无 ON CONFLICT 子句且数据源支持批次索引，计划器会选择 `PhysicalBatchInsert`（见第六节）。`PhysicalBatchInsert` 通过以下机制避免 `Combine()` 的串行瓶颈：

- 每个线程只写独立的批次（`BatchIndex` 隔离），`Combine()` 仅将本批次注册到全局 `collections`，无需持有长时间锁。
- 真正的合并工作由后台 `MergeCollectionTask` 异步执行，与 `Sink()` 流水线化。
- 全局合并与刷盘推迟到 `Finalize()` 阶段统一完成（见 `BATCH_INSERT_DESIGN.md` §四）。

`PhysicalInsert` 并行路径的 `Combine()` 慢路径之所以存在，是因为它需要兼容 ON CONFLICT 子句和 RETURNING，而这些特性需要在写入时访问全局状态，无法实现批次级隔离。

---

## 六、计划器如何选择 PhysicalInsert vs PhysicalBatchInsert

计划入口为 `DuckCatalog::PlanInsert()`（`plan_insert.cpp:99`），核心决策逻辑如下：

```cpp
// plan_insert.cpp:102
bool parallel_streaming_insert = !PhysicalPlanGenerator::PreserveInsertionOrder(context, *plan);
bool use_batch_index           = PhysicalPlanGenerator::UseBatchIndex(context, *plan);

if (op.return_chunk)                        { parallel_streaming_insert = false; use_batch_index = false; }
if (action_type != THROW)                   { use_batch_index = false; }
if (action_type == UPDATE)                  { parallel_streaming_insert = false; }

if (use_batch_index && !parallel_streaming_insert) {
    // → PhysicalBatchInsert
} else {
    // → PhysicalInsert(parallel = parallel_streaming_insert && num_threads > 1)
}
```

### 6.1 PreserveInsertionOrder（`plan_insert.cpp:36`）

递归检查子计划树的顺序保证类型（`OrderPreservationRecursive`），结合配置 `preserve_insertion_order` 做出决策：

| `OrderPreservationType` | `PreserveInsertionOrder` 返回值 |
|------------------------|-------------------------------|
| `FIXED_ORDER`（如 ORDER BY、文件读取） | `true`（必须保序） |
| `NO_ORDER`（如 Hash Join 输出） | `false`（允许乱序） |
| `INSERTION_ORDER`（默认） | 取决于 `preserve_insertion_order` 配置（默认 `true`） |

### 6.2 UseBatchIndex（`plan_insert.cpp:58`）

满足以下全部条件时返回 `true`：

1. 线程数 > 1（单线程无意义）。
2. 子计划所有数据源均支持批次索引（`AllSourcesSupportBatchIndex()`），典型场景为读取多个 Parquet 或 CSV 文件的 `COPY` 操作。

### 6.3 决策矩阵

| `use_batch_index` | `parallel_streaming_insert` | 结果 | 备注 |
|-------------------|----------------------------|------|------|
| `true` | `false` | `PhysicalBatchInsert` | 多线程、有序源、无 ON CONFLICT → 批量写入最优路径 |
| `true` | `true` | `PhysicalInsert(parallel=true)` | `preserve_insertion_order=false` 时并行流式写入优先 |
| `false` | `true` | `PhysicalInsert(parallel=true)` | 源不支持批次索引，但允许乱序并行写入 |
| `false` | `false` | `PhysicalInsert(parallel=false)` | 单线程或必须保序且无批次索引 |

以及强制使用 `PhysicalInsert` 的情况：

- 含 `RETURNING` 子句（`return_chunk = true`）
- 含 `ON CONFLICT DO NOTHING` / `DO UPDATE` / `DO REPLACE`
- 单线程执行（`num_threads == 1`）

详细对比参见 `dev_docs/BATCH_INSERT_DESIGN.md` §六。

---

## 七、关键设计决策

`PhysicalInsert` 的并行路径（`parallel = true`）是一种"先并行写入、后串行合并"的折中方案。各线程在 `Sink()` 阶段完全并行地向各自的 `OptimisticCollection` 追加数据，充分利用多核写入能力；而 `Combine()` 阶段的串行化合并是不可避免的代价——事务本地存储不支持并发写入，且 `insert_count` 需要全局汇总。对于小数据量（< 1 个 Row Group），串行合并的开销可以忽略；对于大数据量，`Combine()` 的串行临界区会成为瓶颈，此时 `PhysicalBatchInsert` 是更好的选择。

`Finalize()` 的空实现是有意为之。`PhysicalInsert` 将数据归并的时机前移到 `Combine()` 而非 `Finalize()`，原因是 ON CONFLICT 处理和 RETURNING 子句都需要在每个 Chunk 被消费时立即处理，不存在需要推迟到全局收尾阶段的操作。这与 `PhysicalBatchInsert` 将大量工作推迟到 `Finalize()` 的策略不同，是两种算子适用场景差异的直接体现。

`InsertLocalState.collection_index` 的懒初始化（在首次 `Sink()` 调用时才分配 `OptimisticCollection`）确保了空写入线程不会占用不必要的存储资源，同时使 `Combine()` 中 `!lstate.collection_index.IsValid()` 的快速返回路径成为可能，减少了无数据线程的合并开销。
