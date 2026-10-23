# DuckDB Join 算子实现与执行过程整理

> 适用源码：`v2.0-cyanoptera` @ `c1cd2470a455`；核对日期：2026-10-23。核对方式：静态源码审查，未执行本文示例或性能测试。

## 一、范围与执行框架

本文覆盖物理选择、Sink/Combine/Finalize、probe执行与Source产出。Join order/costing本身不展开，但物理选择依赖其产生的左右分支、基数、条件和设置，不能单由SQL写法断言唯一算子。

基类见 [physical_join.cpp](../src/execution/operator/join/physical_join.cpp) 的 `PhysicalJoin::BuildJoinPipelines`：常规连接先为RHS建立以join为sink的build子管线，再沿LHS构建probe管线；需要build侧补行或external处理时增加source子管线。

“左=LHS/probe、右=RHS/build”指优化后的物理计划。优化器可交换SQL中两张表，并反转LEFT/RIGHT、SEMI/RIGHT_SEMI等类型，不能将SQL文本顺序当作冻结的build选择。

IEJoin和常规AsOf使用双侧物化、最终Source产出的独立结构，不符合“只Sink右侧、左侧流式输出全部匹配”的通用模板。

## 二、物理计划如何选择

入口：[plan_comparison_join.cpp](../src/execution/physical_plan/plan_comparison_join.cpp) 的 `PlanComparisonJoin`。

1. 特定直接递归CTE state scan、INNER等值/NOT DISTINCT key条件先尝试 `PhysicalRecursiveCTEKeyJoin`；只看普通分派会漏掉此分支。
2. 无条件使用 `PhysicalCrossProduct`。
3. 检查等值与范围条件：`can_merge = has_range > 0`，`can_iejoin = has_range >= 2`且无递归CTE限制；SEMI/ANTI/MARK的merge要求条件总数为1，RIGHT_SEMI/RIGHT_ANTI另禁用IEJoin。
4. 有等值条件且未启用适用的 `prefer_range_joins` 时优先 `PhysicalHashJoin`；hash可以同时保留其他比较与残留布尔条件，并非“ON有复杂函数就必定blockwise”。
5. 无优先hash路径时，任一侧估计基数低于 `nested_loop_join_threshold` 会关闭range候选；若merge与IE均可用，任一侧低于 `merge_join_threshold` 会关闭IE。
6. 然后顺序尝试IEJoin、PiecewiseMerge、`PhysicalNestedLoopJoin::IsSupported`，最终把条件合成布尔表达式交给BlockwiseNL。

当前默认nested阈值5、merge阈值1000，来自 [settings.hpp](../src/include/duckdb/main/settings.hpp)，代码使用严格 `<` 判断。设置值不代替当前查询的实际估计，也不是本轮测试结果。

`PhysicalNestedLoopJoin::IsSupported` 对comparison数、nested物理类型和SEMI/ANTI等有额外限制；不能将其当作支持所有join语义的最终兜底。MARK的生成还有构造期条件和专门三值逻辑约束。

## 三、Hash Join 的阶段与语义

依据：[physical_hash_join.cpp](../src/execution/operator/join/physical_hash_join.cpp)、[join_hashtable.cpp](../src/execution/join_hashtable.cpp)。

### Sink / Combine / Finalize

Sink计算RHS key与payload，写本地hash数据并积累需要的min/max/候选过滤；Combine汇总本地集合。Finalize根据临时内存reservation与分区大小决定内存内或external路径，不能只用一个静态“表大小阈值”解释spill。

内存内路径合并、Unpartition，尝试perfect hash，或安排pointer-table初始化及finalize事件。实际结构完成和deferred runtime filter发布可能在事件任务结束，`Finalize`返回READY并不表示所有工作都在这个函数调用内同步完成。

External路径可repartition，处理当前可驻留分区，probe未匹配当前分区的输入可spill，source阶段按轮次处理剩余任务。runtime Bloom若要推到整个probe scan，必须覆盖完整build；详见 [RUNTIME_FILTER_DESIGN.md](./RUNTIME_FILTER_DESIGN.md)。

### Probe / Source

`ExecuteInternal` 计算LHS key并探测 `ScanStructure`。一批输入可产生多个输出chunk，状态必须保持到这批probe穷尽；SEMI/ANTI/MARK/SINGLE等使用专门路径。

RIGHT/FULL以及RIGHT_SEMI/RIGHT_ANTI要记录build侧是否匹配。source不是一概“输出右侧未匹配”：RIGHT_SEMI输出**已匹配**的build行且不按probe匹配次数重复；RIGHT_ANTI输出未匹配build行。external模式的source还负责分区轮次任务，不局限于outer补行。

### Perfect hash 与本版本快速路径

[PerfectHashJoinExecutor::CanDoPerfectHashJoin](../src/execution/operator/join/perfect_hash_join_executor.cpp) 需要INNER、单整数等值、无残留predicate、可接受build类型及范围等条件。范围来自统计或build min/max；后续字典窄化等路径仍会重新拒绝不兼容情况，不能仅看到整数key就断言perfect hash。

本版本还存在压缩向量probe、字典payload/结果发射及unique-left等快路径。其局部加速不改变连接保留侧、重复和NULL语义，也不能替代逐项条件门槛。本篇核对主入口，未穷尽这些专项快速路径。

## 四、各类普通连接

| 算子与源码 | 构建/执行模式 | 主要边界 |
|---|---|---|
| [PhysicalNestedLoopJoin](../src/execution/operator/join/physical_nested_loop_join.cpp) | RHS条件列/payload物化；LHS逐批比较；需要时Source输出build侧结果 | SEMI/ANTI/MARK有专门路径；支持判定检查类型与条件；额外predicate对候选对求值 |
| [PhysicalBlockwiseNLJoin](../src/execution/operator/join/physical_blockwise_nl_join.cpp) | RHS物化，CrossProductExecutor产生候选对，ExpressionExecutor执行任意布尔条件 | 构造明确排除MARK/SINGLE；SEMI/ANTI和右半/右反连接有状态，不能当成所有类型万能兜底 |
| [PhysicalPiecewiseMergeJoin](../src/execution/operator/join/physical_piecewise_merge_join.cpp) | RHS排序，LHS每chunk排序后按主要范围匹配，其他条件继续检查 | 普通匹配在Execute；需要build侧结果时Source扫描；物理选择对join类型和条件数有限制 |
| [PhysicalCrossProduct](../src/execution/operator/join/physical_cross_product.cpp) | RHS物化，LHS与RHS逐块组合，保留跨调用位置 | 无join condition；不是对所有复杂谓词直接产生最终笛卡尔结果 |

上述有filter_pushdown info的NestedLoop/PiecewiseMerge也会Sink/Combine/Finalize min/max，因此runtime filtering不等于hash join专属。

## 五、IEJoin：双侧物化后Source执行

[PhysicalIEJoin::BuildPipelines](../src/execution/operator/join/physical_iejoin.cpp) 把自身设为当前pipeline source，先建立RHS、再LHS sink管线并安排finish依赖。两侧数据完成后，Source通过排序后的范围连接任务产出结果与需要的outer/半连接语义。

它典型用于至少两个不等式，仍受基数、join类型、recursive CTE和设置影响。`ExecuteInternal`的存在不能据此画成一般hash式流式probe；实际数据产出看 `GetDataInternal` 和任务状态机。

## 六、ASOF 的分派与匹配边界

入口：[plan_asof_join.cpp](../src/execution/physical_plan/plan_asof_join.cpp) 的 `PlanAsOfJoin`、`ValidateAsOfConditions`、`PlanAsOfLoopJoin`。

常规ASOF在等值分区内，按一个方向不等式为每个probe选择最近候选；不是返回所有满足范围条件的连接对。`>=`/`>`与`<=`/`<`决定搜索方向和边界。

- 小的是**LHS/probe估计基数**：已知估计且低于 `asof_loop_join_threshold`（默认64）可尝试loop方案；不是“小RHS一定走NL”。
- loop方案反转连接，用row_number区分重复probe，配合first及arg_min/arg_max聚合再恢复输出。
- 有任意非comparison predicate时强制尝试可一起评估的loop路径；不支持时抛NotImplemented，不能静默交给只检查comparison的常规ASOF。
- 某些SEMI/ANTI/MARK加任意predicate的情形回普通 `PlanComparisonJoin`。
- `debug_asof_iejoin` 提供window+IEJoin变体，不是默认路径。

[physical_asof_join.cpp](../src/execution/operator/join/physical_asof_join.cpp) 的常规 `BuildPipelines` 与IEJoin一样先Sink两侧、最后Source执行；支持特定分区策略和outer补行。能看到RIGHT/OUTER处理分支，不代表planner对任意ASOF条件和join类型组合都接受。

## 七、Positional 与 Delim

[plan_positional_join.cpp](../src/execution/physical_plan/plan_positional_join.cpp)：两边均为TABLE_SCAN/POSITIONAL_SCAN时使用 `PhysicalPositionalScan`，否则 `PhysicalPositionalJoin`。按各侧输出位置对齐，较短一侧补NULL；这不是用持久rowid做等值连接，也不保证无显式排序的任意输入具有稳定SQL顺序。

[plan_delim_join.cpp](../src/execution/physical_plan/plan_delim_join.cpp)：先规划内部comparison join，收集delim scans，建立去重聚合和依赖；没有delim scans时直接返回内部普通join。`PhysicalLeftDelimJoin` / `PhysicalRightDelimJoin` 是相关子查询计划的依赖/去重包装，不能与一个独立hash算法混为一谈。

## 八、JoinType、空侧与NULL

依据：[join_type.cpp](../src/common/enums/join_type.cpp)、[physical_join.cpp](../src/execution/operator/join/physical_join.cpp)、[join_hashtable.cpp](../src/execution/join_hashtable.cpp)。

| 类型 | 必须保留的行为 |
|---|---|
| INNER | 输出精确匹配对，重复key会产生相应匹配组合 |
| LEFT / FULL(`OUTER`) | 无匹配probe行补NULL；FULL还需输出未匹配build行 |
| RIGHT | 已匹配对加未匹配build行；build侧传播不能省略 |
| SEMI / ANTI | 左侧每行最多输出一次，分别按存在/不存在匹配选择；ANTI不能直接当作NOT IN |
| RIGHT_SEMI / RIGHT_ANTI | Source按build的found_match状态输出，不按probe重复数复制 |
| MARK | 左行加TRUE/FALSE/NULL标记，取决于比较、probe/build NULL、空build及相关分组；不是简单has_null布尔公式 |
| SINGLE | scalar-subquery风格，一侧至多一个结果；无匹配补NULL，多匹配按设置报错，不能只描述成LEFT |

`EmptyResultIfRHSIsEmpty` 对INNER、RIGHT、SEMI、RIGHT_SEMI、RIGHT_ANTI可提前无输出；LEFT/FULL/ANTI/MARK/SINGLE等必须按各自语义保留probe行为。普通等值和NOT DISTINCT的NULL处理不同，过滤/rehash/残留predicate都必须保持对应语义。

## 九、阅读与验证边界

从具体计划追踪时，应按 planner选择 → 对应算子BuildPipelines → Sink/Finalize事件 → Execute或Source → JoinType特例读取。本文仅静态核对这些主路径；未运行SQL、测试spilling/多线程/Unicode或性能，未证明任意SQL必然选择表中某一算子。
