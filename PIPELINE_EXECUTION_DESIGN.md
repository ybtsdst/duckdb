# DuckDB Pipeline 并行执行引擎设计文档

## 概述

本文档整理了 DuckDB `src/parallel` 目录下的核心代码，详细说明 Pipeline 并行执行引擎的架构设计，涵盖 Pipeline 构建、事件驱动调度、任务并行执行、中断机制等关键模块，为理解或扩展 DuckDB 执行引擎提供参考。

---

## 一、源码文件总览

### 实现文件（`src/parallel/`）

| 文件 | 核心类 | 职责说明 |
|------|--------|----------|
| `executor.cpp` | `Executor`, `ScheduleEventData` | 查询执行器入口，负责 Pipeline 构建与事件 DAG 调度 |
| `pipeline.cpp` | `Pipeline`, `PipelineTask`, `PipelineBuildState` | Pipeline 定义、并行度决策、任务调度 |
| `pipeline_executor.cpp` | `PipelineExecutor`, `ExecutionBudget` | 单个 Pipeline 实例的执行循环（核心执行引擎） |
| `meta_pipeline.cpp` | `MetaPipeline` | 将共享同一 Sink 的多条 Pipeline 分组管理 |
| `task_scheduler.cpp` | `TaskScheduler`, `ConcurrentQueue` | 线程池与任务队列管理 |
| `event.cpp` | `Event` | 事件 DAG 节点基类，管理依赖与完成通知 |
| `pipeline_event.cpp` | `PipelineEvent` | 触发 Pipeline 主体执行的事件 |
| `pipeline_initialize_event.cpp` | `PipelineInitializeEvent`, `PipelineInitializeTask` | Pipeline 初始化（重置 Sink 全局状态） |
| `pipeline_prepare_finish_event.cpp` | `PipelinePrepareFinishEvent`, `PipelinePreFinishTask` | 调用 `PrepareFinalize`（内存报告等） |
| `pipeline_finish_event.cpp` | `PipelineFinishEvent`, `PipelineFinishTask` | 调用 `Finalize`（生成最终结果） |
| `pipeline_complete_event.cpp` | `PipelineCompleteEvent` | 标记 Pipeline 执行完成，驱动后续 Pipeline |
| `base_pipeline_event.cpp` | `BasePipelineEvent` | Pipeline 相关事件的公共基类 |
| `executor_task.cpp` | `ExecutorTask` | 带 Executor 上下文的可执行任务基类 |
| `task_executor.cpp` | `TaskExecutor`, `BaseExecutorTask` | 辅助并行任务执行的工具类 |
| `interrupt.cpp` | `InterruptState`, `InterruptDoneSignalState` | 异步阻塞与回调机制 |
| `thread_context.cpp` | `ThreadContext` | 线程级状态（profiler、logger 等） |
| `task_notifier.cpp` | `TaskNotifier` | 任务状态变化的监听与通知 |

### 头文件（`src/include/duckdb/parallel/`）

与上述实现文件一一对应，另含 `task.hpp`（抽象任务基类）、`task_counter.hpp`（任务计数）、`concurrentqueue.hpp`（无锁队列第三方库封装）。

---

## 二、总体架构

DuckDB 采用 **推送式（Push-based）Pipeline 执行模型**，配合**事件驱动调度**实现查询的多线程并行执行。

```
物理查询计划 (PhysicalOperator 树)
        │
        ▼
Executor::Initialize()
        │  构建 MetaPipeline / Pipeline
        ▼
Executor::ScheduleEvents()
        │  生成事件 DAG
        ▼
TaskScheduler（线程池）
        │  任务出队执行
        ▼
PipelineExecutor（每线程一个）
   [Source → Operators → Sink]
```

**核心设计理念：**

1. **Pipeline-centric**：每条 Pipeline 表示一段可并行执行的数据流（`Source → 中间算子 → Sink`）
2. **MetaPipeline 分组**：将共享同一 Sink 的多条 Pipeline 归为一组，统一管理批次索引与依赖关系
3. **事件 DAG 协调**：使用五阶段事件链（Initialize → Execute → PrepareFinish → Finish → Complete）描述 Pipeline 的生命周期，并通过 DAG 表达 Pipeline 间的依赖
4. **基于任务的并行**：每条 Pipeline 并行执行时拆分为 N 个 `PipelineTask`，每个任务持有独立的 `PipelineExecutor`
5. **中断机制**：支持 Source/Sink 的异步阻塞，通过回调重新入队任务，实现非阻塞执行

---

## 三、Pipeline 核心结构

### 3.1 Pipeline 定义

`Pipeline`（`src/parallel/pipeline.hpp`）是执行的基本单元，代表一段从 Source 到 Sink 的数据流：

```cpp
class Pipeline {
    optional_ptr<PhysicalOperator> source;           // 数据源（TableScan 等）
    vector<reference<PhysicalOperator>> operators;   // 中间算子链（注意：构建时逆序，Ready() 后正序）
    optional_ptr<PhysicalOperator> sink;             // 数据汇（Aggregate、HashJoin 等）

    unique_ptr<GlobalSourceState> source_state;      // Source 的全局状态（跨线程共享）

    // 批次索引追踪（用于有序 Sink）
    idx_t base_batch_index;
    multiset<idx_t> batch_indexes;                   // 当前活跃批次索引集合
    mutex batch_lock;

    // Pipeline 依赖关系（DAG）
    vector<weak_ptr<Pipeline>> parents;              // 依赖本 Pipeline 的 Pipeline
    vector<weak_ptr<Pipeline>> dependencies;         // 本 Pipeline 依赖的 Pipeline
};
```

**关键方法：**

| 方法 | 说明 |
|------|------|
| `Schedule(event)` | 决定并行/串行执行并创建对应任务 |
| `ScheduleParallel(event)` | 检查所有算子是否支持并行，若支持则创建 N 个 `PipelineTask` |
| `ScheduleSequentialTask(event)` | 创建单个串行 `PipelineTask` |
| `LaunchScanTasks(event, n)` | 生成 N 个 `PipelineTask` 并交由事件调度 |
| `RegisterNewBatchIndex()` | 为新线程注册批次索引 |
| `UpdateBatchIndex(old, new)` | 更新批次索引（线程安全） |
| `ResetSink()` | 初始化 Sink 的全局状态（加锁保护，幂等） |
| `PrepareFinalize()` | 调用 Sink 的 `PrepareFinalize`（内存使用报告） |
| `Ready()` | Pipeline 就绪，将算子链逆序还原为正序 |

### 3.2 并行度决策

```cpp
bool Pipeline::ScheduleParallel(shared_ptr<Event> &event) {
    // 所有组件必须支持并行
    if (!sink->ParallelSink()) return false;
    if (!source->ParallelSource()) return false;
    for (auto &op : operators)
        if (!op.ParallelOperator()) return false;

    // 确定最大并行度
    auto max_threads = source_state->MaxThreads();              // Source 能提供的最大并行度
    max_threads = min(max_threads, scheduler.NumberOfThreads()); // 不超过线程池大小
    if (sink->sink_state)
        max_threads = sink->sink_state->MaxThreads(max_threads); // Sink 的并行上限

    return LaunchScanTasks(event, max_threads);
}
```

### 3.3 批次索引（Batch Index）

批次索引用于支持有序 Sink（如带 `ORDER BY` 的聚合），确保多线程处理结果可以按顺序合并：

- 每条 Pipeline 的 `base_batch_index = BATCH_INCREMENT × pipeline_count_in_metapipeline`
- 每个线程通过 `RegisterNewBatchIndex()` 获取一个批次索引槽
- 处理到下一批数据时调用 `UpdateBatchIndex()` 更新，Sink 通过最小批次索引判断哪些结果已就绪

---

## 四、PipelineExecutor：执行引擎核心

`PipelineExecutor`（`src/parallel/pipeline_executor.cpp`）是单个线程执行 Pipeline 的核心类，每个 `PipelineTask` 持有一个实例。

### 4.1 核心状态

```cpp
class PipelineExecutor {
    Pipeline &pipeline;
    ThreadContext thread;          // 线程级上下文（profiler 等）
    ExecutionContext context;      // 执行上下文

    // 中间数据块（每个算子一个缓冲）
    vector<unique_ptr<DataChunk>> intermediate_chunks;
    vector<unique_ptr<OperatorState>> intermediate_states;

    // Source/Sink 的线程本地状态
    unique_ptr<LocalSourceState> local_source_state;
    unique_ptr<LocalSinkState> local_sink_state;

    // 执行控制标志
    bool exhausted_source;         // Source 已耗尽
    bool started_flushing;         // 开始 Flush 阶段
    bool done_flushing;            // Flush 阶段完成
    bool remaining_sink_chunk;     // Sink 上次返回 BLOCKED，有待处理数据
    bool next_batch_blocked;       // NextBatch 调用被阻塞

    // 算子还有输出未处理的栈（HAVE_MORE_OUTPUT 场景）
    stack<idx_t> in_process_operators;
};
```

### 4.2 执行循环

```
Execute(max_chunks)
│
├─ 若 remaining_sink_chunk → 重试上次被阻塞的 Sink 写入
├─ 若 in_process_operators 非空 → 继续推送算子的剩余输出
├─ 若 source 未耗尽 → FetchFromSource() 获取新数据块
│      └─ 若需要批次追踪 → NextBatch()
│      └─ ExecutePushInternal()：逐算子推送直到 Sink
├─ 若 source 耗尽且未完成 Flush → TryFlushCachingOperators()
│      （触发有缓存算子的 FinalExecute）
└─ 所有数据处理完毕 → PushFinalize()
       （调用 Sink.Combine() 合并本地状态到全局状态）
```

**数据流向：**

```
source_chunk
    └→ intermediate_chunks[0]  (operator[0].Execute)
         └→ intermediate_chunks[1]  (operator[1].Execute)
              └→ ...
                   └→ final_chunk → sink.Sink()
```

### 4.3 算子返回值语义

| 返回值 | 含义 |
|--------|------|
| `NEED_MORE_INPUT` | 当前输入处理完，需要下一个数据块 |
| `HAVE_MORE_OUTPUT` | 算子还有输出未产出，不需要新输入（入栈 `in_process_operators`） |
| `BLOCKED` | 算子被阻塞（异步 I/O 等），任务暂停 |
| `FINISHED` | 算子执行完毕，Pipeline 可以结束 |

### 4.4 收尾阶段（PushFinalize）

```cpp
PipelineExecuteResult PipelineExecutor::PushFinalize() {
    // 将线程本地 Sink 状态合并到全局状态
    sink->Combine(context, {*sink->sink_state, *local_sink_state, interrupt_state});

    // 释放中间算子状态
    for (auto &state : intermediate_states)
        state->Finalize(...);

    executor.Flush(thread);  // 刷新 profiler 数据
    return FINISHED;
}
```

---

## 五、MetaPipeline：Pipeline 分组管理

`MetaPipeline`（`src/parallel/meta_pipeline.cpp`）将共享同一 Sink 的多条 Pipeline 组织在一起，是构建 Pipeline DAG 的核心。

### 5.1 结构定义

```cpp
class MetaPipeline {
    optional_ptr<PhysicalOperator> sink;                     // 共享的 Sink 算子
    MetaPipelineType type;                                    // REGULAR 或 JOIN_BUILD
    bool recursive_cte;                                       // 是否属于递归 CTE

    vector<shared_ptr<Pipeline>> pipelines;                  // 本 MetaPipeline 的所有 Pipeline
    reference_map_t<Pipeline, vector<reference<Pipeline>>>   // Pipeline 内部依赖
        pipeline_dependencies;

    vector<shared_ptr<MetaPipeline>> children;               // 子 MetaPipeline（Join Build 侧等）
    optional_ptr<Pipeline> parent;                           // 父 Pipeline
};
```

### 5.2 为什么需要 MetaPipeline

以 Hash Join 为例：

```
MetaPipeline (JOIN_BUILD)
  Sink: HashJoin
  ├── Pipeline[0] (Base): TableScan(b) → HashJoin (Build)
  └── Pipeline[1]: TableScan(a) → HashJoin (Probe)
```

- 构建侧（BUILD）必须全部完成才能开始探测侧（PROBE）
- 两侧共享同一 `HashJoin` Sink，需要在同一 MetaPipeline 中统一管理批次索引
- `AssignNextBatchIndex()` 为每条 Pipeline 分配不同的批次起点

### 5.3 Union Pipeline

```cpp
Pipeline &MetaPipeline::CreateUnionPipeline(Pipeline &current, bool order_matters) {
    // 创建与 current 相同算子链的新 Pipeline（继承 current 的所有依赖）
    // 若需要保序，则 union_pipeline 依赖 current
}
```

用于 `UNION ALL` 等操作：多条数据流汇入同一 Sink，可并行（不保序）或串行（保序）。

### 5.4 Child Pipeline

```cpp
void MetaPipeline::CreateChildPipeline(Pipeline &current, PhysicalOperator &op, Pipeline &last_pipeline) {
    // 为需要先完成的子计算（如 Join 的 Build 侧）创建单独 Pipeline
    // child_pipeline 必须在 current 完成后才能执行
}
```

---

## 六、事件驱动调度系统

### 6.1 事件类型

每条 Pipeline（准确说是 MetaPipeline 中的每条 Pipeline）会生成一个五阶段事件链：

```
PipelineInitializeEvent
    → PipelineEvent（主执行）
        → PipelinePrepareFinishEvent
            → PipelineFinishEvent
                → PipelineCompleteEvent
```

| 事件类型 | 任务类型 | 职责 |
|----------|----------|------|
| `PipelineInitializeEvent` | `PipelineInitializeTask`（1 个） | 调用 `pipeline->ResetSink()` 初始化全局 Sink 状态 |
| `PipelineEvent` | `PipelineTask`（N 个，并行） | 调用 `pipeline->Schedule()` 创建并行执行任务 |
| `PipelinePrepareFinishEvent` | `PipelinePreFinishTask`（1 个） | 调用 `pipeline->PrepareFinalize()` 报告内存用量 |
| `PipelineFinishEvent` | `PipelineFinishTask`（1 个） | 调用 `sink->Finalize()` 生成最终输出 |
| `PipelineCompleteEvent` | 无任务（纯标记） | 驱动后续依赖 Pipeline 的事件调度 |

### 6.2 事件 DAG 构建

`Executor::SchedulePipeline()` 为每条 Pipeline 创建五阶段事件并建立依赖关系：

```
基础 Pipeline 事件链：
Initialize → Event → PrepareFinish → Finish → Complete

MetaPipeline 内其他 Pipeline（Union、Child 等）：
• Union Pipeline：Event 在 base Initialize 之后，PrepareFinish 之前
• Child Pipeline（如 IEJoin 特殊情况）：Event 在 base Finish 之后，有独立的 Finish 事件
```

**跨 MetaPipeline 依赖（`ScheduleEventsInternal`）：**

```cpp
// Pipeline A 依赖 Pipeline B：A 的 Event 等待 B 的 Complete
entry.second.pipeline_event.AddDependency(dep_entry.pipeline_complete_event);

// 同级 Join Build Pipeline 的内存协调：
// 所有 Join Build 的 PrepareFinish 必须等待所有 Join Build 的 Event 完成
// 所有 Join Build 的 Finish 必须等待所有 Join Build 的 PrepareFinish 完成
child1.PrepareFinish.AddDependency(child2.Event);
child1.Finish.AddDependency(child2.PrepareFinish);
```

### 6.3 事件节点（Event 基类）

```cpp
class Event {
    atomic<idx_t> finished_tasks;       // 已完成任务数
    atomic<idx_t> total_tasks;          // 总任务数
    atomic<idx_t> finished_dependencies;// 已满足依赖数
    idx_t total_dependencies;           // 总依赖数
    vector<weak_ptr<Event>> parents;    // 本事件完成后需通知的父事件
};

// 依赖满足时调用
void Event::CompleteDependency() {
    if (++finished_dependencies == total_dependencies) {
        Schedule();   // 所有依赖满足，调度本事件
        if (total_tasks == 0) Finish();  // 无需任务，直接完成
    }
}

// 一个任务完成时调用
void Event::FinishTask() {
    if (++finished_tasks == total_tasks) Finish();
}

// 事件本身完成时通知所有父事件
void Event::Finish() {
    FinishEvent();  // 子类自定义逻辑
    finished = true;
    for (auto &parent : parents)
        parent->CompleteDependency();
    FinalizeFinish();  // 子类自定义收尾（PipelineCompleteEvent 在此触发 CompletePipeline）
}
```

---

## 七、TaskScheduler：线程池与任务队列

### 7.1 结构

```cpp
class TaskScheduler {
    unique_ptr<ConcurrentQueue> queue;            // 基于 moodycamel 的无锁并发队列
    vector<unique_ptr<SchedulerThread>> threads;  // 后台工作线程
    vector<unique_ptr<atomic<bool>>> markers;     // 各线程停止信号

    atomic<int32_t> requested_thread_count;       // 期望线程数
    atomic<int32_t> current_thread_count;         // 当前活跃线程数
};
```

### 7.2 任务队列实现

- **底层库**：[moodycamel ConcurrentQueue](https://github.com/cameron314/concurrentqueue)（无锁多生产者多消费者队列）
- **生产者令牌（ProducerToken）**：每个 `Executor` 持有一个，隔离不同查询的任务队列
- **消费者**：任意线程均可从任意生产者队列消费任务
- **唤醒机制**：轻量级信号量（`LightweightSemaphore`），线程空闲时 `wait()`，有任务时 `signal(N)`
- **批量入队**：`EnqueueBulk()` 减少入队开销

### 7.3 线程工作循环

```
ExecuteForever(stop_marker):
  while !stop_marker:
    semaphore.wait()
    if stop_marker: break
    task = queue.Dequeue()
    if task:
      result = task->Execute(PROCESS_PARTIAL)
      if result == TASK_NOT_FINISHED:
        queue.Enqueue(task)   // 未完成，重新入队
      elif result == TASK_BLOCKED:
        // 任务已调用 Deschedule()，等待外部回调 Reschedule()
      elif result == TASK_FINISHED:
        event->FinishTask()   // 通知事件
    else:
      // 队列暂时为空，刷新内存分配器
      allocator.Flush()
```

### 7.4 执行模式

| 模式 | 说明 |
|------|------|
| `PROCESS_PARTIAL` | 处理最多 `PARTIAL_CHUNK_COUNT`（50）个数据块后返回，允许任务重新入队实现公平调度 |
| `PROCESS_ALL` | 执行直到完成或阻塞 |

---

## 八、中断（Interrupt）机制

### 8.1 设计目的

允许 Source/Sink 的异步操作（如网络 I/O、云存储读取）在不阻塞工作线程的情况下暂停任务，待操作完成后重新调度。

### 8.2 InterruptState

```cpp
enum class InterruptMode {
    NO_INTERRUPTS,  // 不支持中断（同步模式）
    TASK,           // 任务模式：持有 Task 的弱引用，完成时调用 Reschedule()
    BLOCKING        // 阻塞模式：持有条件变量，完成时 Signal()
};

class InterruptState {
    InterruptMode mode;
    weak_ptr<Task> current_task;                     // TASK 模式
    weak_ptr<InterruptDoneSignalState> signal_state; // BLOCKING 模式

    void Callback() const {
        if (mode == TASK)     current_task->Reschedule();  // 重新入队任务
        if (mode == BLOCKING) signal_state->Signal();      // 唤醒等待线程
    }
};
```

### 8.3 执行流程

```
1. Source/Sink 发起异步操作，返回 BLOCKED（携带 InterruptState）
2. PipelineExecutor 返回 INTERRUPTED
3. PipelineTask 返回 TASK_BLOCKED
4. ExecutorTask::Deschedule() 将任务加入"待重调度"列表（不再入队）
5. 异步操作完成 → 调用 interrupt_state.Callback()
6. TASK 模式：task->Reschedule() → 重新入队 TaskScheduler
7. 任务再次执行时，PipelineExecutor 从上次暂停处继续（remaining_sink_chunk / next_batch_blocked 标志）
```

---

## 九、数据流与执行全流程

### 9.1 简单查询示例

```sql
SELECT SUM(amount) FROM sales WHERE region = 'US'
```

**Pipeline 结构：**
```
Source: TableScan(sales)
  → Filter(region='US')
  → Aggregate(SUM)  ← Sink
```

**执行步骤：**

```
1. Executor::Initialize(plan)
   ├── MetaPipeline::Build() 遍历物理计划树，构建 Pipeline
   └── MetaPipeline::Ready() 将算子链逆序

2. Executor::ScheduleEvents()
   └── 为 Pipeline 生成 5 个事件（Initialize/Event/PrepareFinish/Finish/Complete）

3. PipelineInitializeEvent 触发
   └── PipelineInitializeTask: pipeline->ResetSink() 创建 GlobalAggregateState

4. PipelineEvent 触发
   └── pipeline->ScheduleParallel() → 创建 N 个 PipelineTask（N = 可用线程数）

5. 每个 PipelineTask（并行）：
   loop:
     chunk = source.GetData(local_source_state)  // TableScan 分配行范围
     chunk = filter.Execute(chunk)
     aggregate.Sink(chunk, local_sink_state)      // 累积本地聚合结果
   end
   aggregate.Combine(global_state, local_state)  // 合并到全局状态

6. PipelinePrepareFinishEvent: aggregate.PrepareFinalize() 报告内存

7. PipelineFinishEvent:
   └── aggregate.Finalize() → 生成最终聚合结果，写入输出算子

8. PipelineCompleteEvent: Executor::CompletePipeline()
```

### 9.2 Join 查询示例

```sql
SELECT * FROM a JOIN b ON a.id = b.id
```

**MetaPipeline 结构：**
```
MetaPipeline (JOIN_BUILD, Sink=HashJoin)
  ├── Pipeline[0] Base:  TableScan(b) → HashJoin(Build)  ← 必须先完成
  └── Pipeline[1]:       TableScan(a) → HashJoin(Probe)  ← 依赖 Pipeline[0]
```

**事件依赖关系：**
```
Build_Initialize → Build_Event → Build_PrepareFinish → Build_Finish
                                                              ↓
Probe_Initialize → Probe_Event → Probe_PrepareFinish → Probe_Finish → Complete
```

---

## 十、关键数据结构汇总

### 状态层次结构

```
GlobalSourceState（Source 全局状态，跨线程共享，如文件列表分配）
└── LocalSourceState（每线程独立，如当前读取位置）

GlobalSinkState（Sink 全局状态，如全局哈希表、全局聚合结果）
└── LocalSinkState（每线程独立，如本地聚合累加器）

GlobalOperatorState（中间算子全局状态，可选）
└── OperatorState（中间算子线程本地状态）
```

### 线程安全机制

| 机制 | 用途 |
|------|------|
| `mutex` + `lock_guard` | Sink/Operator 全局状态初始化（`ResetSink`、`Reset`） |
| `atomic<idx_t>` | Event 任务计数、依赖计数 |
| `mutex batch_lock` | Pipeline 批次索引集合的并发访问 |
| `mutex producer_lock` | ConcurrentQueue 每个生产者的入队保护 |
| `LightweightSemaphore` | 工作线程的休眠与唤醒 |
| `condition_variable` | BLOCKING 模式中断的等待与通知 |
| `weak_ptr<Task>` | TASK 模式中断的任务引用（避免循环引用） |

---

## 十一、Pipeline 构建流程

`MetaPipeline::Build()` 通过递归调用 `PhysicalOperator::BuildPipelines()` 自顶向下遍历物理计划树：

```
PhysicalOperator::BuildPipelines(pipeline, meta_pipeline):
  if IsSource():
    pipeline.SetSource(this)
  if IsSink():
    // 创建子 MetaPipeline 处理所有输入
    for each child:
      child_meta = meta_pipeline.CreateChildMetaPipeline(pipeline, this)
      child_meta.Build(child)
  else:
    pipeline.AddOperator(this)
    for each child:
      child.BuildPipelines(pipeline, meta_pipeline)
```

`PipelineBuildState` 辅助管理构建过程，提供设置 Source、Sink、Operator 的接口，并通过 `BATCH_INCREMENT` 为每条 Pipeline 分配不重叠的批次索引空间。

---

## 十二、文件源码位置速查

| 概念 | 关键源文件 |
|------|-----------|
| 执行入口 | `src/execution/executor.cpp`, `src/parallel/executor.cpp` |
| Pipeline 构建 | `src/execution/physical_operator.cpp`, `src/parallel/meta_pipeline.cpp` |
| Pipeline 调度 | `src/parallel/pipeline.cpp` |
| Pipeline 执行循环 | `src/parallel/pipeline_executor.cpp` |
| 事件系统 | `src/parallel/event.cpp`, `src/parallel/pipeline_*_event.cpp` |
| 线程池 | `src/parallel/task_scheduler.cpp` |
| 中断机制 | `src/parallel/interrupt.cpp` |
| Source/Sink 接口 | `src/include/duckdb/execution/physical_operator.hpp` |
| 状态接口 | `src/include/duckdb/execution/operator/` 各算子目录 |
