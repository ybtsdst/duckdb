# DuckDB Table Function 与 Runtime Filter 设计文档

> 适用源码：`v2.0-cyanoptera` @ `c1cd2470a455`；核对日期：2026-10-23。核对方式：静态源码审查，未执行本文示例或性能测试。

## 一、背景与当前表示

Join runtime filter 用 build 侧实际 key 信息减少 probe 扫描的候选。它只是候选裁剪，精确 join 仍负责重复行、残留条件、outer/NULL 等语义。实现不限于 hash join：Nested Loop、Piecewise Merge 和 IEJoin 也调用 `JoinFilterPushdownInfo` 生成 min/max；有 hash table 的路径才能进一步扫描 build keys、构建 Bloom/PRF 等结构。

当前运行期过滤也统一为 `ExpressionFilter`，不是活动 `ConstantFilter` / `InFilter` / `BFTableFilter` 类树。关键对象见 [join_filter_pushdown.hpp](../src/include/duckdb/execution/operator/join/join_filter_pushdown.hpp)、[table_filter_set.hpp](../src/include/duckdb/planner/table_filter_set.hpp)、[table_filter_functions.hpp](../src/include/duckdb/planner/filter/table_filter_functions.hpp)。

| 对象 | 用途 |
|---|---|
| `JoinFilterPushdownInfo` | 条件下标、min/max aggregates、probe 目标和构建/发布方法 |
| `JoinFilterPushdownColumn` | probe binding、storage type、cast 重构步骤与模式 |
| `DynamicTableFilterSet` | 多个物理生产者向同一目标 scan 发布的过滤集合，mutex 保护 |
| `ExpressionFilter` | 实际比较/IN/可选/Bloom/PRF 表达式及绑定状态 |
| `DynamicFilterData` | TopN 等原地更新边界值的另一机制，见本文第八节 |

## 二、优化器：哪些 join 与列可参与

依据：[join_filter_pushdown_optimizer.cpp](../src/optimizer/join_filter_pushdown_optimizer.cpp) 的 `GenerateJoinFilters`、`JoinFilterPushdownUtil::JoinTypeIsSupported`。

该 pass 在 [optimizer.cpp](../src/optimizer/optimizer.cpp) 的 `JOIN_FILTER_PUSHDOWN` 阶段遍历普通 `LOGICAL_COMPARISON_JOIN`，不是对所有 join 节点无条件运行。先 `PhysicalComparisonJoin::ReorderConditions` 冻结条件位置，再为可推条件建立 min/max aggregates。

- 排除 MARK、SINGLE、LEFT、OUTER、ANTI、RIGHT_ANTI；常见可参与者为 INNER、SEMI、RIGHT、RIGHT_SEMI。这些排除保护必须保留的 probe 行。
- 条件选择支持 `=`、`<`、`<=`、`>`、`>=`；当前生成入口跳过 `IS NOT DISTINCT FROM`，即使底层 Bloom 支持判断中预留了此比较，也不代表普通优化路径会生成它。
- 目标 `LogicalGet` 必须声明 `filter_pushdown`。这只是能力条件，还必须找到适用 binding、类型和可穿透计划路径。
- probe 表达式支持列引用、特定整数 cast 链（宽度至64位）、整数与 VARIANT cast 及 `variant_normalize`；一般函数不支持。普通 nested 类型和 INTERVAL 被拒绝，VARIANT 有专门模式约束。
- min/max 若经 collation 绑定产生非单参数聚合，生成流程放弃该优化。

### 到达扫描的路径

`GetPushdownFilterTargets` 可穿透部分 FILTER、ORDER、DISTINCT、投影、分组键以及集合操作；aggregate 必须指向 group，不是任意聚合结果。UNNEST 不能把过滤应用到新展开的 unnest index。集合操作重写 binding，EXCEPT 只递归左侧。

LIMIT / TOP_N 是明确停止点：在 join 前先截取的 probe 行集合不能被下推过滤重新选择。投影穿透使用 `PushdownJoinFilterExpression`，保留 cast 顺序和类型信息，不能仅把最终 key 常量强转到原列类型便宣称等价。

即使没有 probe scan 目标，单条件整数 INNER 等值 join 仍可能保留 min/max aggregates，供 perfect hash 决策使用。因此“有 filter_pushdown info”不等于一定向 scan 发布了过滤器。

## 三、cast 域与错误语义

`JoinFilterPushdownMode::RECONSTRUCT_EXPRESSION` 允许在原始扫描值上重构 join key；`STORAGE_ONLY` 仅允许安全的 storage-domain 裁剪，不可直接对原值按另一个 key 域做 Bloom/PRF lookup。

[RuntimeFilterCastUtil](../src/optimizer/runtime_filter_cast.cpp) 记录每一步默认 cast / TRY_CAST、计算输入类型并构造表达式。[physical_hash_join.cpp](../src/execution/operator/join/physical_hash_join.cpp) 的 `CreateRuntimeFilterInputExpression`、`CreateJoinFilterComparisonExpression`、`PreserveRuntimeFilterCastErrors` 在必要时保留会导致原 join cast 报错的输入，避免预过滤静默吞掉异常。

本版本比较是 bound scalar function，使用 `BoundComparisonExpression::Create`，不能实例化旧 BoundComparisonExpression 类或直接写旧 `condition.left/right/comparison` 字段。

## 四、Build、Finalize 与发布时序

主要实现都在 [physical_hash_join.cpp](../src/execution/operator/join/physical_hash_join.cpp)，没有独立的 `join_filter_pushdown.cpp` 实现文件。

```text
GetGlobalState：ClearFilters(op)，清除同一生产者旧执行的集合
Sink：本地 min/max；必要时积累覆盖完整 build 的 Bloom
Combine：合并本地聚合与 hash 数据
FinalizeMinMax：取得全局范围
FinalizeFilters：发布简单表达式，或登记 deferred Bloom/PRF
HashJoinFinalizeEvent::FinishTasks：完成结构、seal、发布 deferred filters
依赖 build 完成的 probe pipeline 启动
PhysicalTableScan global init：合并静态 + 各生产者运行期集合
init_global / init_local：扫描器消费最终过滤器
```

`PhysicalJoin::BuildJoinPipelines` 建立 RHS build 到 LHS probe 的依赖；IEJoin 等双侧物化路径有自己的 pipeline 结构，见 [JOIN_EXECUTION_DESIGN.md](./JOIN_EXECUTION_DESIGN.md)。不能把所有 join 的调度都画成相同流式 probe 模式。

### 内存内 hash join

合并本地 hash table 后，先决定 perfect hash 和竞争的 filter 形态。Bloom/PRF 可以在 finalize materialize 完整 build 时构建，并在 finalize tasks 全部结束后发布。`PublishDeferredRuntimeFilters` 不会将尚未 sealed 或无效的 Bloom 交给扫描。

### External hash join

`ShouldBuildBloomFilterInSink` 根据估计大小、等值 key 数、build/probe 比例以及 `JoinIsLikelyExternal` 决定是否在 Sink 覆盖完整 build。`FinalizeExternalRuntimeFilters` 在全部 build 已合并后调用，并禁止用只覆盖当前轮 materialized 分区的结构构建全局 PRF。

仅覆盖一个 spill 分区的 Bloom 不能安全下推到整张 probe 扫描。当前外部路径可发布完整 sink-built Bloom 与全局 min/max；若估计与实际外部化路径导致没有可发布完整结构，保守不发 Bloom，而不是拿部分集合替代。

## 五、FinalizeFilters 的分支与收益条件

| 情况 | 当前行为 |
|---|---|
| min/max 转 storage type 失败或为 NULL | 跳过该候选过滤，不能据此多删行 |
| min == max | 对 probe 生成原比较符与单值的表达式，可精确执行该必要条件 |
| min != max，非等值比较 | 生成保守单侧界，使用 selectivity optional |
| min != max，等值 | 尝试 optional IN、prefix-range、范围和/或 Bloom；不是简单按大小二选一 |

方向以 `probe OP build` 为准：等值需要 `[min,max]`；`>`/`>=` 可用 `probe >= min`，`<`/`<=` 可用 `probe <= max`。这些 inclusive 界可以是宽松必要条件，精确 `<`/`>` 仍由 join 检查，不能照旧注释把所有范围称为半开区间。

### IN

`CanUseInFilter` 要求存在 hash table、实际 Count >1 且不超过 `DynamicOrFilterThresholdSetting`、比较为 `=`。`PushInFilter` 扫描对应 build key，转换到正确输入域并去重；含 NULL 或严格连续整数值域时不用 IN，后续选择范围/其他结构。发布的 IN 是 optional，仅用于安全辅助剪枝，不代替 join。

### Bloom

`CanUseBloomFilter` 检查恰好一个等值条件、可用 hash table 与 build/probe 成本。当前 build/probe 比例上限为1；若 build 侧没有过滤，比例超过0.1且 build_count >4194304 时拒绝。估计是启发式输入，不能据此保证收益；多列 join 的多列统计 filter 也不意味着支持复合 key Bloom 下推。

[BloomFilter::Initialize / Seal](../src/planner/filter/table_filter_bloom_function.cpp) 使用每64位一个 sector、每hash四个位，初始按估计行数和内存预算定尺寸；Seal 可 fold 并释放多余内存，再按 density 判断是否仍有用。发布持有 `shared_ptr<const BloomFilter>`，完整且 sealed 后不可再插入。不存在由固定12 bits/key直接保证的实测假阳性率。

### Prefix-range filter（PRF）

`CanUsePrefixRangeFilter` 继承 Bloom 的成本条件，进一步要求等值、非 NULL 相等语义、支持的 key 类型和可计算 span。`FinalizeFilters` 优先考虑 span 小于 `1<<26` 的精确位预算，再比较 span 和 Bloom 位预算；合适时登记 PRF 并跳过后续范围/Bloom选择。小 IN 可能已经额外发布，所以不能将这些选择描述成严格互斥的单一 filter。

PRF build state 在 finalize lanes 中归并，预算约束和类型实现见 [prefix-range 实现](../src/planner/filter/table_filter_prefix_range_function.cpp)。本篇核对选择和发布边界，未逐个穷尽其所有物理类型内核。

## 六、扫描消费与自适应可选执行

[TableScanGlobalSourceState](../src/execution/operator/scan/physical_table_scan.cpp) 把最终集合保存到全局 source state，`init_local` 引用同一集合。单列 key 是 `ProjectionIndex`，先映射到 `input.column_indexes`，不能拿它直接索引数据源原 schema。多生产者同列过滤合并为 AND。

普通 optional 的行级实现恒 TRUE，child 用于统计；selectivity optional 可以真正缩小候选，命中率太高时暂停，之后重试。当前 min/max、BF、PRF 策略为6个vector观察，阈值分别0.9、0.5、0.5，见 [GetThresholdAndVectorsToCheck](../src/planner/filter/table_filter_functions.cpp) 和 [SelectivityStats::Update](../src/planner/filter/table_filter_selectivity_optional_function.cpp)。

Bloom 假阳性不禁止行级预过滤：确定不属于 build 的 key 可以排除，留下的候选仍交给精确 join。不能用 Bloom 阳性来认定连接已匹配，也不能忽略 NULL 和 cast 错误保留策略。

## 七、自定义 Table Function 的责任

声明 `filter_pushdown` 后扫描会成为潜在目标，但 callback、列映射和类型能力仍需要实现。以下是经过接口核对的伪代码，不是完整扩展：

```text
init(input):
  for entry in *input.filters:
    projection_pos = entry.GetIndex()
    source_column = input.column_indexes[projection_pos]
    用该列的块统计检查 entry.Filter() 内的 ExpressionFilter
  保留所有“无法证明不可能匹配”的块
scan():
  生成候选行
  对完全接受的静态精确谓词执行行级判断
  运行期 hint 可在支持时继续预过滤
```

`PhysicalTableScan` 不提供任意 table function 的自动行级补过滤。若只实现块剪枝而忽略完全下推静态谓词，结果可能错误。不能把 unsupported type 的精确过滤静默丢弃；普通 planner 有类型回退路径，扩展需要诚实声明能力。

真实接口节选：[DynamicTableFilterSet](../src/include/duckdb/planner/table_filter_set.hpp)：

```cpp
void PushFilter(const PhysicalOperator &op, ProjectionIndex column_index,
                unique_ptr<TableFilter> filter);
unique_ptr<TableFilterSet> GetFinalTableFilters(
    const PhysicalTableScan &scan, optional_ptr<TableFilterSet> existing_filters) const;
```

## 八、TopN 的 DynamicFilterData 是另一种动态路径

TopN 在规划期就下推 `ExpressionFilter(optional(dynamic(...)))`，运行中原地收紧共享边界，无需每次向 `DynamicTableFilterSet` 新增集合。

[DynamicFilterData](../src/include/duckdb/planner/filter/table_filter_functions.hpp) 当前保存比较类型和 Value，使用 shared mutex 与初始化标志；`SetValue` / `Reset` 实现在 [dynamic_filter.cpp](../src/planner/filter/dynamic_filter.cpp)，执行和统计 callback 在 [table_filter_dynamic_function.cpp](../src/planner/filter/table_filter_dynamic_function.cpp)。

[TopN::PushdownDynamicFilters](../src/optimizer/topn_optimizer.cpp) 接受首排序键 numeric physical type 或 VARCHAR 的列引用，还检查可达目标和可安全重构的 cast 链；不接受 TRY_CAST/无法保留排序及错误语义的路径。ASC 单键 `< boundary`、多键 `<= boundary`，DESC 对称；NULLS FIRST 保留 NULL。 [TopNBoundaryValue::UpdateValue](../src/execution/operator/order/physical_top_n.cpp) 把执行中改善的边界解码并更新。

未初始化时动态谓词保守不裁剪；初始化后后续统计检查可使用新边界。不能把“集合初始化时合并一次”误解为“所有 filter 值从此永不变化”。

## 九、验证边界

本文核对优化器生成条件、cast路径、内外部 hash生命周期、deferred发布和扫描消费，亦定位三种非hash join调用方。未运行 SQL、外部化、多线程/递归CTE或性能测试；没有断言所有执行中必然发布某种 filter、必然触发某种 reader剪枝或得到固定加速。
