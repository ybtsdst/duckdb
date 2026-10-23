# DuckDB Table Function Projection Pushdown 设计文档

> 适用源码：`v2.0-cyanoptera` @ `c1cd2470a455`；核对日期：2026-10-23。核对方式：静态源码审查，未执行本文示例或性能测试。

## 一、三个独立的能力

| 能力 | 决定的内容 | 不应推导出的承诺 |
|---|---|---|
| `projection_pushdown` | 扫描只需读取并输出请求的列/字段 | 不表示已经实现过滤 |
| `filter_pushdown` | 数据源接受扫描过滤条件 | 不表示纯过滤列自动不再输出 |
| `filter_prune` | 可以从 scan 输出中移除只用于扫描内部过滤的列 | 不表示这些列无需读取，也不表示优化器能忽略其谓词 |

能力字段位于 [table_function.hpp](../src/include/duckdb/function/table_function.hpp) 的 `BaseTableFunction`。当前注册对象为 `TableFunction`，已绑定逻辑/物理调用持有 `BoundTableFunction`，二者共享行为字段，但函数签名声明与绑定调用类型分开保存。不能把所有生命周期对象都当成同一个旧 `TableFunction` 结构体。

## 二、从 SQL 到扫描

下面为简化流程，不是实际 EXPLAIN：

```text
SELECT a FROM t WHERE b > 10
  → LogicalGet + 上游引用
  → RemoveUnusedColumns::RemoveColumnsFromLogicalGet
       扫描所需列可能是 [a,b]
       输出位置可能是 [0]（b 已完全由 scan 过滤）
  → PhysicalPlanGenerator::CreatePlan(LogicalGet)
  → PhysicalTableScan(BoundTableFunction, ColumnIndex列表, projection_ids)
  → TableFunctionInitInput
  → 数据源读取/过滤 → 输出 a
```

如果 `b > 10` 仍留在 scan 上方，b 就仍为上层需要的输出列，不能被 filter_prune 去掉。是否下推以及是否残留见 [FILTER_PUSHDOWN_DESIGN.md](./FILTER_PUSHDOWN_DESIGN.md)。

## 三、列路径、位置和输出映射

[TableFunctionInitInput](../src/include/duckdb/function/table_function.hpp) 的真实字段节选：

```cpp
optional_ptr<const FunctionData> bind_data;
vector<column_t> column_ids;
vector<ColumnIndex> column_indexes;
const vector<idx_t> projection_ids;
optional_ptr<TableFilterSet> filters;
```

两个构造重载在 `column_t` 与 `ColumnIndex` 列表间兼容转换；需要子字段、类型和提取信息时使用 `column_indexes`，只看 `column_ids` 会丢失路径语义。当前 `ColumnIndex` 还允许字段名表示，不能对任意对象无条件调用 `GetPrimaryIndex()`。

[column_index.hpp](../src/include/duckdb/common/column_index.hpp) 的区别：

- `FULL_READ`：输出整个请求列；children 可描述内部需读字段。
- `PUSHDOWN_EXTRACT`：扫描必须直接输出指定 STRUCT/VARIANT 字段，可能带 cast 类型；设置时要求类型信息和单一路径。
- 一个原表顶层列可以映射成多个提取输出，因此原表列数、扫描列数和输出列数可能不同。

`projection_ids` 是扫描列表中的**位置**。例如 `column_indexes=[原列7, 原列2, 原列9]`、`projection_ids=[0,2]`，输出顺序为原列7、9。`TableFilterSet` 单列 key 同样为扫描位置 `ProjectionIndex`，不是原始表号。

`CanRemoveFilterColumns()` 只有在 `projection_ids` 非空且数量少于扫描列数量时返回 true。非空映射也可能只是等长映射，不能把“非空”直接等同于“确有纯过滤列可删”；空映射通常表示按 scan 列顺序输出，而不是零列输出协议。

## 四、优化器裁剪与重映射

依据：[remove_unused_columns.cpp](../src/optimizer/remove_unused_columns.cpp) 的 `RemoveColumnsFromLogicalGet`。

1. `everything_referenced` 或不支持 projection pushdown 时不做该裁剪。
2. `proj_sel` 记录上游引用；把下推单列过滤还原成逻辑表达式后访问其列，多列统计 filter 的映射列也显式加入引用集合。
3. `CheckPushdownExtract` 判断扫描是否支持字段提取；根据依赖重建 `ColumnIndex`，必要时把一个顶层列拆成多个直接提取输出。
4. 设置新列列表，并用旧位置→新位置映射重写单列 filter key 和多列 `column_indexes`。
5. `filter_prune` 开启时，匹配投影引用和扫描引用，生成 `projection_ids`。
6. 字段提取改变过滤表达式时，暂时重建 LogicalFilter 再尝试 pushdown；若仍残留上层 filter，清输出映射以保留过滤所需列。

没有实际数据列被引用时，`GetAnyColumn` 提供保持基数所需的扫描请求，不能简单输出零列零行。虚拟列也参与这一机制。

## 五、物理规划回退

[plan_get.cpp](../src/execution/physical_plan/plan_get.cpp) 的 `PhysicalPlanGenerator::CreatePlan(LogicalGet)`：

- 普通 scan 携带 `BoundTableFunction`、列路径和 table filters；单列和多列过滤均通过 `MoveTableFilters` 搬入物理计划。
- `supports_pushdown_type` 可把不支持的类型过滤还原成上层 `PhysicalFilter`，把需要的过滤列补回输出。
- 不支持 projection pushdown 时，扫描输出全部 returned types，再视请求顺序/子集补一个 `PhysicalProjection`；若本来就是全部列且顺序相同，不需要额外 projection。
- 此非下推路径不能通用提供虚拟列，请求虚拟列会报 `Virtual columns require projection pushdown`。
- 带输入 child 的 table-in-out 有自己的 `PhysicalTableInOutFunction` 路径，不等同于无输入的普通 scan。

不能从 `LogicalGet::column_ids` 的初始列表直接推断实际磁盘 I/O；最终输出和具体 reader 实现仍需继续跟踪。

## 六、执行与本地状态

[physical_table_scan.cpp](../src/execution/operator/scan/physical_table_scan.cpp) 在 global/local state 初始化中传递同一组列路径和映射，并合并 runtime filter。具体 `function` 回调得到 bind/global/local state，映射由数据源初始化时保存。

`all_columns` 这种可变中间 chunk 应放在每个 local scan state，不能照搬旧示例放在共享 global state 中让多个 worker 同时写。共享 global state 可保存 immutable 映射和列类型，线程调度另行同步。

当前 scan 支持异步和 read-ahead，`function` 被调用一次不保证已同步产生结果；列与过滤映射的正确性不依赖回调次数。异步 API 细节由执行框架文档负责，此处不提供未经核对的简化调度实现。

## 七、当前内置实现

### duckdb_views：输出位置与实际列号分离

[duckdb_views.cpp](../src/function/table/system/duckdb_views.cpp) 的 `DuckDBViewsInit` 保存 `input.column_indexes`，`DuckDBViewsFunction` 按请求位置 c 遍历，再按 `GetPrimaryIndex()` 的原始系统列号填充 `output[c]`；注册开启 projection pushdown。这是无子字段系统表的简单案例，不表示所有扫描只能使用数字列号。

### 内置表扫描：filter_prune 与选择性读取分开

[table_scan.cpp](../src/function/table/table_scan.cpp) 的 `DuckTableScanInitGlobal`：

- 将 `input.column_indexes` 交给 `InitializeParallelScan`。
- `CanRemoveFilterColumns()` 成立时保存 `projection_ids`，按 rowid/row_number、带类型的 extract 或普通列计算 `scanned_types`。
- 每个 local state 初始化自己的 `all_columns`。
- `ScanIntoOutput` 等调用先在需要时扫描到 all_columns，再用 `output.ReferenceColumns(all_columns, projection_ids)` 输出子集。

这是输出列裁剪；扫描内部 `Select` 是否只解码选中行，另由 codec/select 回调及 updates 决定，见 [FILTER_EXECUTION_DESIGN.md](./FILTER_EXECUTION_DESIGN.md)。

### Arrow 与多文件

[arrow.cpp](../src/function/table/arrow.cpp) 的普通 Arrow scan 注册 projection/filter/filter_prune，另有 `arrow_dumb` 明确关闭相关能力，说明不能把这些能力归为 Arrow 数据本身必然支持的通用属性。

当前多文件包装见 [table_function_multi_file.cpp](../src/common/multi_file/table_function_multi_file.cpp)：由单文件函数能力组成绑定后的多文件扫描。Parquet 的单文件入口 [read_single_parquet_file.cpp](../extension/parquet/read_single_parquet_file.cpp) 与多文件信息 [parquet_multi_file_info.cpp](../extension/parquet/parquet_multi_file_info.cpp) 共同定义行为。不能沿用旧 `MultiFileFunction<OP>` 构造片段来证明当前默认行为，也不能把 CSV 与 Parquet 的过滤/延迟物化能力相互套用。

## 八、扩展实现骨架

以下仅为按当前字段校正的伪代码，省略函数注册、类型绑定、异常与异步处理，未编译：

```text
global_init(input):
  保存 ColumnIndex 请求列表
  保存 projection_ids 和扫描列类型
local_init(global):
  初始化本线程 all_columns 与过滤执行状态
scan(local):
  按扫描列表读取；执行所有已完全接受的精确过滤
  if CanRemoveFilterColumns:
    output.ReferenceColumns(local.all_columns, projection_ids)
  else:
    按 scan 请求顺序直接输出
```

不要以“扫描时忽略 input.filters，框架随后会补过滤”为兜底。完全下推的谓词可能已从上层计划删除，遗漏执行会给出错误结果。

C API 的投影能力入口见 [table_function-c.cpp](../src/main/capi/v1/table_function-c.cpp)：`duckdb_table_function_supports_projection_pushdown`、`duckdb_init_get_column_count`、`duckdb_init_get_column_index`。这里只定位入口，没有验证 C API 对所有嵌套字段能力的映射。

## 九、虚拟列与审查边界

`COLUMN_IDENTIFIER_ROW_ID` 是保留的虚拟列标识，不能作为普通数组下标，也不能在请求后直接跳过填充；需要按数据源约定输出有效值或明确不支持该能力。行 ID 的稳定性和两次扫描身份一致性影响 [LateMaterialization](./LATE_MATERIALIZATION_DESIGN.md) 正确性，多文件可能需要复合 ID。

本文静态核对了字段、优化器重映射、物理回退、内置/Arrow/多文件入口。未运行扩展示例、SQL 或所有 reader，未由 capability 标志推断实际性能。
