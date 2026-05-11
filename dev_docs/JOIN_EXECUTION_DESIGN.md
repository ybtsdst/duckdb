# DuckDB Join 算子实现与执行过程整理

## 1. 范围

本文聚焦 DuckDB 执行层 Join：

- 重点：物理 Join 算子的实现与执行过程（Sink / Finalize / Execute / Source）
- 不涉及：Join order 优化、代价模型等优化器策略

---

## 2. Join 执行框架

### 2.1 类层次

- `PhysicalJoin`：Join 基类，统一 `JoinType`、pipeline 构建、空 RHS 语义
- `PhysicalComparisonJoin`：比较谓词 Join 基类，管理 `JoinCondition`
- `PhysicalRangeJoin`：范围 Join 基类，封装排序与物化能力

### 2.2 常见执行阶段

多数 Join 算子按以下阶段执行：

1. **Sink**：先消费构建侧（通常 RHS），构建哈希表/排序结构/物化块
2. **Finalize**：完成结构初始化和收尾（如指针表、排序结果）
3. **ExecuteInternal**：消费探测侧（通常 LHS）并输出匹配结果
4. **GetDataInternal**：输出右侧未匹配行（RIGHT/FULL）或外部阶段任务结果

---

## 3. 物理 Join 选择（执行计划生成）

`src/execution/physical_plan/plan_comparison_join.cpp` 核心分派：

- 无条件：`PhysicalCrossProduct`
- 有等值条件：优先 `PhysicalHashJoin`
- 范围条件：`PhysicalIEJoin` 或 `PhysicalPiecewiseMergeJoin`
- 不满足上述：`PhysicalNestedLoopJoin`
- 最后兜底：`PhysicalBlockwiseNLJoin`

补充：

- `LogicalAsOfJoin` -> `PhysicalAsOfJoin`（部分小表场景可走 AsOfLoop/NL 路径）
- `LogicalPositionalJoin` -> `PhysicalPositionalJoin`/`PhysicalPositionalScan`
- `LogicalDelimJoin` -> `PhysicalLeftDelimJoin`/`PhysicalRightDelimJoin`（包裹普通 comparison join）

---

## 4. 各 Join 算子执行要点

## 4.1 `PhysicalHashJoin`

文件：

- `src/execution/operator/join/physical_hash_join.cpp`
- `src/execution/join_hashtable.cpp`

执行要点：

1. **Sink**：计算 RHS join key，写入线程本地哈希表，支持并行
2. **Combine/Finalize**：合并本地表到全局表；内存不足时进入 external hash join（分区+spill）
3. **ExecuteInternal**：对 LHS 计算 key，探测 `JoinHashTable::ScanStructure`
4. **Source**：RIGHT/FULL 输出未匹配 build side；external 模式走分阶段任务流

特性：

- 可尝试 `PerfectHashJoinExecutor`（单整型等值且范围可控）
- 支持 Join filter pushdown 统计与下推

## 4.2 `PhysicalNestedLoopJoin`

文件：`src/execution/operator/join/physical_nested_loop_join.cpp`

执行要点：

1. Sink：物化 RHS payload 和 RHS 条件列
2. Execute：
   - `SEMI/ANTI/MARK` 走简化路径（`NestedLoopJoinMark`）
   - `INNER/LEFT/RIGHT/FULL` 走块级双层匹配，可叠加额外 predicate
3. Source：RIGHT/FULL 扫描并输出 RHS 未匹配行

## 4.3 `PhysicalBlockwiseNLJoin`

文件：`src/execution/operator/join/physical_blockwise_nl_join.cpp`

执行要点：

- 先物化 RHS
- 运行时通过 `CrossProductExecutor` 生成块级笛卡尔结果，再对任意布尔 `condition` 过滤
- 作为不规则条件的兜底 Join

## 4.4 `PhysicalPiecewiseMergeJoin`

文件：`src/execution/operator/join/physical_piecewise_merge_join.cpp`

执行要点：

1. Sink RHS 并排序物化
2. Execute 时对每个 LHS chunk 做局部排序（piecewise）
3. 用主范围条件做块迭代匹配，额外条件走 tail filter
4. RIGHT/FULL 在 Source 阶段补未匹配 RHS

## 4.5 `PhysicalIEJoin`

文件：`src/execution/operator/join/physical_iejoin.cpp`

执行要点：

- 典型双不等式范围连接算法
- 双侧排序后在 Source 阶段通过任务机推进（`INIT` 到 `DONE`）
- 内连接结果与 outer 补行均在 Source 阶段产出

## 4.6 `PhysicalAsOfJoin`

文件：`src/execution/operator/join/physical_asof_join.cpp`

执行要点：

- 先按分区键+时间顺序组织两侧数据（`SortStrategy`）
- Source 阶段按分组执行 as-of 匹配（方向由比较符决定）
- RIGHT/FULL 可补未匹配右侧

## 4.7 `PhysicalPositionalJoin`

文件：`src/execution/operator/join/physical_positional_join.cpp`

执行要点：

- 按行号对齐输出（语义上接近按 position 的 FULL OUTER）
- LHS 有而 RHS 无 -> RHS 列补 NULL
- RHS 还有剩余 -> Source 继续输出，LHS 列补 NULL

## 4.8 `PhysicalLeftDelimJoin` / `PhysicalRightDelimJoin`

文件：

- `src/execution/operator/join/physical_left_delim_join.cpp`
- `src/execution/operator/join/physical_right_delim_join.cpp`
- `src/execution/physical_plan/plan_delim_join.cpp`

执行要点：

- 主要用于相关子查询去重（duplicate-eliminated side）
- 结构上是：原始 join + distinct 聚合 + delim scan 依赖管理
- 通过 `delim_join_dependencies` 约束 pipeline 执行依赖

## 4.9 `PhysicalCrossProduct`

文件：`src/execution/operator/join/physical_cross_product.cpp`

执行要点：

- 无 join condition 时采用
- Sink 物化 RHS
- Execute 逐值扫描一侧、整块引用另一侧持续输出笛卡尔积

---

## 5. `JoinType` 在执行中的落地

相关文件：

- `src/common/enums/join_type.cpp`
- `src/execution/operator/join/physical_join.cpp`
- `src/execution/operator/join/physical_comparison_join.cpp`

语义要点：

- `SEMI/ANTI`：最多输出左侧行数，依赖 `found_match`
- `MARK`：输出布尔标记，受 probe key 与 build-side NULL 语义影响
- `LEFT/OUTER/SINGLE`：无匹配时右侧补 NULL
- `RIGHT/OUTER/RIGHT_SEMI/RIGHT_ANTI`：需要传播 build side，通常在 Source 阶段补行

---

## 6. 快速对照表：按 SQL 形态 -> 物理 Join 算子

> 说明：实际选择还会受阈值、条件形态、数据统计和设置项影响，下表是主路径。

| SQL 形态 | 常见条件示例 | 主要物理算子 |
|---|---|---|
| 等值连接 | `a.k = b.k`，多列等值 | `PhysicalHashJoin` |
| 非等值范围连接（单/多不等式） | `a.t < b.t`、`a.x >= b.x` | `PhysicalPiecewiseMergeJoin` 或 `PhysicalIEJoin` |
| 双不等式范围连接（IEJoin 典型） | `a.x < b.x AND a.y > b.y` | `PhysicalIEJoin` |
| 复杂条件连接（含无法结构化为标准 join key 的表达式） | `ON f(a,b,c)` | `PhysicalBlockwiseNLJoin`（兜底） |
| 一般比较连接兜底 | 条件不适配 hash/range | `PhysicalNestedLoopJoin` |
| 无连接条件 | `FROM a, b` / `CROSS JOIN` | `PhysicalCrossProduct` |
| ASOF 连接 | `ASOF JOIN ... ON a.sym=b.sym AND a.ts>=b.ts` | `PhysicalAsOfJoin`（部分场景可走 AsOfLoop/NL 路径） |
| 相关子查询去重连接 | `EXISTS/IN/ANY` 等相关子查询变换后 | `PhysicalLeftDelimJoin` / `PhysicalRightDelimJoin`（内部通常包裹 Hash/NL/Range Join） |
| 按位置连接 | `POSITIONAL JOIN` | `PhysicalPositionalJoin` / `PhysicalPositionalScan` |

---

## 7. 关键源码入口索引

- 计划分派：`src/execution/physical_plan/plan_comparison_join.cpp`
- ASOF 分派：`src/execution/physical_plan/plan_asof_join.cpp`
- Delim 分派：`src/execution/physical_plan/plan_delim_join.cpp`
- Positional 分派：`src/execution/physical_plan/plan_positional_join.cpp`
- Join 基类：`src/execution/operator/join/physical_join.cpp`
- 哈希表核心：`src/execution/join_hashtable.cpp`
