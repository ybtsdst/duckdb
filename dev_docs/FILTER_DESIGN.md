# DuckDB Filter 体系设计文档(总论)

> 本文系列把 DuckDB 静态 `TableFilter` 体系按生命周期拆成 4 篇,本篇是入口:概念、`TableFilterType` 枚举、`TableFilter` 类层次与 10 个具体子类、`TableFilterSet` / `DynamicTableFilterSet`、限制与边界、文件清单与术语表。规划期、扫描期、性能机制单独成文,Ada 借鉴对照在 ada-docs 仓里。

## 本系列文档

| 文档 | 内容 |
|---|---|
| **本文 FILTER_DESIGN.md** | 总论 / 概念 / 类层次 / 数据结构 / 限制 / 附录 |
| [FILTER_PUSHDOWN_DESIGN.md](./FILTER_PUSHDOWN_DESIGN.md) | bool 表达式 → TableFilter:`LogicalFilter::SplitPredicates` / `FilterPushdown` / `FilterCombiner` 全链路与各 bound expression 类型的转换 |
| [FILTER_EXECUTION_DESIGN.md](./FILTER_EXECUTION_DESIGN.md) | 扫描期执行:三层 zone-map(row group / segment / vector)、`ColumnSegment::FilterSelection` 模板化、late materialization、`AdaptiveFilter` ε-greedy 重排 |
| [FILTER_PERFORMANCE_DESIGN.md](./FILTER_PERFORMANCE_DESIGN.md) | 7 类性能优化机制深入 + 端到端 SQL 例子 |

相邻文档:
- [[RUNTIME_FILTER_DESIGN]] —— join build→probe 端到端 runtime filter,FILTER_PERFORMANCE_DESIGN §5.3 / §5.5 边界处引用。
- [[LATE_MATERIALIZATION_DESIGN]] —— filter 命中行才物化无关列,FILTER_EXECUTION_DESIGN §4.4 引用。
- [[EXPRESSION_DESIGN]] / [[LIKE_EXECUTION_ANALYSIS]] —— `ExpressionFilter` 兜底里 `ExpressionExecutor::SelectExpression` 细节归这两篇。

Ada 借鉴对照已迁到 ada-docs 仓:`query/duckdb-filter-borrow.md`。

---

## §1 背景与核心概念

### 1.1 DuckDB 的 push-down 哲学

DuckDB 把 `WHERE` 子句中的谓词分成两类处理:

- **`LogicalFilter` 算子**:独立 plan node,执行时整 chunk 跑 `ExpressionExecutor::SelectExpression()`,任意复杂表达式都能通过(UDF、函数调用、跨列谓词)。
- **`TableFilter`**:**下推到 scan 内部**的、按列组织的过滤器。三个独有特性:
  1. 参与 **zone-map / 统计剪枝**(`CheckStatistics`),整 row group / segment 可被整块跳过,**根本不读 I/O**;
  2. **late materialization** —— 只有命中谓词的行才物化其它列;
  3. 走 **模板化 fast path**(`TemplatedFilterSelection<T, OP, HAS_NULL>`),没有虚函数、SIMD 友好。

Optimizer 的目标是把 `WHERE` 中尽量多的谓词转成 `TableFilter`,无法转的留 LogicalFilter。

### 1.2 管线位置

```
SQL
 ↓
Binder → BoundExpression
 ↓
Optimizer
 ├── FilterPushdown::PushdownFilter
 │    └── LogicalFilter::SplitPredicates  ← 展平 AND
 ├── FilterPushdown::PushdownGet           ← 进入 scan 入口
 │    └── FilterCombiner::AddFilter        ← 等价/传递推理
 └── FilterCombiner::GenerateTableScanFilters → TableFilterSet
 ↓
LogicalGet::table_filters
 ↓
PhysicalTableScan(持 unique_ptr<TableFilterSet>)
 ↓
Storage Layer
 ├── RowGroup::CheckZonemap          ← row group 级剪枝
 ├── RowGroup::CheckZonemapSegments  ← segment 级推进
 └── RowGroup::Scan
      ├── 先扫 filter 列,SelectionVector 流式收窄
      └── 命中行才 Select 其他列(late materialization)
```

### 1.3 `TableFilterType` 枚举

`src/include/duckdb/planner/table_filter.hpp:26-38` 一共 11 个具体类型:

| 序号 | 枚举值 | 含义 |
|---|---|---|
| 0 | `CONSTANT_COMPARISON` | 列与常量比较(`=C`, `>C`, `<=C`, …) |
| 1 | `IS_NULL` | `C IS NULL` |
| 2 | `IS_NOT_NULL` | `C IS NOT NULL` |
| 3 | `CONJUNCTION_OR` | 多个子 filter 的 OR |
| 4 | `CONJUNCTION_AND` | 多个子 filter 的 AND |
| 5 | `STRUCT_EXTRACT` | 应用到 struct 子字段的 filter |
| 6 | `OPTIONAL_FILTER` | 执行非必须、可仅用于 zone-map 剪枝 |
| 7 | `IN_FILTER` | `col IN (C1, C2, …)` |
| 8 | `DYNAMIC_FILTER` | 运行时可更新的 filter |
| 9 | `EXPRESSION_FILTER` | 任意表达式兜底 |
| 10 | `BLOOM_FILTER` | 概率集合成员测试 |

### 1.4 为什么按列组织

`TableFilterSet`(`table_filter.hpp:84-126`)的存储是 `map<idx_t, unique_ptr<TableFilter>>`,**每列最多一个顶层 filter**。源码注释明确写:

```cpp
//! The filters in here are non-composite (only need a single column to be evaluated)
//! Conditions like `A = 2 OR B = 4` are not pushed into a TableFilterSet.
```

这条限制有三个动机:
1. **zone-map 是按列存的**:跨列谓词 `a > b` 没法用 `a` 的统计或 `b` 的统计单独剪枝;
2. **模板化 fast path 是单列驱动的**:`ColumnSegment::FilterSelection` 只接收单个 `Vector` 与对应的 filter;
3. **同列多谓词易合并**:`TableFilterSet::PushFilter` 自动 AND(见 §2.3)。

跨列 OR(`a=2 OR b=4`)保留在 `LogicalFilter`,无法走 zone-map 收益。同列 OR(`a=2 OR a=4`)则转 `ConjunctionOrFilter`,**包在 `OptionalFilter` 里**走 zone-map(详 FILTER_PUSHDOWN_DESIGN §3.3、FILTER_PERFORMANCE_DESIGN §5.4)。

---

## §2 类层次与数据结构

### 2.1 `TableFilter` 基类

`src/include/duckdb/planner/table_filter.hpp:41-80`:

```cpp
class TableFilter {
public:
    explicit TableFilter(TableFilterType filter_type_p);
    virtual ~TableFilter() {}

    TableFilterType filter_type;

public:
    //! Returns whether stats indicate the segment can contain values satisfying this filter
    virtual FilterPropagateResult CheckStatistics(BaseStatistics &stats) const = 0;
    virtual string ToString(const string &column_name) const = 0;
    string DebugToString() const;
    virtual unique_ptr<TableFilter> Copy() const = 0;
    virtual bool Equals(const TableFilter &other) const { ... }
    virtual unique_ptr<Expression> ToExpression(const Expression &column) const = 0;

    virtual void Serialize(Serializer &serializer) const;
    static unique_ptr<TableFilter> Deserialize(Deserializer &deserializer);
};
```

虚函数职责:

- **`CheckStatistics`**:用 `BaseStatistics`(min/max、null count、字典等)推断「这个 segment 有可能命中谓词吗?」。返回值见 FILTER_PERFORMANCE_DESIGN §5.1。
- **`ToString`**:打印到 `EXPLAIN ANALYZE` 的 `Filters:` 一节;
- **`Copy`**:`PhysicalTableScan` 拷贝、跨 worker 时需要;
- **`Equals`**:用于 dedup、planner cache、`DynamicTableFilterSet::Equals`;
- **`ToExpression`**:把 filter 转回 `Expression`,用于打印、回退到 LogicalFilter、跨语言序列化等;
- **`Serialize/Deserialize`**:DuckDB 子查询缓存、跨节点分发需要。

值得注意:**`Filter()` 不在基类**。逐 vector 的过滤(把 SelectionVector 收窄)由 `ColumnSegment::FilterSelection(...)` 在 `src/storage/table/column_segment.cpp:405` 一处集中分派,按 `filter.filter_type` switch 到模板化分支。这是 DuckDB 把 scan 跑到极致吞吐的关键(详 FILTER_EXECUTION_DESIGN §4.5)。

### 2.2 子类逐个介绍

下面 10 个子类。**`CONSTANT_COMPARISON`** + **`IS_NULL`** + **`IS_NOT_NULL`** 是叶子原子 filter;**`CONJUNCTION_AND/OR`** + **`STRUCT_EXTRACT`** + **`OPTIONAL_FILTER`** 是组合器;**`IN_FILTER`** / **`DYNAMIC_FILTER`** / **`BLOOM_FILTER`** / **`EXPRESSION_FILTER`** 各有独特语义。

#### 2.2.1 `ConstantFilter`(列 op 常量)

定义:`src/include/duckdb/planner/filter/constant_filter.hpp`,实现:`src/planner/filter/constant_filter.cpp:10-103`。

```cpp
ConstantFilter::ConstantFilter(ExpressionType comparison_type_p, Value constant_p)
    : TableFilter(TableFilterType::CONSTANT_COMPARISON),
      comparison_type(comparison_type_p),
      constant(std::move(constant_p)) {
    if (constant.IsNull()) {
        throw InternalException("ConstantFilter constant cannot be NULL - use IsNullFilter instead");
    }
}
```

**关键约束**:`constant` 不允许是 NULL(`:14`)。SQL 语义里 `x = NULL` / `x > NULL` 永远 NULL(三值逻辑),必须改用 `IsNullFilter`。FilterCombiner 转换时碰到 NULL 常量直接返回 `UNSATISFIABLE`(`filter_combiner.cpp:735-738`)。

`CheckStatistics` 的核心 3VL 边界(`:37-79`):

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

**仔细看 `:71-77`**:就算 NumericStats 报「值域上谓词永真」,**只要列里可能有 NULL**,filter 必须仍逐行执行—— SQL 里 `NULL > 5 = NULL ≠ true`,不能直接放行 NULL 行。这就是 FILTER_PERFORMANCE_DESIGN §5.1 要讲的 3VL 边界,**许多新人写存储层 filter 都会踩这个坑**。

#### 2.2.2 `IsNullFilter` / `IsNotNullFilter`

`src/planner/filter/null_filter.cpp:10-48`,逻辑直白:

```cpp
FilterPropagateResult IsNullFilter::CheckStatistics(BaseStatistics &stats) const {
    if (!stats.CanHaveNull()) {
        return FilterPropagateResult::FILTER_ALWAYS_FALSE;   // 没有 null,IS NULL 永假
    }
    if (!stats.CanHaveNoNull()) {
        return FilterPropagateResult::FILTER_ALWAYS_TRUE;    // 全是 null,IS NULL 永真
    }
    return FilterPropagateResult::NO_PRUNING_POSSIBLE;
}
```

`IsNotNullFilter::CheckStatistics`(`:39-49`)对称。这要求 stats 同时维护 `CanHaveNull()` 与 `CanHaveNoNull()` 两个信号(很多 storage engine 只有 has_null flag,无法回答「是否全 null」)。

#### 2.2.3 `ConjunctionAndFilter` / `ConjunctionOrFilter`

`src/include/duckdb/planner/filter/conjunction_filter.hpp` + `conjunction_filter.cpp`。

OR 的 `CheckStatistics`(`:10-22`):

```cpp
FilterPropagateResult ConjunctionOrFilter::CheckStatistics(BaseStatistics &stats) const {
    // the OR filter is true if ANY of the children is true
    D_ASSERT(!child_filters.empty());
    for (auto &filter : child_filters) {
        auto prune_result = filter->CheckStatistics(stats);
        if (prune_result == FilterPropagateResult::NO_PRUNING_POSSIBLE) {
            return FilterPropagateResult::NO_PRUNING_POSSIBLE;
        } else if (prune_result == FilterPropagateResult::FILTER_ALWAYS_TRUE) {
            return FilterPropagateResult::FILTER_ALWAYS_TRUE;
        }
    }
    return FilterPropagateResult::FILTER_ALWAYS_FALSE;
}
```

短路逻辑:任一子 `ALWAYS_TRUE` → OR 整体 `ALWAYS_TRUE`;任一子 `NO_PRUNING_POSSIBLE` → OR 整体 `NO_PRUNING_POSSIBLE`;**所有子都 `ALWAYS_FALSE`** → OR 整体 `ALWAYS_FALSE`。注意这里没有 `*_OR_NULL` 的传递处理 —— `ConjunctionOrFilter` 在 row group 级使用,3VL 通过外层 `OptionalFilter` 隔离。

AND 的 `CheckStatistics`(`:70-83`)更微妙:

```cpp
FilterPropagateResult ConjunctionAndFilter::CheckStatistics(BaseStatistics &stats) const {
    D_ASSERT(!child_filters.empty());
    auto result = FilterPropagateResult::FILTER_ALWAYS_TRUE;
    for (auto &filter : child_filters) {
        auto prune_result = filter->CheckStatistics(stats);
        if (prune_result == FilterPropagateResult::FILTER_ALWAYS_FALSE) {
            return FilterPropagateResult::FILTER_ALWAYS_FALSE;
        } else if (prune_result != result) {
            result = FilterPropagateResult::NO_PRUNING_POSSIBLE;
        }
    }
    return result;
}
```

- 任一子 `ALWAYS_FALSE` → AND 整体 `ALWAYS_FALSE`(立即返回);
- 所有子结果**完全一致**(都 ALWAYS_TRUE 或都 NO_PRUNING_POSSIBLE)→ 保持该结果;
- 结果**不一致** → `NO_PRUNING_POSSIBLE`。

这意味着 AND 比 OR 在 row group 级**更激进**:只要有一个子能证明永假,整 row group 直接跳过。

#### 2.2.4 `InFilter`(`col IN (...)`)

`src/planner/filter/in_filter.cpp:9-86`。

构造期就拒绝 NULL 值与混合类型(`:10-22`):
```cpp
for (auto &val : values) {
    if (val.IsNull()) {
        throw InternalException("InFilter constant cannot be NULL - use IsNullFilter instead");
    }
}
```

`CheckStatistics`(`:25-51`)对每个 value 与 stats 做一次 `NumericStats::CheckZonemap` 或 `StringStats::CheckZonemap`,把所有 value 合起来当一组等价点查。**注意**:`IN` 列表很大时 InFilter 会很慢;当类型为整数且值域密集时,`FilterCombiner::TryPushdownInFilter` 会**降级为两个 `ConstantFilter`(>=min AND <=max)**,见 FILTER_PUSHDOWN_DESIGN §3.4。

#### 2.2.5 `StructFilter`

`src/include/duckdb/planner/filter/struct_filter.hpp`。包含 `child_idx`(struct 内的字段下标)+ `child_name` + `child_filter`。`CheckStatistics` 取出 `StructStats` 对应子字段的 stats 转发给 `child_filter`。

用途:`WHERE struct_col.field > 5`,先用 STRUCT_EXTRACT 路径定位字段,再委托给原子 filter。`pushdown_extract` 是支持矩阵;`TryPushdownInFilter` / `TryPushdownOrClause` 都会显式拒绝 `IsPushdownExtract()` 的列(`filter_combiner.cpp:528, 628`),因为 IN/OR 在嵌套字段上还没实现。

#### 2.2.6 `DynamicFilter` + `DynamicFilterData`

`src/include/duckdb/planner/filter/dynamic_filter.hpp:20-48`、`src/planner/filter/dynamic_filter.cpp`。

```cpp
struct DynamicFilterData {
    mutex lock;
    unique_ptr<TableFilter> filter;        // 内嵌的 ConstantFilter
    atomic<bool> initialized = {false};

    void SetValue(Value val);              // 执行期更新 ConstantFilter::constant
    void Reset();
};

class DynamicFilter : public TableFilter {
public:
    shared_ptr<DynamicFilterData> filter_data;
    ...
};
```

`CheckStatistics`(`:14-23`)在 `initialized=false` 时直接返回 `NO_PRUNING_POSSIBLE`(stats 还没积累出来),之后 `lock_guard` 进去转发给内层 ConstantFilter。

`SetValue`(`:54-61`):

```cpp
void DynamicFilterData::SetValue(Value val) {
    if (val.IsNull()) return;
    lock_guard<mutex> l(lock);
    filter->Cast<ConstantFilter>().constant = std::move(val);
    initialized = true;
}
```

设计要点:`shared_ptr<DynamicFilterData>` 让生产端(TopN / Limit / Join build)和消费端(scan)共享同一对象;**没有 atomic ConstantFilter**(只有 atomic bool),实际值更新走 mutex,因为 `Value` 不 trivially copyable。

来源:
- **TopN**(`src/optimizer/topn_optimizer.cpp:67-135` `TopN::PushdownDynamicFilters`)—— 单表 ORDER BY ... LIMIT k,把执行期 top-K 的边界值塞回 scan,详 FILTER_PERFORMANCE_DESIGN §5.3。
- **Join** —— 由 `JoinFilterPushdownOptimizer` 在 hash join build 侧生成 min/max DynamicFilter,详 [[RUNTIME_FILTER_DESIGN §10]](`DynamicFilter` 类型本身与 Top-N 下推)。

#### 2.2.7 `OptionalFilter`

`src/include/duckdb/planner/filter/optional_filter.hpp`、`src/planner/filter/optional_filter.cpp:7-35`。

```cpp
OptionalFilter::OptionalFilter(unique_ptr<TableFilter> filter)
    : TableFilter(TableFilterType::OPTIONAL_FILTER), child_filter(std::move(filter)) {}

FilterPropagateResult OptionalFilter::CheckStatistics(BaseStatistics &stats) const {
    return child_filter->CheckStatistics(stats);
}

idx_t OptionalFilter::FilterSelection(SelectionVector &sel, Vector &vector, ...,
                                      idx_t scan_count, idx_t &approved_tuple_count) const {
    return scan_count;   // ← 关键:逐行 evaluate 直接 no-op
}
```

**语义**:这是「**hint filter**」—— `CheckStatistics` 仍参与 row group 剪枝(stats 命中就剪),但逐 vector 执行直接 no-op,不参与行级判断。

这设计在两处场景特别有用:
1. **OR 跨多列**(`a=2 OR b=4`):跨列 OR 没法严格按列 push,DuckDB 给每一列单独 push 一个 `OptionalFilter(ConjunctionOrFilter(...))`,**只享受 zone-map 收益**,行级回到 LogicalFilter 跑;
2. **`InFilter` 非密集**:`x IN (1, 5, 17, 23, ...)` 不能简化成 BETWEEN,InFilter 单值 zone-map 检查的可剪率仍有用,但行级跑 InFilter 比 LogicalFilter 慢(`filter_combiner.cpp:580-585`),所以用 OptionalFilter 包。

`RowGroup::CheckZonemap` 对 OPTIONAL_FILTER 类型有专门分支,看完 stats 之后**无论结果都标 always-true**(详 FILTER_EXECUTION_DESIGN §4.2)。**这就是「OptionalFilter 仅为 zone-map 服务、从 hot loop 摘掉」这层设计**。

#### 2.2.8 `SelectivityOptionalFilter`

`src/include/duckdb/planner/filter/selectivity_optional_filter.hpp:47-70`、`src/planner/filter/selectivity_optional_filter.cpp:18-114`。

继承自 `OptionalFilter`,但**行级 not no-op**——它真的会跑子 filter,同时统计选择率,如果发现「这个 filter 没什么剪枝效果反而费 CPU」就主动停掉:

```cpp
enum class FilterStatus { ACTIVE, PAUSED_DUE_TO_HIGH_SELECTIVITY };

constexpr float MIN_MAX_THRESHOLD;  // min/max DynamicFilter 用
constexpr idx_t MIN_MAX_CHECK_N;
constexpr float BF_THRESHOLD;       // BFTableFilter 用
constexpr idx_t BF_CHECK_N;

void SelectivityOptionalFilterState::SelectivityStats::Update(idx_t accepted, idx_t processed) {
    if (vectors_processed < n_vectors_to_check) {
        tuples_accepted += accepted;
        tuples_processed += processed;
        vectors_processed += 1;
        if (vectors_processed == n_vectors_to_check) {
            if (GetSelectivity() >= selectivity_threshold) {
                status = FilterStatus::PAUSED_DUE_TO_HIGH_SELECTIVITY;
            }
        }
    }
}
```

`FilterSelection`(`:93-107`):
```cpp
idx_t SelectivityOptionalFilter::FilterSelection(...) const {
    auto &state = filter_state.Cast<SelectivityOptionalFilterState>();
    if (state.stats.IsActive()) {
        const idx_t approved_before = approved_tuple_count;
        const idx_t accepted_count = ColumnSegment::FilterSelection(
            sel, vector, vdata, *child_filter, *state.child_state, scan_count, approved_tuple_count);
        state.stats.Update(accepted_count, approved_before);
        return accepted_count;
    }
    return scan_count;   // 已暂停:跳过 child filter
}
```

源码里还有一条 TODO 注释(`:62-63`):

```cpp
// TODO: A potential optimization would be to pause the filter for this row group if the stats return always true,
//       but this needs to happen thread local, as other threads scan other row groups
```

DuckDB 作者承认 **per-row-group thread-local 暂停**还没做。这是性能调优的「天花板」标尺。

主要用途:`JoinFilterPushdownInfo::FinalizeFilters` 用 SelectivityOptionalFilter 包 min/max DynamicFilter / `BFTableFilter`,在 join build 完后下推。

#### 2.2.9 `BFTableFilter`(Bloom filter 形态)

`src/include/duckdb/planner/filter/bloom_filter.hpp`、`src/planner/filter/bloom_filter.cpp`。

两个相关类:`BloomFilter`(纯数据结构,`:14-80`)+ `BFTableFilter`(`TableFilter` 适配器,`:82-230`)。

BloomFilter 用 4 个 hash 位、cache-line 对齐的 sectorized blocked bloom 结构(`:7-12`):
```cpp
static constexpr idx_t MAX_NUM_SECTORS = (1ULL << 26);
static constexpr idx_t MIN_NUM_BITS_PER_KEY = 12;
static constexpr idx_t LOG_SECTOR_SIZE = 6;             // a sector is 64 bits
static constexpr idx_t N_BITS = 4;                      // bits to set per hash
```

12 bits per key 给出大约 0.04 假阳率(经验值,blocked BF 略高于经典 BF)。

`BFTableFilter::CheckStatistics`(`:173-198`)的玩法值得展开:

```cpp
template <class T>
static FilterPropagateResult TemplatedCheckStatistics(const BloomFilter &bf, const BaseStatistics &stats) {
    if (!NumericStats::HasMinMax(stats)) {
        return FilterPropagateResult::NO_PRUNING_POSSIBLE;
    }
    const auto min = NumericStats::GetMin<T>(stats);
    const auto max = NumericStats::GetMax<T>(stats);
    if (min > max) return FilterPropagateResult::NO_PRUNING_POSSIBLE;

    T range_typed;
    if (!TrySubtractOperator::Operation(max, min, range_typed) || range_typed > 2048) {
        return FilterPropagateResult::NO_PRUNING_POSSIBLE; // Overflow or too wide of a range
    }
    const auto range = NumericCast<idx_t>(range_typed);

    T val = min;
    idx_t hits = 0;
    for (idx_t i = 0; i <= range; i++) {
        hits += bf.LookupOne(Hash(val));
        val += i < range; // Avoids potential signed integer overflow on the last iteration
    }
    if (hits == 0)             return FilterPropagateResult::FILTER_ALWAYS_FALSE;
    if (hits == range + 1)     return FilterPropagateResult::FILTER_ALWAYS_TRUE;
    return FilterPropagateResult::NO_PRUNING_POSSIBLE;
}
```

**思路**:利用 stats 把搜索域缩小到 `[min, max]`(`:141-155`),如果整个区间 ≤ 2048 个整数值,**逐值打 BF**:
- 全部命中(`hits == range+1`)→ ALWAYS_TRUE(BF 覆盖整个段值域,逐行 BF 是浪费);
- 一个都没命中 → ALWAYS_FALSE(整段直接跳);
- 部分命中 → 仍需逐行执行 BF。

这是 `BFTableFilter` 比通用 BloomFilter 更聪明的地方:**把 BF 与 stats 拼在一起**,显著放大可剪枝率。

行级执行(`:96-133` `BFTableFilter::Filter`):用 `VectorOperations::Hash` 批量算 hash → `BloomFilter::LookupHashes` 批量查 → 更新 SelectionVector。常量向量有快路径(`:107-110`)。

#### 2.2.10 `ExpressionFilter`(兜底)

`src/include/duckdb/planner/filter/expression_filter.hpp`、`src/planner/filter/expression_filter.cpp`。

```cpp
ExpressionFilter::ExpressionFilter(unique_ptr<Expression> expr_p)
    : TableFilter(TableFilterType::EXPRESSION_FILTER), expr(std::move(expr_p)) {}

FilterPropagateResult ExpressionFilter::CheckStatistics(BaseStatistics &stats) const {
    if (stats.GetStatsType() == StatisticsType::GEOMETRY_STATS) {
        return GeometryStats::CheckZonemap(stats, expr);
    }
    // we cannot prune based on arbitrary expressions currently
    return FilterPropagateResult::NO_PRUNING_POSSIBLE;
}
```

**`NO_PRUNING_POSSIBLE` 永远不动 zone-map**(geometry 类型例外)。执行走 `ExpressionExecutor::SelectExpression()`,跟 LogicalFilter 算子内核一样。**但相比 LogicalFilter 仍有优势**:
1. **省去 chunk 出 scan、调度到下游算子、再调度回上游**的开销;
2. **late materialization 仍然适用** —— 这个表达式列先扫,其它列只为命中行 Select;
3. **可与其它 TableFilter 共享 SelectionVector**,流式收窄。

何时用 ExpressionFilter:
- LIKE 不带前缀通配(`%urgent%`);
- 含 UDF / 系统函数 / CAST 的复合表达式;
- FilterCombiner::AddFilter 返回 `UNSUPPORTED` 时由 `PushdownGet` 走 `TryPushdownGenericExpression` 包成 ExpressionFilter(`pushdown_get.cpp:86`)。

### 2.3 `TableFilterSet`(每列一个 filter)

`src/include/duckdb/planner/table_filter.hpp:84-126`、`src/planner/table_filter.cpp:10-28`。

```cpp
class TableFilterSet {
public:
    map<idx_t, unique_ptr<TableFilter>> filters;
    void PushFilter(const ColumnIndex &col_idx, unique_ptr<TableFilter> filter);
    bool Equals(TableFilterSet &other) { ... }
    unique_ptr<TableFilterSet> Copy() const { ... }
    void Serialize(Serializer &serializer) const;
    static TableFilterSet Deserialize(Deserializer &deserializer);
};
```

`PushFilter` 的同列合并(`table_filter.cpp:10-28`)是整个体系的一个关键约定:

```cpp
void TableFilterSet::PushFilter(const ColumnIndex &col_idx, unique_ptr<TableFilter> filter) {
    auto column_index = col_idx.GetPrimaryIndex();
    auto entry = filters.find(column_index);
    if (entry == filters.end()) {
        filters[column_index] = std::move(filter);
    } else {
        // there is already a filter: AND it together
        if (entry->second->filter_type == TableFilterType::CONJUNCTION_AND) {
            auto &and_filter = entry->second->Cast<ConjunctionAndFilter>();
            and_filter.child_filters.push_back(std::move(filter));
        } else {
            auto and_filter = make_uniq<ConjunctionAndFilter>();
            and_filter->child_filters.push_back(std::move(entry->second));
            and_filter->child_filters.push_back(std::move(filter));
            filters[column_index] = std::move(and_filter);
        }
    }
}
```

这是 optimizer 层**不主动**生成 `ConjunctionAndFilter` 的原因 —— 同列冲突的两个 `ConstantFilter`(比如 `x > 5` 和 `x < 100`)各自 `PushFilter` 后自动 AND 起来。这也让 BETWEEN 的拆解(FILTER_PUSHDOWN_DESIGN §3.4)很自然:拆成两个 `ConstantFilter` 各自 push,合并由 `PushFilter` 完成。

### 2.4 `DynamicTableFilterSet`(执行期注入)

`src/include/duckdb/planner/table_filter.hpp:128-140`、`src/planner/table_filter.cpp:34-78`。

```cpp
class DynamicTableFilterSet {
public:
    void ClearFilters(const PhysicalOperator &op);
    void PushFilter(const PhysicalOperator &op, idx_t column_index, unique_ptr<TableFilter> filter);
    bool HasFilters() const;
    unique_ptr<TableFilterSet> GetFinalTableFilters(const PhysicalTableScan &scan,
                                                    optional_ptr<TableFilterSet> existing_filters) const;
private:
    mutable mutex lock;
    reference_map_t<const PhysicalOperator, unique_ptr<TableFilterSet>> filters;
};
```

按 `PhysicalOperator` 索引(可多个生产者:不同的 join、TopN、Limit 都可能往同一 scan 注入)。`GetFinalTableFilters`(`table_filter.cpp:58-78`)在 `PhysicalTableScan::GetGlobalSourceState` 初始化阶段被调用,**和 base `table_filters` 合并**成最终的 set 传给 storage 层:

```cpp
// physical_table_scan.cpp:35-37
if (op.dynamic_filters && op.dynamic_filters->HasFilters()) {
    table_filters = op.dynamic_filters->GetFinalTableFilters(op, op.table_filters.get());
}
```

合并仍是用 `TableFilterSet::PushFilter`,所以**同列的静态 filter + 动态 filter 会被 AND 在一起**。

---

## §7 限制与边界

1. **跨列谓词**`a > b`:`TableFilterSet` 按列组织(`table_filter.hpp:82-83` 注释),不会进 TableFilter,保留在 LogicalFilter。
2. **LIKE 不带前缀通配**`%xxx%`:无 zone-map 收益,`ExpressionFilter` 兜底逐行跑。前缀 LIKE `'abc%'` 会拆为两个 ConstantFilter(`[abc, abd)`),**但 LIKE 仍在 LogicalFilter 中保留**(`TryPushdownPrefixFilter` 返回 PARTIALLY)。
3. **CAST 包裹的列**`CAST(x AS T) op c`:不进 ConstantFilter,落 ExpressionFilter。表达式简化(把 CAST 移到右侧)需要在 optimizer 里单独写,DuckDB 部分覆盖。
4. **OR 跨列**`a=2 OR b=4`:不进 TableFilter,LogicalFilter 兜底。
5. **OR 同列但子句非 `col op const` 形式**:也无法下推,LogicalFilter 兜底。
6. **NULL 语义**:`ConstantFilter` 拒绝 NULL 常量(`constant_filter.cpp:14`);`=NULL` 在 combiner 中转 `UNSATISFIABLE`(整支替换为 LogicalEmptyResult);3VL 通过 `*_OR_NULL` 结果传递;`ALWAYS_TRUE + CanHaveNull` 退化为 NO_PRUNING_POSSIBLE。
7. **`StructFilter` 与 IN/OR 不兼容**:`IsPushdownExtract()` 列在 `TryPushdownInFilter` / `TryPushdownOrClause` 被显式拒绝(`filter_combiner.cpp:528, 628`),嵌套字段上的 IN / OR 不下推。
8. **DynamicFilter 初始化前**:`initialized=false` 时 `CheckStatistics` 返回 NO_PRUNING_POSSIBLE,**zone-map 收益要等执行期值更新后才出现**。短 query 上 dynamic filter 可能完全没机会生效。
9. **late materialization 不适用于 filter 列**:filter 列必须先扫才能 evaluate,这是结构限制。
10. **`DynamicTableFilterSet` 可见性**:仅当前 scan 的 dynamic filter,不能跨 `PhysicalOperator` 共享。
11. **AdaptiveFilter 仅在 N >= 2 时启用**(`adaptive_filter.cpp:35`):单 filter 没顺序可调;`disable_permutations`(任一 filter `CanThrow`)时也禁用。
12. **InFilter 不允许 NULL / 不同类型混合**(`in_filter.cpp:10-22`)—— 构造期抛 `InternalException`。
13. **`TopN` DynamicFilter 只支持整型 / varchar**(`topn_optimizer.cpp:71-74`)且 `ORDER BY [col]` 必须是单 column ref(`:75-77`)。Date / decimal 等暂未支持。

---

## §9 附录

### 9.1 关键文件清单

**Planner / 数据结构层**

| 路径 | 作用 |
|---|---|
| `src/include/duckdb/planner/table_filter.hpp` | `TableFilter` 基类、`TableFilterType` 枚举、`TableFilterSet`、`DynamicTableFilterSet` |
| `src/include/duckdb/common/enums/filter_propagate_result.hpp` | `FilterPropagateResult` 5 个值 |
| `src/include/duckdb/planner/filter/constant_filter.hpp` | `ConstantFilter` |
| `src/include/duckdb/planner/filter/null_filter.hpp` | `IsNullFilter` / `IsNotNullFilter` |
| `src/include/duckdb/planner/filter/conjunction_filter.hpp` | `ConjunctionAndFilter` / `ConjunctionOrFilter` |
| `src/include/duckdb/planner/filter/in_filter.hpp` | `InFilter` |
| `src/include/duckdb/planner/filter/struct_filter.hpp` | `StructFilter` |
| `src/include/duckdb/planner/filter/dynamic_filter.hpp` | `DynamicFilter` + `DynamicFilterData` |
| `src/include/duckdb/planner/filter/optional_filter.hpp` | `OptionalFilter` |
| `src/include/duckdb/planner/filter/selectivity_optional_filter.hpp` | `SelectivityOptionalFilter` + 状态机 + 阈值 |
| `src/include/duckdb/planner/filter/bloom_filter.hpp` | `BloomFilter` + `BFTableFilter` |
| `src/include/duckdb/planner/filter/expression_filter.hpp` | `ExpressionFilter` |
| `src/planner/filter/*.cpp` | 各子类实现 |
| `src/planner/table_filter.cpp` | `TableFilterSet::PushFilter` 同列合并、`DynamicTableFilterSet` 实现 |

**Optimizer 层** —— 详见 [FILTER_PUSHDOWN_DESIGN.md](./FILTER_PUSHDOWN_DESIGN.md)
**Storage / Execution 层** —— 详见 [FILTER_EXECUTION_DESIGN.md](./FILTER_EXECUTION_DESIGN.md)

### 9.2 术语英中对照

(扩展 `glossary_db_en_zh.md`)

| 英文 | 中文 |
|---|---|
| TableFilter | 表 filter / 下推 filter |
| FilterPushdown | filter 下推(优化器阶段) |
| Zone-map / Zonemap | 区段统计(min/max + null count + ...) |
| FilterPropagateResult | filter 统计传播结果 |
| SelectionVector | 选择向量 |
| Late Materialization | 延迟物化 |
| AdaptiveFilter | 自适应 filter(按运行时观测重排) |
| ConjunctionFilter | 联合 filter(AND/OR 组合器) |
| OptionalFilter | 可选 filter(只剪枝不行级) |
| SelectivityOptionalFilter | 选择率可选 filter |
| BloomFilter | 布隆过滤器 |
| DynamicFilter | 动态 filter(运行时更新) |
| ExpressionFilter | 表达式兜底 filter |
| 3VL(Three-Valued Logic) | 三值逻辑(true/false/null) |
| Equivalence class | 等价类 |
| Transitive filter | 传递 filter |
| Unsatisfiable | 不可满足 |
| Row group | 行组 |
| Column segment | 列段(压缩单元) |

---

## 文档元信息

- **作者**:基于 DuckDB main 分支源码静态阅读 + 现有 dev_docs 整理。
- **维护建议**:`TableFilter` 体系类层次相对稳定;新增子类时需更新 §1.3 枚举表与 §2.2 子类说明,执行 / 性能机制相关变化分别落到 FILTER_EXECUTION_DESIGN / FILTER_PERFORMANCE_DESIGN。
