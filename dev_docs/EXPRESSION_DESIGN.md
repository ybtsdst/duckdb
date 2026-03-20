# DuckDB 表达式处理设计文档

## 概述

本文档整理了 DuckDB 中表达式（Expression）的完整处理流程，涵盖三个核心阶段：

1. **解析（Parsing）**：SQL 文本 → `ParsedExpression` 树
2. **绑定与规划（Binding & Planning）**：`ParsedExpression` → `Expression`（Bound Expression）树
3. **执行（Execution）**：`Expression` 树 → 向量化计算结果

以及一个高级特性：

4. **表达式下推（Expression Pushdown）**：将过滤表达式下推至特定 Table Function，实现数据源层面的过滤加速

---

## 一、源码文件总览

### 解析层（Parser）

| 文件 | 说明 |
|------|------|
| `src/parser/parser.cpp` | 入口：调用 libpg_query 将 SQL 文本转换为 Postgres AST，再由 `Transformer` 转换为 DuckDB 内部表示 |
| `src/parser/transformer.cpp` | 将 Postgres parse tree 节点转换为 `ParsedExpression` |
| `src/include/duckdb/parser/base_expression.hpp` | 所有表达式的公共基类 `BaseExpression` |
| `src/include/duckdb/parser/parsed_expression.hpp` | 解析阶段表达式基类 `ParsedExpression` |
| `src/include/duckdb/common/enums/expression_type.hpp` | `ExpressionType`（运算符类型）和 `ExpressionClass`（表达式类别）枚举 |
| `src/parser/expression/` | 各类具体 `ParsedExpression` 子类实现 |
| `src/include/duckdb/parser/expression/` | 各类具体 `ParsedExpression` 子类头文件 |

### 绑定层（Planner/Binder）

| 文件 | 说明 |
|------|------|
| `src/planner/binder.cpp` | 主绑定器：将 SQL 语句绑定到 Catalog 对象，生成逻辑计划 |
| `src/planner/expression_binder.cpp` | 表达式绑定器：将 `ParsedExpression` 转换为带类型信息的 `Expression` |
| `src/include/duckdb/planner/expression.hpp` | 绑定后表达式基类 `Expression`（含返回类型 `return_type`） |
| `src/planner/expression/` | 各类 `BoundXxxExpression` 子类实现 |
| `src/include/duckdb/planner/expression/` | 各类 `BoundXxxExpression` 子类头文件 |

### 执行层（Execution）

| 文件 | 说明 |
|------|------|
| `src/execution/expression_executor.cpp` | 核心向量化表达式求值引擎 `ExpressionExecutor` |
| `src/execution/expression_executor_state.cpp` | 表达式执行中间状态管理 |
| `src/execution/expression_executor/execute_*.cpp` | 各类表达式的具体执行逻辑（comparison、function、constant 等） |
| `src/include/duckdb/execution/expression_executor.hpp` | `ExpressionExecutor` 接口声明 |

### 过滤下推层（Optimizer & Filter）

| 文件 | 说明 |
|------|------|
| `src/optimizer/filter_pushdown.cpp` | 过滤下推优化器入口 `FilterPushdown` |
| `src/optimizer/pushdown/pushdown_get.cpp` | 将过滤器下推至 `LogicalGet`（表扫描）节点 |
| `src/optimizer/filter_combiner.cpp` | 将 bound 表达式组合为 `TableFilter`，含 `TryPushdownGenericExpression` |
| `src/planner/table_filter.cpp` | `TableFilter` / `TableFilterSet` 定义 |
| `src/planner/filter/expression_filter.hpp` | `ExpressionFilter`：任意表达式的 TableFilter 包装 |
| `src/include/duckdb/function/table_function.hpp` | `TableFunction` 结构体，含所有 pushdown 回调函数指针 |
| `src/function/table/table_scan.cpp` | 内置表扫描函数（`seq_scan`）的 pushdown 实现示例 |

---

## 二、阶段一：解析（Parsing）

### 2.1 类层次结构

```
BaseExpression              ← 所有表达式公共基类（type, expression_class, alias）
  └── ParsedExpression      ← 解析阶段表达式（无类型信息、无 Catalog 绑定）
        ├── ConstantExpression        (VALUE_CONSTANT)
        ├── ColumnRefExpression       (COLUMN_REF)
        ├── FunctionExpression        (FUNCTION)
        ├── ComparisonExpression      (COMPARE_EQUAL / COMPARE_LESSTHAN / ...)
        ├── ConjunctionExpression     (CONJUNCTION_AND / CONJUNCTION_OR)
        ├── CastExpression            (OPERATOR_CAST)
        ├── CaseExpression            (CASE)
        ├── BetweenExpression         (COMPARE_BETWEEN)
        ├── OperatorExpression        (OPERATOR_IS_NULL / OPERATOR_NOT / ...)
        ├── SubqueryExpression        (SUBQUERY)
        ├── WindowExpression          (WINDOW_*)
        ├── LambdaExpression          (LAMBDA)
        └── ...
```

每个 `ParsedExpression` 都携带两个关键枚举：

- **`ExpressionType`**：表达式的运算符语义，例如 `COMPARE_EQUAL`、`CONJUNCTION_AND`、`VALUE_CONSTANT` 等。
- **`ExpressionClass`**：表达式的结构类型（用于 `Cast<T>()` 安全转型），例如 `CONSTANT`、`COLUMN_REF`、`COMPARISON` 等。

### 2.2 解析流程

```
SQL 字符串
    │
    ▼  Parser::ParseQuery()
libpg_query::pg_query_parse()   ← 调用 Postgres 解析器生成 C 结构体 parse tree
    │
    ▼  Transformer::TransformStatement()
ParsedExpression 树              ← 各 TransformXxx() 方法将 pg_node 转为 ParsedExpression
```

关键函数（`src/parser/transformer.cpp`）：
- `TransformExpression(pg_node*)` — 表达式分发入口
- `TransformAExpr()` — 比较/算术运算符
- `TransformBoolExpr()` — AND/OR/NOT
- `TransformFuncCall()` — 函数调用
- `TransformAConst()` — 常量

### 2.3 示例

```sql
SELECT a + 1 FROM t WHERE b = 'hello'
```

WHERE 子句解析结果（伪代码）：

```
ComparisonExpression(COMPARE_EQUAL)
  ├── ColumnRefExpression("b")
  └── ConstantExpression("hello")
```

---

## 三、阶段二：绑定与规划（Binding & Planning）

### 3.1 类层次结构

```
BaseExpression
  └── Expression                       ← 绑定后表达式（含 return_type: LogicalType）
        ├── BoundConstantExpression     (BOUND_CONSTANT)   — 常量值
        ├── BoundColumnRefExpression    (BOUND_COLUMN_REF) — 绑定列（表索引 + 列索引）
        ├── BoundReferenceExpression    (BOUND_REF)        — 向量化执行中的列偏移引用
        ├── BoundFunctionExpression     (BOUND_FUNCTION)   — 函数（含执行函数指针）
        ├── BoundComparisonExpression   (BOUND_COMPARISON) — 比较运算
        ├── BoundConjunctionExpression  (BOUND_CONJUNCTION)— AND/OR
        ├── BoundCastExpression         (BOUND_CAST)       — 类型转换
        ├── BoundCaseExpression         (BOUND_CASE)       — CASE WHEN
        ├── BoundBetweenExpression      (BOUND_BETWEEN)    — BETWEEN ... AND ...
        ├── BoundAggregateExpression    (BOUND_AGGREGATE)  — 聚合函数
        ├── BoundWindowExpression       (BOUND_WINDOW)     — 窗口函数
        ├── BoundSubqueryExpression     (BOUND_SUBQUERY)   — 子查询
        └── ...
```

### 3.2 绑定流程

```
ParsedExpression 树
    │
    ▼  ExpressionBinder::BindExpression()
        │  根据 ExpressionClass 分发到对应 BindXxx() 方法：
        │  - BindExpression(ColumnRefExpression)  → 解析列名 → BoundColumnRefExpression
        │  - BindExpression(FunctionExpression)   → Catalog 查找 → BoundFunctionExpression
        │  - BindExpression(ComparisonExpression) → 递归绑定子节点 → BoundComparisonExpression
        │  ...
        ▼
BoundExpression 树（含类型信息 + Catalog 绑定）
```

`ExpressionBinder::BindExpression()` 核心代码（`src/planner/expression_binder.cpp`）：

```cpp
BindResult ExpressionBinder::BindExpression(unique_ptr<ParsedExpression> &expr, idx_t depth, bool root_expression) {
    switch (expr->GetExpressionClass()) {
    case ExpressionClass::COLUMN_REF:
        return BindExpression(expr->Cast<ColumnRefExpression>(), depth, root_expression);
    case ExpressionClass::COMPARISON:
        return BindExpression(expr->Cast<ComparisonExpression>(), depth);
    case ExpressionClass::FUNCTION: {
        auto &function = expr->Cast<FunctionExpression>();
        return BindExpression(function, depth, expr);  // 包含 Catalog 查找
    }
    // ...
    }
}
```

绑定列引用时，`ColumnRefExpression`（如 `"b"`）被解析为带有 `(table_index, column_index)` 的 `BoundColumnRefExpression`。

### 3.3 BoundColumnRefExpression vs BoundReferenceExpression

| 类型 | 阶段 | 含义 |
|------|------|------|
| `BoundColumnRefExpression` | 逻辑规划 | 列绑定（`table_index` + `column_index`） |
| `BoundReferenceExpression` | 物理执行 | DataChunk 中的列偏移（`index`） |

在 `ColumnBindingResolver` 阶段（物理规划时），`BoundColumnRefExpression` 被替换为 `BoundReferenceExpression`，以便 `ExpressionExecutor` 直接通过偏移访问向量。

---

## 四、阶段三：执行（Execution）

### 4.1 ExpressionExecutor

`ExpressionExecutor`（`src/include/duckdb/execution/expression_executor.hpp`）是 DuckDB 向量化表达式求值引擎的核心，负责对一批数据（`DataChunk`）批量计算表达式。

```cpp
class ExpressionExecutor {
public:
    // 构造时注入 ClientContext 和一组要执行的表达式
    ExpressionExecutor(ClientContext &context, const Expression &expression);
    ExpressionExecutor(ClientContext &context, const vector<unique_ptr<Expression>> &expressions);

    // 对 input DataChunk 批量执行所有表达式，结果写入 result DataChunk
    void Execute(DataChunk &input, DataChunk &result);

    // 执行单个布尔表达式，生成 SelectionVector（true 的行索引）
    idx_t SelectExpression(DataChunk &input, SelectionVector &sel);

    // 对标量表达式求值（折叠为单个 Value）
    static Value EvaluateScalar(ClientContext &context, const Expression &expr, bool allow_unfoldable = false);
};
```

### 4.2 执行分发

`ExpressionExecutor::Execute()` 通过重载派发到各类型的专用执行函数：

```
Execute(Expression &expr)
  ├── Execute(BoundConstantExpression)   → 直接输出常量向量
  ├── Execute(BoundReferenceExpression)  → 从 DataChunk 取对应列向量
  ├── Execute(BoundComparisonExpression) → 递归执行左右子节点，再比较
  ├── Execute(BoundConjunctionExpression)→ 短路求值 AND/OR
  ├── Execute(BoundFunctionExpression)   → 调用 ScalarFunction::function 函数指针
  ├── Execute(BoundCastExpression)       → 调用类型转换逻辑
  ├── Execute(BoundCaseExpression)       → 按分支求值
  └── Execute(BoundBetweenExpression)    → 展开为两次比较
```

过滤操作使用 `Select()` 系列方法（返回 `SelectionVector`），相比 `Execute()` 可以利用短路优化更高效。

### 4.3 ExpressionState

每个表达式节点在执行时有对应的 `ExpressionState`，存储中间向量、函数缓存等临时状态，通过 `ExpressionExecutorState` 管理。

```
ExpressionExecutorState
  └── ExpressionState[]     ← 与 expressions[] 一一对应
        └── child_states[]  ← 递归子节点的 state
```

---

## 五、阶段四：表达式下推至 Table Function

### 5.1 整体流程

表达式下推是优化器的工作，目标是将 SQL 层面的 WHERE 过滤条件尽可能地"下推"到数据扫描层（Table Function），减少上层算子处理的数据量。

```
查询计划优化阶段
    │
    ▼  FilterPushdown::Rewrite()
        │  遍历逻辑计划树，收集 LogicalFilter 节点上的过滤器
        ▼
    FilterPushdown::PushdownGet()   (src/optimizer/pushdown/pushdown_get.cpp)
        │
        ├── [方式一] pushdown_complex_filter  ← 任意表达式列表，函数自行解析
        ├── [方式二] filter_pushdown + GenerateTableScanFilters()
        │               ← 简单比较（=、<、>、IS NULL 等）→ TableFilterSet
        └── [方式三] pushdown_expression      ← 单列任意表达式 → ExpressionFilter
```

### 5.2 TableFilter 类型层次

TableFilter（`src/include/duckdb/planner/table_filter.hpp`）是下推到扫描层的过滤单元：

```
TableFilter
  ├── ConstantFilter       (CONSTANT_COMPARISON) — 与常量的比较：col = C / col > C 等
  ├── IsNullFilter         (IS_NULL)             — col IS NULL
  ├── IsNotNullFilter      (IS_NOT_NULL)         — col IS NOT NULL
  ├── ConjunctionAndFilter (CONJUNCTION_AND)     — 多个过滤器的 AND 组合
  ├── ConjunctionOrFilter  (CONJUNCTION_OR)      — 多个过滤器的 OR 组合
  ├── InFilter             (IN_FILTER)           — col IN (C1, C2, ...)
  ├── StructFilter         (STRUCT_EXTRACT)      — 结构体子字段过滤
  ├── DynamicFilter        (DYNAMIC_FILTER)      — 运行时动态更新的过滤器
  └── ExpressionFilter     (EXPRESSION_FILTER)  — 任意 bound 表达式（最通用）
```

`TableFilterSet` 持有按列索引（`map<idx_t, unique_ptr<TableFilter>>`）组织的过滤集合，通过 `LogicalGet::table_filters` 传递给物理扫描算子。

### 5.3 三种下推机制详解

#### 机制一：`pushdown_complex_filter`（复杂过滤下推）

函数签名：
```cpp
typedef void (*table_function_pushdown_complex_filter_t)(
    ClientContext &context,
    LogicalGet &get,
    FunctionData *bind_data,
    vector<unique_ptr<Expression>> &filters   // 输入：所有过滤器；修改后剩余者由外层处理
);
```

- 优化器将**所有过滤表达式**（任意复杂度）整体传给函数。
- 函数可以消费自己能处理的表达式（从 `filters` 中移除），剩余的由外层继续处理。
- 适合需要自定义解析过滤逻辑的数据源（如外部 API、格式化文件读取器等）。

#### 机制二：`filter_pushdown` + `GenerateTableScanFilters()`（标准 TableFilter 下推）

```cpp
bool filter_pushdown;   // 标志位，设为 true 即启用
```

当 `filter_pushdown = true` 时，`FilterCombiner::GenerateTableScanFilters()` 自动将简单过滤表达式（单列与常量的比较、IS NULL 等）转换为 `ConstantFilter`、`IsNullFilter` 等结构化 `TableFilter`，存入 `get.table_filters`。

物理扫描算子在读取数据时，通过 `TableFilterSet` 对每列数据进行向量化检查，可在存储层（zone map、行组过滤等）直接剪枝。

#### 机制三：`pushdown_expression`（单列任意表达式下推）

函数签名：
```cpp
typedef bool (*table_function_pushdown_expression_t)(
    ClientContext &context,
    const LogicalGet &get,
    Expression &expr     // 要下推的表达式（仅引用单列）
);
// 返回 true 表示接受下推；返回 false 表示拒绝
```

调用链（`src/optimizer/filter_combiner.cpp`）：

```cpp
FilterPushdownResult FilterCombiner::TryPushdownGenericExpression(LogicalGet &get, Expression &expr) {
    if (!get.function.pushdown_expression) {
        return FilterPushdownResult::NO_PUSHDOWN;
    }
    // 1. 提取表达式中的列绑定，仅支持单列表达式
    vector<ColumnBinding> bindings;
    ColumnLifetimeAnalyzer::ExtractColumnBindings(expr, bindings);
    // ... 确保只有一列

    // 2. 询问 Table Function 是否接受此表达式
    if (!get.function.pushdown_expression(context, get, expr)) {
        return FilterPushdownResult::NO_PUSHDOWN;
    }

    // 3. 将 BoundColumnRefExpression 替换为 BoundReferenceExpression（偏移 0）
    auto filter_expr = expr.Copy();
    ReplaceWithBoundReference(filter_expr);

    // 4. 封装为 ExpressionFilter 存入 table_filters
    auto expr_filter = make_uniq<ExpressionFilter>(std::move(filter_expr));
    auto &column_index = column_ids[bindings[0].column_index];
    get.table_filters.PushFilter(column_index, std::move(expr_filter));
    return FilterPushdownResult::PUSHED_DOWN_FULLY;
}
```

**`ExpressionFilter` 的执行**：在物理扫描阶段，`ExpressionFilterState` 持有一个 `ExpressionExecutor`，对扫描出的每行数据（以单列 `DataChunk` 的形式）调用 `SelectExpression()`，过滤不满足条件的行。

### 5.4 如何为自定义 Table Function 实现表达式下推

以下是一个完整的实现示例，展示如何让自定义 Table Function 支持 `pushdown_expression`：

```cpp
// 步骤 1：实现 pushdown_expression 回调
// 判断哪些表达式可以被该 Table Function 接受（下推至内部处理）
bool MyTableFunctionPushdownExpression(
    ClientContext &context,
    const LogicalGet &get,
    Expression &expr) {
    // 只接受函数调用表达式（例如自定义匹配函数）
    if (expr.GetExpressionClass() != ExpressionClass::BOUND_FUNCTION) {
        return false;
    }
    auto &func_expr = expr.Cast<BoundFunctionExpression>();
    // 只接受名为 "my_match" 的函数
    if (func_expr.function.name != "my_match") {
        return false;
    }
    return true;
}

// 步骤 2：在 TableFunction 初始化时注册回调并开启 filter_pushdown
TableFunction GetMyTableFunction() {
    TableFunction func("my_table_func", {}, MyTableFunctionScan);
    func.bind          = MyTableFunctionBind;
    func.init_global   = MyTableFunctionInitGlobal;
    func.init_local    = MyTableFunctionInitLocal;

    // 开启标准 TableFilter 下推（简单比较下推）
    func.filter_pushdown     = true;
    func.projection_pushdown = true;

    // 注册自定义表达式下推回调（任意单列表达式下推）
    func.pushdown_expression = MyTableFunctionPushdownExpression;

    return func;
}

// 步骤 3：在扫描函数中使用下推的过滤器
void MyTableFunctionScan(ClientContext &context, TableFunctionInput &data, DataChunk &output) {
    auto &bind_data = data.bind_data->Cast<MyBindData>();
    auto &global_state = data.global_state->Cast<MyGlobalState>();

    // table_filters 由优化器通过 init_global 注入（见 TableFunctionInitInput::filters）
    // 在 init_global 中可读取 input.filters 来初始化内部过滤状态
    // 扫描时只返回满足所有下推过滤条件的数据
    // ...
}
```

**注意事项**：
1. `pushdown_expression` 回调只支持**单列**表达式（跨列表达式无法下推）。
2. 接受下推后，优化器会将表达式封装为 `ExpressionFilter` 存入 `table_filters`；函数在执行阶段通过 `TableFunctionInitInput::filters` 获取。
3. `ExpressionFilter` 在存储层和运行时均会被执行：即使 Table Function 不显式处理，框架也会在数据返回后通过 `ExpressionExecutor` 自动应用过滤。
4. 若要在 Table Function 内部提前过滤（如跳过文件/分区），需在 `init_global` 或扫描函数中主动检查 `filters`。

---

## 六、完整数据流示意图

```
-- my_match(col, pattern) 为假设的自定义标量函数，此处仅作示例
SQL: SELECT a FROM t WHERE b > 10 AND my_match(c, 'pattern')
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────┐
│ 1. Parser（解析）                                                │
│    ParsedExpression 树:                                          │
│      ConjunctionExpression(AND)                                  │
│        ├── ComparisonExpression(>) : b, 10                      │
│        └── FunctionExpression(my_match) : c, 'pattern'          │
└──────────────────────────────┬──────────────────────────────────┘
                               │
                               ▼
┌─────────────────────────────────────────────────────────────────┐
│ 2. Binder（绑定）                                                │
│    Expression 树（含类型）:                                      │
│      BoundConjunctionExpression(AND)                             │
│        ├── BoundComparisonExpression(>) : BoundColRef(b:INT), 10 │
│        └── BoundFunctionExpression(my_match) : BoundColRef(c)   │
└──────────────────────────────┬──────────────────────────────────┘
                               │
                               ▼
┌─────────────────────────────────────────────────────────────────┐
│ 3. Optimizer / FilterPushdown（下推优化）                        │
│    - b > 10  → ConstantFilter(COMPARE_GREATERTHAN, 10)          │
│               → table_filters[col_b] = ConstantFilter           │
│    - my_match(c, 'pattern')  → pushdown_expression() 返回 true  │
│               → ExpressionFilter(BoundFunc(my_match, BoundRef(0)))│
│               → table_filters[col_c] = ExpressionFilter         │
└──────────────────────────────┬──────────────────────────────────┘
                               │
                               ▼
┌─────────────────────────────────────────────────────────────────┐
│ 4. Execution（执行）                                             │
│    PhysicalTableScan:                                            │
│      每次 GetData() 时：                                         │
│        1. 读取原始数据 → DataChunk                               │
│        2. 对 col_b 应用 ConstantFilter（zonemap/行级过滤）       │
│        3. 对 col_c 应用 ExpressionFilter                        │
│           └── ExpressionExecutor::SelectExpression()            │
│                 └── Execute(BoundFunctionExpression my_match)    │
│        4. 只将通过所有过滤器的行输出给上层算子                   │
└─────────────────────────────────────────────────────────────────┘
```

---

## 七、关键源码位置速查

| 概念 | 关键文件 |
|------|---------|
| 表达式类型枚举 | `src/include/duckdb/common/enums/expression_type.hpp` |
| 解析表达式基类 | `src/include/duckdb/parser/parsed_expression.hpp` |
| 绑定表达式基类 | `src/include/duckdb/planner/expression.hpp` |
| 表达式绑定器 | `src/planner/expression_binder.cpp` |
| 向量化执行引擎 | `src/execution/expression_executor.cpp` |
| 过滤下推优化器 | `src/optimizer/filter_pushdown.cpp` |
| GET 节点下推 | `src/optimizer/pushdown/pushdown_get.cpp` |
| 通用表达式下推 | `src/optimizer/filter_combiner.cpp`（`TryPushdownGenericExpression`） |
| TableFilter 定义 | `src/include/duckdb/planner/table_filter.hpp` |
| ExpressionFilter | `src/include/duckdb/planner/filter/expression_filter.hpp` |
| TableFunction 接口 | `src/include/duckdb/function/table_function.hpp` |
| seq_scan 下推示例 | `src/function/table/table_scan.cpp`（`TableScanPushdownExpression`） |
