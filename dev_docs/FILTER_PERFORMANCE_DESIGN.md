# DuckDB Filter 性能优化设计文档

> 本文是 `FILTER_DESIGN.md` 系列的第 4 篇,集中讲 **7 类性能优化机制**:zone-map 3VL 边界、SelectionVector + late mat、TopN DynamicFilter、Optional / SelectivityOptional、Bloom × stats 联合裁剪、FilterCombiner 传递性的扫描端收益、ExpressionFilter 兜底代价。末尾一个端到端 SQL 例子串起前三篇的概念。
>
> 类层次见 [FILTER_DESIGN.md](./FILTER_DESIGN.md);规划期转换见 [FILTER_PUSHDOWN_DESIGN.md](./FILTER_PUSHDOWN_DESIGN.md);扫描期执行见 [FILTER_EXECUTION_DESIGN.md](./FILTER_EXECUTION_DESIGN.md)。

## §5 性能优化机制

### 5.1 Zone-map 剪枝(CheckStatistics)与 3VL 边界

`FilterPropagateResult` 5 个枚举值(`src/include/duckdb/common/enums/filter_propagate_result.hpp:15-21`):

```cpp
enum class FilterPropagateResult : uint8_t {
    NO_PRUNING_POSSIBLE = 0,
    FILTER_ALWAYS_TRUE = 1,
    FILTER_ALWAYS_FALSE = 2,
    FILTER_TRUE_OR_NULL = 3,
    FILTER_FALSE_OR_NULL = 4
};
```

后两个 `*_OR_NULL` 用来处理 SQL 三值逻辑(3VL)—— `NULL` 在比较结果中等于 unknown。`FILTER_TRUE_OR_NULL` 的意思是「对于非 null 值这个 filter 一定通过,但 null 值需要单独判断」。

#### 5.1.1 3VL 边界的核心:ConstantFilter::CheckStatistics

回顾 `constant_filter.cpp:37-79`:

```cpp
FilterPropagateResult ConstantFilter::CheckStatistics(BaseStatistics &stats) const {
    if (!stats.CanHaveNoNull()) {
        // no non-null values are possible: always false
        return FilterPropagateResult::FILTER_ALWAYS_FALSE;
    }
    ...
    result = NumericStats::CheckZonemap(stats, comparison_type, array_ptr<const Value>(&constant, 1));
    ...
    if (result == FilterPropagateResult::FILTER_ALWAYS_TRUE) {
        // the numeric filter is always true, but the column can have NULL values
        // we can't prune the filter
        if (stats.CanHaveNull()) {
            return FilterPropagateResult::NO_PRUNING_POSSIBLE;
        }
    }
    return result;
}
```

**这是新手最容易写错的地方**。直觉上 `[100, 200] > 50` 应该是 always-true,但如果列里有 NULL,这些 NULL 行的 `x > 50` 结果是 NULL(在 `WHERE` 中不通过),不能直接把 filter 标 always-true。所以 DuckDB 在 ALWAYS_TRUE + CanHaveNull 时**降级到 NO_PRUNING_POSSIBLE**,让 vector 级执行真的去逐行判断。

#### 5.1.2 Conjunction 的传播

OR / AND 各自的 `CheckStatistics`(见 [FILTER_DESIGN §2.2.3](./FILTER_DESIGN.md#223-conjunctionandfilter--conjunctionorfilter))定义了如何把子 filter 的结果合成。AND 任一 FALSE → 整 row group 跳过(`ALWAYS_FALSE`),这是 zone-map 剪枝的主要来源。OR 任一 TRUE → 整 row group 全过(`ALWAYS_TRUE`),意味着这一列对其它 OR 子句没贡献,但**其它列**的 filter 仍会决定是否继续。

#### 5.1.3 收益估算

ClickBench / TPC-H 这种「strong filter on a clustered column」(典型:lineitem 按 `l_shipdate` 排,WHERE 带 `l_shipdate BETWEEN ...`)上,**很大一部分 row group 的 stats 完全 disjoint**,可被直接整块跳过。一次 row group 通常 122880 行(`STANDARD_VECTOR_SIZE × ROW_GROUP_VECTOR_COUNT`),省 I/O 量级是 1+ MB。

非聚簇列(`l_quantity`、`l_returnflag`)的 in-range 谓词通常无法 zone-map 剪枝,**只能省 emit、不省 storage 读**。

### 5.2 SelectionVector 模板化 + late materialization

见 [FILTER_EXECUTION_DESIGN §4.4 / §4.5](./FILTER_EXECUTION_DESIGN.md#44-vector-级-filter-与-late-materialization)。核心收益:谓词命中率 1% 时,投影列只解压 1% 数据。

具体到 TPC-H Q6(strong shipdate range + quantity range)这种 scan-dominated query,late-mat 与 zone-map 的组合可以让 scan 加速 10× 以上。

详 [[LATE_MATERIALIZATION_DESIGN]]。

### 5.3 DynamicFilter:执行期值注入(非 join 来源)

DynamicFilter 的结构见 [FILTER_DESIGN §2.2.6](./FILTER_DESIGN.md#226-dynamicfilter--dynamicfilterdata)。这里重点讲 **TopN dynamic filter** —— `ORDER BY ... LIMIT k` 模式下的「自我加速」机制。

#### 5.3.1 TopN 生成 DynamicFilter

`TopN::PushdownDynamicFilters`(`src/optimizer/topn_optimizer.cpp:67-135`):

```cpp
void TopN::PushdownDynamicFilters(LogicalTopN &op) {
    bool nulls_first = op.orders[0].null_order == OrderByNullType::NULLS_FIRST;
    auto &type = op.orders[0].expression->return_type;
    if (!TypeIsIntegral(type.InternalType()) && type.id() != LogicalTypeId::VARCHAR) {
        // only supported for integral types currently
        return;
    }
    if (op.orders[0].expression->GetExpressionType() != ExpressionType::BOUND_COLUMN_REF) {
        // we can only pushdown on ORDER BY [col] currently
        return;
    }
    if (op.dynamic_filter) return;
    auto &colref = op.orders[0].expression->Cast<BoundColumnRefExpression>();
    ...
    // 找下游可消费 dynamic filter 的 scan
    vector<PushdownFilterTarget> pushdown_targets;
    JoinFilterPushdownOptimizer::GetPushdownFilterTargets(*op.children[0], std::move(columns), pushdown_targets);
    if (pushdown_targets.empty()) return;

    ExpressionType comparison_type;
    if (op.orders[0].type == OrderType::ASCENDING) {
        comparison_type =
            op.orders.size() == 1 ? ExpressionType::COMPARE_LESSTHAN : ExpressionType::COMPARE_LESSTHANOREQUALTO;
    } else {
        comparison_type =
            op.orders.size() == 1 ? ExpressionType::COMPARE_GREATERTHAN : ExpressionType::COMPARE_GREATERTHANOREQUALTO;
    }
    Value minimum_value = type.InternalType() == PhysicalType::VARCHAR ? Value("") : Value::MinimumValue(type);
    auto base_filter = make_uniq<ConstantFilter>(comparison_type, std::move(minimum_value));
    auto filter_data = make_shared_ptr<DynamicFilterData>();
    filter_data->filter = std::move(base_filter);
    op.dynamic_filter = filter_data;

    for (auto &target : pushdown_targets) {
        ...
        auto dynamic_filter = make_uniq<DynamicFilter>(filter_data);
        unique_ptr<TableFilter> pushed_filter = std::move(dynamic_filter);
        if (nulls_first) {
            auto or_filter = make_uniq<ConjunctionOrFilter>();
            or_filter->child_filters.push_back(make_uniq<IsNullFilter>());
            or_filter->child_filters.push_back(std::move(pushed_filter));
            pushed_filter = std::move(or_filter);
        }
        auto optional_filter = make_uniq<OptionalFilter>(std::move(pushed_filter));
        auto &column_index = get.GetColumnIds()[col_idx];
        get.table_filters.PushFilter(column_index, std::move(optional_filter));
    }
}
```

要点:
1. **限制**:`ORDER BY` 必须是单列且为 integral / varchar(`:71-77`)。其他类型(date、decimal、struct...)暂不支持。
2. **`NULLS FIRST` 包 `ConjunctionOrFilter(IsNullFilter, DynamicFilter)`**(`:123-128`):排序时 NULL 在前的话,初始 top-K 可能全是 NULL,filter 必须放过 NULL 行。
3. **外层包 `OptionalFilter`**(`:129`):一开始 `initialized=false`,`CheckStatistics` 返回 NO_PRUNING_POSSIBLE;**zone-map 收益要等执行期 boundary 收紧后才出现**。
4. **生效条件**:TopN 优化器要 `CanOptimize` 判断 `LIMIT` 是常量且不超过 `0.7% × child_card`(`:50-54`),否则全排序更快。

#### 5.3.2 TopNBoundaryValue::UpdateValue 与值更新

`src/execution/operator/order/physical_top_n.cpp:63-75`:

```cpp
void UpdateValue(string_t boundary_val) {
    unique_lock<mutex> l(lock);
    if (!is_set || boundary_val < string_t(boundary_value)) {
        boundary_value = boundary_val.GetString();
        is_set = true;
        if (op.dynamic_filter) {
            CreateSortKeyHelpers::DecodeSortKey(boundary_val, boundary_vector, 0, boundary_modifiers);
            auto new_dynamic_value = boundary_vector.GetValue(0);
            l.unlock();
            op.dynamic_filter->SetValue(std::move(new_dynamic_value));   // ← 把当前 top-K 边界写回 ConstantFilter
        }
    }
}
```

TopN heap 每次进新元素都会 `EntryShouldBeAdded` 检查(`physical_top_n.cpp:139-149`),如果新值挤掉了 heap 顶,就调 `UpdateValue` 推进边界。scan 端的 ConstantFilter 一旦更新,后续 row group 立即享受到新的剪枝。

#### 5.3.3 实际收益(ClickBench Q24 案例)

ClickBench Q24 `SELECT * FROM hits ORDER BY EventTime LIMIT 10` 这类 query,DuckDB 跑 0.21s(emit 408 行),而**没有** TopN dynamic filter 的引擎可能跑 7.51s 以上(emit 100M 行),**35× 量级 gap**。**根本原因**:scan 在执行 ~1ms 后边界就收紧,后续 row group 几乎全被 zone-map 剪掉;否则 scan 必须把全表所有行都吐到 TopN 算子,白白浪费 I/O + 解压。

### 5.4 OptionalFilter / SelectivityOptionalFilter:自适应跳过

详见 [FILTER_DESIGN §2.2.7 / §2.2.8](./FILTER_DESIGN.md#227-optionalfilter)。这里只强调收益:

- **OptionalFilter**:把 OR / 非密集 IN 从 hot loop 摘掉,**只享受 zone-map 收益**。RowGroup 跳过率高时,无需付出行级执行成本。`row_group.cpp:528-530` 是关键代码:OPTIONAL_FILTER 类型在 row group 级检查后无条件标 always-true,从而被排除出 vector 级 hot loop。
- **SelectivityOptionalFilter**:实测前 N 个 vector 的选择率,>= 阈值后自动暂停。**自动避免「这个 filter 帮不上忙反而费 CPU」的退化场景**。

阈值常量(`selectivity_optional_filter.cpp:18-22`)分两组:
- `MIN_MAX_THRESHOLD` + `MIN_MAX_CHECK_N`:min/max 形态(包 ConstantFilter)用;
- `BF_THRESHOLD` + `BF_CHECK_N`:Bloom filter 形态(包 BFTableFilter)用。

源码 TODO(`:62-63`)指出 per-row-group thread-local pause 还没做。

### 5.5 BloomFilter(静态 + 动态形态)

`BFTableFilter` 的 stats × BF 联合裁剪(详见 [FILTER_DESIGN §2.2.9](./FILTER_DESIGN.md#229-bftablefilterbloom-filter-形态))是 DuckDB 静态阶段对 Bloom 的主要用途:用 stats min/max 把搜索域缩到 ≤2048 整数值后逐值打 BF,全不命中 → 整 row group 跳过,全命中 → BF 没用、行级跳过 BF。

**动态阶段**(join build 后):由 `JoinFilterPushdownInfo::FinalizeFilters` 构造 `SelectivityOptionalFilter<BFTableFilter>` 下推。详 [[RUNTIME_FILTER_DESIGN §10]]。

### 5.6 FilterCombiner 传递性推理的扫描端收益

详见 [FILTER_PUSHDOWN_DESIGN §3.6](./FILTER_PUSHDOWN_DESIGN.md#36-filtercombiner-三大推理)。这里补一点对扫描端的间接收益:`a = b AND b > 100` 在 join 上游推出 `a > 100` 后,**也能下推到 a 所在 scan** —— 给 build / probe 两侧都加 zone-map 机会,从而把 join 上游的 row group 剪枝率显著提高。

### 5.7 ExpressionFilter 兜底的代价与启示

`expression_filter.cpp:29-37` 明确返回 `NO_PRUNING_POSSIBLE`(geometry 例外),所以:

- **无 zone-map 收益**:整 row group 必读;
- **无 SIMD 模板化**:走 ExpressionExecutor 解释执行;
- **不能合并**:多个 ExpressionFilter 各跑各的。

但相比 LogicalFilter:
- **省去 chunk 出 scan 后再过滤的算子调度开销**;
- **late materialization 仍适用**:命中行才物化其它列;
- **可与其它 TableFilter 共享 SelectionVector** 流式收窄。

**表达式简化的价值**:如果能把 `CAST(x AS DATE) > '1996-01-01'` 简化为 `x > '1996-01-01'::TIMESTAMP`,就能从 ExpressionFilter 退化为 ConstantFilter,**直接拿到 zone-map**。值得在 optimizer 里多做这类:

| 模式 | 原 ExpressionFilter | 简化后 |
|---|---|---|
| `CAST(x AS T) op c` | yes | `x op cast_back(c)`,如果可逆 |
| `f(x) op c`(f 单调) | yes | `x op f⁻¹(c)` |
| `x + k op c`(k 常量) | yes | `x op c-k` |
| `lower(x) = 'abc'` | yes | `x IN ('abc', 'Abc', 'ABc', …)` 当 cardinality 小 |

DuckDB 的 `FilterCombiner` / `expression_rewriter` 中已实现部分。

---

## §6 端到端例子

来追一条 TPC-H 风格的 SQL:

```sql
SELECT l_orderkey, SUM(l_extendedprice * (1 - l_discount))
FROM lineitem
WHERE l_shipdate BETWEEN DATE '1996-01-01' AND DATE '1996-12-31'
  AND l_quantity > 24
  AND l_returnflag IN ('A', 'R')
  AND l_comment LIKE '%urgent%'
GROUP BY l_orderkey;
```

### 6.1 Optimizer 阶段

`LogicalFilter::SplitPredicates` 把 AND 展平成 4 个谓词,逐个 `combiner.AddFilter`:

| 谓词 | combiner 处理 | 结果 |
|---|---|---|
| `l_shipdate BETWEEN ... AND ...` | `AddFilter` 走 BoundBetween 分支,拆 2×`ConstantFilter`,各自 push 到 `l_shipdate` | TableFilterSet[l_shipdate] = ConjunctionAndFilter{>=1996-01-01, <=1996-12-31}(由 PushFilter 自动 AND) |
| `l_quantity > 24` | BoundComparison → ConstantFilter | TableFilterSet[l_quantity] = ConstantFilter(>,24) |
| `l_returnflag IN ('A','R')` | TryPushdownInFilter:string 不走密集 path,落到非密集分支 → InFilter + OptionalFilter | TableFilterSet[l_returnflag] = OptionalFilter(InFilter(['A','R'])) |
| `l_comment LIKE '%urgent%'` | 非前缀 LIKE,combiner 返回 UNSUPPORTED;`PushdownGet` 最后阶段 `TryPushdownGenericExpression` 包 ExpressionFilter | TableFilterSet[l_comment] = ExpressionFilter(l_comment LIKE '%urgent%') |

最终 `LogicalGet::table_filters`:

```
TableFilterSet {
    l_shipdate:    ConjunctionAndFilter {
                       ConstantFilter(>= 1996-01-01),
                       ConstantFilter(<= 1996-12-31)
                   },
    l_quantity:    ConstantFilter(> 24),
    l_returnflag:  OptionalFilter { InFilter(['A','R']) },
    l_comment:     ExpressionFilter("l_comment LIKE '%urgent%'")
}
```

### 6.2 Row group 级 zone-map

假设 lineitem 物理按 `l_shipdate` 聚簇(TPC-H dbgen 默认顺序),100M 行分成 ~800 个 row group。

| 列 | filter | CheckStatistics 结果 |
|---|---|---|
| `l_shipdate` | ConjunctionAndFilter | row group min/max 命中 1996 区间外的:`ALWAYS_FALSE` → **整 row group 跳过**;命中区间内:`ALWAYS_TRUE`(整段都在 1996);跨边界:`NO_PRUNING_POSSIBLE` |
| `l_quantity` | ConstantFilter(>24) | row group min/max 大多数命中 [1,50]:`NO_PRUNING_POSSIBLE`;极少数全 <= 24 的段:`ALWAYS_FALSE` |
| `l_returnflag` | OptionalFilter | 类型为 OPTIONAL → **无论 prune_result 都 SetFilterAlwaysTrue**,后续 vector 级别不再执行;但 stats 命中 'A','R' 之外的整段会被 `ALWAYS_FALSE` 跳过(InFilter 在 zone-map 阶段还是会查) |
| `l_comment` | ExpressionFilter | `NO_PRUNING_POSSIBLE`(无 geometry stats) |

**总体效果**:大部分 row group 被 `l_shipdate` 剪掉,余下 ~70(年份命中)进入 vector 级。

### 6.3 Vector 级 partial scan

留下的 row group 进入 `RowGroup::Scan`:

1. **filter 列先扫**:`l_shipdate` / `l_quantity` / `l_returnflag` / `l_comment` 都有 filter。
   - `l_returnflag` 的 filter 是 OPTIONAL,被标 always-true,**不会进入 vector hot loop**;
   - 实际逐 vector 跑的是 `l_shipdate`(ConjunctionAndFilter → 两个 ConstantFilter)、`l_quantity`(ConstantFilter)、`l_comment`(ExpressionFilter)。
2. **AdaptiveFilter 排序**:经过若干 vector 观察后,permutation 可能演变为 `[l_quantity, l_shipdate, l_comment]`(假设 `l_quantity > 24` 选择率最低、`l_comment LIKE` 最贵留到最后)。
3. **SelectionVector 流式收窄**:每个 filter 把 `approved_tuple_count` 减少。
4. **Slice + late materialization**:filter 列按最终 sel `Slice` 一次;`l_orderkey`、`l_extendedprice`、`l_discount` 只为命中行 `Select` 物化。
5. **HASH GROUP BY 上游消费**:scan 输出的 chunk 只含命中行,直接进入 `PhysicalHashGroupBy`。

### 6.4 EXPLAIN ANALYZE 期望节选

```
┌─────────────────────────────────────────┐
│            HASH_GROUP_BY                │
│   --------------------                  │
│   Groups: #0                            │
└──────────────┬──────────────────────────┘
┌──────────────┴──────────────────────────┐
│              PROJECTION                 │
│   --------------------                  │
│   l_orderkey                            │
│   l_extendedprice * (1 - l_discount)    │
└──────────────┬──────────────────────────┘
┌──────────────┴──────────────────────────┐
│               FILTER                    │
│   --------------------                  │
│   l_comment LIKE '%urgent%'             │  ← LIKE 还留在 LogicalFilter 上游
└──────────────┬──────────────────────────┘
┌──────────────┴──────────────────────────┐
│             TABLE_SCAN                  │
│   --------------------                  │
│   Table: lineitem                       │
│   Filters:                              │
│     l_shipdate >= 1996-01-01 AND        │
│     l_shipdate <= 1996-12-31            │
│     l_quantity > 24                     │
│     optional: l_returnflag IN ('A','R') │
└─────────────────────────────────────────┘
```

实际生产的 `EXPLAIN ANALYZE` 还会带 row 数、时间等。这里只示意 `Filters:` 节点的格式。
