# DuckDB 2.0 设计文档与源码审查索引

## 基线与阅读方式

本目录的25篇专题文档面向当前研究分支 `v2.0-cyanoptera`，源码核对基线为：

```text
c1cd2470a455635c6662029a2c44656f7b46ee61
```

核对日期：2026-10-23。此标识固定的是被分析的源码，不是以后文档提交的 HEAD，也不是对所有 DuckDB 2.0 发行版本的泛化保证。

审查方式为全文阅读文档并追踪当前声明、实现和调用方。正文区分源码事实、说明性骨架和有条件的机制推断；本轮没有编译扩展示例、执行 SQL/测试、启动服务或进行性能测量。源码摘录和伪代码均按各节说明阅读，不能把省略类型、状态或恢复处理的骨架直接当作完整实现。

文中源码链接优先指向仓库内的实际文件并给出符号名，避免依赖已漂移的行号。字段、条件和调用链与未来分支发生变化时，应重新核对。没有展开的机制和运行验证边界在各篇末尾注明。

## 文档清单与逐篇审查记录

以下列出全部25篇文档的修订重点及对应源码入口；验收范围见本页末尾。

### 执行与扫描框架（5篇）

| 文档 | 本轮重点修订 | 核心源码定位 |
|---|---|---|
| [Pipeline 执行](PIPELINE_EXECUTION_DESIGN.md) | REGULAR/ASYNC分池、事件依赖、执行预算、可恢复状态、外部输入、取消与任务归属 | [pipeline.cpp](../src/parallel/pipeline.cpp)：TryGetMaxThreads；[pipeline_schedule.cpp](../src/parallel/pipeline_schedule.cpp)：BuildPipelineSchedule；[task_scheduler.cpp](../src/parallel/task_scheduler.cpp)：ExecuteForever |
| [并行扫描](PARALLEL_SCAN_DESIGN.md) | 工作领取与optional_idx、基表/本地数据、I/O与解码分离、read-ahead、逻辑实例与线程区别 | [table_scan.cpp](../src/function/table/table_scan.cpp)：DuckTableScanState；[row_group_collection.cpp](../src/storage/table/row_group_collection.cpp)：NextParallelScan |
| [TableFunction 接口](TABLE_FUNCTION_DESIGN.md) | Base/Bound拆分、当前回调和默认值、初始化与重用、列映射、异步输入和接口边界 | [table_function.hpp](../src/include/duckdb/function/table_function.hpp)；[physical_table_scan.cpp](../src/execution/operator/scan/physical_table_scan.cpp)：GetDataInternal |
| [异步扫描](ASYNC_TABLE_SCAN_DESIGN.md) | mode与并行度分离、结果/块大小约束、合法结果类型转换、携任务与taskless BLOCKED | [async_result.hpp](../src/include/duckdb/parallel/async_result.hpp)；[table_function.cpp](../src/function/table_function.cpp)：HandleBlocked |
| [异步协议内部实现](ASYNC_TABLE_SCAN_PROTOCOL_INTERNALS.md) | 完成批次、唤醒顺序、错误发布、同步降级、辅助TaskExecutor及CancelAndDrain寿命 | [async_result.cpp](../src/parallel/async_result.cpp)；[scan_read_ahead.cpp](../src/parallel/scan_read_ahead.cpp)；[task_executor.cpp](../src/parallel/task_executor.cpp) |

### 表达式与查询优化（10篇）

| 文档 | 本轮重点修订 | 核心源码定位 |
|---|---|---|
| [表达式处理](EXPRESSION_DESIGN.md) | PEG解析、BoundFunctionExpression、列绑定解析、Execute/Select区别与下推责任 | [parser.cpp](../src/parser/parser.cpp)：ParseQuery；[execute_function.cpp](../src/execution/expression_executor/execute_function.cpp) |
| [LIKE 执行](LIKE_EXECUTION_ANALYSIS.md) | LIKE/ILIKE/ESCAPE改写条件、常量matcher、长needle线性回退、contains统计剪枝 | [like_optimizations.cpp](../src/optimizer/rule/like_optimizations.cpp)：Apply；[contains.cpp](../src/function/scalar/string/contains.cpp)：FindStrInStr/ContainsFilterPrune |
| [Filter 总论](FILTER_DESIGN.md) | 活动ExpressionFilter与LEGACY边界、单/多列集合、列索引空间、optional和动态状态 | [expression_filter.hpp](../src/include/duckdb/planner/filter/expression_filter.hpp)；[table_filter_set.cpp](../src/planner/table_filter_set.cpp) |
| [Filter 规划](FILTER_PUSHDOWN_DESIGN.md) | 精确/部分下推、残留谓词、能力检查、barrier/NULL/抛错边界和多列统计下推 | [pushdown_get.cpp](../src/optimizer/pushdown/pushdown_get.cpp)：PushdownGet；[filter_combiner.cpp](../src/optimizer/filter_combiner.cpp) |
| [Filter 执行](FILTER_EXECUTION_DESIGN.md) | row-group/segment统计、行级fast executor、选择向量、codec/updates回退和AdaptiveFilter | [row_group.cpp](../src/storage/table/row_group.cpp)：CheckZonemap/ProcessPreparedScan；[table_filter_state.cpp](../src/planner/table_filter_state.cpp) |
| [Filter 性能机制](FILTER_PERFORMANCE_DESIGN.md) | 剪枝/解码收益条件、selectivity暂停重试、TopN/Join候选裁剪，删除无依据的固定性能承诺 | [standard_column_data.cpp](../src/storage/table/standard_column_data.cpp)：Select；[table_filter_selectivity_optional_function.cpp](../src/planner/filter/table_filter_selectivity_optional_function.cpp) |
| [Projection 下推](PROJECTION_PUSHDOWN_DESIGN.md) | ColumnIndex路径、ProjectionIndex位置、projection_ids、filter_prune、物理回退与虚拟列 | [remove_unused_columns.cpp](../src/optimizer/remove_unused_columns.cpp)：RemoveColumnsFromLogicalGet；[plan_get.cpp](../src/execution/physical_plan/plan_get.cpp) |
| [Runtime Filter](RUNTIME_FILTER_DESIGN.md) | Join过滤器构建与发布、min/max/IN/Bloom/prefix-range、全局/分区边界、TopN可变句柄 | [physical_hash_join.cpp](../src/execution/operator/join/physical_hash_join.cpp)；[table_filter_functions.cpp](../src/planner/filter/table_filter_functions.cpp) |
| [延迟物化](LATE_MATERIALIZATION_DESIGN.md) | 优化器触发条件、行ID改写、两次扫描身份和次序、嵌套字段与多文件能力边界 | [late_materialization.cpp](../src/optimizer/late_materialization.cpp)；[table_scan.cpp](../src/function/table/table_scan.cpp) |
| [Join 执行](JOIN_EXECUTION_DESIGN.md) | 当前物理选择条件、Build/Probe/Source、连接类型保留语义、不同算法与外部执行边界 | [plan_comparison_join.cpp](../src/execution/physical_plan/plan_comparison_join.cpp)；[physical_join.cpp](../src/execution/operator/join/physical_join.cpp) |

### 写入、索引与事务存储（8篇）

| 文档 | 本轮重点修订 | 核心源码定位 |
|---|---|---|
| [Insert 执行](INSERT_EXECUTION_DESIGN.md) | 算子选择精确条件、冲突处理、大小collection分流与Finalize压实事件 | [plan_insert.cpp](../src/execution/physical_plan/plan_insert.cpp)；[physical_insert.cpp](../src/execution/operator/persistent/physical_insert.cpp)：Combine/Finalize |
| [Batch Insert](BATCH_INSERT_DESIGN.md) | batch协议、合并占位、精确阈值/安全前缀、内存阻塞、最终归并与提交边界 | [physical_batch_insert.cpp](../src/execution/operator/persistent/physical_batch_insert.cpp)；[collection_merger.hpp](../src/include/duckdb/execution/operator/persistent/collection_merger.hpp) |
| [ART 索引](ART_INDEX_DESIGN.md) | NodePtr与键编码、候选rowid/MVCC、排序构建、索引增量与存储版本条件 | [art.cpp](../src/execution/index/art/art.cpp)；[art_key.cpp](../src/execution/index/art/art_key.cpp)；[index_entry.cpp](../src/storage/index_entry.cpp) |
| [自定义索引](CUSTOM_INDEX_DESIGN.md) | 当前IndexType/BoundIndex签名、默认抛错行为、重复注册、恢复和delta接口，移除失效示例 | [index_type.hpp](../src/include/duckdb/execution/index/index_type.hpp)；[bound_index.cpp](../src/execution/index/bound_index.cpp) |
| [Catalog 事务](CATALOG_TRANSACTION_DESIGN.md) | SnapshotView、版本链、锁、Undo、提交依赖验证和内置/扩展Catalog边界 | [catalog_set.cpp](../src/catalog/catalog_set.cpp)；[catalog_transaction.cpp](../src/catalog/catalog_transaction.cpp) |
| [依赖管理](DEPENDENCY_MANAGER_DESIGN.md) | schema_path/table/OID身份、双向记录、ownership/ALTER_BLOCKING、提交竞态与排序 | [dependency_manager.cpp](../src/catalog/dependency_manager.cpp)；[dependency.hpp](../src/include/duckdb/catalog/dependency.hpp) |
| [事务与MVCC](TRANSACTION_MVCC_DESIGN.md) | 统一可见性边界、行版本与更新链、LocalStorage转移、WAL提交及失败回滚 | [transaction_data.hpp](../src/include/duckdb/transaction/transaction_data.hpp)；[duck_transaction.cpp](../src/transaction/duck_transaction.cpp)；[duck_transaction_manager.cpp](../src/transaction/duck_transaction_manager.cpp) |
| [启动与恢复](STARTUP_AND_CRASH_RECOVERY_DESIGN.md) | 当前头格式/版本条件、checkpoint/WAL状态、辅助WAL恢复、只读及故障边界 | [storage_manager.cpp](../src/storage/storage_manager.cpp)；[single_file_block_manager.cpp](../src/storage/single_file_block_manager.cpp)；[write_ahead_log.cpp](../src/storage/write_ahead_log.cpp) |

### 日志与性能观测（2篇）

| 文档 | 本轮重点修订 | 核心源码定位 |
|---|---|---|
| [Logging](LOGGING.md) | WARNING宏、库/CLI默认值、注册/配置、后端切换、基础函数与视图区别、结构化消息及失败行为 | [logger.hpp](../src/include/duckdb/logging/logger.hpp)；[log_manager.cpp](../src/logging/log_manager.cpp)；[logging_utils.cpp](../src/function/table/system/logging_utils.cpp) |
| [Profiling Metrics](PROFILING_METRICS.md) | 命名空间指标、tracked_metrics、分组/legacy输出、秒单位、累计时间和内存/I/O统计边界 | [metrics.json](../src/common/metrics.json)；[query_profiler.cpp](../src/main/query_profiler.cpp)；[gathered_metrics.cpp](../src/main/profiler/gathered_metrics.cpp) |

## 跨文档的共同约定

- Local执行状态归逻辑执行实例所有，任务恢复后可以迁移OS线程；异步访问的数据仍要处理同步和寿命。
- 能力标志表示实现必须承担的协议。接受精确下推后，不能假定上层还会补做同一个谓词。
- 统计剪枝、精确行级过滤、选择性解码、优化器延迟物化分别说明；剪枝不等于保证零物理I/O。
- operator完成、LocalStorage归并、事务发布、WAL同步和checkpoint是不同阶段。
- D_ASSERT/debug校验与运行时异常检查分别说明；类型已声明、描述符已注册、回调存在，不等于该路径已生效。
- 性能机制的存在不等于收益已实测；没有用本次静态审查替代编译、运行、并发或恢复验收。

## 静态验收记录

本轮完成25/25篇专题文档的全文审查与修订，并对日志、profiling、runtime filter、延迟物化的重点控制流进行了独立交叉复核。逐篇修订重点和源码依据见上表，各篇正文保留具体符号、条件和未展开的边界。

- 25篇正文均标注相同的源码基线、核对日期和静态审查范围。
- 全部26份Markdown（25篇正文与本索引）的代码围栏闭合、正文相对链接目标存在；本索引覆盖全部25篇。
- `git diff --check -- dev_docs` 无空白错误；新增索引另行检查行尾空白。
- 源码HEAD保持上述基线；原有 `.vscode/tasks.json` 修改的文件内容与本轮开始时一致。本轮仅修改 `dev_docs`，未提交或推送。

这些检查验证文档结构、引用目标和修改范围。它们不证明每个示例可以编译或运行，也不替代并发、恢复和性能验证；本轮未执行这些任务。

## 待独立核查的源码观察

- [日志文档](LOGGING.md)记录了 `FileLogStorage::SetPaths` 在“非 `.csv` 路径 + `normalize=false`”组合下设置LOG_ENTRIES路径、但后续使用ALL_LOGS的静态分支不一致。示例已使用显式 `.csv` 路径；未运行复现，也未修改源码。
- [延迟物化文档](LATE_MATERIALIZATION_DESIGN.md)限定了当前单列filter复制与复合rowid映射的说明范围。多列filter与两次扫描的交互、复合rowid经过不同Filter projection map的组合，仍需专门验证；本轮未将其定性为源码错误。
