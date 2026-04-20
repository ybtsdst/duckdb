# DuckDB `WHERE a_col LIKE '%value%'` 执行路径分析

## 执行链路概览

```
SQL: WHERE a_col LIKE '%value%'
         │
         ▼
  1. Parser (libpgquery)
     LIKE → 操作符 "~~"
         │
         ▼
  2. Binder
     "~~" → BoundFunctionExpression
     常量 pattern → 预解析为 LikeMatcher
         │
         ▼
  3. Optimizer (LikeOptimizationRule)
     '%value%' → 改写为 contains("value")
         │
         ▼
  4. Executor
     FindStrInStr() SIMD 子串搜索
```

---

## 阶段一：解析（Parsing）

**文件**: `third_party/libpg_query/grammar/statements/select.y:2341`

SQL `LIKE` 被 PostgreSQL 兼容语法解析为操作符节点：

```c
a_expr LIKE a_expr
    → makeSimpleAExpr(PG_AEXPR_LIKE, "~~", $1, $3)

a_expr NOT LIKE a_expr   → 操作符 "!~~"
a_expr ILIKE a_expr      → 操作符 "~~*"
a_expr LIKE a_expr ESCAPE a_expr → 调用函数 like_escape()
```

输出：`FunctionExpression("~~", [a_col, '%value%'])`

---

## 阶段二：绑定（Binding）

**文件**: `src/function/scalar/string/like.cpp`

### 函数注册（L554）

```cpp
ScalarFunction like("~~",
    {LogicalType::VARCHAR, LogicalType::VARCHAR},
    LogicalType::BOOLEAN,
    RegularLikeFunction<LikeOperator, false>,
    LikeBindFunction);
```

### 绑定时 pattern 预解析（L344）

```cpp
unique_ptr<FunctionData> LikeBindFunction(...) {
    if (arguments[1]->IsFoldable()) {   // pattern 是常量
        Value pattern_str = ExpressionExecutor::EvaluateScalar(...);
        return LikeMatcher::CreateLikeMatcher(pattern_str.ToString());
    }
    return nullptr;
}
```

若 pattern 是常量，绑定阶段就将其解析为 `LikeMatcher`（含预分段结果），执行时无需重复解析。

---

## 阶段三：优化器改写（LikeOptimizationRule）

**文件**: `src/optimizer/rule/like_optimizations.cpp`

这是 `'%value%'` 性能的核心所在。优化器检测 pattern 结构，直接改写为更快的等价函数：

| Pattern 形式 | 改写目标 | 说明 |
|---|---|---|
| `'value'` | `=`（等号比较） | 精确匹配 |
| `'value%'` | `prefix()` | strncmp 前缀比较 |
| `'%value'` | `suffix()` | 比较末尾字节 |
| **`'%value%'`** | **`contains("value")`** | **子串搜索（最常见）** |
| `'%val_ue%'`（含 `_`） | `LikeMatcher` 段匹配 | 分段搜索 |
| 动态 pattern | `TemplatedLikeOperator` | 完整回溯逻辑 |

**`'%value%'` 的识别条件**（`PatternIsContains()`）：  
pattern 形如 `[%]+[^%_]*[%]+`，即首尾均为 `%`，中间不含通配符。

改写后，`LIKE '%value%'` 完全等价于 `contains(a_col, 'value')`，通用 LIKE 逻辑不再参与执行。

---

## 阶段四：执行（Executor）

### 入口函数（L507）

```cpp
template <class OP, bool INVERT>
void RegularLikeFunction(DataChunk &input, ExpressionState &state, Vector &result) {
    if (func_expr.bind_info) {
        auto &matcher = func_expr.bind_info->Cast<LikeMatcher>();
        // 快速路径：使用预解析的 LikeMatcher
        UnaryExecutor::Execute<string_t, bool>(input.data[0], result, input.size(),
            [&](string_t input) { return matcher.Match(input); });
    } else {
        // 慢速路径：动态 pattern，逐行解析
        BinaryExecutor::ExecuteStandard<string_t, string_t, bool, OP>(...);
    }
}
```

---

## 子串搜索：`FindStrInStr()`

**文件**: `src/function/scalar/string/contains.cpp:76`

`contains()` 的底层实现，按 needle 长度选择不同的 SIMD 路径：

```
Step 1: memchr() 快速跳过，定位 needle 首字节的位置
Step 2: 按 needle 长度选择比较策略：
    1 byte  → 直接返回 memchr 结果
    2-3     → uint16_t 对齐批量比较
    4-7     → uint32_t 对齐批量比较
    8+      → uint64_t 对齐批量比较（SIMD 效果）
    fallback → memcmp 通用比较
```

三种 MatchRemainder 变体：
- `ContainsAligned`：needle 长度能整除时使用
- `ContainsUnaligned`：非整除时使用
- `ContainsGeneric`：大 needle 使用 `memcmp`

---

## 通用 LIKE 路径（含 `_` 或动态 pattern 时）

**文件**: `src/function/scalar/string/like.cpp:174`

```cpp
template <char PERCENTAGE, char UNDERSCORE, bool HAS_ESCAPE, class READER>
bool TemplatedLikeOperator(const char *sdata, idx_t slen,
                           const char *pdata, idx_t plen, char escape)
```

- `%` → 匹配任意多个字符（含零个）
- `_` → 匹配恰好一个字符
- 支持 `ESCAPE` 转义字符
- `StandardCharacterReader`：UTF-8 安全版本
- `ASCIILCaseReader`：ASCII 大小写不敏感版（用于 ILIKE）

---

## LikeMatcher（含 `_` 但 pattern 为常量时）

**文件**: `src/function/scalar/string/like.cpp:225`

```cpp
struct LikeMatcher : public FunctionData {
    vector<LikeSegment> segments;   // 预分割的字面量段
    bool has_start_percentage;
    bool has_end_percentage;

    bool Match(string_t &str);      // 依次用 FindStrInStr 搜索各段
};
```

Pattern 在绑定时被分割为字面量段，运行时依次搜索每段（类似多级 `contains`）。

---

## 关键文件速查

| 阶段 | 文件 | 关键函数 |
|---|---|---|
| 解析 | `third_party/libpg_query/grammar/statements/select.y:2341` | `makeSimpleAExpr()` |
| 函数注册 | `src/function/scalar/string/like.cpp:554` | `LikeFun::GetFunction()` |
| 绑定预解析 | `src/function/scalar/string/like.cpp:344` | `LikeBindFunction()` |
| 优化器改写 | `src/optimizer/rule/like_optimizations.cpp` | `LikeOptimizationRule::Apply()` |
| 执行入口 | `src/function/scalar/string/like.cpp:507` | `RegularLikeFunction()` |
| LikeMatcher | `src/function/scalar/string/like.cpp:225` | `LikeMatcher::Match()` |
| 通用 LIKE | `src/function/scalar/string/like.cpp:174` | `TemplatedLikeOperator()` |
| 子串搜索 | `src/function/scalar/string/contains.cpp:76` | `FindStrInStr()` |
