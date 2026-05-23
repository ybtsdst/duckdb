# DuckDB Filter Execution 设计文档(扫描期执行)

> 本文是 `FILTER_DESIGN.md` 系列的第 3 篇,专注**扫描期**:`PhysicalTableScan` 接到 `TableFilterSet` 后,storage 层是怎么用三层 zone-map(row group / segment / vector)做剪枝、怎么把 SelectionVector 流式收窄实现 late materialization、`ColumnSegment::FilterSelection` 怎么走模板化 fast path、`AdaptiveFilter` 怎么按观测选择率重排。
>
> 类层次见 [FILTER_DESIGN.md](./FILTER_DESIGN.md);规划期转换见 [FILTER_PUSHDOWN_DESIGN.md](./FILTER_PUSHDOWN_DESIGN.md);性能机制深入见 [FILTER_PERFORMANCE_DESIGN.md](./FILTER_PERFORMANCE_DESIGN.md)。

## §4 执行流程:scan 怎么用 filter

### 4.1 PhysicalTableScan 入口

`src/execution/operator/scan/physical_table_scan.cpp:159` `PhysicalTableScan::GetDataInternal`,它把 `global_state.global_state` 传给 `function.function(...)`(table function 的实现)。filter 是在 `TableScanGlobalSourceState` 构造期合并的:

```cpp
// physical_table_scan.cpp:32-37
TableScanGlobalSourceState(ClientContext &context, const PhysicalTableScan &op) {
    ...
    if (op.dynamic_filters && op.dynamic_filters->HasFilters()) {
        table_filters = op.dynamic_filters->GetFinalTableFilters(op, op.table_filters.get());
    }
    ...
    auto filters = table_filters ? *table_filters : GetTableFilters(op);
    TableFunctionInitInput input(op.bind_data.get(), op.column_ids, op.projection_ids, filters,
                                 op.extra_info.sample_options, &op);
    global_state = op.function.init_global(context, input);
}
```

`table_filters` 字段(`:71`)保存合并后的最终 set,`GetTableFilters(op)`(`:73`)若动态 set 为空就用 base set。**只在 scan 全局初始化时合并一次** —— dynamic filter 后续的 `SetValue()` 通过 `shared_ptr<DynamicFilterData>` 在 storage 层看到。

对内置表(`DataTable`):table function 的 init/scan 实现在 `src/storage/data_table.cpp` + `RowGroupCollection::InitializeScan`。filter 通过 `ScanFilterInfo` 暴露给 `RowGroup::Scan`。

### 4.2 Row group 级 zone-map 剪枝

`src/storage/table/row_group.cpp:515-538` `RowGroup::CheckZonemap`:

```cpp
bool RowGroup::CheckZonemap(ScanFilterInfo &filters) {
    auto &filter_list = filters.GetFilterList();
    // new row group - label all filters as up for grabs again
    filters.CheckAllFilters();
    for (idx_t i = 0; i < filter_list.size(); i++) {
        auto &entry = filter_list[i];
        auto &filter = entry.filter;
        const auto &base_column_index = entry.table_column_index;

        auto prune_result = GetColumn(base_column_index).CheckZonemap(base_column_index, filter);
        if (prune_result == FilterPropagateResult::FILTER_ALWAYS_FALSE) {
            return false;          // ← 整 row group 跳过
        }
        if (filter.filter_type == TableFilterType::OPTIONAL_FILTER) {
            // these are only for row group checking, set as always true so we don't check it
            filters.SetFilterAlwaysTrue(i);
        } else if (prune_result == FilterPropagateResult::FILTER_ALWAYS_TRUE) {
            // filter is always true - no need to check it
            filters.SetFilterAlwaysTrue(i);
        }
    }
    return true;
}
```

这 24 行包含整个 row group 级剪枝的全部设计:

1. **`CheckAllFilters()`**(`:518`):每进一个新 row group,重置「always-true」标记。因为上个 row group 的 stats 可能命中 always-true,但下个 row group 不一定。
2. **`prune_result == FILTER_ALWAYS_FALSE`**(`:525-527`):返回 `false`,整 row group 跳过 —— **根本不读 I/O**。
3. **`OPTIONAL_FILTER` 类型特判**(`:528-530`):无论 `prune_result` 如何,标 always-true。后续 vector 级扫描跳过这个 filter,对应 [FILTER_DESIGN §2.2.7](./FILTER_DESIGN.md#227-optionalfilter) 的设计意图。
4. **`prune_result == FILTER_ALWAYS_TRUE`**(`:531-535`):同样标 always-true,vector 级别不再 evaluate。
5. **`NO_PRUNING_POSSIBLE`**(隐式):保持原状,下一阶段的 segment 级或 vector 级仍要执行。

### 4.3 Segment 级 zone-map 推进

`row_group.cpp:540-594` `RowGroup::CheckZonemapSegments`:

```cpp
bool RowGroup::CheckZonemapSegments(CollectionScanState &state) {
    auto &filters = state.GetFilterInfo();
    optional_idx target_vector_index_max;
    for (auto &entry : filters.GetFilterList()) {
        if (entry.IsAlwaysTrue()) continue;
        auto column_idx = entry.scan_column_index;
        auto base_column_idx = entry.table_column_index;
        auto &filter = entry.filter;

        auto prune_result = GetColumn(base_column_idx).CheckZonemap(state.column_scans[column_idx], filter);
        if (prune_result != FilterPropagateResult::FILTER_ALWAYS_FALSE) continue;

        // 找到能跳过的目标 vector 边界
        auto &column_scan_state = state.column_scans[column_idx];
        auto current_segment = column_scan_state.current;
        if (!current_segment) continue;
        auto row_start = current_segment->GetRowStart();
        idx_t target_row = row_start + current_segment->GetNode().count;
        if (target_row >= state.max_row) target_row = state.max_row;
        D_ASSERT(target_row >= row_start);
        D_ASSERT(target_row <= row_start + this->count);
        idx_t target_vector_index = (target_row - row_start) / STANDARD_VECTOR_SIZE;

        if (!target_vector_index_max.IsValid() || target_vector_index_max.GetIndex() < target_vector_index) {
            target_vector_index_max = target_vector_index;
        }
    }
    if (target_vector_index_max.IsValid()) {
        if (state.vector_index == target_vector_index_max.GetIndex()) {
            // we can't skip any full vectors because this segment contains less than a full vector
            // for now we just bail-out
            // FIXME: we could check if we can ALSO skip the next segments, in which case skipping a full vector
            // might be possible
            return true;
        }
        while (state.vector_index < target_vector_index_max.GetIndex()) {
            NextVector(state);
        }
        return false;
    }
    return true;
}
```

每个 row group 内部有多个 `ColumnSegment`(压缩单元,默认 STANDARD_VECTOR_SIZE × N 大小)。segment 级 zone-map 比 row group 更细一档。

注释里保留了 DuckDB 作者的 FIXME(`:581-583`):「当前 segment 不足一个 vector 时无法跳过,因为还不会合并多个 segment 的跳过」 —— 但「< 一个 vector 的段极少」所以实际影响有限。这是真实生产代码里能学到的一手观察。

### 4.4 Vector 级 filter 与 late materialization

`row_group.cpp:596-720` `RowGroup::Scan`,这是 storage 端最核心的一段。

#### 4.4.1 Fast path:无 filter 且无删除

```cpp
// row_group.cpp:639-647
bool has_filters = filter_info.HasFilters();
if (count == max_count && !has_filters) {
    // scan all vectors completely: full scan without deletions or table filters
    for (idx_t i = 0; i < column_ids.size(); i++) {
        const auto &column = column_ids[i];
        auto &col_data = GetColumn(column);
        state.column_scans[i].update_scan_type = options.update_type;
        col_data.Scan(transaction, state.vector_index, state.column_scans[i], result.data[i]);
    }
}
```

满速直读,没有 SelectionVector 物化开销。这是「`SELECT *` 全表 + 无 WHERE」的极速路径。

#### 4.4.2 Partial path:有 filter / 有删除

```cpp
// row_group.cpp:648-719
else {
    // partial scan: we have deletions or table filters
    idx_t approved_tuple_count = count;
    SelectionVector sel;
    if (count != max_count) {
        sel.Initialize(state.valid_sel);   // 含删除信息
    } else {
        sel.Initialize(nullptr);
    }
    //! first, we scan the columns with filters, fetch their data and generate a selection vector.
    auto adaptive_filter = filter_info.GetAdaptiveFilter();
    auto filter_state = filter_info.BeginFilter();
    if (has_filters) {
        auto &filter_list = filter_info.GetFilterList();
        for (idx_t i = 0; i < filter_list.size(); i++) {
            auto filter_idx = adaptive_filter->permutation[i];     // ← AdaptiveFilter 排序
            auto &filter = filter_list[filter_idx];
            if (filter.IsAlwaysTrue()) continue;
            auto &table_filter_state = *filter.filter_state;

            const auto scan_idx = filter.scan_column_index;
            const auto column_idx = filter.table_column_index;

            auto &result_vector = result.data[scan_idx];
            if (approved_tuple_count == 0) {
                auto &col_data = GetColumn(column_idx);
                col_data.Skip(state.column_scans[scan_idx]);       // 没人活下来,只推进 offset
                continue;
            }
            auto &col_data = GetColumn(column_idx);
            col_data.Filter(transaction, state.vector_index, state.column_scans[scan_idx], result_vector, sel,
                            approved_tuple_count, filter.filter, table_filter_state);
        }
        for (auto &table_filter : filter_list) {
            if (table_filter.IsAlwaysTrue()) continue;
            result.data[table_filter.scan_column_index].Slice(sel, approved_tuple_count);   // ← 一次性按 sel 物化
        }
    }
    if (approved_tuple_count == 0) {
        // all rows were filtered out
        result.Reset();
        for (idx_t i = 0; i < column_ids.size(); i++) {
            auto &col_idx = column_ids[i];
            if (has_filters && filter_info.ColumnHasFilters(i)) continue;
            auto &col_data = GetColumn(col_idx);
            col_data.Skip(state.column_scans[i]);                  // 把非 filter 列的 offset 也推过去
        }
        state.vector_index++;
        continue;
    }
    //! Now we use the selection vector to fetch data for the other columns.
    for (idx_t i = 0; i < column_ids.size(); i++) {
        if (has_filters && filter_info.ColumnHasFilters(i)) continue;
        auto &column = column_ids[i];
        auto &col_data = GetColumn(column);
        state.column_scans[i].update_scan_type = options.update_type;
        col_data.Select(transaction, state.vector_index, state.column_scans[i], result.data[i], sel,
                        approved_tuple_count);                     // ← 仅为存活行 Select
    }
}
```

#### 4.4.3 关键观察

这段代码体现了三条性能哲学:

1. **filter 列先扫**(`:663-684`):每个有 filter 的列调 `ColumnData::Filter`,sel 与 `approved_tuple_count` 流式收窄。早期收窄越好,后面 I/O / 解压越少。
2. **Slice 一次性物化**(`:685-690`):全部 filter 跑完后,把 filter 列按最终 sel 一次 `Slice`(不是逐 filter Slice)。**这点重要**:连续多个 filter 时,中间不必反复物化向量,只在最后一次性切片。
3. **late materialization**(`:692-719`):
   - 如果 `approved_tuple_count == 0` → 整 vector 跳过(`continue`),非 filter 列只调 `Skip()` 推进 offset,**不读 I/O**;
   - 否则非 filter 列调 `Select(...)`(`:717`),**仅为存活行解压**,而不是 `Scan()` 全部解压再过滤。

> 「先 filter 后取列」是 DuckDB 把 ClickBench/TPC-H 跑到极致的根本机制:不命中谓词的行,投影列连解压都不做。

详细对比 [[LATE_MATERIALIZATION_DESIGN]]。

### 4.5 `ColumnSegment::Filter` / `FilterSelection` 模板化

`src/storage/table/column_segment.cpp:405` `ColumnSegment::FilterSelection`,按 `filter.filter_type` 分发:

```cpp
idx_t ColumnSegment::FilterSelection(SelectionVector &sel, Vector &vector, UnifiedVectorFormat &vdata,
                                     const TableFilter &filter, TableFilterState &filter_state,
                                     idx_t scan_count, idx_t &approved_tuple_count) {
    switch (filter.filter_type) {
    case TableFilterType::OPTIONAL_FILTER: {
        auto &opt_filter = filter.Cast<OptionalFilter>();
        return opt_filter.FilterSelection(sel, vector, vdata, filter_state, scan_count, approved_tuple_count);
    }
    case TableFilterType::CONJUNCTION_OR: { ... }
    case TableFilterType::CONJUNCTION_AND: {
        auto &conjunction_and = filter.Cast<ConjunctionAndFilter>();
        auto &state = filter_state.Cast<ConjunctionAndFilterState>();
        for (idx_t child_idx = 0; child_idx < conjunction_and.child_filters.size(); child_idx++) {
            auto &child_filter = *conjunction_and.child_filters[child_idx];
            FilterSelection(sel, vector, vdata, child_filter, *state.child_states[child_idx], scan_count,
                            approved_tuple_count);
        }
        return approved_tuple_count;
    }
    case TableFilterType::CONSTANT_COMPARISON: {
        auto &constant_filter = filter.Cast<ConstantFilter>();
        switch (vector.GetType().InternalType()) {
        case PhysicalType::UINT8: {
            auto predicate = UTinyIntValue::Get(constant_filter.constant);
            FilterSelectionSwitch<uint8_t>(vdata, predicate, sel, approved_tuple_count,
                                           constant_filter.comparison_type);
            break;
        }
        case PhysicalType::INT32: { ... }
        ...
        }
    }
    case TableFilterType::IS_NULL: { ... }
    case TableFilterType::IS_NOT_NULL: { ... }
    case TableFilterType::DYNAMIC_FILTER: { ... 转发到内层 ConstantFilter ... }
    ...
    }
}
```

ConjunctionOr 的处理(`:413-444`)略复杂:对每个子 filter 用临时 sel 跑一遍,把命中的 idx 用朴素 O(N²) 去重合并到结果 sel,**简单但能用** —— OR 通常在 hot path 已被 OptionalFilter 包,这里执行不算高频。

#### 4.5.1 `TemplatedFilterSelection<T, OP, HAS_NULL>`(SIMD 友好 hot loop)

`column_segment.cpp:288-303`:

```cpp
template <class T, class OP, bool HAS_NULL>
static idx_t TemplatedFilterSelection(UnifiedVectorFormat &vdata, T predicate, SelectionVector &sel,
                                      idx_t approved_tuple_count, SelectionVector &result_sel) {
    auto &mask = vdata.validity;
    auto vec = UnifiedVectorFormat::GetData<T>(vdata);
    idx_t result_count = 0;
    for (idx_t i = 0; i < approved_tuple_count; i++) {
        auto idx = sel.get_index(i);
        auto vector_idx = vdata.sel->get_index(idx);
        bool comparison_result =
            (!HAS_NULL || mask.RowIsValid(vector_idx)) && OP::Operation(vec[vector_idx], predicate);
        result_sel.set_index(result_count, idx);
        result_count += comparison_result;
    }
    return result_count;
}
```

要点:
- **没有虚函数**:`OP` 是 `Equals` / `LessThan` / `GreaterThan` 这类 trivial functor,编译期单态化;
- **`HAS_NULL` 模板参数**:`mask.AllValid()` 时 dispatch 到 `HAS_NULL=false` 分支,内层 `mask.RowIsValid()` 完全消失;
- **`result_count += comparison_result`**:branchless 写法,编译器能 vectorize。

`FilterSelectionSwitch<T>`(`:305-376`)按 `comparison_type` × `HAS_NULL` 展开 6×2 = 12 个特化:

```cpp
case ExpressionType::COMPARE_LESSTHAN: {
    if (mask.AllValid()) {
        approved_tuple_count =
            TemplatedFilterSelection<T, LessThan, false>(vdata, predicate, sel, approved_tuple_count, new_sel);
    } else {
        approved_tuple_count =
            TemplatedFilterSelection<T, LessThan, true>(vdata, predicate, sel, approved_tuple_count, new_sel);
    }
    break;
}
```

再算上外层 `physical_type`(uint8/uint16/uint32/uint64/int8/int16/int32/int64/float/double/decimal128 等),整套 `ConstantFilter` 行级执行**全程没有动态 dispatch**,这就是 DuckDB 在 ClickBench / TPC-H 跑到 GB/s scan 吞吐的根本。

DuckDB 不依赖 LLVM JIT,完全靠 C++ 模板。代价是**二进制大**(每个 type × OP × HAS_NULL 组合都生成代码),但运行时零开销。

#### 4.5.2 `TemplatedNullSelection<IS_NULL>`(NULL 检查)

`column_segment.cpp:378-403`:

```cpp
template <bool IS_NULL>
static idx_t TemplatedNullSelection(UnifiedVectorFormat &vdata, SelectionVector &sel, idx_t &approved_tuple_count) {
    auto &mask = vdata.validity;
    if (mask.AllValid()) {
        // no NULL values
        if (IS_NULL) {
            approved_tuple_count = 0;
            return 0;
        } else {
            return approved_tuple_count;
        }
    } else {
        ...
        for (idx_t i = 0; i < approved_tuple_count; i++) {
            auto idx = sel.get_index(i);
            auto vector_idx = vdata.sel->get_index(idx);
            if (mask.RowIsValid(vector_idx) != IS_NULL) {
                result_sel.set_index(result_count++, idx);
            }
        }
        ...
    }
}
```

`mask.AllValid()` 时的快速判定:`IS NULL` 直接归零,`IS NOT NULL` 直接全过 —— **O(1)**,不动 SelectionVector。

### 4.6 AdaptiveFilter:按观测选择率重排序

`src/execution/adaptive_filter.cpp` + `src/include/duckdb/execution/adaptive_filter.hpp`。**这是 DuckDB 一个容易被忽略但对性能影响很大的机制**。

#### 4.6.1 数据结构

```cpp
class AdaptiveFilter {
public:
    explicit AdaptiveFilter(const Expression &expr);
    explicit AdaptiveFilter(const TableFilterSet &table_filters);

    vector<idx_t> permutation;   // 当前执行顺序

public:
    void AdaptRuntimeStatistics(double duration);
    AdaptiveFilterState BeginFilter() const;
    void EndFilter(AdaptiveFilterState state);

private:
    bool disable_permutations = false;
    idx_t iteration_count = 0;
    idx_t swap_idx = 0;
    idx_t right_random_border = 0;
    idx_t observe_interval = 0;       // = 10
    idx_t execute_interval = 0;       // = 20
    double runtime_sum = 0;
    double prev_mean = 0;
    bool observe = false;
    bool warmup = false;
    vector<idx_t> swap_likeliness;    // 每个相邻位置的换位概率(初始 100)
    RandomEngine generator;
};
```

构造期初始顺序由 `ExpressionHeuristics::GetInitialOrder(table_filters)` 给出(把贵的 filter 排后);随后通过 ε-greedy 在线学习。

#### 4.6.2 调度与学习

`RowGroup::Scan` 的 hot loop(`row_group.cpp:659-664`):

```cpp
auto adaptive_filter = filter_info.GetAdaptiveFilter();
auto filter_state = filter_info.BeginFilter();
if (has_filters) {
    auto &filter_list = filter_info.GetFilterList();
    for (idx_t i = 0; i < filter_list.size(); i++) {
        auto filter_idx = adaptive_filter->permutation[i];   // ← 按学到的 permutation 执行
        ...
```

vector 级算完后 `EndFilter` 记录时间,统计积累到一定 vector 数(`execute_interval=20`)后,**尝试随机交换两个相邻 filter**;再观察 `observe_interval=10` 个 vector 看 runtime 是否下降,下降则保留,不下降则撤销并降低这个位置的换位概率(`adaptive_filter.cpp:52-110`):

```cpp
void AdaptiveFilter::AdaptRuntimeStatistics(double duration) {
    iteration_count++;
    runtime_sum += duration;
    if (!warmup) {
        if (observe && iteration_count == observe_interval) {
            // 观察期结束:看 runtime 是否下降
            if (prev_mean - (runtime_sum / static_cast<double>(iteration_count)) <= 0) {
                // 没下降,撤销 swap
                std::swap(permutation[swap_idx], permutation[swap_idx + 1]);
                if (swap_likeliness[swap_idx] > 1) swap_likeliness[swap_idx] /= 2;   // 降低后续 swap 概率
            } else {
                // 下降,保留 swap,重置概率
                swap_likeliness[swap_idx] = 100;
            }
            observe = false;
            ...
        } else if (!observe && iteration_count == execute_interval) {
            // 执行期结束:尝试新 swap
            prev_mean = runtime_sum / static_cast<double>(iteration_count);
            auto random_number = generator.NextRandomInteger(1, NumericCast<uint32_t>(right_random_border));
            swap_idx = random_number / 100;
            idx_t likeliness = random_number - 100 * swap_idx;
            if (swap_likeliness[swap_idx] > likeliness) {
                std::swap(permutation[swap_idx], permutation[swap_idx + 1]);
                observe = true;
            }
            ...
        }
    } else {
        if (iteration_count == 5) { warmup = false; }
    }
}
```

#### 4.6.3 为什么重要

`x > 5 AND y < 100` 哪个先跑取决于数据分布:
- 如果 90% 的行满足 `x > 5`、10% 的行满足 `y < 100`,先跑 `y < 100` 把 sel 收到 10%,再跑 `x > 5` 在 10% 的数据上跑 —— 总成本 ≈ 1×N(y filter) + 0.1×N(x filter);
- 反过来先跑 `x > 5` → 总成本 ≈ 1×N + 0.9×N。

**两种顺序差 1.8×**,而数据分布在 plan 期通常不可知。AdaptiveFilter 在线学到最优 permutation,常见 ClickBench / TPC-H query 上有显著收益。

### 4.7 全段流程整合(伪代码)

```
RowGroup::Scan(state, result):
  while !done:
    if state.vector_index * STANDARD_VECTOR_SIZE >= state.max_row_group_row: return

    # (1) sampling
    if sampling and skip: NextVector(state); continue

    # (2) segment 级 zone-map(可一次跳多 vector)
    if !CheckZonemapSegments(state): continue

    # (3) MVCC + 删除可见性
    count = current_row_group.GetSelVector(...)
    if count == 0: NextVector(state); continue

    # (4) 预取
    if block_manager.Prefetch(): ...InitializePrefetch...; buffer_manager.Prefetch(...)

    # (5) fast path:无 filter + 无删除
    if count == max_count and !has_filters:
      for col in column_ids: col_data.Scan(...)
      return have_chunk

    # (6) partial path
    sel = SelectionVector(initial)
    approved_tuple_count = count

    # (6a) AdaptiveFilter 决定顺序,逐 filter 收窄 sel
    adaptive_filter = filter_info.GetAdaptiveFilter()
    BeginFilter()
    for i in 0..N_filters:
      filter_idx = adaptive_filter->permutation[i]
      if filter.IsAlwaysTrue(): continue
      col_data.Filter(transaction, vector_index, scan_state, result_vector,
                      sel, approved_tuple_count, filter, table_filter_state)

    # (6b) 一次性 Slice filter 列
    for f in filter_list: result.data[f.scan_column_index].Slice(sel, approved_tuple_count)

    # (6c) 全过滤掉 → 跳整 vector,推进所有列的 offset
    if approved_tuple_count == 0:
      for col not in filter_list: col_data.Skip(...)
      state.vector_index++; continue

    # (6d) late materialization:只为命中行 Select 其它列
    for col in column_ids:
      if col in filter_list: continue
      col_data.Select(transaction, vector_index, scan_state, result.data[col_idx],
                      sel, approved_tuple_count)

    EndFilter()
    return have_chunk
```

### 4.8 关键文件清单

| 路径 | 作用 |
|---|---|
| `src/storage/table/row_group.cpp` | `CheckZonemap` / `CheckZonemapSegments` / `Scan` 三层 zone-map |
| `src/storage/table/column_data.cpp` | `FilterVector` / `ScanVector` / `Select` |
| `src/storage/table/column_segment.cpp` | `FilterSelection` / `TemplatedFilterSelection<T,OP,HAS_NULL>` / `TemplatedNullSelection<IS_NULL>` 模板化 hot loop |
| `src/execution/operator/scan/physical_table_scan.cpp` | `GetDataInternal`、dynamic filter 合并 |
| `src/execution/adaptive_filter.cpp` + `src/include/duckdb/execution/adaptive_filter.hpp` | ε-greedy 在线学习 filter 顺序 |
