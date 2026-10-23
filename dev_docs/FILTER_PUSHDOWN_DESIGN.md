# DuckDB Filter Pushdown 设计文档（规划期转换）

> 适用源码：`v2.0-cyanoptera` @ `c1cd2470a455`；核对日期：2026-10-23。核对方式：静态源码审查，未执行本文示例或性能测试。

## 范围与入口

本文是 [Filter 系列](./FILTER_DESIGN.md) 的规划期部分。当前输出统一为 `ExpressionFilter`，同时保留 FilterCombiner 的等价类、常量约束和专门模式推理。旧“常量比较生成活动 ConstantFilter、跨列绝不下推”的模型不再成立。

主要源码：[filter_pushdown.cpp](../src/optimizer/filter_pushdown.cpp)、[pushdown_filter.cpp](../src/optimizer/pushdown/pushdown_filter.cpp)、[pushdown_get.cpp](../src/optimizer/pushdown/pushdown_get.cpp)、[filter_combiner.cpp](../src/optimizer/filter_combiner.cpp)。

```text
LogicalFilter::SplitPredicates：展开 AND
  → FilterPushdown 收集、分类和沿计划下推
  → PushdownGet：数据源入口与语义门槛
  → FilterCombiner::GenerateTableScanFilters
  → GenerateFilters 回吐未消费的约束
  → TryPushdownGenericExpression：剩余表达式
  → FinishPushdown：保留必要的 LogicalFilter
```

`LogicalFilter::SplitPredicates` 在 [logical_filter.cpp](../src/planner/operator/logical_filter.cpp) 中只展开 AND，OR 不可按独立过滤条件拆开。按列分别产生的多个谓词在 `TableFilterSet::PushFilter` 内用表达式 AND 合并。

## 一、PushdownGet 的实际顺序与停止条件

1. `NormalizeColumnRefAliases` 把别名恢复到扫描所认识的名字，避免 CTE 内联后的投影别名泄漏到数据源；名字采用 `Identifier`，原始字符串通过 `GetIdentifierName()` 取出。
2. 暂存 barrier filters，避免它们下推后比仍在 scan 上方的前置过滤更早求值。
3. 数据源支持复杂或普通 filter pushdown 时，含 parameter 的过滤会使参数失效，以便执行时重新绑定。
4. 在无 WITH ORDINALITY 时给 `pushdown_complex_filter` 机会；回调从表达式列表中消费自己完整负责的谓词，剩余者继续处理。
5. 已有单列 table filters、数据源未声明 `filter_pushdown`、table-in-out 部分类型下推场景、WITH ORDINALITY 等会使普通路径退回 scan 上方过滤。不能为了减少行数而改变 ordinality 的编号语义。
6. `PushFilters()` 发现 `UNSATISFIABLE` 时构造 `LogicalEmptyResult`；否则生成 table filters 并回吐剩余表达式。
7. 对此前没有部分/完全下推的剩余谓词尝试 generic 路径；部分下推的精确原条件仍保留。

`PushdownBarrierFilters` 只在所有普通过滤都已进入 scan、目标确为 DuckDB 内置表、且单列非 volatile 等条件下尝试下推。throwing/短路/副作用语义是正确性条件，不应视作单纯性能限制。

## 二、当前输出与索引空间

`GenerateTableScanFilters` 从等价类的常量约束和 remaining filters 产生表达式过滤器。简单比较先构造 `BoundReference(0) op constant`，外包 `ExpressionFilter`，用原逻辑 binding 的 `ProjectionIndex` 放进集合。

真实声明节选，来自 [table_filter_set.hpp](../src/include/duckdb/planner/table_filter_set.hpp)：

```cpp
void PushFilter(ProjectionIndex col_idx, unique_ptr<TableFilter> filter);
void PushMultiColumnFilter(unique_ptr<TableFilter> filter);
bool HasFilters() const;
bool HasMultiColumnFilters() const;
```

这些是 API 摘录，不是完整可编译程序。key 表示扫描列位置，不是 `ColumnIndex::GetPrimaryIndex()` 返回的原始列号。列裁剪在 `RemoveColumnsFromLogicalGet` 中同时重映射单列 key 和多列 `column_indexes`。

## 三、特殊模式转换

| 输入形态 | 当前转换与精确性 |
|---|---|
| 单列/可定位字段与常量比较 | `TryPushdownConstantFilter` 构造比较函数表达式，完全下推；受类型、比较符、可定位投影约束 |
| BETWEEN | `AddFilter` 使用 `BoundBetweenExpression` 辅助接口拆上下界，进入常量约束推理 |
| `prefix` / `starts_with` / `^@` | `TryPushdownPrefixFilter` 尝试合法 UTF-8 后继上界；完整界时可完全下推 |
| 尚未改写的 LIKE | `TryPushdownLikeFilter`：无通配符普通 LIKE 可等值；固定前缀生成范围，仍保留精确匹配 |
| ILIKE 前缀 | 仅在可计算保守界时部分下推；当前 ASCII 前缀界还处理特殊 Unicode case-fold 上界 |
| 单元素 IN | 支持的类型生成等值，完全下推 |
| 严格连续整数 IN | 转换为闭区间，完全下推，不留有洞的近似范围 |
| 非密集常量 IN | optional(IN表达式)，部分下推，保留原 IN |
| 同列简单比较 OR | 一般 optional(OR表达式)，部分下推；纯等值且连续整数可变成精确范围 |
| temporal CAST 比较 | 支持的类型对生成宽松 optional 范围，部分下推；原 CAST 条件仍精确执行 |

这些入口均在 [filter_combiner.cpp](../src/optimizer/filter_combiner.cpp)。

### IN 与 OR 的细节

`IsDenseRange` 排序后要求每两个相邻值之差**恰好为1**，检查减法溢出，排除不支持的类型（例如该路径不接受 UHUGEINT）。它不是“允许少量洞”的密集度启发式；重复值也会使此检测失败，之后可走保守路径。

`TryPushdownInFilter` 要求首参数为 bound column ref，其他参数为非 NULL 常量。非密集列表以 optional 表达式做统计；`PushdownGet` 会让可由 `InClauseRewriter` 改成 hash join 的 IN 留在逻辑计划，也拒绝 throwing IN 下推以保留短路语义。因此不能用列表大小独立预测最终形态。

`TryPushdownOrClause` 要求各分支是同一 `ProjectionIndex` 上的列常量比较（允许常量在左并翻转比较）。NULL 的 DISTINCT FROM / NOT DISTINCT FROM 分别生成 NULL 检查；普通 `= NULL` 分支在 WHERE 的 OR 中不贡献 TRUE。跨列 OR 不符合这条专门模式，但仍可能有后述多列统计路径。

### LIKE / prefix 的边界

`TryPushdownPrefixFilter` 使用 `Utf8Proc::FindNextLegalUTF8`，不是最后一个字节无条件加1。成功得到完整界可返回 FULLY；找不到上界时已有下界也不能据此移除精确 predicate。

LIKE 可能已被 `LikeOptimizationRule` 改成 prefix 或 contains，所以要区分“prefix函数精确范围替换”和“仍为LIKE时的宽松部分下推”。ILIKE 不由这个重写规则等同变成普通 contains。详见 [LIKE_EXECUTION_ANALYSIS.md](./LIKE_EXECUTION_ANALYSIS.md)。

### Temporal cast 的宽松范围

`TryPushdownTemporalCastFilter` 要求可识别的 CAST、一侧 foldable 常量、支持的时间类型对及可定位底层列。不接受 `!=`；常量无法求值、转回源类型或边界调整溢出时保守拒绝。`GetTemporalCastMargin` 按类型损失使用不同安全余量（DST、丢失时分秒、精度舍入），原 CAST 表达式保留。不能将其泛化为任意函数求逆，也不能把近似范围称为精确替换。

## 四、通用表达式与多列统计下推

真实回调声明节选，来自 [table_function.hpp](../src/include/duckdb/function/table_function.hpp)：

```cpp
typedef bool (*table_function_pushdown_expression_t)(
    ClientContext &context, const LogicalGet &get, Expression &expr);
```

单列路径 `TryPushdownGenericExpression` 要求存在回调、表达式至少有列绑定；询问数据源是否接受后复制表达式，将列引用替换为 `BoundReference(0)` 并完全下推。内置 [TableScanPushdownExpression](../src/function/table/table_scan.cpp) 返回 true，但其调用方先阻止 volatile、部分 throwing、多谓词抛错与可改写 IN 等情况。

多列路径不会逐一询问单列回调：仅目标 `GetTable()->IsDuckTable()`、`CanPropagateExpressionStatistics(expr)` 成立、绑定都属于该 get 且不含虚拟列时，`TryCreateMultiColumnExpressionFilter` 创建 dense reference 映射。返回 PARTIALLY，精确原表达式保留在上层。扫描只用多列统计证明整个 row group 不可能命中；不能声称它已对多列逐行运行完整谓词。

## 五、等价类、传递与不可满足检测

`AddConstantComparison` 通过 `CompareValueInformation` 剪掉冗余约束或发现矛盾，例如 `x > 5 AND x > 7` 收紧为后者，`x = 5 AND x > 6` 不可满足。

`AddBoundComparisonFilter` 处理列/表达式与 scalar 的关系，也合并等值关系中的等价类；`FindTransitiveFilter` / `AddTransitiveFilters` 补充可推导约束。这可以间接为 join 两侧产生常量限制，但下推能否穿过 join 仍由 join 类型和保留侧语义决定，不能向 LEFT/FULL/ANTI 任意传播会删行的条件。

`x = NULL` 在普通 WHERE 比较中不可能产生 TRUE，combiner 可以判空；这不表示 SQL 值层面 `NULL = NULL` 等于 FALSE，也不适用于 `IS NOT DISTINCT FROM NULL` 的语义。

## 六、数据源能力承诺与残留谓词

完全下推意味着扫描必须给出正确结果，可能不再有上层过滤补救；部分下推意味着原精确条件仍有执行位置。`pushdown_complex_filter` 删除表达式也是正确性承诺。自定义扩展不能只实现统计剪枝便无条件宣称 `filter_pushdown` / `pushdown_expression` 支持精确过滤。

本文跟踪了入口、转换、集合写入和主要扫描调用方，未执行 SQL 或穷尽所有 optimizer pass 交互。扫描执行见 [FILTER_EXECUTION_DESIGN.md](./FILTER_EXECUTION_DESIGN.md)。
