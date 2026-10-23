# DuckDB Filter 性能优化设计文档

> 适用源码：`v2.0-cyanoptera` @ `c1cd2470a455`；核对日期：2026-10-23。核对方式：静态源码审查，未执行本文示例或性能测试。

## 范围与证据

本文是 [Filter 系列](./FILTER_DESIGN.md) 的性能机制篇。以下均为静态源码机制及有条件的成本推断，不是本轮实测。旧文档中的固定加速倍数、延迟和输出行数没有可复核实验依据，不能据此用于性能比较。

## 一、统计剪枝：收益来自能证明排除的数据范围

[ExpressionFilter::CheckExpressionStatistics](../src/planner/filter/expression_filter.cpp) 通过表达式和子统计推导判断结果，包含比较、IN/NULL/NOT、AND/OR、BOOLEAN 引用、函数 prune callback 等路径。当前 `ExpressionFilter` 同时承担普通比较和复杂表达式，不能把它等同于“无法 zone-map 的兜底”。

[RowGroup::CheckZonemap](../src/storage/table/row_group.cpp) 对 FALSE / FALSE_OR_NULL 跳过行组，对精确 ALWAYS_TRUE 免去相应行级过滤。TRUE_OR_NULL 仍可能有 WHERE 不接受的 NULL，不可直接全放行。受限多列表达式也可在行组级联合推导统计；原始行级谓词仍保留。

更窄、与谓词范围更一致的统计更可能剪枝。数据聚簇、行组大小、分布和 NULL 都会影响收益；不能声称 TPC-H dbgen 输出默认按 `l_shipdate` 聚簇。非聚簇列也可能遇到完全不相交的区段，只是常见的宽 min/max 会降低机会。

跳过行组减少后续扫描/解码，具体物理 I/O 还受缓存、元数据、预取和读取粒度影响。未测量时不宜写“每次必省多少 MB”。

## 二、SelectionVector 与延后读取

[RowGroup::ProcessPreparedScan](../src/storage/table/row_group.cpp) 先执行 active filter 列，用同一个选择集合逐步缩小候选，再读取其它列。整批零命中时可跳过其余列；部分命中时调用 `ColumnData::Select`。

这个机制能减少后续计算和输出数据，但部分命中的解码成本有严格条件：

- [ColumnData::Select](../src/storage/table/column_data.cpp) 的基础路径为完整 `Scan` 后 `Slice`。
- [StandardColumnData::Select](../src/storage/table/standard_column_data.cpp) 只有数据和 validity codec 均实现 select 且无 updates 才使用专门选择路径。
- codec 内部读取/解码粒度可能仍大于选中行粒度。

因此不可由“命中率1%”直接推出“解压量1%”或固定10倍加速。还要与 [LateMaterialization](./LATE_MATERIALIZATION_DESIGN.md) 的两次扫描/行 ID 改写区分。

## 三、快速行级执行与自适应顺序

[table_filter_state.cpp](../src/planner/table_filter_state.cpp) 的 `TryCreateFastExecutor` 识别简单比较、部分 AND 和内部运行期过滤函数。`ComparisonFilterExecutor` 用类型、比较符和 NULL 状态特化循环；未命中则使用 `ExpressionExecutor`，其中某些函数仍有专门 select callback。因此“通用表达式没有模板化/向量内核”同样过于绝对。

[AdaptiveFilter](../src/execution/adaptive_filter.cpp) 以整个过滤阶段的耗时试探相邻交换，不能理解为精确的每列选择率排序。有抛错或 barrier 时禁用重排。更早收窄候选集合可能降低后续谓词工作量；实际是否更快取决于内核成本、数据局部性、解码和批大小，不能承诺找到最优 permutation。

## 四、Optional 与 selectivity optional

当前二者均为 `ExpressionFilter` 内部函数，声明见 [table_filter_functions.hpp](../src/include/duckdb/planner/filter/table_filter_functions.hpp)。

普通 optional 的 child 用于统计推导，行级语义为 TRUE。用于非密集 IN、一般同列 OR、宽松 temporal-cast 界以及部分 runtime min/max 等；精确谓词或 join 仍负责结果语义。root non-selectivity optional 在行组检查后被摘出行级过滤列表，见 `RowGroup::CheckZonemap`。

选择率可选过滤不是永久停用：[table_filter_selectivity_optional_function.cpp](../src/planner/filter/table_filter_selectivity_optional_function.cpp) 的 `SelectivityStats::Update` 在观测后暂停低收益过滤，并按 `VECTOR_PAUSE=10` 与递增 `pause_multiplier` 重新激活采样。当前策略常量见 [GetThresholdAndVectorsToCheck](../src/planner/filter/table_filter_functions.cpp)：

| 类型 | accepted / processed 达到此值则可暂停 | 观测 vector 数 |
|---|---:|---:|
| min/max | 0.9 | 6 |
| Bloom | 0.5 | 6 |
| prefix-range | 0.5 | 6 |

命中率高表示过滤掉的行少。暂停只适用于正确性上可省略的候选裁剪，不能用来忽略已完全下推的普通 WHERE。

## 五、TopN 的动态边界

[TopN::CanOptimize](../src/optimizer/topn_optimizer.cpp) 要求常量 LIMIT、非表达式 OFFSET，并找到 ORDER BY（可穿过 projection）。存在基数估计时，仅当 `limit + offset > 5000` **且**超过 child cardinality 的0.7%，才因“大 limit”拒绝 TopN；旧“所有 limit 必须 <=0.7%”错误。

`PushdownDynamicFilters` 还要求首排序键为 `BOUND_COLUMN_REF`，类型为 `TypeIsNumeric(InternalType)` 或 VARCHAR；不是“仅逻辑整数和 varchar”。目标扫描必须可到达，cast 重构路径、try-cast/错误语义和类型要满足进一步检查。

```text
LogicalTopN::dynamic_filter
  → 共享 DynamicFilterData
  → scan 内 optional(dynamic(sort_key))
  ← TopNBoundaryValue::UpdateValue 收紧边界
```

[physical_top_n.cpp](../src/execution/operator/order/physical_top_n.cpp) 的 `TopNBoundaryValue::UpdateValue` 将 sort-key 边界解码后调用 `SetValue`。ASC 单排序键用 `<`、多键用 `<=`；DESC 对称，NULLS FIRST 额外保留 NULL。边界可帮助跳过未来统计不可能贡献更优结果的区域，是否收益大取决于数据顺序、分布、k/offset 和扫描速度。它不是每读一行都必定更新一次的 API 承诺。

## 六、Join 的 min/max、IN、Bloom 与 prefix-range

详细生命周期见 [RUNTIME_FILTER_DESIGN.md](./RUNTIME_FILTER_DESIGN.md)。关键条件在 [physical_hash_join.cpp](../src/execution/operator/join/physical_hash_join.cpp) 的 `CanUseInFilter`、`CanUseBloomFilter`、`CanUsePrefixRangeFilter`、`FinalizeFilters`：

- min/max 小范围可以生成便宜比较；相等时生成精确单值比较。
- 小 hash build 可尝试 optional IN；列表需要非 NULL、非密集，不能把 build 行数等同于 distinct key 数。
- Bloom 还依赖唯一等值 key、build/probe 估计比例和完整构建后的发布条件，不是“build 大就必用 Bloom”。
- 当前存在 prefix-range filter，并按 key 类型、值域跨度和位预算优先选择；外部 join 不从单轮 materialized 分区构造全局 PRF。
- [BloomFilter::Seal](../src/planner/filter/table_filter_bloom_function.cpp) 可 fold 并释放多余内存；仅完整、sealed、仍有用的过滤器可发布。不能发布只覆盖某个 build 分区的候选集合。

Bloom/PRF 可减少候选行和部分区段扫描，同时有构建、hash/lookup 和内存成本。假阳性需要精确 join 继续判断；无假阴性才是预过滤正确性的前提。源码的目标假阳性模型不是本轮测量结果。

## 七、FilterCombiner 与函数统计的间接收益

[FilterCombiner](../src/optimizer/filter_combiner.cpp) 合并等价类、消除冗余比较并检测矛盾，例如 `x > 5 AND x > 7` 可收紧为后者；能证明不可满足时可替换为 `LogicalEmptyResult`。在允许传播的 join 语义下，等值关系可把常量约束传给另一侧。outer/anti 的保留侧不能随意裁掉。

普通函数也有特定统计机会：[ContainsFilterPrune](../src/function/scalar/string/contains.cpp) 利用最大字符串长度和精确/截断 min/max；CAST 可依赖 [ExpressionFilter](../src/planner/filter/expression_filter.cpp) 的 cast 统计传播；temporal cast 的宽松界只部分下推并保留原条件。不能用通用“对 f 求逆”替换作等价优化，尤其要考虑溢出、精度、NULL、排序规则和抛错语义。

## 八、端到端示意

以下 SQL 仅作路径说明，未执行，不给出臆测 EXPLAIN、行数或耗时：

```sql
SELECT l_orderkey, SUM(l_extendedprice * (1 - l_discount))
FROM lineitem
WHERE l_shipdate BETWEEN DATE '1996-01-01' AND DATE '1996-12-31'
  AND l_quantity > 24
  AND l_returnflag IN ('A', 'R')
  AND l_comment LIKE '%urgent%'
GROUP BY l_orderkey;
```

可能的机制是日期/数量比较成为 `ExpressionFilter`，非密集 IN 部分下推 optional 并保留精确 IN；LIKE 若被改为 contains，内置表可接受通用单列表达式下推，并有 contains 自身统计 callback。实际剩余 FILTER 还受 IN rewrite、表达式优化、数据源能力和统计影响，不能同时声称 LIKE 已完全下推又画一个负责同一精确条件的必然残留 FILTER。

行组阶段能证明不匹配才跳；扫描阶段 active 谓词缩小选择集，其余列按 codec/updates 条件延后读取。要给出性能结论，还需冻结数据、排序布局、配置、构建、冷热缓存和 profiling 指标；本轮没有开展这些实验。
