# DuckDB 并行 Scan 设计文档

## 概述

本文档整理了 DuckDB 存储引擎并行 Scan 的设计原理，涵盖并行调度层、内置存储引擎的 RowGroup 级并行机制、以及扩展（Extension）实现并行 Table Function 的设计规范与注意事项，为编写支持并行扫描的插件提供参考。

---

## 一、相关源码文件

| 文件 | 说明 |
|------|------|
| `src/parallel/pipeline.cpp` | Pipeline 并行调度，决定线程数量与任务分发 |
| `src/execution/operator/scan/physical_table_scan.cpp` | PhysicalTableScan 的全局/本地状态初始化与数据获取 |
| `src/include/duckdb/execution/operator/scan/physical_table_scan.hpp` | PhysicalTableScan 头文件 |
| `src/include/duckdb/function/table_function.hpp` | TableFunction 所有回调接口声明 |
| `src/include/duckdb/storage/table/scan_state.hpp` | 扫描状态结构体：CollectionScanState、ParallelCollectionScanState 等 |
| `src/storage/table/row_group_collection.cpp` | RowGroupCollection 并行扫描核心逻辑 |
| `src/storage/data_table.cpp` | DataTable::MaxThreads / InitializeParallelScan / NextParallelScan |
| `src/function/table/table_scan.cpp` | 内置表扫描的 GlobalState / LocalState / ScanFunc 实现 |
| `src/function/table/arrow.cpp` | Arrow Scanner 并行实现参考 |
| `src/include/duckdb/common/multi_file/multi_file_states.hpp` | MultiFileGlobalState / MaxThreads 参考实现 |

---

## 二、并行执行总体架构

DuckDB 的并行 Scan 建立在 **Pipeline 执行模型**之上，通过 **全局/本地状态分离（Global/Local State）** 来实现多线程并发读取数据。

```
┌─────────────────────────────────────────────────────────────┐
│                      Pipeline 调度层                         │
│  Pipeline::ScheduleParallel()                               │
│    → source->ParallelSource()   // 是否支持并行             │
│    → source_state->MaxThreads() // 最大线程数               │
│    → LaunchScanTasks(N)         // 启动 N 个 PipelineTask    │
└──────────────────────────┬──────────────────────────────────┘
                           │ N 个并发线程
           ┌───────────────┼───────────────┐
           ▼               ▼               ▼
    ┌─────────────┐ ┌─────────────┐ ┌─────────────┐
    │ Thread 1    │ │ Thread 2    │ │ Thread N    │
    │ LocalState  │ │ LocalState  │ │ LocalState  │
    └──────┬──────┘ └──────┬──────┘ └──────┬──────┘
           │               │               │
           └───────────────┼───────────────┘
                           │ 原子领取任务（加锁）
                           ▼
                   ┌───────────────┐
                   │ GlobalState   │
                   │ 任务队列/指针  │
                   │ mutex 保护    │
                   └───────────────┘
```

**核心设计原则：**
- **全局状态（GlobalTableFunctionState）**：所有线程共享，存放"待读任务队列"（如哪些 RowGroup 还未被扫描），通过 mutex 保护并发访问。
- **本地状态（LocalTableFunctionState）**：每个工作线程独占，存放当前线程正在扫描的位置，无锁读取。

---

## 三、Pipeline 调度层

### 3.1 并行条件检查（`src/parallel/pipeline.cpp`）

```cpp
bool Pipeline::ScheduleParallel(shared_ptr<Event> &event) {
    // 1. Sink 必须支持并行
    if (!sink->ParallelSink()) return false;
    // 2. Source 必须支持并行
    if (!source->ParallelSource()) return false;
    // 3. 获取最大线程数（来自 GlobalSourceState::MaxThreads）
    auto max_threads = source_state->MaxThreads();
    // 4. 中间算子也必须支持并行
    for (auto &op : operators) {
        if (!op.ParallelOperator()) return false;
        max_threads = min(max_threads, op.op_state->MaxThreads(max_threads));
    }
    // 5. 不超过活跃线程数和 Sink 的约束
    max_threads = min(max_threads, scheduler.NumberOfThreads());
    max_threads = min(max_threads, sink->sink_state->MaxThreads(max_threads));
    return LaunchScanTasks(event, max_threads);
}
```

`PhysicalTableScan::ParallelSource()` 的逻辑：只要 `function.function` 不为空（普通 Table Function 而非 in-out function），即返回 `true`。

### 3.2 状态初始化

```
// 每个 pipeline 执行前调用一次（单线程）
PhysicalTableScan::GetGlobalSourceState()
  → function.init_global(context, input) → GlobalTableFunctionState
  → max_threads = global_state->MaxThreads()

// 每个工作线程独立调用
PhysicalTableScan::GetLocalSourceState()
  → function.init_local(context, input, global_state) → LocalTableFunctionState
```

### 3.3 数据获取

```
// 多线程并发调用
PhysicalTableScan::GetDataInternal()
  → function.function(context, {bind_data, local_state, global_state}, chunk)
```

---

## 四、内置存储引擎的并行 Scan

### 4.1 存储结构

```
DataTable
  └─ RowGroupCollection
       └─ RowGroupSegmentTree  (RowGroup 链表)
            └─ RowGroup[]      (每个 RowGroup 默认 122880 行)
                 └─ ColumnData[]
                      └─ ColumnSegment[]  (压缩数据块)
```

**并行的粒度是 RowGroup**：每个线程每次领取一个 RowGroup 进行扫描。

### 4.2 并行状态结构（`src/include/duckdb/storage/table/scan_state.hpp`）

```cpp
// 多线程共享的全局并行状态
struct ParallelCollectionScanState {
    RowGroupCollection *collection;
    shared_ptr<RowGroupSegmentTree> row_groups;
    optional_ptr<SegmentNode<RowGroup>> current_row_group; // 下一个待领取的 RowGroup 指针
    idx_t vector_index;          // verify_parallelism 模式下用于更细粒度切分
    idx_t max_row;
    idx_t batch_index;           // 单调递增，标记批次顺序（用于保序写入）
    atomic<idx_t> processed_rows;// 已处理行数（进度显示用）
    mutex lock;                  // 保护 current_row_group 的并发访问
};

// 包含持久化数据和事务本地数据两个并行状态
struct ParallelTableScanState {
    ParallelCollectionScanState scan_state;   // 持久化数据的并行状态
    ParallelCollectionScanState local_state;  // 事务本地数据的并行状态
    shared_ptr<CheckpointLock> checkpoint_lock; // 防止扫描期间 checkpoint
};
```

### 4.3 核心并行方法

**初始化**（`DataTable::InitializeParallelScan`）：
```cpp
void DataTable::InitializeParallelScan(ClientContext &context,
                                        ParallelTableScanState &state, ...) {
    row_groups->InitializeParallelScan(state.scan_state);    // 持久化数据
    local_storage.InitializeParallelScan(*this, state.local_state); // 事务本地
}

void RowGroupCollection::InitializeParallelScan(ParallelCollectionScanState &state) {
    state.collection = this;
    state.row_groups = GetRowGroups();
    state.current_row_group = state.GetRootSegment(*state.row_groups);
    state.max_row = base_row_id + total_rows;
    state.batch_index = 0;
    state.processed_rows = 0;
}
```

**领取下一个 RowGroup**（`RowGroupCollection::NextParallelScan`）：
```cpp
bool RowGroupCollection::NextParallelScan(ClientContext &context,
                                           ParallelCollectionScanState &state,
                                           CollectionScanState &scan_state) {
    while (true) {
        optional_ptr<SegmentNode<RowGroup>> row_group;
        {
            lock_guard<mutex> l(state.lock);  // 加锁领取工作单元
            if (!state.current_row_group) break; // 无更多数据

            row_group = state.current_row_group;
            state.processed_rows += row_group->GetNode().count;
            state.current_row_group = GetNextRowGroup(*state.row_groups, *row_group);
            scan_state.batch_index = ++state.batch_index;
        }
        // 临界区外执行初始化（无锁）
        bool need_to_scan = InitializeScanInRowGroup(context, scan_state, ..., *row_group, ...);
        if (need_to_scan) return true;
        // 统计信息可以过滤掉整个 RowGroup，则继续领取下一个
    }
    return false;
}
```

**最大线程数计算**（`DataTable::MaxThreads`）：
```cpp
idx_t DataTable::MaxThreads(ClientContext &context) const {
    idx_t row_group_size = GetRowGroupSize(); // 默认 122880
    idx_t parallel_scan_tuple_count = STANDARD_VECTOR_SIZE * (row_group_size / STANDARD_VECTOR_SIZE);
    return GetTotalRows() / parallel_scan_tuple_count + 1;
    // 近似等于 RowGroup 数量 + 1
}
```

### 4.4 内置 Scan 执行流（`src/function/table/table_scan.cpp`）

```
init_global (DuckTableScanState):
  → storage.InitializeParallelScan(state, column_indexes)
  → state.max_threads = storage.MaxThreads(context)

init_local (TableScanLocalState):
  → 将 ColumnIndex 转换为 StorageIndex
  → scan_state.Initialize(storage_ids, ...)
  → rows_in_current_row_group = storage.NextParallelScan(...)  // 领取第一个 RowGroup

function (DuckTableScanState::TableScanFunc):
  → storage.Scan(tx, output, l_state.scan_state)               // 扫描当前 RowGroup
  → if output.size() == 0:
      → storage.NextParallelScan(context, state, scan_state)   // 领取下一个 RowGroup
      → if rows == 0: return (所有数据已读完)
```

---

## 五、插件（Extension）实现并行 Scan

### 5.1 必须实现的回调函数

| 回调 | 必要性 | 说明 |
|------|--------|------|
| `bind` | 必须 | 绑定参数，返回列定义，创建 `FunctionData`（只读，bind 后不可修改） |
| `init_global` | **必须（支持并行）** | 创建全局状态，初始化任务队列，**重写 `MaxThreads()`** |
| `init_local` | **必须（支持并行）** | 每个线程调用一次，领取初始工作单元，创建线程本地扫描状态 |
| `function` | 必须 | 主扫描函数，无锁读取本地状态数据，通过全局状态领取新任务 |

### 5.2 代码框架（C++ 扩展）

```cpp
// ─── 1. 绑定数据（常量，bind 后不可修改） ───────────────────────────────
struct MyBindData : public FunctionData {
    vector<string> files;  // 数据源描述（例如文件列表）

    unique_ptr<FunctionData> Copy() const override {
        auto result = make_uniq<MyBindData>();
        result->files = files;
        return std::move(result);
    }
    bool Equals(const FunctionData &other) const override {
        auto &o = other.Cast<MyBindData>();
        return files == o.files;
    }
};

// ─── 2. 全局状态 —— 存放待扫描的任务队列，线程共享 ─────────────────────
struct MyGlobalState : public GlobalTableFunctionState {
    mutex lock;
    vector<string> files;
    atomic<idx_t> next_file_index {0};  // 原子计数器，保护并发领取

    idx_t MaxThreads() const override {
        // 返回最大并行线程数，通常等于数据分片数（文件数/分区数等）
        return files.size();
    }
};

// ─── 3. 本地状态 —— 每个线程独占，存放当前扫描位置 ─────────────────────
struct MyLocalState : public LocalTableFunctionState {
    idx_t file_index = DConstants::INVALID_INDEX;
    idx_t batch_index = 0;
    unique_ptr<MyFileReader> reader;  // 当前文件的读取句柄
};

// ─── 4. 全局初始化（pipeline 开始时调用一次）────────────────────────────
static unique_ptr<GlobalTableFunctionState> MyInitGlobal(
        ClientContext &context, TableFunctionInitInput &input) {
    auto &bind_data = input.bind_data->Cast<MyBindData>();
    auto state = make_uniq<MyGlobalState>();
    state->files = bind_data.files;
    return std::move(state);
}

// ─── 5. 本地初始化（每个线程调用一次）──────────────────────────────────
static unique_ptr<LocalTableFunctionState> MyInitLocal(
        ExecutionContext &context, TableFunctionInitInput &input,
        GlobalTableFunctionState *g_state) {
    auto &global = g_state->Cast<MyGlobalState>();
    auto local = make_uniq<MyLocalState>();

    // 领取第一个工作单元
    idx_t idx = global.next_file_index.fetch_add(1);
    if (idx < global.files.size()) {
        local->file_index = idx;
        local->reader = OpenFile(context.client, global.files[idx]);
        local->batch_index = idx;
    }
    // 如果没有工作可领取，返回 nullptr 或空状态均可（该线程不参与扫描）
    return std::move(local);
}

// ─── 6. 主扫描函数（多线程并发调用） ───────────────────────────────────
static void MyScanFunction(
        ClientContext &context, TableFunctionInput &data_p, DataChunk &output) {
    auto &global = data_p.global_state->Cast<MyGlobalState>();
    auto &local = data_p.local_state->Cast<MyLocalState>();

    while (true) {
        if (local.file_index == DConstants::INVALID_INDEX) {
            return; // 没有更多工作，返回空 chunk 表示结束
        }

        // 从本地 reader 读取数据（无锁）
        local.reader->ReadChunk(output);
        if (output.size() > 0) return;

        // 当前文件读完，领取下一个文件
        idx_t next = global.next_file_index.fetch_add(1);
        if (next >= global.files.size()) {
            local.file_index = DConstants::INVALID_INDEX;
            return; // 所有文件处理完毕，返回空 chunk
        }
        local.file_index = next;
        local.batch_index = next;
        local.reader = OpenFile(context, global.files[next]);
    }
}

// ─── 7. 注册 TableFunction ───────────────────────────────────────────
TableFunction CreateMyTableFunction() {
    TableFunction tf("my_scan", {LogicalType::VARCHAR},
                     MyScanFunction,
                     MyBindFunction,
                     MyInitGlobal,
                     MyInitLocal);
    tf.projection_pushdown = true;  // 启用列裁剪
    tf.filter_pushdown = true;      // 启用过滤下推
    return tf;
}
```

### 5.3 C API 实现并行 Scan

通过 C API（`duckdb.h`）开发的扩展，需在 `init` 回调中显式设置最大线程数：

```c
void my_init(duckdb_init_info info) {
    // 获取 bind 数据
    MyBindData *bind_data = (MyBindData *)duckdb_init_get_bind_data(info);

    // 关键：设置最大线程数，否则默认为 1（串行执行）
    duckdb_init_set_max_threads(info, bind_data->num_partitions);

    // 初始化全局状态
    MyGlobalState *state = malloc(sizeof(MyGlobalState));
    state->next_index = 0;
    duckdb_init_set_init_data(info, state, free);
}

// local_init 中领取工作单元
void my_local_init(duckdb_init_info info) {
    MyGlobalState *global = (MyGlobalState *)duckdb_init_get_bind_data(info);
    MyLocalState *local = malloc(sizeof(MyLocalState));
    // 原子领取
    local->file_index = atomic_fetch_add(&global->next_index, 1);
    duckdb_init_set_init_data(info, local, free);
}
```

---

## 六、注意事项与常见陷阱

### 6.1 线程安全
- **全局状态必须加锁**：`GlobalTableFunctionState` 会被多个线程并发访问，任何共享状态的读写都需要 mutex 保护。
- **本地状态无需加锁**：`LocalTableFunctionState` 每个线程独享，可直接读写。
- **bind_data 是只读的**：`FunctionData` 在 bind 后就不可修改；`function` 回调中获取到的是 `const FunctionData *`，不应绕过强转来写入。

### 6.2 MaxThreads 的返回值
- `MaxThreads()` 返回的是**建议**的最大线程数，调度器会取 `min(MaxThreads, active_threads)`。
- 返回 `GlobalTableFunctionState::MAX_THREADS`（= 999999999）表示"尽可能多的线程"。
- 建议返回实际**数据分片数**（文件数、分区数、RowGroup 数等），避免线程空转。

### 6.3 init_local 返回 nullptr
`init_local` 如果返回 `nullptr`，该线程不参与扫描（DuckDB 会跳过对该线程的 `function` 调用）。

### 6.4 空 DataChunk 代表结束
`function` 回调返回空 chunk（`output.size() == 0`）时，DuckDB 认为该线程的数据已全部返回。因此**不能**在还有数据时返回空 chunk，也不应该在数据读完之前返回非空 chunk 之后再多轮返回空 chunk（否则会导致提前结束）。

### 6.5 in-out function 不支持并行
`function.in_out_function` 类型的 Table Function（既有输入又有输出的流式算子），`PhysicalTableScan::ParallelSource()` 返回 `false`，不支持并行执行。只有普通 `function` 才能并行。

### 6.6 batch_index 与有序写入
- `batch_index` 是一个全局单调递增的整数，在并行扫描中由全局状态统一分配。
- 若下游 Sink 需要保序输出（如 `INSERT INTO ... SELECT ... ORDER BY` 或 Batch Insert），需要实现 `get_partition_data` 回调，返回本地线程的 `batch_index`，DuckDB 会据此还原 RowGroup 的原始顺序。

### 6.7 CheckpointLock（内置表扫描）
内置表扫描在执行期间持有 `CheckpointLock`，防止扫描进行中发生 checkpoint（否则数据页可能被回收）。自定义 Table Function 如需访问 DuckDB 持久化存储（而非外部数据），也应考虑类似的并发保护。

### 6.8 verify_parallelism 调试模式
开启 `SET verify_parallelism = true` 后，内置表扫描的调度粒度从 RowGroup 细化为单个 Vector（2048 行），强制触发更多线程切换，便于测试并行正确性。

### 6.9 MVCC 与事务本地数据
内置表扫描需要扫描两个状态：
- `scan_state.table_state`：已持久化/提交的数据（RowGroup Collection）。
- `scan_state.local_state`：当前事务本地未提交的写入（LocalStorage）。

自定义 Table Function 一般不涉及 MVCC，但若需要读取 DuckDB 内部事务数据，应通过 `DuckTransaction::Get(context, catalog)` 获取事务对象，并使用 `LocalStorage` 相关接口。

---

## 七、各类并行 Scan 模式对比

| 模式 | 实现位置 | 并行粒度 | 适用场景 |
|------|---------|---------|---------|
| 内置表扫描 | `src/function/table/table_scan.cpp` | RowGroup（默认 ~122k 行） | DuckDB 原生表 |
| Arrow Scanner | `src/function/table/arrow.cpp` | Arrow Chunk（每次 GetNextChunk） | Arrow IPC Stream |
| Multi-File Reader | `src/include/duckdb/common/multi_file/` | 文件级 | Parquet/CSV/JSON 多文件扫描 |
| Index Scan | `src/function/table/table_scan.cpp` | STANDARD_VECTOR_SIZE 批次 | 索引查找后的存储行获取 |
| 自定义扩展 | 扩展中实现 | 自定义（文件/分片/分区） | 外部存储系统、对象存储等 |

---

## 八、调用时序总结

```
SQL 执行
    │
    ▼
Planner → PhysicalTableScan 物理计划节点
    │
    ▼
Pipeline::ScheduleParallel()
  → GetGlobalSourceState()    // 单线程，调用 init_global
      → function.init_global(context, input)
      → MaxThreads() → 决定线程数 N
    │
    ▼ 启动 N 个 PipelineTask（并发）
    │
    ├─ Thread 1: GetLocalSourceState()
    │              → function.init_local(ctx, input, g_state)  // 领取第一个工作单元
    │            GetDataInternal() 循环调用直到返回空 chunk
    │              → function.function(ctx, {bind, local, global}, chunk)
    │
    ├─ Thread 2: 同上
    │
    └─ Thread N: 同上
    │
    ▼
所有线程完成 → Pipeline 结束
```
