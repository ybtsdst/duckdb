# DuckDB Pipeline 并行执行引擎设计文档

> 适用源码：`v2.0-cyanoptera` @ `c1cd2470a455`；核对日期：2026-10-23。核对方式：静态源码审查，未执行本文示例或性能测试。

## 概述与源码入口

Pipeline 将物理计划划分为可逐块执行的数据流，事件图描述初始化、执行及收尾之间的依赖，任务调度器分配实际执行线程。本文所有流程图和代码骨架均是解释用的简化表示，未编译运行；它们不替代具体算子的状态机。

| 概念 | 声明与实现，重点符号 |
|---|---|
| 查询协调 | [executor.hpp](../src/include/duckdb/execution/executor.hpp)、[executor.cpp](../src/parallel/executor.cpp)：`Executor::InitializeInternal`、`ScheduleEventsInternal`、`CancelTasks` |
| Pipeline | [pipeline.hpp](../src/include/duckdb/parallel/pipeline.hpp)、[pipeline.cpp](../src/parallel/pipeline.cpp)：`Pipeline`、`PipelineTask`、`PipelineBuildState` |
| 执行循环 | [pipeline_executor.hpp](../src/include/duckdb/parallel/pipeline_executor.hpp)、[pipeline_executor.cpp](../src/parallel/pipeline_executor.cpp)：`Execute`、`FlushAndFinalize`、`PushFinalize` |
| 分组与依赖图 | [meta_pipeline.cpp](../src/parallel/meta_pipeline.cpp)：`MetaPipeline`；[pipeline_schedule.cpp](../src/parallel/pipeline_schedule.cpp)：`BuildPipelineSchedule` |
| 事件 | [event.cpp](../src/parallel/event.cpp)：`Event::SetTasks`、`CompleteDependency`、`Finish` |
| 线程池与队列 | [task_scheduler.cpp](../src/parallel/task_scheduler.cpp)、[task_scheduler_queue.cpp](../src/parallel/task_scheduler_queue.cpp)、[task_scheduler_pool.cpp](../src/parallel/task_scheduler_pool.cpp) |
| 阻塞与错误 | [interrupt.hpp](../src/include/duckdb/parallel/interrupt.hpp)、[interrupt.cpp](../src/parallel/interrupt.cpp)、[executor_task.cpp](../src/parallel/executor_task.cpp) |

## 一、执行单元与线程归属

典型有 Sink 的 Pipeline 在一次执行中按 `Source → Operators → Sink` 处理 DataChunk：调用 Source 拉取一块，再把该块推过中间算子直至 Sink。`PipelineTask` 懒构造并持有自己的 `PipelineExecutor`，其中保存 LocalSourceState、LocalSinkState、中间 OperatorState、缓冲块及恢复位置。

这些本地状态属于执行实例，不能理解为固定 OS 线程的 TLS。任务因执行预算或 BLOCKED 暂停后可以由另一个线程继续执行，同一个 `PipelineExecutor` 和本地状态会保留。全局状态由多个执行实例共享；不同实例可并发调用算子，扩展中的共享可变数据需要同步。Global/Local 是配对状态类型，不存在 `GlobalSourceState` 继承出 `LocalSourceState` 的关系。

```text
Executor::InitializeInternal
  ├─ MetaPipeline::Build → PhysicalOperator::BuildPipelines
  ├─ PipelineBuildState::ResolveExternalInputs
  ├─ MetaPipeline::Ready → Pipeline::Ready（恢复算子顺序）
  └─ ScheduleEventsInternal
       └─ BuildPipelineSchedule → Event 图 → TaskScheduler
            └─ PipelineTask → PipelineExecutor
                 └─ Source.GetData → Operators.Execute → Sink.Sink
```

2.0 还支持外部输入 Pipeline。`Pipeline::Schedule` 对 `IsExternalInput()` 走 `ScheduleExternalInputEvent`，不创建普通扫描任务；数据通过 `PipelineExecutor::PushExternal` 等入口推进，结束时由生产侧调用完成逻辑。不能把“每条 Pipeline 必然有 N 个扫描任务”作为全局不变量。相关入口见 [pipeline.cpp](../src/parallel/pipeline.cpp) 的 `SetExternalInput`、`CompleteExternalInput`、`PipelineBuildState::ResolveExternalInputs` 和 [pipeline_executor.cpp](../src/parallel/pipeline_executor.cpp) 的外部输入方法；本文不展开完整广播交换协议。

## 二、并行度与状态初始化

普通扫描路径的 `Pipeline::Schedule` 先 `Reset()`，初始化/取得 Source、Sink 和中间算子的全局状态，再尝试 `ScheduleParallel()`。关键决策已经集中到 `Pipeline::TryGetMaxThreads`：

1. Sink 必须 `ParallelSink()`，Source 必须 `ParallelSource()`，所有中间算子必须 `ParallelOperator()`。
2. 从 Source 全局状态的 `MaxThreads()` 开始，应用存在的中间算子全局状态限制。
3. 受 `TaskScheduler::NumberOfThreads()` 的 regular 线程数约束，再应用 Sink 全局状态限制，最后再次限制到 regular 线程数。
4. Sink 需要 batch index 时，`ScheduleParallel` 还检查 Source 的 `SupportsPartitioning()`，不满足会抛出 `InternalException`。
5. `LaunchScanTasks` 仅在上限大于 1 时创建多个任务，否则回退到单个 `PipelineTask`。

因此任务数是执行上限，既不保证创建同等数量的新线程，也不保证所有任务同时运行。`NumberOfAsyncThreads()` 没有直接加入此处扫描并行度上限。

`ResetSink()` 在算子的锁内按需创建全局 Sink 状态；`ResetSource(false)` 复用已存在的 Source 状态。设置 `INITIALIZE_ON_SCHEDULE` 的表扫描由调度图记录，`ScheduleEventsInternal` 在启动事件前调用 `ResetSource(true)` 提前初始化。重复执行另有 `ResetForReschedule` 与显式 `SupportsReuse`/`Reset` 钩子，不能把全局初始化次数固定为对象生命周期内恰好一次。

## 三、MetaPipeline 与物理计划拆分

`MetaPipeline` 通常组织写入同一 Sink 的 Pipeline，并给它们分配批次索引范围。`CreateChildMetaPipeline` 默认向父 Pipeline 添加对子 MetaPipeline 完成的依赖；`CreateUnionPipeline` 复制算子链及依赖，保序时建立执行依赖；`CreateChildPipeline` 在同一组内创建后续执行路径，并设置组内依赖。这些操作的具体调用由物理算子的 `BuildPipelines` 决定。

Hash Join 的 Build 和 Probe 不应画成“同一 MetaPipeline 内共享 HashJoin Sink 的两条 Pipeline”。在 [physical_join.cpp](../src/execution/operator/join/physical_join.cpp) 的 `PhysicalJoin::BuildJoinPipelines` 中，Build 侧建立以 Join 为 Sink 的子 MetaPipeline，Probe 侧把 Join 加为父 Pipeline 的中间算子，再继续构建左子树。示意：

```text
子 MetaPipeline：TableScan(build) → HashJoin 的 Build Sink
                                    │ 完成依赖（含 Finalize）
父 Pipeline：   TableScan(probe) → HashJoin 的 Probe Operator → 下游 Sink
```

`UNION ALL` 等路径可以共享一个收尾链；一个物理算子也可能承担不同 Pipeline 中的 Source/Sink/Operator 角色。不要根据树上节点数推导任务或事件数量。

## 四、事件图与收尾链

[BuildPipelineSchedule](../src/parallel/pipeline_schedule.cpp) 先生成调度阶段，再由 `Executor::ScheduleEventsInternal` 创建实际 Event 并连边。基础链为：

```text
INITIALIZE → EXECUTE → PREPARE_FINISH → FINISH → COMPLETE
```

| 阶段与实现 | 职责 |
|---|---|
| [PipelineInitializeTask](../src/parallel/pipeline_initialize_event.cpp) | 普通路径 `ResetSink()`；外部输入路径 `PrepareExternalInput()` |
| [PipelineEvent](../src/parallel/pipeline_event.cpp) | 调用 `Pipeline::Schedule`，正常路径启动扫描任务 |
| [PipelinePreFinishTask](../src/parallel/pipeline_prepare_finish_event.cpp) | 调用 Sink 的 `PrepareFinalize`，算子可报告内存需求等 |
| [PipelineFinishTask](../src/parallel/pipeline_finish_event.cpp) | 对要求全局收尾的中间算子调用 `OperatorFinalize`，然后调用 Sink `Finalize`；二者均可 BLOCKED |
| [PipelineCompleteEvent](../src/parallel/pipeline_complete_event.cpp) | 向 Executor 报告 MetaPipeline 完成 |

并非每条 Pipeline 都独占五个事件。`AddMetaPipeline` 为基础 Pipeline 建完整链，其他 Pipeline 可共享 initialize/prepare/finish/complete，或者拥有独立 prepare/finish、加入 finish group。`Executor::InitializeInternal` 的完成计数按 MetaPipeline 设置。

跨 Pipeline 普通完成依赖指向依赖方的 COMPLETE；数据流依赖仅要求生产方 INITIALIZE 完成；组内依赖连接 EXECUTE 阶段。同一父 Pipeline 下的兄弟 JOIN_BUILD，还建立“所有执行完成后才能 PrepareFinalize、所有 PrepareFinalize 完成后才能 Finalize”的内存协调屏障。详见 `BuildPipelineSchedule`。

`Event::CompleteDependency` 在依赖计数满足后调度，`FinishTask` 在任务计数满足后完成事件，`Finish` 通知父事件。无任务时是否自动完成还受 `AutoFinishWithoutTasks()` 控制：外部输入的 `PipelineEvent` 特意返回 false，不能立即结束。`BuildPipelineSchedule` 的有环检查会抛出运行时异常；额外的 `VerifyScheduledEvents` DFS 属于调试校验。

## 五、PipelineExecutor 的可恢复状态机

[PipelineExecutor::Execute](../src/parallel/pipeline_executor.cpp) 的简化逻辑如下，省略了 profiler 和若干分区细节：

```text
先完成 pending_batch_advance_state（空批次推进/最小批次更新）
  → 若 remaining_sink_chunk，重试尚未被 Sink 接收的块
  → 若中间算子仍有 HAVE_MORE_OUTPUT，复用输入继续推送
  → 若 Pipeline 已耗尽，FlushAndFinalize
  → 否则 FetchFromSource，必要时 NextBatch，再推到 Sink
预算耗尽且仍有工作：NOT_FINISHED
需要外部唤醒：INTERRUPTED
Flush 和 Combine 完成：FINISHED
```

应区分各接口的结果类型，定义见 [operator_result_type.hpp](../src/include/duckdb/common/enums/operator_result_type.hpp)：

| 调用边界 | 结果与恢复要点 |
|---|---|
| Source `GetData` | `HAVE_MORE_OUTPUT`、`FINISHED`、`BLOCKED`；在本版本显式 HAVE_MORE_OUTPUT 可以携带空块；FINISHED 携带的最终非空块仍会推送 |
| 中间 `Execute` | `NEED_MORE_INPUT` 消费完本输入；`HAVE_MORE_OUTPUT` 入恢复栈；`FINISHED` 提前结束 Pipeline。枚举虽含 BLOCKED，头文件明确普通中间算子当前不应返回它，执行循环未提供通用中间算子阻塞恢复协议 |
| Sink `Sink` | BLOCKED 保留最终块重试；FINISHED 可提前停止上游，不等于 Source 自然 EOF |
| `NextBatch` / `UpdateMinBatchIndex` | 可以 BLOCKED；执行器保存批次推进阶段，恢复时不重新抓取当前块 |
| `FinalExecute` | 按 HAVE_MORE_OUTPUT/FINISHED 多轮刷新缓存；推送这些输出时仍可预算耗尽或被 Sink 阻塞 |
| Sink `Combine` | 合并本地状态到全局，可 BLOCKED；成功后才设置 `finalized` |

`TryFlushCachingOperators` 保留 `flushing_idx`、`should_flush_current_idx` 与恢复栈，防止重试时重复执行已经产出数据的 FinalExecute。`PushFinalize` 在 Combine 成功后通知 Source、结束局部 profiler、调用中间状态 Finalize 并刷新信息。它不是 Sink 全局 `Finalize`；后者属于事件链 FINISH 阶段。

### 批次索引

批次索引用于需要保序/分区信息的 Sink，不等同 SQL `ORDER BY` 的完整排序实现。`MetaPipeline::AssignNextBatchIndex` 分配不重叠的基础范围，`PipelineTask` 构造时可预留活跃索引，避免懒构造执行器让最小索引提前前进。`PipelineExecutor::ToPipelinePartitionData` 将 Source 索引映射为 `base + source_index + 1` 并检查范围，`NextBatch` 检查单调性并维护最小索引。

2.0 的 `SourceBatchIndexState::ADVANCED` 支持“未产出行但批次前进”的通知，`FetchFromSource` 连同 SourceResultType 保存它，后续经过 NextBatch 和 UpdateMinBatchIndex 两步。相关限制有的仅为 `D_ASSERT`（如 ADVANCED 对应 BLOCKED），不能写成所有构建都强制检查的运行保证。

## 六、TaskScheduler 的两个池与任务预算

[TaskScheduler](../src/include/duckdb/parallel/task_scheduler.hpp) 使用按 [TaskSchedulerType](../src/include/duckdb/common/enums/task_scheduler_type.hpp) 索引的 pools/queues 数组：REGULAR 和 ASYNC。每个池有独立队列与线程管理，`ProducerToken` 为每个队列持有独立底层 producer token，查询仍可用一个外层 token 做任务归属和 drain。

线程路由并非严格隔离：

- `ExecuteForever(REGULAR)` 顺序检查所有队列，regular worker 可以执行 async 队列任务。
- async worker 只消费自身队列。
- `GetTaskFromProducer`、`ExecuteTasks` 等调用线程协作路径也会检查多个队列。
- 未指定 pool 的 `ScheduleTask(s)` 默认 REGULAR；`AsyncResult` 自身默认也是 REGULAR，调用方可指定 ASYNC。

因此不能断言异步 I/O 永远只占 async worker，也不能继续把系统描述为单一队列/单一线程池。`AsyncTask::Execute()` 仍是普通同步调用，可阻塞实际执行它的线程。

`TryDequeueAndProcessTask` 根据 `SchedulerProcessPartialSetting` 选择 PROCESS_ALL 或 PROCESS_PARTIAL。后者使 PipelineTask 使用 `PARTIAL_CHUNK_COUNT`（50）的执行预算；预算限制的是执行循环工作量，且推送多输出也可消耗预算，不是精确墙钟时间片、50 个 RowGroup 或严格的源块计数。只有返回 TASK_NOT_FINISHED 时调度器立即重新入队；函数返回空的显式 HAVE_MORE_OUTPUT 并不直接产生一次任务重调度。

## 七、BLOCKED、异常、取消与生命周期

`PipelineTask` 将 INTERRUPTED 转换为 TASK_BLOCKED，保留执行器且不调用 `event->FinishTask()`。调度器随后调用 `ExecutorTask::Deschedule`，Executor 保持强引用。异步完成的 `InterruptState::Callback` 在 TASK 模式下锁定同一任务并 `Reschedule`，再次投入 REGULAR 队列；任务可以迁移线程。若 callback 早于 deschedule，`Executor::RescheduleTask` 循环取锁检查，直到任务登记，或者发现取消退出。这不是持有同一把锁不释放地等待。

BLOCKING 模式通过 `InterruptDoneSignalState` 的条件变量唤醒等待者；NO_INTERRUPTS 调用 Callback 会抛异常。weak_ptr 只保证已销毁任务的回调可成为 no-op，不保证异步任务引用的任意业务对象都安全。

`ExecutorTask::Execute` 捕获异常并 `Executor::PushError`，返回 TASK_ERROR。`CancelTasks` 标记取消、释放已停放任务，清理队列中的未执行任务，并等待已登记任务计数归零，之后才销毁 pipelines/events/states。不能把取消写成强制中断正在进行的阻塞 I/O；具体 I/O 的退出能力仍依赖实现。读前预取另有 `TaskExecutor`/`ScanReadAhead::CancelAndDrain` 生命周期，见[异步协议内部实现](ASYNC_TABLE_SCAN_PROTOCOL_INTERNALS.md)。

## 八、阅读与验证边界

本文描述冻结提交的静态控制流。并行是否生效还取决于物理计划、Source/Sink 能力、线程配置、数据分片与运行时阻塞；没有据此给出吞吐或延迟结论。进一步阅读：[并行扫描](PARALLEL_SCAN_DESIGN.md)、[TableFunction 接口](TABLE_FUNCTION_DESIGN.md)、[异步扫描](ASYNC_TABLE_SCAN_DESIGN.md)。
