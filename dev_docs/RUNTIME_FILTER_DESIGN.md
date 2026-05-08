# DuckDB Table Function 与 Runtime Filter 设计文档

## 1. 背景与核心概念

### 1.1 什么是 Runtime Filter（运行时过滤器）

Runtime Filter（也称 Dynamic Filter）是一种执行时优化技术：在 Join 的 **Build 阶段**（构建哈希表）完成之后，将 Build 侧的数据特征（min/max 范围、IN 列表、Bloom Filter）"推送"回 Probe 侧的扫描算子，从而在扫描时提前跳过不可能满足 join 条件的数据分块（row group/block/partition），减少 I/O 和计算量。

典型场景：

```sql
SELECT * FROM large_table l JOIN small_table s ON l.key = s.key WHERE s.category = 'A';
```

small_table 的 key 经过过滤后范围较窄（如 100~200），这个范围可在 Build 阶段计算出来，并在扫描 large_table 时直接跳过 key 不在此范围内的数据分块。

### 1.2 与静态 Filter Pushdown 的区别

| 特性 | 静态 Filter Pushdown | Runtime Filter |
|---|---|---|
| 决定时机 | 规划期（Optimizer） | 执行期（Build Pipeline 完成后） |
| 来源 | WHERE 子句常量条件 | Join Build 侧的实际数据统计 |
| 传递方式 | `LogicalGet::table_filters` | `LogicalGet::dynamic_filters` |
| 过滤器类型 | `ConstantFilter`、`InFilter` 等 | `ConstantFilter`、`InFilter`、`BFTableFilter` 等 |

---

## 2. 整体架构与数据流

```
Optimizer Phase (JoinFilterPushdownOptimizer)
│
├─ 遍历 LogicalComparisonJoin
│   ├─ 对 probe 侧寻找支持 filter_pushdown 的 LogicalGet
│   ├─ 创建 shared_ptr<DynamicTableFilterSet>，写入 LogicalGet::dynamic_filters
│   └─ 创建 JoinFilterPushdownInfo（含 min/max aggregates），写入 join::filter_pushdown
│
Physical Plan Generation
│
├─ LogicalComparisonJoin → PhysicalHashJoin（携带 filter_pushdown）
└─ LogicalGet → PhysicalTableScan（携带 dynamic_filters）
         ↕ shared_ptr（共享所有权）
    DynamicTableFilterSet
         ↕ shared_ptr（共享所有权）
    PhysicalHashJoin::filter_pushdown::probe_info

Execution Phase
│
├─ [Pipeline 1] Hash Join Build 阶段
│   ├─ Sink：收集 build 侧每列的 local min/max
│   ├─ Combine：汇总为 global min/max
│   └─ Finalize：
│       ├─ 计算全局 min/max
│       ├─ 生成 ConstantFilter / InFilter / BFTableFilter
│       └─ 调用 DynamicTableFilterSet::PushFilter() 写入过滤器
│
└─ [Pipeline 2] Table Scan (Probe) 阶段（在 Build Pipeline 完成后调度）
    └─ GetGlobalSourceState：
        ├─ 检测 dynamic_filters->HasFilters()
        ├─ 调用 GetFinalTableFilters() 合并静态+动态过滤器
        └─ 将合并后的 TableFilterSet 传入 init_global / init_local
```

---

## 3. 关键数据结构

### 3.1 `DynamicTableFilterSet`（核心共享桥梁）

```cpp
// src/include/duckdb/planner/table_filter.hpp
class DynamicTableFilterSet {
    mutable mutex lock;
    reference_map_t<const PhysicalOperator, unique_ptr<TableFilterSet>> filters;
public:
    void ClearFilters(const PhysicalOperator &op);
    void PushFilter(const PhysicalOperator &op, idx_t column_index, unique_ptr<TableFilter> filter);
    bool HasFilters() const;
    unique_ptr<TableFilterSet> GetFinalTableFilters(
        const PhysicalTableScan &scan,
        optional_ptr<TableFilterSet> existing_filters) const;
};
```

- `LogicalGet` 和 `PhysicalTableScan` 都持有同一个 `shared_ptr<DynamicTableFilterSet>`
- `PhysicalHashJoin` 的 `filter_pushdown->probe_info` 也引用同一个 `shared_ptr`
- 这是 Build 侧**写入**、Scan 侧**读取**的共享内存通道，通过 mutex 保证线程安全

### 3.2 `JoinFilterPushdownInfo`（存在于 Join 算子）

```cpp
// src/include/duckdb/execution/operator/join/join_filter_pushdown.hpp
struct JoinFilterPushdownInfo {
    vector<idx_t> join_condition;                   // 哪些 join 条件参与 min/max 聚合
    vector<JoinFilterPushdownFilter> probe_info;    // 目标扫描的 DynamicTableFilterSet
    vector<unique_ptr<Expression>> min_max_aggregates; // MIN/MAX 聚合表达式
    bool build_side_has_filter;

    void Sink(DataChunk &chunk, JoinFilterLocalState &) const;
    void Combine(JoinFilterGlobalState &, JoinFilterLocalState &) const;
    unique_ptr<DataChunk> Finalize(ClientContext &, optional_ptr<JoinHashTable> ht,
                                   JoinFilterGlobalState &, const PhysicalComparisonJoin &) const;
};
```

### 3.3 `TableFilterSet`（传入 Table Function 的过滤器集合）

```cpp
class TableFilterSet {
public:
    map<idx_t, unique_ptr<TableFilter>> filters; // column_index → filter
};
```

`column_index` 是 `TableFunctionInitInput::column_ids` 中的位置索引，与 `return_types` 中的列编号对应。

### 3.4 过滤器类型体系

| 类型 | 枚举值 | 典型来源 | 含义 |
|---|---|---|---|
| `ConstantFilter` | 0 | 静态/动态 | `col OP C`，如 `key >= 100` |
| `IsNullFilter` | 1 | 静态 | `col IS NULL` |
| `IsNotNullFilter` | 2 | 静态 | `col IS NOT NULL` |
| `ConjunctionOrFilter` | 3 | 静态 | OR 组合 |
| `ConjunctionAndFilter` | 4 | 静态 | AND 组合 |
| `StructExtractFilter` | 5 | 静态 | 结构体子列过滤 |
| `OptionalFilter` | 6 | 动态 | 可选过滤，只用于 zonemap 剪枝，不保证正确性 |
| `InFilter` | 7 | 动态 | `col IN (v1, v2, ...)`（build 侧数据量较小时） |
| `DynamicFilter` | 8 | 动态 | 运行时可更新的过滤器（基础类型） |
| `ExpressionFilter` | 9 | 静态 | 任意表达式 |
| `BFTableFilter` | 10 | 动态 | 概率 Bloom Filter（build 侧数据量较大时） |

**Runtime Filter 产生的过滤器类型**（由 `JoinFilterPushdownInfo::FinalizeFilters` 生成）：

- `min == max` 时：直接生成 `ConstantFilter`（等值）
- `min != max` + equality join + 数据量小：`InFilter`（IN 列表）
- `min != max` + equality join + 数据量大：`SelectivityOptionalFilter<BFTableFilter>` + 可选范围 `ConstantFilter`
- `min != max` + range join：`SelectivityOptionalFilter<ConstantFilter>`（单侧范围）

---

## 4. 执行时序

```
Build Pipeline (Pipeline 1)                Probe Pipeline (Pipeline 2)
──────────────────────────────             ──────────────────────────────
HashJoin::Sink()                            （等待 Pipeline 1 完成后调度）
  → filter_pushdown->Sink()
    → 收集 local min/max

HashJoin::Combine()
  → filter_pushdown->Combine()
    → 合并为 global min/max

HashJoin::Finalize()
  → filter_pushdown->FinalizeMinMax()
  → filter_pushdown->FinalizeFilters()
    → DynamicTableFilterSet::PushFilter()
      写入 ConstantFilter/InFilter/BFTableFilter
                                             ↓ Pipeline 1 完成，调度 Pipeline 2
                                             PhysicalTableScan::GetGlobalSourceState()
                                               → dynamic_filters->HasFilters() == true
                                               → GetFinalTableFilters(op, static_filters)
                                                 合并静态+动态过滤器
                                               → init_global(context, TableFunctionInitInput{
                                                    ..., filters: merged_filters, ...})
                                                 ← Table Function 在此消费过滤器

                                             PhysicalTableScan::GetLocalSourceState()
                                               → init_local(context, TableFunctionInitInput{
                                                    ..., filters: merged_filters, ...})

                                             PhysicalTableScan::GetData()
                                               → function(context, data, chunk)
```

关键代码位于 `src/execution/operator/scan/physical_table_scan.cpp`：

```cpp
// PhysicalTableScan::GetGlobalSourceState
TableScanGlobalSourceState(ClientContext &context, const PhysicalTableScan &op) {
    if (op.dynamic_filters && op.dynamic_filters->HasFilters()) {
        // 合并静态过滤器（来自 WHERE）和动态过滤器（来自 Join Build）
        table_filters = op.dynamic_filters->GetFinalTableFilters(op, op.table_filters.get());
    }
    if (op.function.init_global) {
        auto filters = table_filters ? *table_filters : GetTableFilters(op);
        TableFunctionInitInput input(op.bind_data.get(), op.column_ids, op.projection_ids,
                                     filters, op.extra_info.sample_options, &op);
        global_state = op.function.init_global(context, input);
    }
}
```

---

## 5. 如何扩展 Table Function 支持 Runtime Filter

### 5.1 必要条件：声明 `filter_pushdown = true`

```cpp
TableFunction my_table_function("my_scan", ...);

// 必须设置为 true，否则：
// 1. JoinFilterPushdownOptimizer 不会将此函数纳入 runtime filter 目标
// 2. init_global/init_local 接收到的 filters 始终为 nullptr
my_table_function.filter_pushdown = true;

// 可选：允许裁剪只用于过滤但不出现在 SELECT 中的列
my_table_function.filter_prune = true;
```

**原因**：`JoinFilterPushdownOptimizer::GetPushdownFilterTargets()` 在遍历发现 `LogicalGet` 时，检查 `get.function.filter_pushdown`，只有为 `true` 才将该扫描加入 runtime filter 链路（见 `src/optimizer/join_filter_pushdown_optimizer.cpp`）：

```cpp
case LogicalOperatorType::LOGICAL_GET: {
    auto &get = probe_child.Cast<LogicalGet>();
    if (!get.function.filter_pushdown) {
        // filter pushdown 不支持，直接返回
        return;
    }
    // ... 加入 targets
}
```

### 5.2 在 `init_global` 中消费过滤器

```cpp
unique_ptr<GlobalTableFunctionState> MyInitGlobal(
    ClientContext &context,
    TableFunctionInitInput &input) {

    auto state = make_uniq<MyGlobalState>();

    // input.filters 已由 PhysicalTableScan::GetGlobalSourceState 合并：
    //   静态过滤器（WHERE 子句下推）+ 动态过滤器（Join Runtime Filter）
    if (input.filters) {
        for (auto &[col_idx, filter] : input.filters->filters) {
            // col_idx 是 column_ids 中的位置索引
            // 利用过滤器跳过不满足条件的数据块（zonemap pruning）
            state->ApplyZonemapFilter(col_idx, *filter);
        }
    }
    return std::move(state);
}
```

### 5.3 利用 `CheckStatistics` 做 Block 级剪枝

`TableFilter::CheckStatistics()` 是与 Runtime Filter 对接的核心接口。对每个数据块维护统计信息（min/max），调用此方法决定是否跳过：

```cpp
void MyGlobalState::ApplyZonemapFilter(idx_t col_idx, TableFilter &filter) {
    for (idx_t block_idx = 0; block_idx < total_blocks; block_idx++) {
        BaseStatistics &block_stats = GetBlockStatistics(block_idx, col_idx);
        auto result = filter.CheckStatistics(block_stats);
        if (result == FilterPropagateResult::FILTER_ALWAYS_FALSE) {
            // 该 block 中没有任何数据可能满足过滤条件，跳过
            skip_blocks.insert(block_idx);
        }
    }
}
```

`FilterPropagateResult` 的取值：

| 值 | 含义 |
|---|---|
| `NO_PRUNING_POSSIBLE` | 无法判断，不能跳过 |
| `FILTER_ALWAYS_TRUE` | 整个 block 都满足，无需逐行过滤 |
| `FILTER_ALWAYS_FALSE` | 整个 block 都不满足，直接跳过 |

### 5.4 处理各种 Filter 类型

对于 Runtime Filter，`init_global` 阶段主要处理以下类型：

```cpp
void MyGlobalState::ApplyFilter(idx_t col_idx, TableFilter &filter) {
    switch (filter.filter_type) {
    case TableFilterType::CONSTANT_COMPARISON: {
        auto &cf = filter.Cast<ConstantFilter>();
        // cf.comparison_type: COMPARE_EQUAL/GREATER/LESSTHAN 等
        // cf.constant: 比较的常量值（来自 build 侧 min 或 max）
        ApplyRangeFilter(col_idx, cf.comparison_type, cf.constant);
        break;
    }
    case TableFilterType::IN_FILTER: {
        auto &inf = filter.Cast<InFilter>();
        // 来自 build 侧数据量小时，inf.values 包含 build 侧所有值
        ApplyInFilter(col_idx, inf.values);
        break;
    }
    case TableFilterType::OPTIONAL_FILTER:
    case TableFilterType::BLOOM_FILTER: {
        // OPTIONAL_FILTER / BFTableFilter 是非强制的，不影响正确性
        // 可选地利用其 CheckStatistics() 做 zonemap 剪枝
        // 不应依赖 Bloom Filter 来决定输出哪些行（存在假阳性）
        break;
    }
    case TableFilterType::CONJUNCTION_AND: {
        auto &and_filter = filter.Cast<ConjunctionAndFilter>();
        for (auto &child : and_filter.child_filters) {
            ApplyFilter(col_idx, *child);
        }
        break;
    }
    default:
        break; // 其他类型交由上层 Filter 算子处理
    }
}
```

### 5.5 可选：实现 `statistics` 辅助全局剪枝

```cpp
unique_ptr<BaseStatistics> MyStatistics(
    ClientContext &context,
    const FunctionData *bind_data,
    column_t column_index) {

    auto &my_bind = bind_data->Cast<MyBindData>();
    // 返回整张表（全部分块）的列统计信息
    return my_bind.GetGlobalColumnStatistics(column_index);
}

my_table_function.statistics = MyStatistics;
```

### 5.6 可选：实现 `pushdown_complex_filter` 处理分区过滤

对于 Hive 分区或自定义分区结构，可通过此回调在规划期处理任意表达式：

```cpp
void MyPushdownComplexFilter(
    ClientContext &context,
    LogicalGet &get,
    FunctionData *bind_data,
    vector<unique_ptr<Expression>> &filters) {

    auto &my_bind = bind_data->Cast<MyBindData>();
    for (auto it = filters.begin(); it != filters.end(); ) {
        if (TryApplyAsPartitionFilter(my_bind, **it)) {
            it = filters.erase(it); // 标记为已处理，不再生成 Filter 算子
        } else {
            ++it;
        }
    }
}

my_table_function.pushdown_complex_filter = MyPushdownComplexFilter;
```

---

## 6. 完整示例骨架

```cpp
// ──────────────────────────────────────────────────
// 1. FunctionData（bind 阶段产出，执行期只读）
// ──────────────────────────────────────────────────
struct MyBindData : public FunctionData {
    string data_path;
    idx_t total_blocks;
    // per-block statistics: block_idx -> col_idx -> BaseStatistics
    vector<vector<unique_ptr<BaseStatistics>>> block_stats;

    unique_ptr<FunctionData> Copy() const override { /* ... */ }
    bool Equals(const FunctionData &other) const override { /* ... */ }
};

// ──────────────────────────────────────────────────
// 2. GlobalTableFunctionState（init_global 产出，多线程共享）
// ──────────────────────────────────────────────────
struct MyGlobalState : public GlobalTableFunctionState {
    vector<idx_t> blocks_to_scan; // 经 zonemap 过滤后需要扫描的 block 列表
    atomic<idx_t> next_block_idx = {0};

    void InitBlockList(const MyBindData &bind, optional_ptr<TableFilterSet> filters) {
        for (idx_t i = 0; i < bind.total_blocks; i++) {
            bool skip = false;
            if (filters) {
                for (auto &[col_idx, filter] : filters->filters) {
                    auto result = filter->CheckStatistics(*bind.block_stats[i][col_idx]);
                    if (result == FilterPropagateResult::FILTER_ALWAYS_FALSE) {
                        skip = true;
                        break;
                    }
                }
            }
            if (!skip) {
                blocks_to_scan.push_back(i);
            }
        }
    }

    idx_t MaxThreads() const override {
        return blocks_to_scan.size();
    }
};

// ──────────────────────────────────────────────────
// 3. Bind
// ──────────────────────────────────────────────────
unique_ptr<FunctionData> MyBind(
    ClientContext &context,
    TableFunctionBindInput &input,
    vector<LogicalType> &return_types,
    vector<string> &names) {
    auto result = make_uniq<MyBindData>();
    result->data_path = input.inputs[0].GetValue<string>();
    // 读取 metadata，填充 block_stats ...
    return std::move(result);
}

// ──────────────────────────────────────────────────
// 4. init_global：消费 filters，完成 block-level 剪枝
// ──────────────────────────────────────────────────
unique_ptr<GlobalTableFunctionState> MyInitGlobal(
    ClientContext &context,
    TableFunctionInitInput &input) {

    auto &bind = input.bind_data->Cast<MyBindData>();
    auto state = make_uniq<MyGlobalState>();

    // input.filters 已由 PhysicalTableScan 合并静态+动态过滤器
    state->InitBlockList(bind, input.filters);

    return std::move(state);
}

// ──────────────────────────────────────────────────
// 5. Scan 函数：仅扫描过滤后的 blocks
// ──────────────────────────────────────────────────
void MyScan(ClientContext &context, TableFunctionInput &data, DataChunk &output) {
    auto &gstate = data.global_state->Cast<MyGlobalState>();
    auto &bind = data.bind_data->Cast<MyBindData>();

    auto local_idx = gstate.next_block_idx.fetch_add(1);
    if (local_idx >= gstate.blocks_to_scan.size()) {
        output.SetCardinality(0);
        return;
    }
    auto block_idx = gstate.blocks_to_scan[local_idx];
    // 读取 block_idx 对应的数据 ...
}

// ──────────────────────────────────────────────────
// 6. 注册
// ──────────────────────────────────────────────────
TableFunction GetMyTableFunction() {
    TableFunction func("my_scan", {LogicalType::VARCHAR}, MyScan, MyBind, MyInitGlobal);
    func.filter_pushdown = true; // 必须设置，否则 runtime filter 不会下推
    func.filter_prune = true;
    return func;
}
```

---

## 7. 优化器触发条件

`JoinFilterPushdownOptimizer::GenerateJoinFilters()` 的启用条件（`src/optimizer/join_filter_pushdown_optimizer.cpp`）：

| 条件 | 要求 |
|---|---|
| Join 类型 | `INNER`、`SEMI`、`RIGHT`、`RIGHT_SEMI`（LEFT/OUTER/ANTI 不支持） |
| Join 条件 | 包含 `=`、`<`、`<=`、`>`、`>=` 可比较条件 |
| Probe 侧扫描 | `LogicalGet::function.filter_pushdown == true` |
| 列类型 | 非嵌套类型（STRUCT/LIST/MAP 不支持），非 INTERVAL 类型 |
| 投影 | 可以通过 Projection/Aggregate 的 column reference 或 integral cast 向下穿透 |

---

## 8. 注意事项

| 注意点 | 说明 |
|---|---|
| **过滤器在 init 时一次性注入** | `init_global` 调用时过滤器已确定，之后不再变化；block 列表在此时构建 |
| **OPTIONAL_FILTER 不影响正确性** | 只用于 zonemap 剪枝，不能用于决定哪些数据行输出；Bloom Filter 存在假阳性 |
| **静态+动态过滤器已合并** | `PhysicalTableScan::GetGlobalSourceState` 中调用 `GetFinalTableFilters` 完成合并，`init_global` 收到的是合并结果 |
| **Pipeline 顺序保证** | DuckDB 保证 Build Pipeline 完成后才调度 Probe Pipeline；写入和读取 `DynamicTableFilterSet` 之间无并发冲突 |
| **多次执行（如递归 CTE）** | `ClearFilters` 在每次 Build 开始前清除旧过滤器，`init_global` 在每次 Probe Pipeline 启动时重新调用 |
| **`filter_pushdown = false`** | 优化器直接跳过，不生成 `DynamicTableFilterSet`，过滤器链路完全旁路 |

---

## 9. 相关源码索引

| 文件 | 说明 |
|---|---|
| `src/include/duckdb/function/table_function.hpp` | `TableFunction` 定义，`filter_pushdown`/`filter_prune` 等字段 |
| `src/include/duckdb/planner/table_filter.hpp` | `TableFilter`、`TableFilterSet`、`DynamicTableFilterSet` |
| `src/include/duckdb/planner/filter/dynamic_filter.hpp` | `DynamicFilter`、`DynamicFilterData` |
| `src/include/duckdb/planner/filter/bloom_filter.hpp` | `BFTableFilter`、`BloomFilter` |
| `src/include/duckdb/execution/operator/join/join_filter_pushdown.hpp` | `JoinFilterPushdownInfo`、`JoinFilterPushdownFilter` |
| `src/include/duckdb/optimizer/join_filter_pushdown_optimizer.hpp` | `JoinFilterPushdownOptimizer` |
| `src/optimizer/join_filter_pushdown_optimizer.cpp` | 优化器实现，`GetPushdownFilterTargets`、`GenerateJoinFilters` |
| `src/execution/operator/join/physical_hash_join.cpp` | `Sink`/`Combine`/`Finalize`，写入 `DynamicTableFilterSet` |
| `src/execution/operator/scan/physical_table_scan.cpp` | `GetGlobalSourceState`，读取并合并过滤器，调用 `init_global` |
| `src/planner/table_filter.cpp` | `DynamicTableFilterSet` 实现 |
| `src/include/duckdb/planner/operator/logical_get.hpp` | `LogicalGet::dynamic_filters`、`table_filters` |
