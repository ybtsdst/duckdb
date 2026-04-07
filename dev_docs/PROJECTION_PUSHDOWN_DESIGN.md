# DuckDB Table Function Projection Pushdown 设计文档

## 一、什么是 Projection Pushdown

**Projection Pushdown（列裁剪下推）** 指优化器将"上层只需要某几列"的信息传递给底层扫描器，使扫描器在读取数据时**只读取实际需要的列**，跳过不需要的列，减少 I/O 和内存开销。

---

## 二、整体流程（从 SQL 到执行）

```
SQL: SELECT a, b FROM my_table_func(...)
           ↓ Bind 阶段
   LogicalGet（包含完整列列表 column_ids = [0,1,2,3...]）
           ↓ 优化器：RemoveUnusedColumns
   LogicalGet（column_ids 被裁剪为 [0,1]，仅包含 a, b）
           ↓ PhysicalPlanGenerator::CreatePlan(LogicalGet)
   PhysicalTableScan（携带裁剪后的 column_ids 和 projection_ids）
           ↓ 执行：GetGlobalSourceState / GetLocalSourceState
   TableFunctionInitInput（column_ids=[0,1] 传给 init_global/init_local）
           ↓ 扫描函数
   只读 a, b 两列 → DataChunk
```

---

## 三、关键数据结构

### 3.1 `TableFunctionInitInput`

**源文件：** `src/include/duckdb/function/table_function.hpp`

```cpp
struct TableFunctionInitInput {
    optional_ptr<const FunctionData> bind_data;  // 绑定数据（来自 bind 阶段）
    vector<column_t>    column_ids;              // 需要读取的列的逻辑索引（原始兼容接口）
    vector<ColumnIndex> column_indexes;          // 同上，更新版，支持 struct 子字段下推
    const vector<idx_t> projection_ids;          // 输出列在 column_ids 中的下标（仅在 filter_prune 时非空）
    optional_ptr<TableFilterSet> filters;        // 下推的过滤条件（filter_pushdown=true 时有效）
    ...
    bool CanRemoveFilterColumns() const;         // 是否可以移除纯过滤列（filter_prune 时有用）
};
```

**`column_ids` 语义：**
- 当 `projection_pushdown = false`（默认）：`column_ids` 包含所有列，扫描器必须输出全部列，DuckDB 在上层加 Projection 算子做列裁剪。
- 当 `projection_pushdown = true`：`column_ids` 只包含上层实际需要的列，扫描器**只读取并输出这些列**。

**`projection_ids` 语义（仅在 `filter_prune = true` 时使用）：**
- 有些列只用于过滤（WHERE 条件），不需要出现在最终输出中。
- `column_ids` 包含"需要扫描的列"（包括纯过滤列）。
- `projection_ids` 是 `column_ids` 的一个子集下标，指向"最终要输出的列"。
- 扫描函数应先把所有 `column_ids` 对应的列填充到 `all_columns` 缓冲区，再调用 `output.ReferenceColumns(all_columns, projection_ids)` 只输出需要的列。

---

## 四、启用 Projection Pushdown 的标志位

在注册 `TableFunction` 时设置以下字段：

| 标志位 | 作用 | 默认 |
|--------|------|------|
| `projection_pushdown` | 开启列裁剪下推，`column_ids` 只含实际需要的列 | `false` |
| `filter_pushdown` | 开启过滤下推，`filters` 中含下推的过滤条件 | `false` |
| `filter_prune` | 开启纯过滤列的裁剪，结合 `projection_ids` 使用 | `false` |

> ⚠️ **仅在实现正确支持对应语义时才设置这些标志**，否则会产生错误结果或不必要的 I/O。

---

## 五、优化器如何裁剪列：`RemoveUnusedColumns`

**源文件：** `src/optimizer/remove_unused_columns.cpp`

核心函数 `RemoveColumnsFromLogicalGet(LogicalGet &get)` 的逻辑如下：

1. 若 `get.function.projection_pushdown == false`，直接返回，不做裁剪。
2. 遍历上层所有表达式，统计哪些列被引用（`column_references`）。
3. 分别计算：
   - `proj_sel`：被投影表达式（SELECT 列表）引用的列集合。
   - `col_sel`：被投影或过滤表达式引用的列集合（`proj_sel` 的超集）。
4. 用 `col_sel` 重写 `LogicalGet::column_ids`，去除完全未引用的列。
5. 若 `get.function.filter_prune == true`，计算 `projection_ids`：找出 `col_sel` 中属于 `proj_sel` 的下标并写入 `get.projection_ids`。

---

## 六、物理计划层：`PhysicalPlanGenerator::CreatePlan(LogicalGet)`

**源文件：** `src/execution/physical_plan/plan_get.cpp`

```cpp
if (!op.function.projection_pushdown) {
    // 未开启：创建扫描节点（输出全部列），再在上层加 Projection 算子做列选择
    auto &table_scan = Make<PhysicalTableScan>(
        op.returned_types, ..., column_ids, /*projection_ids=*/{}, ...);
    auto &proj = Make<PhysicalProjection>(...);
    proj.children.push_back(table_scan);
    return proj;
}

// 已开启：创建扫描节点，直接只输出需要的列
auto &table_scan = Make<PhysicalTableScan>(
    op.types, ..., column_ids, op.projection_ids, ...);
return table_scan;
```

---

## 七、执行层：`init_global` / `init_local` / `function`

**源文件：** `src/execution/operator/scan/physical_table_scan.cpp`

在 `PhysicalTableScan` 执行时，`column_ids` 和 `projection_ids` 被打包进 `TableFunctionInitInput` 传给扫描函数：

```cpp
// GetGlobalSourceState（单线程，在 Pipeline 就绪时调用一次）
TableFunctionInitInput input(op.bind_data.get(), op.column_ids, op.projection_ids, filters, ...);
global_state = op.function.init_global(context, input);

// GetLocalSourceState（每个工作线程调用一次）
TableFunctionInitInput input(op.bind_data.get(), op.column_ids, op.projection_ids, filters, ...);
local_state = op.function.init_local(context, input, global_state.get());
```

---

## 八、内置实现示例分析

### 8.1 `duckdb_views`（最简单的系统函数）

**源文件：** `src/function/table/system/duckdb_views.cpp`

```cpp
// 注册时开启
duckdb_views.projection_pushdown = true;

// init_global：把 column_indexes 保存到状态中
unique_ptr<GlobalTableFunctionState> DuckDBViewsInit(ClientContext &, TableFunctionInitInput &input) {
    auto result = make_uniq<DuckDBViewsData>();
    result->column_ids = input.column_indexes;  // 只保存实际需要的列
    return result;
}

// 扫描函数：只遍历 column_ids，只填充需要的列
void DuckDBViewsFunction(ClientContext &, TableFunctionInput &data_p, DataChunk &output) {
    auto &data = data_p.global_state->Cast<DuckDBViewsData>();
    for (idx_t c = 0; c < data.column_ids.size(); c++) {
        auto column_id = data.column_ids[c].GetPrimaryIndex(); // 实际列序号
        switch (column_id) {
        case 0: output.SetValue(c, count, ...); break; // database_name
        case 1: output.SetValue(c, count, ...); break; // database_oid
        // ...
        }
    }
    output.SetCardinality(count);
}
```

**关键模式**：`output` 的第 `c` 列对应 `column_ids[c]` 指向的实际列。输出位置（`c`）和实际列序号（`column_id`）解耦。

### 8.2 Arrow 扫描（带 `filter_prune` 的完整模式）

**源文件：** `src/function/table/arrow.cpp`

```cpp
arrow.projection_pushdown = true;
arrow.filter_prune = true;

// init_global：处理 filter_prune 情况
unique_ptr<GlobalTableFunctionState> ArrowScanInitGlobal(ClientContext &, TableFunctionInitInput &input) {
    auto result = make_uniq<ArrowScanGlobalState>();
    // 向 Arrow stream 传递投影列（真正的 I/O 优化）
    result->stream = ProduceArrowScan(bind_data, input.column_ids, input.filters.get());

    if (!input.projection_ids.empty()) {
        // filter_prune：保存 projection_ids 和扫描列类型（含过滤列）
        result->projection_ids = input.projection_ids;
        for (const auto &col_idx : input.column_ids) {
            result->scanned_types.push_back(bind_data.all_types[col_idx]);
        }
    }
    return result;
}

// 扫描函数：根据是否有 filter_prune 决定输出方式
void ArrowScanFunction(ClientContext &, TableFunctionInput &data_p, DataChunk &output) {
    auto &global_state = data_p.global_state->Cast<ArrowScanGlobalState>();

    if (global_state.CanRemoveFilterColumns()) {
        // 先填充含过滤列的 all_columns，再裁剪输出
        state.all_columns.Reset();
        ArrowToDuckDB(state, ..., state.all_columns);
        output.ReferenceColumns(state.all_columns, global_state.projection_ids);
    } else {
        // 直接填充 output
        ArrowToDuckDB(state, ..., output);
    }
}
```

### 8.3 DuckDB 内置表扫描（`table_scan`）

**源文件：** `src/function/table/table_scan.cpp`

```cpp
scan_function.projection_pushdown = true;
scan_function.filter_prune = true;

// init_global：处理 filter_prune 情况
if (input.CanRemoveFilterColumns()) {
    g_state->projection_ids = input.projection_ids;
    for (const auto &col_idx : input.column_indexes) {
        g_state->scanned_types.push_back(columns.GetColumn(col_idx.ToLogical()).Type());
    }
}

// 扫描函数
if (CanRemoveFilterColumns()) {
    l_state.all_columns.Reset();
    storage.Scan(tx, l_state.all_columns, l_state.scan_state); // 扫描含过滤列
    output.ReferenceColumns(l_state.all_columns, projection_ids); // 裁剪输出
} else {
    storage.Scan(tx, output, l_state.scan_state); // 直接输出
}
```

### 8.4 MultiFileFunction（Parquet / CSV 等多文件扫描的基类）

**源文件：** `src/include/duckdb/common/multi_file/multi_file_function.hpp`

```cpp
template <class OP>
class MultiFileFunction : public TableFunction {
    explicit MultiFileFunction(string name_p) : ... {
        projection_pushdown = true;  // 默认开启
        // Parquet 扩展额外设置 filter_prune = true
        // filter_pushdown = true（由各自 pushdown_complex_filter 回调实现）
    }
};
```

---

## 九、在自己的 Extension 中支持 Projection Pushdown

### 9.1 最小实现（仅 projection_pushdown）

**步骤 1：注册时开启标志**

```cpp
TableFunction my_func("my_scan", {LogicalType::VARCHAR}, MyScan, MyBind, MyInitGlobal, MyInitLocal);
my_func.projection_pushdown = true;  // ← 关键
```

**步骤 2：`init_global`（或 `init_local`）中保存 `column_ids`**

```cpp
struct MyGlobalState : public GlobalTableFunctionState {
    vector<column_t> column_ids; // 保存实际需要的列
};

unique_ptr<GlobalTableFunctionState> MyInitGlobal(ClientContext &, TableFunctionInitInput &input) {
    auto state = make_uniq<MyGlobalState>();
    state->column_ids = input.column_ids; // 只包含上层需要的列
    return state;
}
```

**步骤 3：扫描函数中根据 `column_ids` 只输出请求的列**

```cpp
void MyScan(ClientContext &context, TableFunctionInput &data_p, DataChunk &output) {
    auto &state = data_p.global_state->Cast<MyGlobalState>();

    // output 的列数 = column_ids.size()
    // output[i] 对应 column_ids[i] 所指向的实际列数据
    for (idx_t i = 0; i < state.column_ids.size(); i++) {
        auto col_id = state.column_ids[i]; // 实际列序号（对应 bind 时的列顺序）

        if (col_id == COLUMN_IDENTIFIER_ROW_ID) {
            // 特殊：rowid 伪列请求，填充行号或跳过
            continue;
        }

        switch (col_id) {
        case 0: FillColumn0(output.data[i], ...); break;
        case 1: FillColumn1(output.data[i], ...); break;
        // ...
        }
    }
    output.SetCardinality(row_count);
}
```

### 9.2 进阶实现（projection_pushdown + filter_prune）

当扫描函数需要读取某些列做过滤但不输出时（例如 `WHERE col3 = 1 SELECT col1, col2`），启用 `filter_prune`：

```cpp
my_func.projection_pushdown = true;
my_func.filter_prune        = true;
my_func.filter_pushdown     = true; // 通常同时开启，否则过滤仍由上层算子执行
```

```cpp
struct MyGlobalState : public GlobalTableFunctionState {
    vector<column_t>    column_ids;      // 所有需要扫描的列（含纯过滤列）
    vector<idx_t>       projection_ids;  // column_ids 中要输出的列的下标
    vector<LogicalType> scanned_types;   // 所有扫描列的类型（用于初始化 all_columns）
    DataChunk           all_columns;     // 扫描所有列（含过滤列）的中间缓冲
};

unique_ptr<GlobalTableFunctionState> MyInitGlobal(ClientContext &ctx, TableFunctionInitInput &input) {
    auto state = make_uniq<MyGlobalState>();
    state->column_ids = input.column_ids;

    if (input.CanRemoveFilterColumns()) { // 存在纯过滤列
        state->projection_ids = input.projection_ids;
        for (auto col_id : input.column_ids) {
            state->scanned_types.push_back(my_schema_types[col_id]);
        }
        state->all_columns.Initialize(ctx, state->scanned_types);
    }
    return state;
}

void MyScan(ClientContext &, TableFunctionInput &data_p, DataChunk &output) {
    auto &state = data_p.global_state->Cast<MyGlobalState>();

    if (!state.projection_ids.empty()) {
        // filter_prune 模式：先扫描所有列（含过滤列），再裁剪输出
        state.all_columns.Reset();
        ScanColumns(state.all_columns, state.column_ids); // 填充全部扫描列
        output.ReferenceColumns(state.all_columns, state.projection_ids); // 只输出需要的列
    } else {
        // 普通 projection_pushdown：直接输出
        ScanColumns(output, state.column_ids);
    }
}
```

### 9.3 使用 C API（扩展不编写 C++ 时）

```c
// 注册时启用 projection_pushdown
duckdb_table_function_supports_projection_pushdown(func, true);

// init 函数中获取需要扫描的列
idx_t col_count = duckdb_init_get_column_count(info);
for (idx_t i = 0; i < col_count; i++) {
    idx_t col_id = duckdb_init_get_column_index(info, i);
    // col_id == DUCKDB_ROW_ID 表示 rowid 伪列
    // 否则是 bind 阶段返回的列序号
}
```

---

## 十、`COLUMN_IDENTIFIER_ROW_ID` 的处理

`column_ids` 中可能出现特殊值 `COLUMN_IDENTIFIER_ROW_ID`（即 `UINT64_MAX`），表示上层需要行 ID（`rowid` 伪列）。扫描函数需特殊处理，**不能将其直接用作数组下标**：

```cpp
for (idx_t i = 0; i < state.column_ids.size(); i++) {
    if (state.column_ids[i] == COLUMN_IDENTIFIER_ROW_ID) {
        // 填充行号（通常是连续递增的行偏移量）
        FillRowId(output.data[i], ...);
    } else {
        // 正常列，按 column_id 取数据
        FillColumn(output.data[i], state.column_ids[i], ...);
    }
}
```

---

## 十一、实现检查清单

| # | 检查项 | 说明 |
|---|--------|------|
| ✅ 1 | `my_func.projection_pushdown = true` | 注册时开启标志位 |
| ✅ 2 | `init_global` 或 `init_local` 中读取并保存 `input.column_ids` | 记录实际需要哪些列 |
| ✅ 3 | 扫描函数中 `output[i]` 填充 `column_ids[i]` 对应的数据 | 输出位置与实际列索引分离 |
| ✅ 4 | 处理 `COLUMN_IDENTIFIER_ROW_ID` 特殊值 | 不能直接作为数组下标 |
| ✅ 5 | `output` 的列数必须等于 `column_ids.size()` | 大小必须严格匹配 |
| ⚠️ 6 | 若启用 `filter_prune`，需维护 `all_columns` 中间缓冲 | 用 `output.ReferenceColumns(all_columns, projection_ids)` 裁剪 |
| ⚠️ 7 | 若同时启用 `filter_pushdown`，需在扫描时应用 `input.filters` | 否则过滤下推无效，上层仍会加额外过滤算子 |

---

## 十二、相关源码速查

| 概念 | 源文件 |
|------|--------|
| 标志位定义及 `TableFunctionInitInput` | `src/include/duckdb/function/table_function.hpp` |
| 优化器列裁剪（`RemoveColumnsFromLogicalGet`） | `src/optimizer/remove_unused_columns.cpp` |
| 物理计划生成（`CreatePlan(LogicalGet)`） | `src/execution/physical_plan/plan_get.cpp` |
| 执行层 `column_ids` 传递 | `src/execution/operator/scan/physical_table_scan.cpp` |
| 最简内置示例（`duckdb_views`） | `src/function/table/system/duckdb_views.cpp` |
| `filter_prune` 完整示例（Arrow 扫描） | `src/function/table/arrow.cpp` |
| `filter_prune` 完整示例（内置表扫描） | `src/function/table/table_scan.cpp` |
| MultiFile 扫描基类（Parquet/CSV） | `src/include/duckdb/common/multi_file/multi_file_function.hpp` |
| C API 接口 | `src/main/capi/table_function-c.cpp` |
