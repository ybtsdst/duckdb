# DuckDB `WHERE a_col LIKE '%value%'` 执行路径分析

> 适用源码：`v2.0-cyanoptera` @ `c1cd2470a455`；核对日期：2026-10-23。核对方式：静态源码审查，未执行本文示例或性能测试。

## 执行链路概览

对于可改写的普通常量 LIKE，主要路径是 PEG 解析 → 绑定 `~~` 标量函数 → `LikeOptimizationRule` → `contains` → 子串查找。该结论有条件：表达式重写优化器必须执行，pattern 符合识别规则；ILIKE、ESCAPE、含 `_` 的 pattern 和动态 pattern 不能全部套用此路径。

下面的 SQL 和流程图都是静态说明，未执行或采集 EXPLAIN。

```sql
SELECT a_col FROM t WHERE a_col LIKE '%value%';
```

```text
PEGTransformerFactory::TransformLikeClause
  → FunctionExpression("~~", a_col, '%value%')
  → BoundFunctionExpression
  → LikeOptimizationRule::Apply
  → contains(a_col, 'value')
  → GetStringContains / FindStrInStr
```

## 一、解析与绑定

当前入口是 [parser.cpp](../src/parser/parser.cpp) 的 `Parser::ParseQuery`，使用 PEG grammar/tokenizer；旧 `third_party/libpg_query/...select.y` 路径不再是此版本的解析依据。

[transform_expression.cpp](../src/parser/peg/transformer/transform_expression.cpp) 中：

| SQL 形式 | 转换符号 |
|---|---|
| LIKE | `TransformLikeToken` → `~~` |
| ILIKE | `TransformILikeToken` → `~~*` |
| NOT LIKE / NOT ILIKE | `TryNegateLikeFunction` / 对应 token → `!~~` / `!~~*` |
| LIKE / ILIKE ... ESCAPE | `TransformLikeClause` → `like_escape` / `ilike_escape` |

绑定函数见 [like.cpp](../src/function/scalar/string/like.cpp)：`LikeFun::GetFunction`、`LikeBindFunction`、`RegularLikeFunction`。当前 bind 接口是 `BindScalarFunctionInput`，通过 `TryGetConstant(1)` 尝试取 pattern；不能继续使用旧签名和旧代码行号。

`LikeBindFunction` 会拒绝带 collation 的快速 matcher，常量 pattern 也不保证产生 matcher。`LikeMatcher::CreateLikeMatcher` 遇到 `_` 或其 escape 字符会返回 nullptr；只有 `%`、没有字面量段的 pattern 也返回 nullptr。

## 二、优化器改写条件

依据：[like_optimizations.cpp](../src/optimizer/rule/like_optimizations.cpp) 的 `LikeOptimizationRule::Apply`、`PatternIsConstant`、`PatternIsPrefix`、`PatternIsSuffix`、`PatternIsContains`。

| 普通 LIKE 常量 pattern | 可识别的结果 |
|---|---|
| `'value'` | 等值比较（当前为 `BoundFunctionExpression`） |
| `'value%'` | `prefix(a_col, 'value')` |
| `'%value'` | `suffix(a_col, 'value')` |
| `'%value%'` | `contains(a_col, 'value')` |
| `'%val_ue%'` | 本规则不改写，继续 LIKE matcher 路径 |
| 动态 pattern | 不符合常量 matcher，不由此规则改写 |

前后允许多个连续 `%`，中间字面量不能再含 `%` 或 `_`。NOT LIKE 的对应结果外包 NOT；该规则也识别 GLOB 形式，但通配符规则不同。`Apply` 对 ILIKE / NOT ILIKE 直接不进行上述改写；ESCAPE 是独立函数，不在本规则匹配列表中。NULL pattern 返回相应 NULL 常量。

因此，“`'%value%'` 被改写为 contains”是这个优化规则的条件结论，不是所有 LIKE 表达式绑定后无条件转换的承诺。

## 三、FindStrInStr 的实际搜索策略

[contains.cpp](../src/function/scalar/string/contains.cpp) 的 `FindStrInStr` 先用 `memchr` 找首字节，再按 needle 长度选择实现：

| needle 字节数 | 主要实现 |
|---|---|
| 0 | `string_t` 重载直接返回位置 0 |
| 1 | 返回首次 `memchr` 命中位置 |
| 2 / 4 / 8 | 对应宽度的整数 `Load` + `ContainsAligned` |
| 3 / 5–7 | 整数前缀比较 + `ContainsUnaligned` 的剩余字节检查 |
| >8 | `ContainsLong`：64 位前缀、`memcmp`；反复近似命中时切换 `ContainsLinear` |

`ContainsLinear` 使用 KMP，避免长 needle 反复近似匹配导致二次复杂度。旧文档把 >8 字节全部归为一个 `ContainsGeneric`、把 64 位整数加载称为 SIMD，是不准确的。`memchr`/`memcmp` 的底层实现可能利用平台向量指令，源码本身不能证明每个长度分支都使用显式 SIMD，也不能给出吞吐提升倍数。

## 四、未改写的 LIKE 与 ILIKE

`LikeMatcher` 将可接受的常量 pattern 按 `%` 分割成非空字面量段。开头/结尾没有 `%` 时直接比较对应边界，中间段使用 `FindStrInStr`。例如 `'ab%cd%ef'` 可以走此路径；`'ab_cd'` 不能，因为 `_` 需要字符级通配。

`RegularLikeFunction` 有 bind info 时使用 `LikeMatcher::Match`，否则由 `TemplatedLikeOperator` 执行通用匹配。`%` 匹配任意长度，`_` 匹配一个字符；通用路径处理字符读取及 escape 语义，不能将其理解为简单字节定长替换。

本版本还在 [like.cpp](../src/function/scalar/string/like.cpp) 的 `ILikeFunction` / `ILikeEscapeFunction` 中优化常量 pattern：每次函数执行先 lowercase pattern，复用 scratch buffer 转换输入，再尝试构造 `LikeMatcher`。含 `_`、只有 `%` 或有效 escape 时可能回退通用匹配；非恒定 pattern/escape 走逐行路径。另有 `ILikePropagateStats` 的 ASCII 专用路径。这里的缓存范围和普通 LIKE 的 bind-time 预处理不同，不能声称 ILIKE 已被优化器改写成普通 contains。

## 五、扫描下推与统计剪枝

`contains` 可以作为 `ExpressionFilter` 下推到支持的扫描中。本版本还注册了 `ContainsFilterPrune`：

- 最大字符串长度小于 needle 长度，可证明整块不匹配。
- min/max 相同且已有前缀包含 needle，可以证明非 NULL 行匹配。
- 若 needle 不在保存前缀内，只有精确 min/max 才能据此证明不匹配；截断前缀必须保守处理。
- 可能含 NULL 时，不能把非 NULL 行永真提升为所有行永真。

因此 `%value%` 不能概括成“绝无 zone-map 收益”。它通常缺乏普通前缀范围裁剪，但函数的统计 callback 仍有上述机会。路径见 [ExpressionFilter::CheckExpressionStatistics](../src/planner/filter/expression_filter.cpp) 与 [Filter 规划](./FILTER_PUSHDOWN_DESIGN.md)。

若 LIKE 被改成 `prefix`，`FilterCombiner::TryPushdownPrefixFilter` 可以构造 UTF-8 合法的上下界；未改写而仍是 LIKE 时，`TryPushdownLikeFilter` 的部分下推会保留精确匹配。不同优化阶段的剩余谓词必须分别判断。

## 六、审查边界

本篇核对了 parser、函数注册/绑定、重写、子串内核和 contains 统计 callback。未穷尽所有 collation、Unicode case folding、escape 或 GLOB 的组合，也未执行性能测试；实际是否命中改写、下推和 prune，应在另行授权的运行验证中检查。
