# DuckDB 并行 Scan 设计文档

> 适用源码：`v2.0-cyanoptera` @ `c1cd2470a455`；核对日期：2026-10-23。核对方式：静态源码审查，未执行本文示例或性能测试。

## 概述与入口

并行扫描依赖两层分工：Pipeline 决定可并发的执行实例数；具体 Source 在这些实例之间领取工作，并维护每个实例的扫描位置。内置表扫描、索引扫描、多文件扫描的工作粒度不同，不能统一描述成每线程固定一个 RowGroup。

| 层次 | 源码与关键符号 |
|---|---|
| 扫描任务数 | [pipeline.cpp](../src/parallel/pipeline.cpp)：`TryGetMaxThreads`、`ScheduleParallel`、`LaunchScanTasks` |
| 表函数适配 | [physical_table_scan.cpp](../src/execution/operator/scan/physical_table_scan.cpp)：`TableScanGlobalSourceState`、`TableScanLocalSourceState`、`GetDataInternal` |
| 扩展接口 | [table_function.hpp](../src/include/duckdb/function/table_function.hpp)：`GlobalTableFunctionState`、`TableFunctionInput` |
| 内置扫描 | [table_scan.cpp](../src/function/table/table_scan.cpp)：`DuckTableScanState`、`DuckIndexScanState`、`DuckTableScanInitGlobal` |
| 工作领取 | [data_table.cpp](../src/storage/data_table.cpp)：`MaxThreads`、`NextParallelScan`；[row_group_collection.cpp](../src/storage/table/row_group_collection.cpp)：`NextParallelScan` |
| 状态与预取 | [scan_state.hpp](../src/include/duckdb/storage/table/scan_state.hpp)：`ParallelCollectionScanState`、`ParallelTableScanState`；[scan_read_ahead.cpp](../src/parallel/scan_read_ahead.cpp)：`AcquireJob` |

## 一、Pipeline 的并行度上限

普通 Source 驱动的 Pipeline 在 `Pipeline::Schedule` 中初始化全局状态后，调用 `TryGetMaxThreads`：检查 Source/Sink/中间算子的并行能力，从 Source 的 MaxThreads 开始，叠加中间全局状态限制、regular 调度线程数和 Sink 全局状态限制。最终上限不超过 regular 线程数。Sink 需要批次索引时还检查 Source 的分区信息支持。

`LaunchScanTasks` 在上限大于 1 时创建多个 `PipelineTask`，否则回退到一个任务。它创建的是任务而非专属线程。任务因预算耗尽重新排队或阻塞唤醒后，可能迁移到不同 OS 线程。

`PhysicalTableScan::ParallelSource()` 在存在普通 `function` 时返回 true；只有 in-out 回调的 PhysicalTableScan 返回 false，因为此适配器的输入只有一行参数。这不表示所有关系输入的 in-out 算子都不能并行，后者使用 [physical_tableinout_function.cpp](../src/execution/operator/projection/physical_tableinout_function.cpp) 的独立实现。

`PhysicalTableScan::SourceParallelism()` 返回 `function.parallelism`，其枚举包括 SELF_MANAGED_PARALLELISM（默认）、SEQUENTIAL、FORCE_SINGLE_THREADED。它是能力声明，不能代替上述 `MaxThreads` 与 Pipeline 检查，亦不能仅据其名称推断实际线程数。

## 二、Global/Local 状态和空状态

普通路径中，`TableScanGlobalSourceState` 调用可选 `init_global`，取得状态并缓存其 `MaxThreads()`。无回调时最大线程数为 1，表函数 global_state 可以为空；有回调但返回空状态时内部初值仍为 0，最终扫描调度仍会回退单任务，不能把返回空指针用作跳过扫描的协议。

`PipelineTask` 懒构造 `PipelineExecutor`，随后由 `GetLocalSourceState` 调用可选 `init_local`。因此 local 初始化按执行实例发生，并可能彼此并发；不是 OS 线程启动时只调用一次。状态重建/复用还受重复执行和 Reset 机制影响。

**`init_local` 返回 nullptr 不会使框架跳过 `function`。** `TableScanLocalSourceState` 保存这个空指针，`GetDataInternal` 仍把它传入 `TableFunctionInput`。如果扫描回调需要 Cast 本地状态，必须返回一个有效的状态对象，并在其中标记无工作。状态确实可选的函数则可以自行处理空指针。

```text
多个 PipelineTask
  ├─ 各自 PipelineExecutor / LocalSourceState / LocalTableFunctionState
  └─ 共享 GlobalSourceState / GlobalTableFunctionState
         └─ 由扫描器使用锁、原子操作或其他同步方式分配工作
```

本地状态不会被多个正常 PipelineTask 同时共享，但可被同一任务先后在不同线程使用；异步 I/O 也可能访问它引用的数据。只有在没有这些并发访问时才可省略同步，不能把 local 理解成任意线程安全保证。bind_data 在执行回调中以 const 指针暴露，可变运行状态应放到 global/local 对象。

## 三、内置存储的工作领取

### 3.1 工作量与线程数估计

[DataTable::MaxThreads](../src/storage/data_table.cpp) 使用以下简化公式；代码骨架省略了事务本地数据获取细节，未编译运行：

```text
vector_count = verify_parallelism ? 1 : GetRowGroupSize() / STANDARD_VECTOR_SIZE
assignment_scale = STANDARD_VECTOR_SIZE * vector_count
total = 基表行数 + 当前事务 LocalStorage 行数
max_threads = total / assignment_scale + 1
```

`GetRowGroupSize()` 来自表的存储配置，不能把所有 RowGroup 固定写成 122880 行。verify_parallelism 模式下领取范围细化为一个 STANDARD_VECTOR_SIZE；此处是调试切分工作，不保证每次切分都发生 OS 线程切换。

### 3.2 ParallelCollectionScanState

当前状态保存 collection、共享 row_groups 树、current_row_group、vector_index、max_row、batch_index、原子 skipped_rows、可选 row_number_base、mutex、可选 reorderer 和 partitions_to_scan。旧文档的 `processed_rows` 字段已经不存在。

[RowGroupCollection::NextParallelScan](../src/storage/table/row_group_collection.cpp) 的返回值是 **optional_idx**：有效时表示领取范围的行数，无效时无更多工作。应以 `IsValid()` 判断，不是 bool/“rows == 0”接口。

其工作流为：

1. 共享 row-group 树到局部 CollectionScanState。
2. 在全局状态锁内选定下一个 RowGroup 或调试 vector 范围，推进全局指针并分配 batch index；可为可见行号预留范围。
3. 锁外调用 `InitializeScanInRowGroup`，由 `initialize_columns` 控制是否同时初始化列扫描。
4. 若该范围被过滤掉，给 skipped_rows 加上范围行数并继续领取；成功则返回 assignment_rows，耗尽则返回无效 optional_idx。

锁保护领取阶段；不能据此声称整个扫描完全无锁。列读取、缓冲管理和事务可见性有各自同步机制。

### 3.3 基表与事务本地数据

`ParallelTableScanState` 持有基表和事务 LocalStorage 两个 ParallelCollectionScanState。`DataTable::NextParallelScan` 先领取基表，耗尽后转到事务本地集合；需要行号时还传递基表行号基准。**事务本地集合也可并行扫描**，不可把它统称“最后由固定线程串行读取”。索引扫描的 LocalStorage 尾段则有自己的一名逻辑执行者，见后文。

头文件仍声明了 `ParallelTableScanState::checkpoint_lock`，但当前 `DataTable::InitializeParallelScan` 只初始化两个集合，本文核对的调用链没有给该字段赋值。因此不能凭字段注释断言每次普通扫描都持有该锁，更不能据此提出扩展的持锁规范；完整 checkpoint/MVCC 保活需沿事务和存储对象生命周期另行核对。

## 四、2.0 内置 TableScan 的扫描与 I/O

### 4.1 无读前预取时

[DuckTableScanState](../src/function/table/table_scan.cpp) 保存 ParallelTableScanState、存储列映射和过滤信息。本地状态保存 TableScanState、投影缓冲、当前 assignment 的进度。`InitLocalState` 在无 read_ahead 时通过 `ClaimAssignment` 领取初始范围。

`ScanPersistentStorage` 把一个持久化 vector 的工作分为：

```text
CollectionScanState::PrepareScanIO
   → AsyncResult::FromTasks(io_tasks, ASYNC)
   → 有任务时 TableFunctionInput::HandleBlocked
   → ProcessPreparedScan 解码已准备的 vector
   → 输出非空：返回；全过滤：NEXT_VECTOR 并检查中断
```

TASK_EXECUTOR 可以让有任务的 I/O 以 BLOCKED 上浮；SYNCHRONOUS 由 HandleBlocked 就地执行任务。恢复后沿已准备的扫描状态解码，不应重新登记同一批 I/O。持久化范围耗尽时 `storage.Scan` 还处理已领取的本地存储部分。整个范围没有输出后再 `ClaimAssignment` 领取下一个范围；TASK_EXECUTOR 可显式返回空的 HAVE_MORE_OUTPUT，SYNCHRONOUS 则内部继续直到输出或耗尽。

### 4.2 ScanReadAhead 路径

`DuckTableScanInitGlobal` 在非创建索引、非 repeatable percentage sample 时尝试创建 read-ahead；`CreateTableScanReadAhead` 还检查 BlockManager 的 Prefetch 能力，`ScanReadAhead::Create` 检查 async 线程数和 read_ahead_depth。存在 TASK_EXECUTOR 并不代表必定启用 read-ahead。

`ProduceJob` 从状态池取一个扫描状态，持 `read_ahead_lock` 领取范围并分配连续 job batch index，然后在锁外初始化列并登记 I/O。`ScanReadAhead` 调度提前的 I/O，`ScanWithReadAhead` 领取 job 并解码。若 I/O 未完成且可以回调，可登记唤醒并返回**不带任务列表的 BLOCKED**；恢复后 WaitForJob，继续同一个 job。

job 耗尽时累计进度、释放 pins，再把扫描状态放回池。领取范围、job 生产、I/O 任务、vector 解码、PipelineTask 调度是不同粒度；RowGroup 不是这些层次共同的调度单位。

### 4.3 索引与多文件不是同一粒度

`DuckIndexScanState::TableScanFunc` 对匹配 rowid 以 STANDARD_VECTOR_SIZE 批次领取基表 fetch 工作，再由一名逻辑执行者负责事务 LocalStorage 尾段；该执行实例仍可迁移 OS 线程。

[MultiFileFunction](../src/include/duckdb/common/multi_file/multi_file_function.hpp) 使用文件状态和 reader 定义的 job/scan state；`ProduceJob`、`AcquireNextPerThread`、`AcquireNextReadAhead` 和 `DecodeCurrentJob` 分离领取、I/O、解码，不能归纳为“多文件扫描只支持文件级并行”。

## 五、实现并行 TableFunction 的骨架

下面是同步扫描器的**伪代码**，省略绑定、reader 定义、类型适配和错误处理，未编译运行。`init_global`/`init_local` 在接口上都可选；需要共享分工和局部 reader 的实现才需要提供它们。

```text
GlobalState:
  files                         // 初始化后只读
  atomic next = 0
  MaxThreads() = max(1, files.size())  // 上限，并不预先创建线程

LocalState:
  reader = null
  exhausted = false

init_local:
  返回有效 LocalState；不要求此时就领取工作

function(data, output):
  loop:
    如果 reader 不存在:
      index = global.next.fetch_add(1)
      如果 index 越界: exhausted = true; return（IMPLICIT + 空块 = EOF）
      reader = open(files[index])
    reader.read(output)
    如果 output 非空: return（保持 IMPLICIT）
    reader = null               // 当前文件读完，继续领取，不伪装成 EOF
```

原子计数器可以分配不重叠工作，mutex 可以保护复杂共享队列，只读文件列表不需要每次读取都加锁。若显式返回空 HAVE_MORE_OUTPUT，必须遵守 TASK_EXECUTOR 的结果协议；SYNCHRONOUS 下该组合会抛异常。

仅在实现真正支持时设置 projection_pushdown、filter_pushdown、filter_prune。尤其 filter_pushdown 会把正确过滤的责任交给扫描器，忽略 filters 可能产生错误结果，不能指望框架再补一个同样的过滤算子。参见 [TableFunction 接口](TABLE_FUNCTION_DESIGN.md)。

## 六、C API 的状态获取边界

实现现位于 [src/main/capi/v1/table_function-c.cpp](../src/main/capi/v1/table_function-c.cpp)：`CTableFunctionInit`、`CTableFunctionLocalInit`、`CTableFunction`。C 端在 global init 中调用 `duckdb_init_set_max_threads`，缺省为 1。

`duckdb_init_get_bind_data(info)` **始终返回 bind data**，在 local init 中也不变；不能将它强转为 global init 分配的执行状态。实际扫描回调可分别用 `duckdb_function_get_init_data`、`duckdb_function_get_local_init_data` 取得 global/local init 数据。当前 local-init 包装器也没有把 C++ `gstate` 作为独立 C 参数传给用户回调，因此原先“local init 取 bind data 当 global queue”的示例已移除。需要共享分工时可在扫描回调取得 global init 数据后领取，并确保该数据并发安全。

## 七、EOF、顺序与验收边界

- IMPLICIT + 空块表示当前执行实例 EOF；暂时无输出但仍有工作时，不能沿用这个组合。
- 显式 FINISHED/HAVE_MORE_OUTPUT/BLOCKED 的合法块大小由当前 execution strategy 校验，详见[异步扫描](ASYNC_TABLE_SCAN_DESIGN.md)。
- 下游需要 batch index 时实现 get_partition_data，并保证索引与领取/输出顺序契合。PhysicalTableScan 的 SupportsPartitioning 当前只检查回调是否存在，源码仍留 FIXME，不能视为框架已经验证所有分区能力。
- MaxThreads 是上限；空数据源也应能以一个局部状态正确返回 EOF，不能依赖“零任务”阻止错误回调。
- 本文未运行并发、取消、过滤、顺序或性能测试；“可并行”的静态实现不等于运行时并行验收。
