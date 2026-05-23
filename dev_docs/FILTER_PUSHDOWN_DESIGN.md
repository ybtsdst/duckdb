# DuckDB Filter Pushdown 设计文档(规划期转换)

> 本文是 `FILTER_DESIGN.md` 系列的第 2 篇,专注**规划期**:`WHERE` 子句中的 bound expression 是怎么转成 `TableFilter` 子类的。FilterPushdown 的入口链路、FilterCombiner 的等价类与传递性推理、各 bound expression 类型的转换映射、OR/IN/LIKE/BETWEEN 的特殊处理。
>
> 类层次本身见 [FILTER_DESIGN.md](./FILTER_DESIGN.md);执行时的 zone-map 与 vector 级 filter 见 [FILTER_EXECUTION_DESIGN.md](./FILTER_EXECUTION_DESIGN.md);7 类性能优化见 [FILTER_PERFORMANCE_DESIGN.md](./FILTER_PERFORMANCE_DESIGN.md)。

## §3 bool 表达式 → TableFilter

### 3.1 入口链路

```
LogicalFilter (WHERE)
  ↓
LogicalFilter::SplitPredicates           ← 展平 CONJUNCTION_AND
  src/planner/operator/logical_filter.cpp:25-43
  ↓
FilterPushdown::PushdownFilter
  src/optimizer/filter_pushdown.cpp
  ↓
FilterPushdown::PushdownGet              ← 进入 LogicalGet 的入口
  src/optimizer/pushdown/pushdown_get.cpp:10-96
  ├── combiner.AddFilter(*filter)        ← 进入等价类/传递推理
  └── combiner.GenerateTableScanFilters  ← 输出 TableFilterSet
       └── 写入 LogicalGet::table_filters
```

`LogicalFilter::SplitPredicates`(`logical_filter.cpp:25-43`):把 `WHERE a AND b AND (c AND d)` 嵌套 AND 拍成 `[a, b, c, d]`,每个子表达式独立送进 combiner。这是「AND 不需要单独的 `ConjunctionAndFilter`」的根源 —— optimizer 层把 AND 当成平铺的谓词集合,需要时由 `TableFilterSet::PushFilter` 自动 AND(见 [FILTER_DESIGN.md §2.3](./FILTER_DESIGN.md#23-tablefilterset每列一个-filter))。

```cpp
// logical_filter.cpp:25-43
bool LogicalFilter::SplitPredicates(vector<unique_ptr<Expression>> &expressions) {
    bool found_conjunction = false;
    for (idx_t i = 0; i < expressions.size(); i++) {
        if (expressions[i]->GetExpressionType() == ExpressionType::CONJUNCTION_AND) {
            auto &conjunction = expressions[i]->Cast<BoundConjunctionExpression>();
            found_conjunction = true;
            for (idx_t k = 1; k < conjunction.children.size(); k++) {
                expressions.push_back(std::move(conjunction.children[k]));
            }
            expressions[i] = std::move(conjunction.children[0]);
            i--;   // 重新检查该位置,处理嵌套 AND
        }
    }
    return found_conjunction;
}
```

`FilterPushdown::PushdownGet`(`pushdown_get.cpp:10-96`)的主流程:

```cpp
unique_ptr<LogicalOperator> FilterPushdown::PushdownGet(unique_ptr<LogicalOperator> op) {
    auto &get = op->Cast<LogicalGet>();

    // (1) 给 table function 一次自定义 pushdown 的机会
    if (get.function.pushdown_complex_filter) {
        ...
        get.function.pushdown_complex_filter(optimizer.context, get, get.bind_data.get(), expressions);
        ...
    }

    if (!get.table_filters.filters.empty() || !get.function.filter_pushdown) {
        return FinishPushdown(std::move(op));   // table function 不支持就退回 LogicalFilter
    }

    // (2) AddFilter 到 combiner(等价类、传递推理)
    if (PushFilters() == FilterResult::UNSATISFIABLE) {
        return make_uniq<LogicalEmptyResult>(std::move(op));   // x=5 AND x=10 检测出来直接空集
    }

    // (3) 生成 TableFilterSet
    vector<FilterPushdownResult> pushdown_results;
    get.table_filters = combiner.GenerateTableScanFilters(column_ids, pushdown_results);

    GenerateFilters();   // 回吐未推下去的表达式到 remaining filters

    // (4) 剩余表达式:能尝试就包 ExpressionFilter
    for (idx_t i = 0; i < filters.size(); ++i) {
        ...
        pushdown_result = combiner.TryPushdownGenericExpression(get, expr);
        if (pushdown_result == FilterPushdownResult::PUSHED_DOWN_FULLY) {
            filters.erase_at(i--);
        }
    }

    return FinishPushdown(std::move(op));   // 没推下去的留在 LogicalFilter
}
```

### 3.2 各 bound expression 类型的转换映射

| Bound 表达式 | 目标 TableFilter | 关键转换函数 | 备注 |
|---|---|---|---|
| `BoundConjunctionExpression`(AND) | 展平到顶层,逐条 AddFilter,**不**生成 ConjunctionAndFilter | `logical_filter.cpp:28`,`filter_pushdown.cpp` | 同列冲突由 `TableFilterSet::PushFilter` 合并(FILTER_DESIGN §2.3) |
| `BoundConjunctionExpression`(OR) | `ConjunctionOrFilter` 外包 `OptionalFilter` | `filter_combiner.cpp:588-662 TryPushdownOrClause` | 只对**同列** OR;跨列 OR 不进 TableFilter |
| `BoundComparisonExpression`(=, !=, <, ≤, >, ≥) | `ConstantFilter` | `filter_combiner.cpp:717-813 AddBoundComparisonFilter` | NULL 常量 → `UNSATISFIABLE` |
| `BoundBetweenExpression` | 拆 2×`ConstantFilter`(>=lo AND <=hi) | `filter_combiner.cpp:836-913` | 拆后走传递性合并 |
| `BoundOperatorExpression`(IN) | 1 元素 → `ConstantFilter`;密集整数 → 2 范围 `ConstantFilter`;其他 → `InFilter`(包 OptionalFilter) | `filter_combiner.cpp:515-586 TryPushdownInFilter` | 详 §3.4 |
| `BoundOperatorExpression`(IS NULL / IS NOT NULL) | `IsNullFilter` / `IsNotNullFilter` | `null_filter.cpp` | OR 分句的 `DISTINCT_FROM` / `NOT_DISTINCT_FROM` 也走这里(`filter_combiner.cpp:640,645`) |
| `BoundOperatorExpression`(LIKE prefix `'abc%'`) | 2×`ConstantFilter`(>=prefix AND <=prefix+1) + LIKE 兜底 | `filter_combiner.cpp:498-513 TryPushdownPrefixFilter` | LIKE 仍需 ExpressionFilter 兜底,因为 zone-map 范围比 LIKE 更宽松 |
| LIKE 非前缀 / NOT / 函数 / 多列谓词 / UDF | `ExpressionFilter` 兜底 | `filter_combiner.cpp:919` UNSUPPORTED;`TryPushdownGenericExpression` | 无 zone-map 收益 |

### 3.3 OR 的特殊处理

`TryPushdownOrClause`(`filter_combiner.cpp:588-663`):

```cpp
FilterPushdownResult FilterCombiner::TryPushdownOrClause(...) {
    if (expr.GetExpressionType() != ExpressionType::CONJUNCTION_OR) return NO_PUSHDOWN;
    auto conj_filter = make_uniq<ConjunctionOrFilter>();
    idx_t column_id = 0;
    for (idx_t i = 0; i < conj.children.size(); i++) {
        auto &child = conj.children[i];
        if (child->GetExpressionClass() != ExpressionClass::BOUND_COMPARISON) return NO_PUSHDOWN;
        // 只接受 (col op const) 或 (const op col) 模式
        ...
        if (i == 0) {
            column_id = column_ids[column_ref->binding.column_index].GetPrimaryIndex();
        } else if (column_id != column_ids[column_ref->binding.column_index].GetPrimaryIndex()) {
            return FilterPushdownResult::NO_PUSHDOWN;   // ← 跨列 OR 不下推
        }
        ...
        // null 常量:DISTINCT_FROM → IsNotNullFilter, NOT_DISTINCT_FROM → IsNullFilter
        // 其他 EQUAL/NOT_EQUAL with NULL → 直接忽略(NULL 三值在 OR 链里恒假)
        ...
        conj_filter->child_filters.push_back(std::move(const_filter));
    }
    // 全部子句都是同列 col op const → 包 OptionalFilter 后 push
    auto optional_filter = make_uniq<OptionalFilter>();
    optional_filter->child_filter = std::move(conj_filter);
    table_filters.PushFilter(ColumnIndex(column_id), std::move(optional_filter));
    return FilterPushdownResult::PUSHED_DOWN_PARTIALLY;
}
```

要点:
1. **OR 的子句必须全部是 `col op const`**(或 `const op col`),否则整支 NO_PUSHDOWN;
2. **OR 的所有子句必须引用同一列**,跨列 OR 不下推;
3. **NULL 常量**只在 `DISTINCT_FROM / NOT_DISTINCT_FROM` 时有用(转 `IsNotNullFilter` / `IsNullFilter`);
4. **整体包 `OptionalFilter`** —— 因为 `ConjunctionOrFilter` 行级执行(O(N×M) 朴素查所有 child)远慢于 LogicalFilter 算子,只用它做 zone-map 剪枝。

### 3.4 IN 的多档处理

`TryPushdownInFilter`(`filter_combiner.cpp:515-586`)分四档:

```cpp
// 1) 单元素 IN → ConstantFilter(EQUAL)
if (func.children.size() == 2 && TypeSupportsConstantFilter(type)) {
    auto bound_eq_comparison = make_uniq<ConstantFilter>(ExpressionType::COMPARE_EQUAL, fst_const_value_expr.value);
    table_filters.PushFilter(column_index, std::move(bound_eq_comparison));
    return FilterPushdownResult::PUSHED_DOWN_FULLY;
}

// 2) 密集整数 IN → 范围 ConstantFilter
if (type.IsIntegral() && IsDenseRange(in_list)) {
    auto lower_bound = make_uniq<ConstantFilter>(COMPARE_GREATERTHANOREQUALTO, std::move(in_list.front()));
    auto upper_bound = make_uniq<ConstantFilter>(COMPARE_LESSTHANOREQUALTO,    std::move(in_list.back()));
    table_filters.PushFilter(column_index, std::move(lower_bound));
    table_filters.PushFilter(column_index, std::move(upper_bound));
    return FilterPushdownResult::PUSHED_DOWN_FULLY;
}

// 3) 非密集 → InFilter + OptionalFilter
auto optional_filter = make_uniq<OptionalFilter>();
auto in_filter = make_uniq<InFilter>(std::move(in_list));
optional_filter->child_filter = std::move(in_filter);
table_filters.PushFilter(column_index, std::move(optional_filter));
return FilterPushdownResult::PUSHED_DOWN_PARTIALLY;
```

- **单元素 IN**(`x IN (5)`):退化为 `x = 5`,完美下推。
- **密集整数 IN**(`x IN (1, 2, 3, 4, 5)`):变成 `x >= 1 AND x <= 5`,**完全下推** —— zone-map 剪枝 + 行级 fast path。`IsDenseRange` 排序后检查相邻差值,所以**牺牲一些精度**(漏过的"洞"留在 LogicalFilter 由 LogicalFilter 二次过滤);但 DuckDB 这里默认是 `PUSHED_DOWN_FULLY` 后**移除**对应 LogicalFilter 表达式(`pushdown_get.cpp:87-90`),所以密集 IN 是完全下推、**没有二次过滤**。
- **非密集 IN**(`x IN (1, 5, 17)`):包 OptionalFilter 后 push,仅享受 zone-map 剪枝,行级回到 LogicalFilter。

**大 IN 列表的 Bloom filter 形态**:静态阶段 IN 不会变 BloomFilter(只在 join build 后的 runtime filter 阶段会)。

### 3.5 LIKE prefix 的处理

`TryPushdownPrefixFilter`(`filter_combiner.cpp:498-513`)处理 `WHERE x LIKE 'abc%'`:

```cpp
// 拆成 x >= 'abc' AND x <= 'abd'(也就是 prefix + 1)
auto lower_bound = make_uniq<ConstantFilter>(COMPARE_GREATERTHANOREQUALTO, Value(prefix));
prefix[prefix.size() - 1]++;
auto upper_bound = make_uniq<ConstantFilter>(COMPARE_LESSTHAN, Value(prefix));
table_filters.PushFilter(column_index, std::move(lower_bound));
table_filters.PushFilter(column_index, std::move(upper_bound));
return FilterPushdownResult::PUSHED_DOWN_PARTIALLY;   // ← 注意 PARTIALLY
```

`PARTIALLY` 表示「**LIKE 仍在 LogicalFilter 中保留**」 —— 因为 `[abc, abd)` 比 `LIKE 'abc%'` 范围更宽(注:在 ASCII 排序下 `LIKE 'abc%'` 等价于 `>= 'abc' AND < 'abd'`,但如果碰到非 ASCII / 字符集排序问题,二者可能不严格等价,所以保留行级 LIKE 校验)。**zone-map 剪枝得到,但行级真值由 LogicalFilter 决定**。

### 3.6 FilterCombiner 三大推理

`FilterCombiner` 是 optimizer 中最有意思的部分,在 `AddFilter` 调用过程中沉淀了三种推理能力。

#### 3.6.1 等价类合并

`AddConstantComparison`(`filter_combiner.cpp:71-99`):

```cpp
FilterResult FilterCombiner::AddConstantComparison(vector<ExpressionValueInformation> &info_list,
                                                   ExpressionValueInformation info) {
    ...
    for (idx_t i = 0; i < info_list.size(); i++) {
        auto comparison = CompareValueInformation(info_list[i], info);
        switch (comparison) {
        case ValueComparisonResult::PRUNE_LEFT:   info_list.erase_at(i); i--; break;
        case ValueComparisonResult::PRUNE_RIGHT:  return FilterResult::SUCCESS;
        case ValueComparisonResult::UNSATISFIABLE_CONDITION:
            info_list.push_back(info);
            return FilterResult::UNSATISFIABLE;
        default: break;
        }
    }
    info_list.push_back(info);
    return FilterResult::SUCCESS;
}
```

例:`x > 5 AND x > 7 ⇒ x > 7`(`x > 5` 被 `PRUNE_LEFT`)。每个列表达式有一个等价类,等价类内的多个常量比较会两两比对消除冗余。

#### 3.6.2 跨列等价 / 传递

`AddBoundComparisonFilter`(`filter_combiner.cpp:717-813`)处理两种情况:

1. **常量比较**:`x = 5` 加到 `x` 的等价类(`:726-769`)。同时,如果 `x` 在等价图里已经和 `y` 相等(`x = y` 之前已加),`FindTransitiveFilter` + `AddTransitiveFilters` 会生成 `y = 5`(`:756-768`)。
2. **跨列相等**(`x = y`):把 `y` 的等价类整体并入 `x` 的等价类(`:770-811`),所有约束传递过去:

```cpp
// :793-810 合并两个等价类
auto &left_bucket = equivalence_map.find(left_equivalence_set)->second;
auto &right_bucket = equivalence_map.find(right_equivalence_set)->second;
for (auto &right_expr : right_bucket) {
    equivalence_set_map[right_expr] = left_equivalence_set;
    left_bucket.push_back(right_expr);
}
auto &left_constant_bucket = constant_values.find(left_equivalence_set)->second;
auto &right_constant_bucket = constant_values.find(right_equivalence_set)->second;
for (auto &right_constant : right_constant_bucket) {
    if (AddConstantComparison(left_constant_bucket, right_constant) == FilterResult::UNSATISFIABLE) {
        return FilterResult::UNSATISFIABLE;
    }
}
```

这是为什么 `SELECT * FROM a JOIN b ON a.k = b.k WHERE a.k > 100` 可以同时下推 `b.k > 100` —— join 上游的 `a.k > 100` 通过等价类传到 `b.k` 上。

#### 3.6.3 不可满足检测

`UNSATISFIABLE_CONDITION` 是 `CompareValueInformation` 的一种返回(比如 `x = 5 AND x > 6`)。`AddFilter` 一旦发现:

```cpp
// pushdown_get.cpp:52-54
if (PushFilters() == FilterResult::UNSATISFIABLE) {
    return make_uniq<LogicalEmptyResult>(std::move(op));
}
```

整支 scan 直接被替换为 `LogicalEmptyResult`,不再生成任何 plan node。

### 3.7 反面例子(无法下推的)

- **跨列谓词**`a > b`:`AddBoundComparisonFilter` 在 `:773-781` 处理「两个非标量」时只接受 `COMPARE_EQUAL`(用作等价类合并),其它比较直接返 UNSUPPORTED,保留在 LogicalFilter;
- **CAST 包裹的列**:`CAST(x AS DATE) > '1996-01-01'` 中 LHS 不是 BoundColumnRef,直接 UNSUPPORTED → ExpressionFilter。如果 optimizer 能简化 CAST(把右值转过去)就能退化为 ConstantFilter,**这是 Ada P0b 的本质**(详 ada-docs/query/duckdb-filter-borrow.md);
- **UDF / 函数**:`my_udf(x) > 5` —— 同上,UNSUPPORTED;
- **包含 `NULL` 常量的等值**:`x = NULL` 在 `:735-738` 直接返回 `UNSATISFIABLE`(永远空集),整支 scan 替换为 `LogicalEmptyResult`。

### 3.8 关键文件清单

| 路径 | 作用 |
|---|---|
| `src/optimizer/filter_pushdown.cpp` | `FilterPushdown` 主框架 |
| `src/optimizer/pushdown/pushdown_get.cpp` | LogicalGet 入口、TryPushdownGenericExpression 兜底 |
| `src/optimizer/filter_combiner.cpp` | 等价类、传递推理、BoundComparison/BoundBetween/OR/IN/LIKE 转换 |
| `src/planner/operator/logical_filter.cpp` | `SplitPredicates` AND 展平 |
| `src/optimizer/topn_optimizer.cpp` | TopN DynamicFilter 下推(详见 FILTER_PERFORMANCE_DESIGN §5.3) |
| `src/include/duckdb/optimizer/expression_heuristics.hpp` | `GetInitialOrder` 决定 AdaptiveFilter 初始 permutation(详见 FILTER_EXECUTION_DESIGN §4.6) |
