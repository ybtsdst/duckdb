# DuckDB 延迟物化（Late Materialization）设计与实现文档

> 适用源码：`v2.0-cyanoptera` @ `c1cd2470a455`；核对日期：2026-10-23。核对方式：静态源码审查，未执行本文示例或性能测试。

## 概述：区分计划改写与扫描内延后读取

`LateMaterialization` 优化器将部分 TopN/Limit/Sample 计划改写成以行 ID 为连接条件的 SEMI JOIN：RHS 保留原来的筛选/截断链并裁成少量 key/rowid，作为 build；LHS 是克隆的宽列扫描，作为 probe 并输出最终数据。

这与单次扫描中“先过滤列、后 Select 其余列”的机制不同。后者位于 `RowGroup::ProcessPreparedScan`，不要求此优化 pass，也不保证按命中率等比例解码；参见 [FILTER_EXECUTION_DESIGN.md](./FILTER_EXECUTION_DESIGN.md)。

本篇纠正左右分支和物理阶段的混淆。所有 SQL、计划图均为说明性示意，未执行或采集 EXPLAIN。

## 一、入口与依赖

| 源码 | 核心符号 |
|---|---|
| [optimizer.cpp](../src/optimizer/optimizer.cpp) | `LATE_MATERIALIZATION`，在 sampling pushdown / TopN 之后，join filter pushdown 之前 |
| [late_materialization.cpp](../src/optimizer/late_materialization.cpp) | `Optimize`、`TryLateMaterialization`、`OptimizeLargeLimit`、`ConstructRHS` |
| [late_materialization_helper.cpp](../src/optimizer/late_materialization_helper.cpp) | `CreateLHSGet`、`GetOrInsertRowIds` |
| [settings.hpp](../src/include/duckdb/main/settings.hpp) | `LateMaterializationMaxRowsSetting`，默认50 |
| [table_function.hpp](../src/include/duckdb/function/table_function.hpp) | `BaseTableFunction::late_materialization`、`get_row_id_columns`、`get_virtual_columns` |
| [row_id_column_data.cpp](../src/storage/table/row_id_column_data.cpp) | `RowIdColumnData::ScanCount`、`Filter`、`Select` |

能力声明位于 `BaseTableFunction`，注册函数和已绑定调用分别为 `TableFunction` / `BoundTableFunction`。设置标志不等同于自动提供随机 Fetch 协议。

## 二、算子阈值与实际停止条件

`Optimize` 的外层选择：

| 算子 | 尝试条件 |
|---|---|
| `LogicalTopN` | `top_n.limit <= max_row_count`；此处比较 limit 本身，不是 limit+offset |
| 常量 `LogicalLimit`，limit不超过阈值 | 必须存在 offset 节点（检查是否 UNSET，不只是数值非零） |
| 常量 `LogicalLimit`，limit超过阈值 | 通过 `OptimizeLargeLimit` 后仍可尝试 |
| `LogicalSample` | 非百分比且 sample size 不超过阈值；仍需通过后续扫描条件 |

`OptimizeLargeLimit` 的当前限制是 limit <=1000000，路径仅能经过 Projection 到 Get，Get 不得有单列 table filters；无 offset 且 `preserve_insertion_order=false` 时跳过。该函数的精确判断以源码为准，不能把注释中的“没有过滤”扩展成已穷尽所有新增过滤/采样形态的证明。

`TryLateMaterialization` 继续检查：

1. 下方算子链只允许 Projection、Filter，直至 Get；Join/Aggregate 等直接拒绝。
2. Projection 中任何 volatile 表达式都会拒绝，哪怕不是当前排序/过滤所需列。
3. 跟踪当前算子/投影/过滤依赖，再把 Get 的单列 table filter 列计入 `required_columns`；所需列数必须小于 Get 请求列数。这里比较的是当前扫描投影列表，不是原始schema总列数，也不是最终SELECT列数。
4. `get.function.late_materialization` 必须为 true。
5. 已下推的按行数 sampling 会拒绝此改写，避免复制其扫描；百分比采样有不同条件，不能仅据外层 sample 阈值推断最终应用。
6. 必须存在 `get_row_id_columns`，返回非空列表，且每个 ID 都在 Get 的 virtual_columns 中声明，否则抛内部错误。

`late_materialization_max_rows=0` 不等同于完全禁用：大 Limit 特殊路径仍可能尝试。需要完全禁用此 pass 时应使用对应 optimizer 控制，不能用这个阈值的含义替代整个开关。

## 三、正确的左右分支

示意 SQL：

```sql
SELECT id, ts, payload FROM wide_table ORDER BY ts LIMIT 5;
```

改写前：

```text
TopN(ts, 5)
  └─ Get[id, ts, payload]
```

改写后（省略若干投影与binding调整）：

```text
Order(ts)
  └─ Final Projection[id, ts, payload]
       └─ SEMI JOIN ON lhs.rowid = rhs.rowid
            ├─ LHS / probe: 克隆 Get[id, ts, payload, rowid]
            └─ RHS / build: TopN(ts, 5)
                             └─ 原始 Get[ts, rowid]
```

RHS 才是先运行、产生少量 rowid 的窄链；LHS 才是随后输出宽列的扫描。SEMI JOIN 的输出来自左侧，不能把 TopN 小集合画在左侧然后仍声称输出整行。RHS 的列裁剪由改写末尾 `RemoveUnusedColumns` 完成，TopN 不需要的 payload 从该分支移除。

## 四、改写实现分步

### CreateLHSGet：克隆宽扫描

`LateMaterializationHelper::CreateLHSGet` 生成新 table index，复制函数、bind data、returned types、names、virtual columns、扫描列和projection映射、参数及输入元数据。不是直接把原 Get 指针复用为两个并发消费者。

现有单列扫描过滤在克隆侧被转成 optional 表达式；含动态内部函数的过滤不复制，以免把 TopN 自己更新的边界错误用于取回已选行。精确原过滤仍在 RHS 决定 rowid 集合。当前 helper 只显式遍历单列集合；不要声称它逐字段完整复制了所有 Get 状态或所有多列过滤。

### GetOrInsertRowIds 与 ConstructRHS

`GetOrInsertRowIds` 在扫描列表已有 ID 时复用其位置，否则追加 `ColumnIndex`，必要时更新 projection_ids 和 types，返回 `vector<ProjectionIndex>`。

真实声明使用的回调类型节选，来自 [table_function.hpp](../src/include/duckdb/function/table_function.hpp)：

```cpp
typedef vector<column_t> (*table_function_get_row_id_columns)(
    ClientContext &context, optional_ptr<FunctionData> bind_data);
```

`ConstructRHS` 在原 Get 添加 rowid，然后自底向上在 Projection 添加 rowid 引用，穿过 Filter 的投影映射，最后返回新 binding。构造 SEMI JOIN 后会调整 RHS 顶层 table index，保证最终投影继续给原上游提供正确 binding。

### 最终排序与投影

TopN 分支先投影最终列再按原 TopN ordering 排序，因为 semi join 不保留原 TopN 输出顺序。Limit/Sample 分支先按 rowid 列升序排序，再移除行 ID。复合 rowid 按各分量构成排序键，扩展不能返回不稳定或非唯一的“行号”来冒充身份。

这些重新排序也有代价；没有执行证据时不能用“只取5行”忽略两次扫描、join和排序成本。

## 五、存储：rowid 如何支持筛选

[RowIdColumnData](../src/storage/table/row_id_column_data.cpp) 不存储实体行号列。`ScanCount` 由 row-group start + offset 生成 Sequence；`Select` 对所选位置写出 rowid，推进整批扫描状态。

`RowGroup::CheckRowIdFilter` 为连续 rowid 区间构造非 NULL 数值统计，当前 max 为排他 end-1；`RowIdColumnData::Filter` 还会在 vector 层再检查区间，必要时生成行号并执行过滤。`RowIdColumnData::FetchRows` 也能按位置生成 rowid，但这不意味着 `LateMaterialization` 本身改写成一个随机 Fetch 算子。

`COLUMN_IDENTIFIER_ROW_ID` 是保留虚拟列 ID；列标识不是存储位置，更不是可以当作schema数组下标的值。MVCC、删除和本地事务行等仍由存储扫描负责，本篇未穷尽这些状态的实现。

## 六、物理执行与避免过度物化的条件

通常 rowid 等值连接规划为 `PhysicalHashJoin(SEMI)`：RHS narrow TopN/Limit/Sample 先 Sink/Finalize，LHS wide scan 再 probe。之后的 [join filter pushdown](./RUNTIME_FILTER_DESIGN.md) 可能把 rowid min/max、IN、PRF/Bloom 等信息下推到 LHS，具体受条件和成本控制。

因此不能一概写“LHS 必须逐行完整扫描并读取所有宽列”：rowid 统计可能跳过不相干行组/向量，scan 内过滤又可延后其它列读取；另一方面也不能写“必定按5个rowid直接随机读5行”。逻辑改写仍包含 scan，实际物理读取取决于过滤发布、行号分布、reader和codec。

[table_scan.cpp](../src/function/table/table_scan.cpp) 的 ART 路径确有收集rowids后 `storage.Fetch` 的实现，由 `TableScanInitGlobal` / `TryScanIndex` 等条件选择。那是索引扫描路径，不能用其存在来证明所有 late-materialization scan 都走 Fetch。

## 七、内置与多文件身份

| 数据源 | 当前身份列与能力依据 |
|---|---|
| DuckDB 内置表 | [TableScanGetRowIdColumns](../src/function/table/table_scan.cpp)：`COLUMN_IDENTIFIER_ROW_ID`；注册开启 late materialization |
| Parquet 单文件 | [GetSingleFileFunction](../extension/parquet/read_single_parquet_file.cpp)：注册能力及单文件 rowid 回调 |
| Parquet 多文件 | [ParquetGetRowIdColumns](../extension/parquet/parquet_multi_file_info.cpp)：FILE_INDEX + FILE_ROW_NUMBER |
| read_duckdb | [DuckDBGetRowIdColumns](../src/function/table/read_duckdb.cpp)：FILE_INDEX + COLUMN_IDENTIFIER_ROW_ID |

[TableFunctionMultiFile](../src/common/multi_file/table_function_multi_file.cpp) 从单文件函数转发 late_materialization 等能力；不是所有多文件 reader 默认都具备该能力。

[MultiFileReader](../src/include/duckdb/common/multi_file/multi_file_reader.hpp) 当前 FILE_ROW_NUMBER / FILE_INDEX 常量分别为 `9223372036854775809` / `9223372036854775810`，不是 UINT64_MAX-1/-2。扩展应使用具名常量，不硬编码这些保留数值。

## 八、扩展契约与局限

扩展需要提供稳定、在两次扫描间一致且组合唯一的rowid，声明虚拟列类型并正确响应rowid与列裁剪请求；标志为true但不提供非空回调会触发内部错误。`get_row_id_columns` 可以返回多列，但并不免除Filter投影映射、读者状态复制和快照一致性的责任。

以下仅为未编译的设计骨架：

```text
get_virtual_columns → 声明 identity 分量与类型
get_row_id_columns → 返回共同唯一识别一行的虚拟列 ID
bind/copy → 两份扫描保持相同数据集合与 identity 语义
scan → 按 ColumnIndex 输出请求的普通列与 identity
filter → 仅在正确域中保守剪枝/精确执行
```

宽表、小截断、rowid候选集中且可有效剪枝时可能受益；窄表、随机散布rowid、宽松统计、昂贵重复扫描可能抵消收益。本次只审查计划与主要内置路径，没有验证具体SQL最终计划、所有扩展和codec，更没有给出I/O节约公式或加速倍数。
