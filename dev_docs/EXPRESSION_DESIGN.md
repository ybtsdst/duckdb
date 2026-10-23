# DuckDB 表达式处理设计文档

> 适用源码：`v2.0-cyanoptera` @ `c1cd2470a455`；核对日期：2026-10-23。核对方式：静态源码审查，未执行本文示例或性能测试。

## 概述

表达式经过解析、绑定、优化、列绑定解析和向量化执行。扫描过滤是这些表达式的一种使用方式；聚合、窗口和子查询也有自己的规划与执行阶段，不能把所有 bound 表达式直接交给 `ExpressionExecutor`。

本版本有两项容易被旧资料遮蔽的变化：解析入口已经使用 PEG；比较、CAST、BETWEEN 的 bound 表示已经统一到 `BoundFunctionExpression`。旧的 `BoundComparisonExpression` 等名字仍存在，但它们是构造和访问辅助接口。

## 一、源码入口

| 阶段 | 源码与符号 |
|---|---|
| SQL 解析 | [parser.cpp](../src/parser/parser.cpp)：`Parser::ParseQuery`、`ParseStatement`；PEG tokenizer 与 `PEGTransformerFactory` |
| 解析表达式 | [parsed_expression.hpp](../src/include/duckdb/parser/parsed_expression.hpp)：`ParsedExpression` |
| PEG 表达式转换 | [transform_expression.cpp](../src/parser/peg/transformer/transform_expression.cpp)：`PEGTransformerFactory` 的表达式转换方法 |
| 表达式绑定 | [expression_binder.cpp](../src/planner/expression_binder.cpp)：`ExpressionBinder::BindExpression` |
| 已绑定函数 | [bound_function_expression.hpp](../src/include/duckdb/planner/expression/bound_function_expression.hpp)：`BoundFunctionExpression` |
| 列绑定解析 | [column_binding_resolver.cpp](../src/execution/column_binding_resolver.cpp)：`ColumnBindingResolver` |
| 向量化执行 | [expression_executor.cpp](../src/execution/expression_executor.cpp)：`ExpressionExecutor::InitializeState`、`Execute`、`Select` |
| 扫描过滤 | [expression_filter.hpp](../src/include/duckdb/planner/filter/expression_filter.hpp)：`ExpressionFilter` |

## 二、解析：文本到 ParsedExpression

以下为简化流程图，不是函数调用栈的完整摘录：

```text
SQL 文本
  → Parser::ParseQuery
  → CompiledGrammar 的 Tokenizer
  → 逐条解析 TopLevelStatement
  → PEGTransformerFactory
  → SQLStatement / ParsedExpression
```

当前入口不再是 `libpg_query::pg_query_parse`，也不是 Postgres AST → 旧 `Transformer`。`ParsedExpression` 仍按结构区分 `ColumnRefExpression`、`FunctionExpression`、`ComparisonExpression`、`ConjunctionExpression`、`CastExpression` 等。解析结构与执行结构并不一一对应。

`ExpressionType` 表示运算语义，`ExpressionClass` 表示节点的结构类别，二者不可互相替代。名字和别名采用 [identifier.hpp](../src/include/duckdb/common/identifier.hpp) 的 `Identifier`：保留原始拼写，比较、hash 和排序使用大小写不敏感语义；运行期 `string` 转换为 `Identifier` 是显式操作，取字符串使用 `GetIdentifierName()`。

示意 SQL（未执行）：

```sql
SELECT a + 1 FROM t WHERE b = 'hello';
```

WHERE 在解析阶段是 `ComparisonExpression`，绑定后则是带比较语义的 `BoundFunctionExpression`，而非一个 `BoundComparisonExpression` 对象。

## 三、绑定与规划

`ExpressionBinder::BindExpression` 根据解析节点类别调用相应的绑定方法，完成列查找、函数重载解析、类型协调、隐式转换等。绑定后对象通过 `GetReturnType()`、`GetExpressionType()`、`GetExpressionClass()` 等接口访问元信息。

| 表示 | 当前职责 |
|---|---|
| `BoundColumnRefExpression` | 逻辑列引用，`Binding()` 为 `(TableIndex, ProjectionIndex)` |
| `BoundReferenceExpression` | 执行输入的向量位置，`Index()` 为 chunk 内列偏移 |
| `BoundFunctionExpression` | 持有 `BoundScalarFunction`、参数和 bind data；通过 `Function()`、`GetChildren()`、`BindInfo()` 访问 |
| `BoundConjunctionExpression` | AND/OR，仍为独立结构 |
| `BoundCaseExpression`、`BoundOperatorExpression` | CASE、IN/NULL 检查等仍有专门表示 |
| 聚合/窗口/子查询表达式 | 由对应规划阶段提取或改写，不能作为任意 scalar executor 节点执行 |

辅助接口的实际声明：

- [bound_comparison_expression.hpp](../src/include/duckdb/planner/expression/bound_comparison_expression.hpp)：`BoundComparisonExpression::Create`、`IsComparison`、`Left`、`Right`。修改比较类型使用 `SetType` / `FlipType`，保持 bind data 与 expression type 同步。
- [bound_cast_expression.hpp](../src/include/duckdb/planner/expression/bound_cast_expression.hpp)：`BoundCastExpression::IsCast`、`Child`、`SourceType`、`AddCastToType`；CAST 是 `__cast` bound function。
- [bound_between_expression.hpp](../src/include/duckdb/planner/expression/bound_between_expression.hpp)：`BoundBetweenExpression::Create`、`Input`、`LowerBound`、`UpperBound`。

物理规划的 `ColumnBindingResolver` 把逻辑 binding 解析为输入位置。因此不能把逻辑表的原始列号当作执行 chunk 的列偏移；列裁剪、投影和连接都会改变位置。

## 四、执行：值向量与选择向量

[ExpressionExecutor](../src/include/duckdb/execution/expression_executor.hpp) 按表达式初始化 `ExpressionState`，递归保存子节点状态和中间结果。当前执行分派覆盖 reference、constant、function、conjunction、case、operator、parameter、lambda 等；比较/CAST/BETWEEN 经 function 路径进入其绑定实现。

`Execute` 生成结果向量；`SelectExpression` / `Select` 返回通过过滤的行号，WHERE 只保留结果为 TRUE 的行。不能把 NULL 当作 FALSE 值在所有表达式上下文中任意替换。

[execute_function.cpp](../src/execution/expression_executor/execute_function.cpp) 中的 `ExpressionExecutor::Select` 优先使用函数 select callback，无 callback 时走 `DefaultSelect`；普通函数执行通过 `BoundScalarFunction::Execute`，不是直接读取旧公开 `function.function` 字段。

AND/OR 的两种模式有区别，见 [execute_conjunction.cpp](../src/execution/expression_executor/execute_conjunction.cpp)：

- `Execute(BoundConjunctionExpression)` 计算子结果后用向量 AND/OR 合并，不应概括为总会短路。
- `Select(BoundConjunctionExpression)` 逐步缩小待判断集合；AND 继续判断已通过行，OR 继续判断尚未通过行。
- `AdaptiveFilter` 可根据观测耗时尝试重排；有 `CanThrow()` 或表达式 barrier 时禁止该重排，以保留语义边界。

向量化不等于所有函数都使用 SIMD 指令。具体内核可能是模板循环、专门 select callback 或通用 executor，是否生成机器级 SIMD 还受编译器、构建选项、类型和向量表示影响。

## 五、表达式下推到扫描

当前活动扫描过滤统一为 `ExpressionFilter`。`TableFilterType` 中其他旧类型标记为 `LEGACY_*`，用于兼容序列化；不能再画成活动 `ConstantFilter` / `StructFilter` / `BFTableFilter` 类树。详见 [Filter 总论](./FILTER_DESIGN.md)。

规划期路径：

```text
LogicalFilter
  → FilterPushdown::PushdownGet
     ├─ pushdown_complex_filter：数据源可消费表达式列表
     ├─ FilterCombiner::GenerateTableScanFilters：构造 ExpressionFilter
     └─ TryPushdownGenericExpression：剩余表达式的能力检查
  → LogicalGet::table_filters
  → PhysicalTableScan → TableFunctionInitInput::filters
```

依据：[pushdown_get.cpp](../src/optimizer/pushdown/pushdown_get.cpp)、[filter_combiner.cpp](../src/optimizer/filter_combiner.cpp)。

单列表达式被复制，列引用替换为 `BoundReferenceExpression(0)`；`TableFilterSet` 的 key 是当前扫描投影位置 `ProjectionIndex`。`pushdown_expression` 回调决定数据源是否接受通用单列表达式；内置 `TableScanPushdownExpression` 返回 true，但调用方仍会检查 volatile、抛错、IN 改写和 barrier 等条件。

多列表达式有受限路径：对于 DuckDB 内置表且 `CanPropagateExpressionStatistics` 成立，构造带 `column_indexes` 的 `ExpressionFilter`，部分下推做 row-group 统计剪枝，精确行级表达式仍保留在 `LogicalFilter`。这不是任意 Table Function 的多列执行保证。

### 自定义 Table Function 的正确性边界

接受精确下推后，优化器可能移除上层谓词。扫描实现必须消费并正确执行过滤条件；`PhysicalTableScan` 只转交过滤器，不提供对任意 Table Function 输出的自动补过滤。仅做 zone-map 剪枝不足以实现已被完全下推的 SQL 谓词。

以下为未编译的概念骨架，省略注册、类型和状态管理，不是可直接使用的扩展代码：

```text
init(input):
  保存扫描列 ColumnIndex 和输出映射 projection_ids
  为支持的 ExpressionFilter 初始化本地执行状态
scan():
  统计能证明不可能匹配的块才跳过
  读取所需列，对精确谓词执行行级判断
  按 projection_ids 输出列
```

`filter_pushdown`、`projection_pushdown`、`filter_prune` 是不同能力承诺。`filter_prune` 只移除扫描输出中的纯过滤列，不免除扫描内部读取和执行这些列的责任。扩展实现参考 [Projection 下推](./PROJECTION_PUSHDOWN_DESIGN.md)。

## 六、边界与关联阅读

表达式能下推、能传播统计、能选择性解码是三个独立问题。`ExpressionFilter` 不再等于“不能用 zone-map 的兜底”。比较、NULL 检查、IN、函数 prune callback、CAST 统计以及部分多列表达式都可参与统计推导；无法证明时保守返回 `NO_PRUNING_POSSIBLE`。

LIKE 细节见 [LIKE_EXECUTION_ANALYSIS.md](./LIKE_EXECUTION_ANALYSIS.md)；过滤规划和执行分别见 [FILTER_PUSHDOWN_DESIGN.md](./FILTER_PUSHDOWN_DESIGN.md)、[FILTER_EXECUTION_DESIGN.md](./FILTER_EXECUTION_DESIGN.md)。本文未验证扩展 ABI、示例编译结果或具体 SQL 的最终计划。
