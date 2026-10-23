# PhysicalBatchInsert 设计文档

> 适用源码：`v2.0-cyanoptera` @ `c1cd2470a455`；核对日期：2026-10-23。核对方式：静态源码审查，未执行本文示例或性能测试。

## 概述

`PhysicalBatchInsert` 用 batch index 组织并行输入，按批次次序归并事务本地 collection，在需要保留输入顺序且源支持 batch index 时提供并行写入路径。它并不是“大数据必选”的算子，也不是 `SinkOrderDependent=false` 就“不保序”。普通插入路径见 [INSERT_EXECUTION_DESIGN.md](INSERT_EXECUTION_DESIGN.md)。

## 一、源码入口与适用条件

| 源码 | 主要符号 |
|---|---|
| [plan_insert.cpp](../src/execution/physical_plan/plan_insert.cpp) | `DuckCatalog::PlanInsert`、`UseBatchIndex`、`PreserveInsertionOrder` |
| [plan_create_table.cpp](../src/execution/physical_plan/plan_create_table.cpp) | `DuckCatalog::PlanCreateTableAs` |
| [physical_batch_insert.hpp](../src/include/duckdb/execution/operator/persistent/physical_batch_insert.hpp) | `PhysicalBatchInsert`、`RequiredPartitionInfo` |
| [physical_batch_insert.cpp](../src/execution/operator/persistent/physical_batch_insert.cpp) | 全局/本地状态、merge task、Sink/NextBatch/Combine/Finalize |
| [collection_merger.hpp](../src/include/duckdb/execution/operator/persistent/collection_merger.hpp) | 与 PhysicalInsert 共用的 `CollectionMerger` |
| [batch_memory_manager.hpp](../src/include/duckdb/execution/operator/persistent/batch_memory_manager.hpp) | 配额、阻塞与唤醒 |
| [batch_task_manager.hpp](../src/include/duckdb/execution/operator/persistent/batch_task_manager.hpp) | 合并任务队列 |

普通 INSERT 最终只有在 `use_batch_index && !parallel_streaming_insert` 时选择 batch。`use_batch_index` 要求线程数不为 1 且所有源支持 batch index；`parallel_streaming_insert` 初值为 `!PreserveInsertionOrder(child)`。RETURNING 禁用两个开关，任何非 THROW 的冲突动作禁用 batch，UPDATE 还禁用并行 streaming。REPLACE 在绑定时改写为 UPDATE。

CTAS 独立使用相同的顺序/batch 决策；文件导入是否落到该算子，应追踪实际绑定后的 INSERT 子计划，不能仅凭 COPY、CSV 或 Parquet 名称判断，更不能使用 `COPY <file> INTO <table>` 作为 DuckDB 语法依据。

## 二、状态与批次协议

`ParallelSink()` 为 true。`RequiredPartitionInfo()` 返回 `OperatorPartitionInfo::BatchIndex(preferred_batch_size)`：普通 INSERT 的 preferred size 来自目标表行组大小，CTAS 构造时用默认行组大小。实际合并阈值仍从创建后的表存储读取。

| 结构 | 作用 |
|---|---|
| `BatchInsertGlobalState` | 表、row_group_size、insert_count、`annotated_mutex lock`、有序 collections、next_start、memory/task manager、optimistically_written |
| `BatchInsertLocalState` | current_index、append state、collection_index、writer、constraint state |
| `RowGroupBatchEntry` | batch_idx、total_rows、unflushed_memory、collection_index、FLUSHED/NOT_FLUSHED |
| `MergeCollectionTask` | 持有一组待合并条目，在工作线程取任务时执行 |

批次不是固定绑定到线程的连续区间；线程可多次切换批次，唯一 batch index 只能登记一份 collection。`AddCollection` 用 lower_bound 插入有序向量，重复 batch index、低于 min batch index 均显式抛出内部错误。对外要求源与 Pipeline 正确遵守 batch 分区协议。

`FLUSHED` 也用于表示已调度合并的占位条目，此时 collection_index 暂时无效；不能将它一概解释成“磁盘上已经完整写好的结果”。任务完成才会替换结果索引。

## 三、执行流程

以下为控制流示意，并非源码逐行摘录：

```text
GetGlobalSinkState：CTAS 创建表 → 绑定索引 → 设置内存启发值
GetLocalSinkState：collection index 无效，按需创建

每个 local sink：
  Sink：内存/批次检查 → 验证约束 → Append → 可选预刷行组
  NextBatch：FinalizeAppend → AddCollection(writer) → 唤醒/消费任务
  UpdateMinBatchIndex：推进 memory manager 的下界
  ...
  Combine：登记最后 collection（不传 writer）→ 合并 writer → 唤醒

Finalize：按有序 collections 合并 / LocalAppend → LocalMerge / FinalFlush
Source：输出 insert_count
```

### 3.1 Sink 的内存与约束分支

非最小批次先更新 min batch index；若 `OutOfMemory`，执行队列中可用任务，然后在 memory manager 锁下再次确认自己是否仍不是最小批次，必要时返回 `BlockSink(input.interrupt_state)`。这里重查的是最小批次身份，不能改述成“再次检查内存必然已足够”。

按需创建 collection 后检查 `current_index == batch_index`，再懒初始化 `ConstraintState`、`VerifyAppendConstraints`。Append 返回有效行组索引时调用 `WriteNewRowGroup`。该算子仍检查约束，只是不实现 ON CONFLICT 的处理动作。

### 3.2 NextBatch 与 Combine

`NextBatch` 先结束上一批追加，并向 `AddCollection` 传 writer，允许注册时刷出大 collection 并调度任务。若没有唤醒其他任务，可由本线程消费任务。随后使本地 collection index 失效，记录新批次。

`Combine` 更新 min batch index、结束最后追加，只在 collection 非空时登记。此处不传 writer，因此不会通过该次 AddCollection 触发同样的调度；若本地 writer 存在，持全局锁合并进事务 writer。它不是“所有后台任务的统一执行点”。

### 3.3 Finalize

分支条件是 `optimistically_written || insert_count >= row_group_size`。

| 分支 | 行为 |
|---|---|
| 大量/曾乐观合并 | 连续 NOT_FLUSHED 合成 merger；FLUSHED 各自独立 merger；顺序调用 Flush，逐个 LocalMerge/reset，合并 writer 并 FinalFlush |
| 小量且未乐观合并 | 初始化 LocalAppend，按 batch 顺序扫描各 collection 追加并 reset，FinalizeLocalAppend |

两条路径都减少登记的未刷内存计数，最终 `FinalCheck()` 在非零时显式抛异常，并非仅调试断言。此处 Flush 循环在 Finalize 中顺序执行，不应称其为独立后台线程并行合并。

## 四、Row Group 合并策略

来源：`BatchInsertGlobalState::ReadyToMerge`。设 R 为目标表行组大小，下表保留整数除法的精确顺序：

| 条件 | 近似窗口 |
|---|---|
| `R / 10 * 9 <= count && count <= R` | 0.9R–R |
| `R / 10 * 18 <= count && count <= 2R` | 1.8R–2R |
| `R / 10 * 27 <= count && count <= 3R` | 2.7R–3R |
| `count >= R / 10 * 36` | 至少约 3.6R |

窗口间存在空档；整数舍入取决于 R。这是填充率启发式，并不保证每个输出行组满载，也没有“绝对偏差保持不变”的性质。

`ScheduleMergeTasks` 只考察不超过 min batch index 的安全前缀。遇 FLUSHED 边界时，已有非空小段也可直接调度，不要求一定满足 ReadyToMerge。调度将被合并区间压成占位记录，由工作线程通过 `ExecuteTask(s)` 调用 `MergeCollections`，再在锁下安装结果。队列机制不意味着存在专用后台线程。

`CollectionMerger::Flush` 把多个未刷 collection 顺序扫描追加到第一个 collection，释放其他 collection，结束追加并写出未刷行组；单个 FLUSHED collection 不再重新合并。该帮助类现在也服务于 PhysicalInsert 的剩余数据压实。

## 五、内存配额的真实边界

`GetGlobalSinkState` 用物理列数 × 4 MiB 估算每线程最低需求；`MaxThreads` 请求源线程数对应的内存，再按 reservation 限制线程数。`BatchMemoryManager::SetMemorySize` 将请求上限设为 `GetOperatorMemoryLimit()/4`，并由 TemporaryMemoryManager 决定实际 reservation；不足时可能尝试翻倍。

计数主要针对登记的 NOT_FLUSHED collection；这不是整个 INSERT 或整个进程的硬内存上限。最小批次可继续推进以避免调度停滞，所以不能宣称此机制保证不 OOM。

## 六、与 PhysicalInsert 的一致性对照

| 维度 | PhysicalBatchInsert | PhysicalInsert |
|---|---|---|
| 并行条件 | 能力声明支持并行，实际线程受源与配额约束 | 计划器设置 parallel |
| 顺序 | 以 batch index 顺序登记与归并 | 并行 streaming 不保留输入顺序 |
| ON CONFLICT / RETURNING | 计划器不选择此算子 | 根据动作选择串行/并行 |
| Combine | 登记最后批次、合并 writer | 大 collection 直接 merge，小 collection 延迟 |
| Finalize | 按 batch 的全局合并/追加 | 剩余小 collection 直接追加或通过事件并行压实 |
| 事务 | LocalStorage，提交另行完成 | 相同 |

预写数据块不改变其他事务的可见性，也不代表事务已经持久提交。提交、回滚和恢复边界见 [TRANSACTION_MVCC_DESIGN.md](TRANSACTION_MVCC_DESIGN.md) 与 [STARTUP_AND_CRASH_RECOVERY_DESIGN.md](STARTUP_AND_CRASH_RECOVERY_DESIGN.md)。本文未测量吞吐、锁竞争、碎片率或峰值内存。
