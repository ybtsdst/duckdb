# Async Table Scan 执行模式分析

> 适用源码：`v2.0-cyanoptera` @ `c1cd2470a455`；核对日期：2026-10-23。核对方式：静态源码审查，未执行本文示例或性能测试。

## 概述：两个执行模式不等同两种并行度

普通 TableFunction 通过 [TableFunctionInput](../src/include/duckdb/function/table_function.hpp) 的 async_result 表达当前调用的进度，通过 results_execution_mode 判断能否返回 BLOCKED。框架实现见 [PhysicalTableScan::GetDataInternal / ValidateAsyncStrategyResult](../src/execution/operator/scan/physical_table_scan.cpp)。

SYNCHRONOUS 要求函数在本次调用内处理好其 I/O 任务，直到有数据或 EOF；TASK_EXECUTOR 允许函数显式交回进度或停放，等待以后继续。两者不决定 PipelineTask 数量，扫描并行度仍由 Source/Sink、中间算子能力和 MaxThreads 等控制。TASK_EXECUTOR 不保证一次 RowGroup 对应一次任务调度，也不保证调用线程不会阻塞。

## 一、输入与结果类型

[async_result.hpp](../src/include/duckdb/parallel/async_result.hpp) 声明两种模式：

| 模式 | 函数应如何处理待执行 I/O |
|---|---|
| SYNCHRONOUS | 不向普通扫描框架返回 BLOCKED；携任务结果可调用 ExecuteTasksSynchronously 就地执行，再恢复扫描 |
| TASK_EXECUTOR | 可把携任务结果上交框架；或登记自己的唤醒后以 taskless BLOCKED 停放 |

`TableFunctionInput` 默认 results_execution_mode 为 SYNCHRONOUS、async_result 为 INVALID。普通扫描调用前框架将 async_result 设为 IMPLICIT，并按 [PhysicalTableScanExecutionStrategy](../src/include/duckdb/execution/physical_table_scan_enum.hpp) 设置 mode：DEFAULT、TASK_EXECUTOR、TASK_EXECUTOR_BUT_FORCE_SYNC_CHECKS 映射 TASK_EXECUTOR；SYNCHRONOUS 映射 SYNCHRONOUS。FORCE_SYNC_CHECKS 虽然向实现者传 TASK_EXECUTOR，仍执行同步结果检查，是调试策略，不能当普通同步 mode 使用。

| AsyncResultType | 普通 TableFunction 中的含义 |
|---|---|
| INVALID | 尚未初始化或已消费的结果，不能作为正常返回 |
| IMPLICIT | 保留框架初值，非空 output → HAVE_MORE_OUTPUT，空 output → FINISHED |
| HAVE_MORE_OUTPUT | 本执行实例仍可继续；TASK_EXECUTOR 下本次可以没有输出 |
| FINISHED | 本执行实例不再取数；TASK_EXECUTOR 下可携最后一个非空块 |
| BLOCKED | 现在不能继续；本次 output 必须为空，唤醒后再调用 |

`AsyncResult` 支持 SourceResultType 的构造和赋值，也支持 AsyncResultType 的赋值；旧示例混用枚举不必然构成编译错误，但容易混淆 Source 边界与 TableFunction 边界。本文骨架显式使用 AsyncResultType，不假定 FINISHED 总能和非空块组合。

### 结果与块大小的校验

以下约束是 `ValidateAsyncStrategyResult` 的运行时异常检查：

| 策略 | 约束 |
|---|---|
| 所有策略 | 函数不得修改 results_execution_mode；调用前结果应为 IMPLICIT |
| SYNCHRONOUS、TASK_EXECUTOR_BUT_FORCE_SYNC_CHECKS | 拒绝 INVALID 和 BLOCKED；FINISHED 必须空块；HAVE_MORE_OUTPUT 必须非空块 |
| DEFAULT、TASK_EXECUTOR | BLOCKED 必须空块；允许空 HAVE_MORE_OUTPUT 和带最终数据的 FINISHED |

INVALID 在异步策略下没有被这个校验函数直接拒绝，但结果随后交给 AsyncResult::GetSourceResultType 时会抛出异常；GetResultType 自身还含 D_ASSERT。不能把断言或某一处校验列成覆盖所有滥用方式的运行保证。

## 二、最小同步函数与协作进度骨架

以下为**简化骨架/伪代码**，Reader、状态类型和输出填充均未定义，未编译运行。

### 2.1 无异步需求

```cpp
void Scan(ClientContext &context, TableFunctionInput &data, DataChunk &output) {
    auto &local = data.local_state->Cast<MyLocalState>();
    if (local.done) {
        return; // 保留 IMPLICIT；空块表示 EOF
    }
    ReadNextChunk(context, local, output); // 必须读到真实输出或确认真正 EOF
    // 返回最后一个非空块时仍可保持 IMPLICIT，下一次返回空块结束。
}
```

这里不能无条件在“刚填完最后一个块”时设置 FINISHED：同步策略会拒绝 FINISHED + 非空块。暂时未产生输出也不能直接返回 IMPLICIT + 空块，否则当前实例被提前终止。

### 2.2 能在无输出时交回进度

```text
Scan:
  loop:
    做一段扫描或过滤工作
    如果 output 非空: return（IMPLICIT）
    如果确认已耗尽: return（IMPLICIT + 空块）
    如果 mode == TASK_EXECUTOR:
      async_result = AsyncResultType::HAVE_MORE_OUTPUT
      return                     // 空块但尚未 EOF
    context.InterruptCheck()     // 同步路径继续前的协作检查
```

这种 return 只返回到 PipelineExecutor。它可能在剩余预算内立即再调 Source，直到预算耗尽才返回 TASK_NOT_FINISHED 并重新排队；不是函数每 return 一次就切换 worker。耗时 CPU 工作或阻塞调用内部仍可能长时间占用线程，中断只在检查点生效。

## 三、携任务的 BLOCKED

[TableFunctionInput::HandleBlocked](../src/function/table_function.cpp) 封装了模式分支。建议调用者明确保留跨调用的阶段，而不是每次进来都重新发起同一项 I/O。以下为未编译的伪代码：

```text
Scan:
  if phase == NEED_IO:
    tasks = PrepareIOAndPersistResumeState(local)
    phase = DECODE                 // 先保存恢复阶段
    result = AsyncResult::FromTasks(move(tasks), TaskSchedulerType::ASYNC)
    if result.GetResultType() == BLOCKED:
      if data.HandleBlocked(result): return
      // SYNCHRONOUS：任务已就地执行，继续 DECODE
  if phase == DECODE:
    DecodePreparedData(local, output)
    设置下一个阶段；按 output/是否耗尽返回结果
```

HandleBlocked 在 TASK_EXECUTOR 中移动 blocked_result 到 data.async_result 并返回 true；框架看到携任务 BLOCKED 后，在支持回调且全局状态 CanBlock 时调用 ScheduleTasks，返回 SourceResultType::BLOCKED。若不能回调或已阻止阻塞，框架改为**就地执行任务并返回 HAVE_MORE_OUTPUT**，不是旧版本文档所写的丢弃任务/返回 FINISHED。

SYNCHRONOUS 中 HandleBlocked 调用 ExecuteTasksSynchronously，任务串行执行完后结果转为 HAVE_MORE_OUTPUT，函数应继续处理已准备的数据。框架不会先接受一个同步 BLOCKED 再替函数补救：ValidateAsyncStrategyResult 会先拒绝它，所以模式分支必须在函数内部做好。

AsyncResult 构造携任务结果要求非空任务列表；FromTasks 对空列表返回 HAVE_MORE_OUTPUT。若选择构造器，默认池是 REGULAR；内置扫描会显式选择 ASYNC，不能从“Async”类名推断池归属。任务执行后会调用完成通知，异常处理和取消见[内部协议](ASYNC_TABLE_SCAN_PROTOCOL_INTERNALS.md)。

## 四、不携任务的停放与读前预取

2.0 的 TableFunctionInput 已有可选 interrupt_state。普通扫描在调用者 `CanCallback()` 时注入它。实现者可先把回调副本登记到自己的完成对象，再赋值 `data.async_result = AsyncResultType::BLOCKED`；此时 HasTasks 为 false。框架直接返回 SourceResultType::BLOCKED，不会替它创建任务、登记唤醒或再次检查 CanBlock。

实际用法见 [ReadAheadJobCompletion::TryPark(TableFunctionInput &)](../src/parallel/scan_read_ahead.cpp)：

1. 先要求 TASK_EXECUTOR 且 interrupt_state 非空。
2. 在 parked_scan.lock 下检查 pending_io_tasks；为零则不阻塞。
3. 仍有 I/O 时把 InterruptState 登记到 parked_scan，随后设置 taskless BLOCKED。
4. I/O 的最后一次 FinishIOTask 在同一锁下 UnblockTasks，触发已登记回调。

共享锁中的检查/登记配合完成端锁，避免“刚检查有工作、完成通知却已发出、随后永远等不到唤醒”。不可保留 TableFunctionInput 或其临时指针供以后解引用；完成状态应持有 InterruptState 的安全副本，以及它需要的资源。

SYNCHRONOUS 或没有可回调状态时，此路径不停放，ScanReadAhead 通过 WaitForJob/WaitForIO 同步等待并可主动执行排队 I/O。taskless BLOCKED 不能交给 ExecuteTasksSynchronously：没有任务时该方法会抛异常。

## 五、内置表扫描的实际工作粒度

[DuckTableScanState](../src/function/table/table_scan.cpp) 当前包含以下不同路径：

| 路径 | 关键方法 | 实际行为 |
|---|---|---|
| 普通持久化读取 | ScanPersistentStorage | PrepareScanIO → ASYNC tasks → HandleBlocked → ProcessPreparedScan；全过滤 vector 检查中断后继续 |
| 无读前预取的范围推进 | ClaimAssignment、TableScanFunc | 领取 NextParallelScan 的 optional_idx 范围；范围耗尽后 TASK_EXECUTOR 可空 HAVE_MORE_OUTPUT 返回，同步模式继续 |
| 读前预取 | ProduceJob、ScanWithReadAhead | 提前领取范围和 I/O，领取 job 后可 taskless park；job 耗尽释放 pins 并回收 scan state |
| 创建索引扫描 | TableScanFunc 的 is_create_index 分支 | 调用 CreateIndexScan，不应套用普通读取的全部异步路径 |
| 索引命中扫描 | DuckIndexScanState::TableScanFunc | rowid 批次 fetch，另处理事务本地尾段；空结果时 TASK_EXECUTOR 可返回显式 HAVE_MORE_OUTPUT |

读前预取还受 BlockManager Prefetch、async 线程数、read_ahead_depth、创建索引和 repeatable percentage sample 等条件限制，详见[并行扫描](PARALLEL_SCAN_DESIGN.md)。老文档围绕 rows_in_current_row_group 的旧循环已经不适用。

[MultiFileFunction](../src/include/duckdb/common/multi_file/multi_file_function.hpp) 的 `DecodeCurrentJob` 也使用 HandleBlocked，但保留内部 scan_chunk 的部分数据与 resuming_blocked_scan 标记；外层 BLOCKED output 仍为空。不要将“BLOCKED 要空输出”误读为要清空 reader 恢复需要的内部缓冲。

## 六、调度和性能边界

[TaskScheduler::ExecuteForever](../src/parallel/task_scheduler.cpp) 中有 REGULAR/ASYNC 两个池和队列，regular worker 也可消费 async 队列，async worker 只消费 async 队列；调用线程主动执行任务的路径也可能执行 I/O。AsyncTask::Execute 是同步方法，阻塞 I/O 会占用实际执行它的线程。

BLOCKED 的意义是让调用它的 PipelineTask 等待唤醒，而不是把所有 I/O 自动转换成内核非阻塞操作。分池、预取与解码重叠可能改变吞吐、延迟、内存和调度开销，取决于文件系统、数据与预算。本文没有依据静态分支宣称 TASK_EXECUTOR 必然更快、每个 RowGroup 一次调度，或同步模式只能用一个 worker。
