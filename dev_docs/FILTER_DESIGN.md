# DuckDB Filter 体系设计文档（总论）

> 适用源码：`v2.0-cyanoptera` @ `c1cd2470a455`；核对日期：2026-10-23。核对方式：静态源码审查，未执行本文示例或性能测试。

## 本系列文档

| 文档 | 职责 |
|---|---|
| 本文 | 当前过滤表示、索引空间、可选语义与兼容边界 |
| [FILTER_PUSHDOWN_DESIGN.md](./FILTER_PUSHDOWN_DESIGN.md) | 逻辑谓词到扫描过滤器的规划过程 |
| [FILTER_EXECUTION_DESIGN.md](./FILTER_EXECUTION_DESIGN.md) | row group / segment 统计与向量选择执行 |
| [FILTER_PERFORMANCE_DESIGN.md](./FILTER_PERFORMANCE_DESIGN.md) | 性能机制、收益条件和限制 |

相邻主题：[表达式](./EXPRESSION_DESIGN.md)、[Runtime Filter](./RUNTIME_FILTER_DESIGN.md)、[Projection 下推](./PROJECTION_PUSHDOWN_DESIGN.md)、[延迟物化](./LATE_MATERIALIZATION_DESIGN.md)。

## 一、核心模型：活动过滤器统一为 ExpressionFilter

本版本的 [table_filter.hpp](../src/include/duckdb/planner/table_filter.hpp) 中，`TableFilterType` 仍保留旧编号，但常量、NULL、AND/OR、STRUCT、IN、dynamic、Bloom、prefix-range 等旧类型都已命名为 `LEGACY_*`。活动路径以 `EXPRESSION_FILTER` 为统一表示。

`TableFilter` 基类主要保留 `ToExpression` 和序列化接口；`CheckStatistics`、`Copy`、`Equals`、显示接口由 [ExpressionFilter](../src/include/duckdb/planner/filter/expression_filter.hpp) 提供。旧版“11 个活动子类 + ColumnSegment 按枚举 switch”不能描述当前实现。

```text
SQL 谓词 / 运行期过滤信息
  → ExpressionFilter
       expr: unique_ptr<Expression>
       column_indexes: vector<ProjectionIndex>（多列时使用）
  → TableFilterSet
       单列 map<ProjectionIndex, unique_ptr<TableFilter>>
       多列 vector<unique_ptr<TableFilter>>
  → 数据源的统计剪枝和/或行级执行
```

比较、CAST、BETWEEN 已表示为 `BoundFunctionExpression`，其辅助 API 名字仍为 `BoundComparisonExpression` 等，参见 [EXPRESSION_DESIGN.md](./EXPRESSION_DESIGN.md)。

## 二、列号空间必须分清

| 表示 | 含义 |
|---|---|
| `ColumnIndex` | 扫描请求的原始列及嵌套字段路径；`FULL_READ` 与 `PUSHDOWN_EXTRACT` 的输出语义不同 |
| `ProjectionIndex` | 当前 `LogicalGet::GetColumnIds()` / 扫描列列表中的位置，不是原始表列号 |
| `StorageIndex` | 内置存储扫描的列定位，由扫描初始化转换得到 |
| 单列 filter 的 `BoundReferenceExpression(0)` | 单列表达式输入的唯一向量，不表示原表第 0 列 |
| 多列 filter 的 `column_indexes` | dense BoundReference 输入位置到扫描 `ProjectionIndex` 的映射 |

依据：[column_index.hpp](../src/include/duckdb/common/column_index.hpp)、[table_filter_set.hpp](../src/include/duckdb/planner/table_filter_set.hpp)、[scan_state.cpp](../src/storage/table/scan_state.cpp) 的 `ScanFilter`。

例如扫描请求为 `[原表列7, 原表列2]`，key 为 `ProjectionIndex(1)` 的单列 filter 作用于原表列2。列裁剪后必须重映射 key；嵌套字段下推可能令同一个顶层列产生多个扫描投影位置。

## 三、TableFilterSet 与 DynamicTableFilterSet

当前声明和实现分别在 [table_filter_set.hpp](../src/include/duckdb/planner/table_filter_set.hpp)、[table_filter_set.cpp](../src/planner/table_filter_set.cpp)，不在已移除的 `src/planner/table_filter.cpp`。

`TableFilterSet` 的内部容器是 private。调用方用 iterator 的 `GetIndex()` / `Filter()`、`HasFilters()`、`HasMultiColumnFilters()`、`GetMultiColumnFilters()` 等接口，不能继续访问 `.filters`。

`PushFilter(ProjectionIndex, ...)` 要求活动 `ExpressionFilter`，同一位置已有 filter 时把两棵 `expr` 以 `BoundConjunctionExpression(AND)` 合并。单列入口拒绝带多列映射的 filter；`PushMultiColumnFilter` 要求至少两个有效映射位置并消除完全相同的重复项。

`HasFilters()` 仅检查单列 map，检查整个集合时需同时考虑 `HasMultiColumnFilters()`。当前内置多列下推用于 row-group 统计：无法证明不匹配的行仍须经过残留 `LogicalFilter`。

`DynamicTableFilterSet` 按生产者 `PhysicalOperator` 存储集合，使用 mutex 保护 `PushFilter`、`ClearFilters`、合并。一个目标 scan 可接收多个生产者的过滤器；`GetFinalTableFilters` 复制静态集合和各生产者集合，同列仍按 AND 合并。它是运行期集合容器，不等同于动态边界值 `DynamicFilterData`。

## 四、ExpressionFilter 的语义形态

| 形态 | 当前表示与作用 |
|---|---|
| `col op constant` | 比较函数表达式；可传播统计并尝试创建快速行级 executor |
| IS NULL / IS NOT NULL | `BoundOperatorExpression`；NULL 统计与行级执行 |
| AND / OR / IN | bound conjunction/operator；可传播统计，是否完全下推由规划结果决定 |
| STRUCT/VARIANT 字段 | 列路径、extract 表达式及统计传播；不能继续用旧 `StructFilter` 活动树概括 |
| 普通标量函数 / CAST | 能否剪枝取决于参数统计、函数 callback 与 cast 统计；否则保守执行 |
| Optional | 内部标量函数 + bind data 持有 child，行级为 TRUE，仅辅助剪枝 |
| Selectivity optional | 内部函数执行 child 并观测命中率，低收益时暂停，之后重试 |
| Dynamic | 内部函数持有共享 `DynamicFilterData`，边界值可在执行中改变 |
| Bloom / prefix-range | 内部函数与已构建运行期结构，提供无假阴性的候选裁剪 |

构造入口见 [table_filter_functions.hpp](../src/include/duckdb/planner/filter/table_filter_functions.hpp)、[table_filter_functions.cpp](../src/planner/filter/table_filter_functions.cpp) 的 `CreateOptionalFilterExpression`、`CreateSelectivityOptionalFilterExpression`、`CreateDynamicFilterExpression`。这些函数是内部接口，普通 SQL 绑定被 `TableFilterFunctions::Bind` 拒绝。

### 可选不等于可以误删

Optional 表示“不执行也不影响结果”，仍必须满足：过滤掉的行确定不可能贡献结果。Bloom 的假阳性使候选可能多留，不能多删；它完全可以安全地做行级预过滤，但不能代替精确 join。静态 IN/OR 的 optional 过滤仍依赖残留精确谓词，不能只保留 hint 然后移除原 WHERE。

### DynamicFilterData

当前数据直接保存 `comparison_type`、`constant`、`initialized` 和 `annotated_shared_mutex`，不再内嵌一个活动 `ConstantFilter`。`SetValue` 忽略 NULL，独占锁更新；读取使用共享锁，`Reset` 清初始化状态。见 [dynamic_filter.cpp](../src/planner/filter/dynamic_filter.cpp)、[table_filter_dynamic_function.cpp](../src/planner/filter/table_filter_dynamic_function.cpp)。复制函数 bind data 共享同一状态，典型来源是 TopN。Join runtime filter 也属于动态生成过滤，但通常发布比较/IN/Bloom/PRF 表达式，而非 TopN 的可变边界句柄。

## 五、统计推导与三值逻辑

[ExpressionFilter::CheckExpressionStatistics](../src/planner/filter/expression_filter.cpp) 按函数、operator、conjunction、BOOLEAN reference 分派；通过输入统计推导函数参数或子表达式统计，调用 scalar function 的 filter prune callback，或检查 BOOLEAN 结果统计。

[filter_propagate_result.hpp](../src/include/duckdb/common/enums/filter_propagate_result.hpp) 的五个结果为：`NO_PRUNING_POSSIBLE`、`FILTER_ALWAYS_TRUE`、`FILTER_ALWAYS_FALSE`、`FILTER_TRUE_OR_NULL`、`FILTER_FALSE_OR_NULL`。

WHERE 不接受 NULL，因此 FALSE / FALSE_OR_NULL 均可排除整块；TRUE_OR_NULL 不能当作所有行通过。内置 row-group 路径仅对精确 ALWAYS_TRUE 省去行级判断（非 selectivity 的 root optional 另有专门处理）。统计可能不完整，返回 NO_PRUNING 不代表实际无可过滤行。

普通函数也可能剪枝，例如 [contains.cpp](../src/function/scalar/string/contains.cpp) 的 `ContainsFilterPrune`；“ExpressionFilter 永远不能 zone-map”已经失效。

## 六、兼容与边界

`LegacyConstantFilter`、`LegacyConjunction*Filter` 等用于旧计划序列化/反序列化。`ExpressionFilter::FromTableFilter` 需要实际列类型，将旧 filter 转为表达式；`GetExpressionFilter` 在活动路径遇到遗留类型会 fail fast。`TableFilterSet::GetTableFiltersForSerialization` 尝试转换为旧格式，内部 Bloom/PRF 状态不会作为可恢复的实时过滤数据完整保存。

跨列谓词不再一律“不能进入 TableFilterSet”，但受限多列统计下推也不等于支持任意多列行级扫描过滤。`ProjectionIndex`、NULL、volatile/throwing/barrier、数据源能力和序列化边界都需要在调用链核对。

本文未对所有扩展、所有统计类型和历史序列化版本进行运行验证。性能机制与解码限制见 [FILTER_PERFORMANCE_DESIGN.md](./FILTER_PERFORMANCE_DESIGN.md)。
