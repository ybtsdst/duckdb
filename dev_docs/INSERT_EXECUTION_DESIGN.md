# PhysicalInsert 执行设计文档

> 适用源码：`v2.0-cyanoptera` @ `c1cd2470a455`；核对日期：2026-10-23。核对方式：静态源码审查，未执行本文示例或性能测试。

## 概述

`PhysicalInsert` 同时承接普通 INSERT 和部分 CTAS。它有串行追加、并行线程本地追加两条路径；当前实现还会在 `Finalize()` 中压实跨线程的小 collection，不能再把 Finalize 描述为空操作。批次索引路径见 [BATCH_INSERT_DESIGN.md](BATCH_INSERT_DESIGN.md)。

本文流程图都是省略异常与框架调度细节的控制流示意；行组大小来自目标表，不能固定等同于默认值 122880。算子完成也不等于事务提交或 WAL 已同步。

## 一、计划器的精确选择条件

来源：[plan_insert.cpp](../src/execution/physical_plan/plan_insert.cpp)，符号 `DuckCatalog::PlanInsert`、`PhysicalPlanGenerator::PreserveInsertionOrder`、`UseBatchIndex`。

先计算：

- `parallel_streaming_insert = !PreserveInsertionOrder(context, child_plan)`。
- `use_batch_index = UseBatchIndex(context, child_plan)`，要求调度器线程数不为 1，且 `AllSourcesSupportBatchIndex()` 为真。
- `RETURNING` 同时将上述两个开关置为 false。
- `action_type != THROW` 禁用 batch index；`action_type == UPDATE` 另禁用 parallel streaming。
- 旧计划仍可能带 `column_index_map`，由 `ResolveDefaultsProjection` 补默认值投影；源码明确将此字段标为旧版本兼容。

随后按最终开关选择：

| use_batch_index | parallel_streaming_insert | 构造结果 |
|---|---|---|
| true | false | `PhysicalBatchInsert` |
| true | true | `PhysicalInsert(parallel = num_threads > 1)` |
| false | true | `PhysicalInsert(parallel = num_threads > 1)` |
| false | false | `PhysicalInsert(parallel = false)` |

所以 batch insert 不是按估计行数或 SQL 名称直接选择的。单线程不会选择 batch，也不会启用并行 `PhysicalInsert`。`preserve_insertion_order=false` 不能覆盖源报告的 `FIXED_ORDER`。

顺序检查递归到 source，忽略物理 CTE 的第 0 个物化 child，按遍历遇到的首个非 `INSERTION_ORDER` 结果返回：`FIXED_ORDER` 强制保序，`NO_ORDER` 不保序，其余读取设置。不要把它简化为“只看全局设置”，也不要将某一种文件格式一概认定为固定顺序源。

`REPLACE` 只存在于 transform/bind 阶段，之后改写为 `UPDATE`，因此不能把 DO REPLACE 列为并行 NOTHING 路径。见 [insert_statement.hpp](../src/include/duckdb/parser/statement/insert_statement.hpp) 的 `OnConflictAction` 和 [bind_insert.cpp](../src/planner/binder/statement/bind_insert.cpp) 的 REPLACE 分支。

CTAS 有独立入口 [plan_create_table.cpp](../src/execution/physical_plan/plan_create_table.cpp)：`DuckCatalog::PlanCreateTableAs` 使用相同的顺序/batch 条件；是否真的进入 CTAS 路径还取决于已有表、REPLACE 和是否有查询 child。

## 二、状态与所有权

声明：[physical_insert.hpp](../src/include/duckdb/execution/operator/persistent/physical_insert.hpp)。

| 状态 | 关键内容 |
|---|---|
| `PhysicalInsert` | 目标表或 CTAS 的 schema/info、`parallel`、`return_chunk`、约束及冲突更新表达式 |
| `InsertGlobalState` | `lock`、`insert_count`、`return_collection`、`unmerged_collections` |
| `InsertLocalState` | collection 索引、append state、optimistic writer、约束状态、update/append chunk、delete state |
| 更新去重 | `unique_ptr<RowIdDeduplicator> updated_rows` 与 `update_count`，不再是旧版 `unordered_set<row_t>` |

[physical_insert.cpp](../src/execution/operator/persistent/physical_insert.cpp) 中 `GetGlobalSinkState` 为 CTAS 创建表；`InsertGlobalState` 构造时 `BindIndexes`。线程本地 collection 在首次并行 `Sink` 时创建，空线程无需分配。绑定索引是运行时数据结构绑定，不是“索引归当前事务独占”。

## 三、Sink：接收输入

来源：同文件 `PhysicalInsert::Sink`、`OnConflictHandling`、`HandleInsertConflicts`。

```text
串行 Sink
  Flatten
  OnConflictHandling
  累加新插入行数与受影响更新数
  有 RETURNING 则收集输出
  LocalAppend（THROW 路径可复用已做的约束检查）
  UPDATE 内部重复键产生的 update_chunk 再进入冲突处理

并行 Sink
  Flatten
  必要时在 gstate.lock 下创建本线程 optimistic collection/writer
  OnConflictHandling
  collection.Append
  若返回可刷出的 row-group index，WriteNewRowGroup
```

并行路径的 `!return_chunk`、`action_type != UPDATE` 有 `D_ASSERT`，受支持的组合主要由计划器阻止；断言本身不是 release 下的输入校验。线程拥有不同 collection 不代表整个 Sink 无锁：初始化、约束检查、索引访问和底层存储仍可能加锁。

`OnConflictHandling` 的 THROW 分支执行 `VerifyAppendConstraints`。NOTHING/UPDATE 会检查输入 chunk 内重复键，再分别处理全局与事务本地冲突；冲突目标、WHERE、SET、旧值 Fetch 都会影响处理结果。当前对“chunk 内重复键且带条件 DO UPDATE”的组合有显式 `NotImplementedException`，不能宣称冲突语义无条件完整支持。

## 四、Combine：大 collection 直接归并，小 collection 延迟

来源：[physical_insert.cpp](../src/execution/operator/persistent/physical_insert.cpp) 的 `PhysicalInsert::Combine`。

```text
Combine
  刷新 profiler
  非并行或 collection index 无效 → FINISHED
  collection.FinalizeAppend(TransactionData::Unversioned())
  append_count = collection.GetTotalRows()
  append_count >= table.row_group_size?
    是 → WriteUnflushedRowGroups + writer.FinalFlush（全局锁之前）
  持 gstate.lock
    insert_count += append_count
    小 collection → 只登记到 unmerged_collections
    大 collection → LocalMerge + 合并本线程 writer
```

修正点：小 collection 不在 Combine 中逐 chunk LocalAppend；大 collection 的预刷盘也不在全局临界区内。临界区仍串行维护共享状态和大 collection 的 LocalMerge，但不能据此断言其是测得的性能瓶颈。

这里的“大小”按每个线程 collection 判断。Finalize 的小总量条件则使用全局 `insert_count`，两者不是同一个阈值判断。

## 五、Finalize：跨线程剩余数据的压实

来源：同文件 `PhysicalInsert::Finalize`、`MergeCollectionsEvent`、`MergeCollectionsTask`，以及共享的 [collection_merger.hpp](../src/include/duckdb/execution/operator/persistent/collection_merger.hpp) 中 `CollectionMerger::Flush`。

| 条件 | 行为 |
|---|---|
| `unmerged_collections.empty()` | 直接 READY |
| 有剩余且 `insert_count < row_group_size` | 初始化一次 LocalAppend，扫描所有剩余 collection 逐 chunk 追加，reset collection，FinalizeLocalAppend |
| 有剩余且总量达到行组大小 | 将剩余 collection 累加分组，每组达到行组大小就关闭，尾组可不足；插入 `MergeCollectionsEvent` |

事件的 `Schedule()` 为每组创建独立 writer 与 `MergeCollectionsTask`，任务调用 `merger.Flush(writer)`。`FinishEvent()` 再顺序 LocalMerge、reset collection、合并各 writer，最后全局 writer FinalFlush。

```text
所有 local Combine
  → PhysicalInsert::Finalize
    → [小总量] 直接 LocalAppend
    → [大总量] event.InsertEvent(MergeCollectionsEvent)
                   Schedule: 多组 Flush 任务
                   FinishEvent: LocalMerge + writer 合并 + FinalFlush
  → 后续依赖事件 / Source
```

Finalize 返回 READY 不意味着插入的事件已经执行；事件依赖承担后续顺序约束。此实现与 batch insert 共用 CollectionMerger，但分组依据不同：这里按线程完成顺序收集剩余数据，batch 路径按 batch index 维护顺序。

## 六、Source、提交与可见性

`GetDataInternal` 在无 RETURNING 时输出 BIGINT 的 `insert_count`；有 RETURNING 时扫描 `return_collection`。更新结果的收集还涉及 `PerformOnConflictAction`，不能仅将 Sink 中追加的新行看作 RETURNING 的全部内容。

`LocalAppend` / `LocalMerge` 将结果交给事务本地存储；optimistic writer 可能预写数据块，但这既不单独发布 MVCC 可见性，也不等价于 COMMIT。参见 [local_storage.cpp](../src/storage/local_storage.cpp) 的 `LocalStorage::Flush/Commit/Rollback`、[TRANSACTION_MVCC_DESIGN.md](TRANSACTION_MVCC_DESIGN.md) 与 [STARTUP_AND_CRASH_RECOVERY_DESIGN.md](STARTUP_AND_CRASH_RECOVERY_DESIGN.md)。

## 七、阅读与性能边界

- `ParallelSink()` 返回 `parallel`，表示可并行 sink；`SinkOrderDependent()` 为 true，必须连同计划器的顺序约束理解。
- 不由数据量推荐强行切换算子；要先满足源 batch 能力、线程数、顺序与冲突处理限制。
- 本文没有给出可直接编译的 C++ 扩展样例，没有执行 SQL 或性能测试；并发收益、I/O 重叠和锁开销均需独立测量。
