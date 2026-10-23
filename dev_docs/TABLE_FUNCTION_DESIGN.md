# DuckDB TableFunction 接口设计文档

> 适用源码：`v2.0-cyanoptera` @ `c1cd2470a455`；核对日期：2026-10-23。核对方式：静态源码审查，未执行本文示例或性能测试。

## 概述与 2.0 对象模型

声明以 [table_function.hpp](../src/include/duckdb/function/table_function.hpp) 为准，实现见 [table_function.cpp](../src/function/table_function.cpp)。2.0 将接口拆分成：

- `BaseTableFunction`：回调与能力字段，供注册定义和绑定结果共享，不继承 Function。
- `TableFunction : BaseTableFunction, SimpleFunction`：注册到目录的名称、签名和行为。既有参数类型 vector/initializer_list 构造器，也有 FunctionSignature 构造器；名称类型为 Identifier。
- `BoundTableFunction : BaseTableFunction, BoundSimpleFunction`：一次绑定的行为副本、绑定参数类型、原始定义的 shared_ptr。`SetCallArguments` 保存调用参数布局，供序列化重选相同重载。

以下接口表是声明的摘要，不是独立可编译头文件。凡写成骨架的示例均未编译运行，不省略项不代表可在扩展中直接粘贴。

## 一、生命周期与线程边界

```text
绑定：选择重载 → bind_operator → bind_replace → bind（前者成功可提前返回）
    ↓
执行初始化：init_global → GlobalTableFunctionState
    ↓
每个执行实例：init_local → LocalTableFunctionState
    ↓
多次 function / in_out_function 调用，按各自结果协议推进
    ↓
局部状态、全局状态与 bind data 按计划/执行器生命周期销毁
```

实际绑定分支见 [Binder::BindTableFunction](../src/planner/binder/tableref/bind_table_function.cpp)。`bind_operator` 与 `bind_replace` 不受接口强制互斥：先尝试前者，返回空则可以尝试后者；二者都没有替换时才要求普通 bind。bind 本身可以返回空 FunctionData（无额外数据的函数合法），但仍须给出合法输出列定义。不能将“bind 回调可选”误解成任意 Source 省略 bind 就能自动推断 schema。

绑定、优化器及序列化/重新绑定可能重复处理函数，不能承诺“每条 SQL 生命周期内 bind 恰好一次”。初始化发生在执行或调度阶段，并非规划阶段；多个 Pipeline/重复执行还可能重建状态。

普通扫描的 `init_local` 按 PipelineExecutor 实例发生，可并发，实例后来也可能迁移 OS 线程。本地状态表示逻辑执行归属，不是永久线程 TLS。全局可变状态需采用适当的同步；原子操作、只读数据和锁各有适用场景，不能要求所有字段一律 mutex。异步任务引用的局部数据也需要单独管理并发和生命周期。

## 二、状态与输入结构

### 2.1 状态对象

| 类型 | 语义 |
|---|---|
| TableFunctionInfo | 注册时附加元数据，由 function_info shared_ptr 持有，经 bind input.info 传入；若跨绑定共享可变数据，实现者负责同步 |
| GlobalTableFunctionState | 本次执行的共享状态；虚方法 `idx_t MaxThreads() const` 默认返回 1，`MAX_THREADS` 常量是 999999999，表示请求尽可能多的线程，仍受 Pipeline 限制 |
| LocalTableFunctionState | 每个逻辑执行实例的状态；可存 reader、游标、缓冲和耗尽标记 |
| FunctionData | 绑定/优化配置。执行回调取得 const 指针；规划期仍有合法接收可变 FunctionData 的回调，不能笼统称“bind 返回后任何阶段都不可修改” |

`TableScanGlobalSourceState` 无 init_global 时不创建一个虚构的表函数空状态，而是 global_state 为空、max_threads=1。init_local 可选，返回空时扫描仍会被调用；需要 local_state 的回调必须自行保证非空。实现依据见 [physical_table_scan.cpp](../src/execution/operator/scan/physical_table_scan.cpp) 的两个状态包装器与 `GetDataInternal`。

### 2.2 TableFunctionBindInput

| 字段 | 当前类型/作用 |
|---|---|
| inputs | `vector<Value> &`，位置参数值 |
| named_parameters | `named_argument_map_t &`，命名参数 |
| input_table_types / input_table_names | `vector<LogicalType> &` / `vector<Identifier> &`，输入关系列 |
| info / binder | `optional_ptr<TableFunctionInfo>` / `optional_ptr<Binder>` |
| table_function | `BoundTableFunction &`，正在绑定的调用 |
| ref | `const TableFunctionRef &`，语法节点 |
| input_plan | `optional_ptr<unique_ptr<LogicalOperator>>`，可选关系输入计划 |
| multi_file_input | `optional_ptr<const TableFunctionFileBindInput>`，被多文件扫描包装时的单文件绑定上下文 |

### 2.3 TableFunctionInitInput

`bind_data` 为 optional_ptr<const FunctionData>；`column_ids` 是 vector<column_t>，`column_indexes` 是带子列路径的 vector<ColumnIndex>；两个构造器会从一种形式填充另一种。`projection_ids` 是 **const vector<idx_t> 值成员**；`filters`、`sample_options`、`op` 分别为可选 TableFilterSet、SampleOptions、const PhysicalOperator 指针；`multi_file_input` 提供单文件初始化上下文。

`CanRemoveFilterColumns()` 当 projection_ids 非空且数量少于扫描列数时为 true。扫描器承担 scan schema 到 output schema 的映射；设置 filter_prune 后不能继续原样返回所有过滤列。

### 2.4 TableFunctionInput 与异步协议

| 字段 | 类型与初始状态 |
|---|---|
| bind_data | `optional_ptr<const FunctionData>` |
| local_state / global_state | 可选 LocalTableFunctionState / GlobalTableFunctionState 指针 |
| async_result | AsyncResult，默认 INVALID；PhysicalTableScan 普通 function 调用前设 IMPLICIT |
| results_execution_mode | AsyncResultsExecutionMode，结构默认 SYNCHRONOUS，普通扫描调用前按 strategy 覆盖 |
| interrupt_state | `optional_ptr<const InterruptState>`，仅在调用者支持 Callback 时由普通扫描适配器注入 |

`bool HandleBlocked(AsyncResult &)` 在 TASK_EXECUTOR 下移动结果到本次 input.async_result 并返回 true，表示函数应立即返回；在 SYNCHRONOUS 下执行所带任务并返回 false，表示实现应继续原扫描。它不能给没有任务的自停放结果补出唤醒；taskless BLOCKED 必须由实现者预先登记唤醒，并检查当前模式和 interrupt_state。详见[异步扫描](ASYNC_TABLE_SCAN_DESIGN.md)与[内部协议](ASYNC_TABLE_SCAN_PROTOCOL_INTERNALS.md)。

## 三、绑定、初始化和扫描回调签名

下列是从头文件转写的签名摘要（省略形参名，不是源码逐字摘录）。`unique_ptr<T>` 的返回对象由框架持有。

| 字段（类型别名） | 返回值与参数 | 调用语义 |
|---|---|---|
| bind（table_function_bind_t） | `unique_ptr<FunctionData>(ClientContext &, TableFunctionBindInput &, vector<LogicalType> &, vector<Identifier> &)` | 决定输出 types/names 和绑定数据；两者列数需对应 |
| bind_replace（table_function_bind_replace_t） | `unique_ptr<TableRef>(ClientContext &, TableFunctionBindInput &)` | 以 TableRef 替换调用，空返回可回退 |
| bind_operator（table_function_bind_operator_t） | `unique_ptr<LogicalOperator>(ClientContext &, TableFunctionBindInput &, TableIndex, vector<Identifier> &)` | 自定义逻辑计划，根列绑定需使用传入 TableIndex |
| init_global（table_function_init_global_t） | `unique_ptr<GlobalTableFunctionState>(ClientContext &, TableFunctionInitInput &)` | 共享运行状态初始化 |
| init_local（table_function_init_local_t） | `unique_ptr<LocalTableFunctionState>(ExecutionContext &, TableFunctionInitInput &, GlobalTableFunctionState *)` | 逻辑执行实例初始化 |
| function（table_function_t） | `void(ClientContext &, TableFunctionInput &, DataChunk &)` | 普通 Source，填 output，状态通过 async_result 表达 |
| in_out_function（table_in_out_function_t） | `OperatorResultType(ExecutionContext &, TableFunctionInput &, DataChunk &, DataChunk &)` | 接受输入块和输出块；不自动成为 Pipeline Breaker |
| in_out_function_final（table_in_out_function_final_t） | `OperatorFinalizeResultType(ExecutionContext &, TableFunctionInput &, DataChunk &)` | 输入结束后刷新，可 HAVE_MORE_OUTPUT 多次，不能写成只调用一次 |

普通 Source 的 IMPLICIT 结果通过块大小判定：非空为 HAVE_MORE_OUTPUT，空为 FINISHED。TASK_EXECUTOR 下可显式返回空的 HAVE_MORE_OUTPUT，或者带最终非空块的 FINISHED；同步策略有更严格的块大小检查。SourceResultType 可以通过 AsyncResult 的构造/赋值转换，但自定义代码宜明确使用当前边界的类型。

in-out 有两个不同适配器，必须区分：

- [PhysicalTableScan::GetDataInternal](../src/execution/operator/scan/physical_table_scan.cpp) 可以把常量参数作为一行输入给 in_out_function；仅专门处理其 BLOCKED，其余结果仍主要按 chunk size 推进，源码留有 FIXME。该路径的 final 也不能抽象为全局仅一次。
- [PhysicalTableInOutFunction](../src/execution/operator/projection/physical_tableinout_function.cpp) 作为普通中间算子处理关系输入，支持直接输入块或按 projected_input 逐行调用；`FinalExecute` 转发 final 回调，并明确拒绝 projected_input 的该收尾路径。此适配器没有像普通 TableScan 那样注入 async mode/interrupt_state，不能复用 Source 异步协议作为通用中间算子阻塞承诺。

## 四、统计、优化和元数据回调

所有类型别名均在 [table_function.hpp](../src/include/duckdb/function/table_function.hpp) 声明，未设置的可选回调默认 nullptr。表中用 `fd` 表示形参名时，其类型仍完整写出。

| 字段 | 返回值与参数摘要 | 职责与边界 |
|---|---|---|
| statistics | `unique_ptr<BaseStatistics>(ClientContext &, const FunctionData *, column_t)` | 列统计，未知可空 |
| statistics_extended | `unique_ptr<BaseStatistics>(ClientContext &, TableFunctionGetStatisticsInput &)` | 使用完整 ColumnIndex 的统计；[StatisticsPropagator::PropagateStatistics](../src/optimizer/statistics/operator/propagate_get.cpp) 优先调用它 |
| cardinality | `unique_ptr<NodeStatistics>(ClientContext &, const FunctionData *)` | 行数估计，未知可空；不承诺所有估计都精确 |
| dependency | `void(LogicalDependencyList &, const FunctionData *)` | 记录逻辑/目录依赖；该回调本身不是任意外部资源的保活锁 |
| pushdown_complex_filter | `void(ClientContext &, LogicalGet &, FunctionData *, vector<unique_ptr<Expression>> &)` | 可消费表达式，剩余表达式仍后置过滤；并不强制要求 filter_pushdown 标志先置 true |
| pushdown_expression | `bool(ClientContext &, const LogicalGet &, Expression &)` | 判定能否作为 TableFilter 下推 |
| supports_pushdown_type | `bool(const FunctionData &, idx_t)` | 按列限制过滤下推能力 |
| supports_pushdown_extract | `bool(const FunctionData &, const LogicalIndex &)` | 控制嵌套字段投影提取支持 |
| projection_expression_pushdown | `bool(ClientContext &, const TableFunctionProjectionExpressionInput &)` | 扫描器接受 cast/函数投影表达式，成功返回 true；取代旧 type_pushdown 字段 |
| is_repeatable | `bool(optional_ptr<const FunctionData>)` | 同一查询中相同绑定数据重复执行是否稳定，缺失时保守视为未知 |
| to_string | `InsertionOrderPreservingMap<string>(TableFunctionToStringInput &)` | ParamsToString 用于 explain/profile 描述，不只在一次 EXPLAIN 中调用 |
| to_sql | `TableFunctionToSQLResult(ClientContext &, const LogicalGet &)` | 返回未投影 Source 的 TableRef，或 unsupported_reason；源码约定导出时不执行 Source、不产生副作用 |
| get_metrics | `void(TableFunctionGetMetricsInput &)` | 运行时指标；输入含 context、bind/local/global 状态及 OperatorMetrics 引用；替代旧 dynamic_to_string |
| table_scan_progress | `double(ClientContext &, const FunctionData *, const GlobalTableFunctionState *)` | 扫描百分比，负值在 PhysicalTableScan::GetProgress 中转为无效进度；共享读也需安全 |
| get_bind_info | `BindInfo(TableFunctionGetBindInfoInput &)` | 输入含 ClientContext & 与可变 bind_data；BindInfo 含 ScanType、options 和列/嵌套字段标识 |
| get_table_entry | `optional_ptr<TableCatalogEntry>(optional_ptr<const FunctionData>)` | 此调用扫描的目录表，供 LogicalGet 等定位 |
| get_multi_file_reader | `unique_ptr<MultiFileReader>(const BoundTableFunction &)` | 注入多文件发现/映射实现 |
| get_virtual_columns | `virtual_column_map_t(ClientContext &, optional_ptr<FunctionData>)` | 枚举按需可见虚拟列 |
| get_row_id_columns | `vector<column_t>(ClientContext &, optional_ptr<FunctionData>)` | 行标识列列表 |

过滤实现不能套用旧的多种常量 TableFilter 子类表：当前活动过滤使用 [ExpressionFilter](../src/include/duckdb/planner/filter/expression_filter.hpp)，[TableFilterSet](../src/include/duckdb/planner/table_filter_set.hpp) 独立保存过滤集合并支持多列过滤。复杂下推的实际调用见 [FilterPushdown::PushdownGet](../src/optimizer/pushdown/pushdown_get.cpp)；从表达式列表移除一个条件意味着扫描器负责正确应用它，遗漏会产生错误结果。

`TableFunctionProjectionExpressionInput` 含 `const LogicalGet &get`、`const Expression &expr`、ProjectionIndex column_index，后者是 get.GetColumnIds() 中的位置。当前 cast 分析见 [type_pushdown.cpp](../src/optimizer/type_pushdown.cpp)，实际回调调用见 [type_pushdown.hpp](../src/include/duckdb/optimizer/type_pushdown.hpp) 的 `PushdownOptimize`；不要继续写成向扫描器传 unordered_map<idx_t, LogicalType> 的旧接口。

其他回调的实际调用方包括：[plan_get.cpp](../src/execution/physical_plan/plan_get.cpp) 的物理 Get 规划调用 dependency、拆分不支持的过滤类型；[logical_operator_repeatability.cpp](../src/planner/logical_operator_repeatability.cpp) 的 LogicalGet 分支调用 is_repeatable；[table_function_sql_export.cpp](../src/planner/sql_export/table_function_sql_export.cpp) 的 ReconstructSQLSource 调用 to_sql；[query_profiler.cpp](../src/main/query_profiler.cpp) 的 OperatorProfiler::FinishSource 经 PhysicalTableScan::GetMetrics 调用 get_metrics；[table_function_multi_file.cpp](../src/common/multi_file/table_function_multi_file.cpp) 的单文件绑定路径读取 get_bind_info；[multi_file_reader.cpp](../src/common/multi_file/multi_file_reader.cpp) 的 MultiFileReader::Create 调用 get_multi_file_reader。行标识的实际消费还包括 [LateMaterialization](../src/optimizer/late_materialization.cpp) 的 row-id 获取，不能只解释成 UPDATE/DELETE。

### 分区与扫描顺序

| 字段 | 返回值与参数摘要 | 语义 |
|---|---|---|
| get_partition_data | `OperatorPartitionData(ClientContext &, TableFunctionGetPartitionInput &)` | 当前局部位置的 batch index / 分区值；input 含 bind/local/global 和 const OperatorPartitionInfo & |
| get_partition_info | `TablePartitionInfo(ClientContext &, TableFunctionPartitionInput &)` | 输出分区属性，input 含 bind data 和 partition_ids |
| get_partition_stats | `vector<PartitionStatistics>(ClientContext &, GetPartitionStatsInput &)` | 分区行偏移、数量和精确性；input 含 const BoundTableFunction & 与 const bind data |
| set_scan_order | `void(unique_ptr<RowGroupOrderOptions>, optional_ptr<FunctionData>)` | 设置行组扫描顺序 |
| set_partitions_to_scan | `void(vector<idx_t>, optional_ptr<FunctionData>)` | 按 get_partition_stats 顺序限制扫描分区 |

调用链可从 [LogicalGet::SetScanOrder / SetPartitionsToScan](../src/planner/operator/logical_get.cpp)、[partitioned_execution.cpp](../src/optimizer/partitioned_execution.cpp) 的分区统计调用继续追踪。不同回调报告不同层次的信息；存在 get_partition_data 仅使 PhysicalTableScan::SupportsPartitioning 当前返回 true，源码尚未完整验证所请求分区能力。

## 五、序列化与行为字段默认值

序列化回调当前使用 **BoundTableFunction**，签名摘要：

```cpp
// 签名摘要，未作为独立示例编译。
void serialize(Serializer &, const optional_ptr<FunctionData>, const BoundTableFunction &);
unique_ptr<FunctionData> deserialize(Deserializer &, BoundTableFunction &);
```

`BaseTableFunction::HasSerializationCallbacks()` 仅在二者都非空时为 true。需成对提供以支持专用 bind-data 序列化；未成对时不是这里自动抛异常。实际计划路径见 [LogicalGet::Serialize / Deserialize](../src/planner/operator/logical_get.cpp) 与 [FunctionSerializer](../src/include/duckdb/function/function_serialization.hpp)。有些调用保存参数供重新绑定，有些含进程本地绑定输入会拒绝序列化，不能承诺任何表函数都可跨进程复用。verify_serialization 默认 true 仅表示参与相关验证逻辑，不是生产环境自动验证所有序列化的保证。

| 字段 | 默认值 | 意义 |
|---|---|---|
| projection_pushdown | false | 支持按实际请求列扫描；否则由计划追加投影 |
| filter_pushdown | false | 承担下推 TableFilter 的过滤责任；开启却忽略 filters 可能返回错误结果 |
| filter_prune | false | 支持不输出仅用于过滤的列，需正确应用 projection_ids |
| sampling_pushdown | false | 承担下推采样语义 |
| late_materialization | false | 声明支持延迟物化相关规划 |
| verify_serialization | true | 序列化验证能力开关 |
| return_type | TABLE_RETURNING_FUNCTION | 另有 SET_RETURNING_FUNCTION |
| call_return_type | QUERY_RESULT | CALL 的结果类型；仅副作用调用可声明 NOTHING |
| order_preservation_type | INSERTION_ORDER | 输出保序能力，不能替代 SQL 全局排序 |
| global_initialization | INITIALIZE_ON_EXECUTE | 可改为 INITIALIZE_ON_SCHEDULE |
| parallelism | SELF_MANAGED_PARALLELISM | 另有 SEQUENTIAL、FORCE_SINGLE_THREADED；实际并行度仍由 Pipeline 能力和状态决定 |
| function_info | 空 shared_ptr | 共享注册元数据 |

`INITIALIZE_ON_SCHEDULE` 由 [BuildPipelineSchedule](../src/parallel/pipeline_schedule.cpp) 收集，`Executor::ScheduleEventsInternal` 在启动事件前 ResetSource(true)；默认在普通 Pipeline::Schedule 的 Reset 中创建 Source 状态。这是初始化先后顺序，不能据此推导远程连接异步建立或必定隐藏延迟。

## 六、扩展实现检查要点

1. 用当前 Identifier/TableIndex/BoundTableFunction 等签名实现回调；不要沿用 vector<string> 名称、idx_t bind_index、dynamic_to_string 或 type_pushdown。
2. 将运行游标放入状态，明确无工作标记；不要用 init_local 返回空指针阻止框架调用 function。
3. 共享工作分配需同步，异步任务必须在对象销毁前完成或 drain；局部执行对象可迁移线程。
4. 普通同步函数可保留 IMPLICIT，直至非空输出或真实 EOF；需要异步时遵守 mode、块大小与唤醒协议。
5. 只声明已实现的 pushdown 能力；复杂过滤保留未处理条件。
6. 本轮仅核对静态接口和调用链，扩展编译、过滤结果、重复执行、取消、并行顺序仍需独立验证。

并行状态的伪代码见[并行扫描](PARALLEL_SCAN_DESIGN.md)，BLOCKED 的实现骨架见[异步扫描](ASYNC_TABLE_SCAN_DESIGN.md)。C API 的实现路径已移至 [src/main/capi/v1/table_function-c.cpp](../src/main/capi/v1/table_function-c.cpp)，不能将 C++ 私有接口签名套用于 C API。
