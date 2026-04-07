# DuckDB 延迟物化（Late Materialization）设计与实现文档

## 概述

**延迟物化（Late Materialization）** 是一种查询执行优化技术：在含有 LIMIT/ORDER BY/SAMPLE 的查询中，不在排序或过滤阶段读取所有列，而是先只读取过滤条件或排序键所涉及的少量列以及行 ID，执行完 TopN/Limit/Sample 之后，再通过行 ID 回表取回最终需要的完整列值。

**核心收益：** 对宽表的 `SELECT * FROM tbl ORDER BY ts LIMIT 5` 类查询，只需对 `ts` 列排序后取前 5 个行 ID，再按行 ID 精确读取这 5 行的所有列，避免对全表所有列做大规模中间物化，显著减少 I/O 和内存压力。

本文档涵盖：
1. 存储引擎对延迟物化的基础支持（行 ID 虚拟列）
2. 优化器对延迟物化的计划变换
3. 执行器层面的物理执行
4. Extension（扩展）如何实现延迟物化支持

---

## 一、源码文件总览

### 存储引擎层

| 文件 | 核心类/函数 | 职责说明 |
|------|------------|---------|
| `src/storage/table/row_id_column_data.cpp` | `RowIdColumnData` | 行 ID 虚拟列的存储实现，继承 `ColumnData` |
| `src/include/duckdb/storage/table/row_id_column_data.hpp` | `RowIdColumnData` | 行 ID 虚拟列头文件 |
| `src/include/duckdb/common/constants.hpp` | `COLUMN_IDENTIFIER_ROW_ID` | 行 ID 虚拟列的保留列 ID 常量（`UINT64_MAX`） |

### 扫描函数层

| 文件 | 核心类/函数 | 职责说明 |
|------|------------|---------|
| `src/function/table/table_scan.cpp` | `TableScanGetRowIdColumns` | DuckDB 内置表扫描的行 ID 列提供回调 |
| `src/function/table/read_duckdb.cpp` | `DuckDBGetRowIdColumns` | `read_duckdb` 函数的行 ID 列提供回调 |
| `extension/parquet/parquet_multi_file_info.cpp` | `ParquetGetRowIdColumns` | Parquet 扫描的行 ID 列提供回调 |
| `src/include/duckdb/function/table_function.hpp` | `TableFunction` | 表函数元数据结构，含 `late_materialization` 标志和 `get_row_id_columns` 回调 |

### 优化器层

| 文件 | 核心类 | 职责说明 |
|------|--------|---------|
| `src/optimizer/late_materialization.cpp` | `LateMaterialization` | 延迟物化主优化 Pass，将 TopN/Limit/Sample 计划改写为半连接形式 |
| `src/optimizer/late_materialization_helper.cpp` | `LateMaterializationHelper` | 辅助工具：构建 LHS 扫描节点、插入行 ID 列 |
| `src/include/duckdb/optimizer/late_materialization.hpp` | `LateMaterialization` | 优化器头文件 |
| `src/include/duckdb/optimizer/late_materialization_helper.hpp` | `LateMaterializationHelper` | 辅助工具头文件 |
| `src/optimizer/optimizer.cpp` | `Optimizer::Optimize` | 优化器主流程，负责调用 `LateMaterialization::Optimize()` |

### 配置层

| 文件 | 设置项 | 说明 |
|------|--------|------|
| `src/include/duckdb/main/settings.hpp` | `LateMaterializationMaxRowsSetting` | 控制触发延迟物化的最大行数阈值，默认 50 |
| `src/main/config.cpp` | `DUCKDB_SETTING(LateMaterializationMaxRowsSetting)` | 注册配置项 |

### 测试文件

| 文件 | 覆盖场景 |
|------|---------|
| `test/sql/copy/parquet/parquet_late_materialization.test` | Parquet 文件的延迟物化端到端测试 |
| `test/fuzzer/duckfuzz/late_materialization_filter.test` | 带过滤条件的延迟物化模糊测试 |
| `test/sql/topn/top_n_materialization.test` | TopN 延迟物化场景测试 |
| `test/optimizer/issue_21011.test` | TopN Window 消除与延迟物化的交互测试 |

---

## 二、存储引擎对延迟物化的支持

### 2.1 行 ID 虚拟列（RowIdColumnData）

**行 ID** 是 DuckDB 存储引擎为每一行隐式维护的物理位置标识符，类型为 `BIGINT`（`row_t`），可通过虚拟列 `COLUMN_IDENTIFIER_ROW_ID`（`= UINT64_MAX`）请求。

```cpp
// src/include/duckdb/common/constants.hpp
DUCKDB_API extern const column_t COLUMN_IDENTIFIER_ROW_ID;  // == UINT64_MAX
extern const row_t MAX_ROW_ID;        // 事务已提交行 ID 上界
extern const row_t MAX_ROW_ID_LOCAL;  // 事务本地行 ID 起始
```

`RowIdColumnData` 继承 `ColumnData`，不存储实际数据，而是在扫描时按 RowGroup 起始偏移量动态生成行 ID 序列：

```cpp
// src/storage/table/row_id_column_data.cpp
idx_t RowIdColumnData::ScanCount(ColumnScanState &state, Vector &result,
                                  idx_t count, idx_t result_offset) {
    auto row_start = state.parent->row_group->GetRowStart();
    // 以 row_start + offset 为起点生成连续序列
    ScanCommittedRange(row_start, state.offset_in_column, count, result);
    state.offset_in_column += count;
    return count;
}

void RowIdColumnData::ScanCommittedRange(idx_t row_group_start,
                                          idx_t offset_in_row_group,
                                          idx_t count, Vector &result) {
    result.Sequence(
        UnsafeNumericCast<int64_t>(row_group_start + offset_in_row_group),
        1, count);
}
```

`Filter()` 方法在行 ID 列上应用谓词时会先进行 ZoneMap 剪枝，避免不必要的全量扫描：

```cpp
void RowIdColumnData::Filter(TransactionData transaction, ...) {
    const auto rowid_start = current_row;
    const auto rowid_end   = current_row + max_count;
    // CheckRowIdFilter 对整个 RowGroup 做区间判断
    const auto prune_result = RowGroup::CheckRowIdFilter(filter, rowid_start, rowid_end);
    if (prune_result == FilterPropagateResult::FILTER_ALWAYS_FALSE) {
        count = 0;  // 整个 vector 被剪掉
        return;
    }
    // 生成实际行 ID 数据
    for (size_t sel_idx = 0; sel_idx < count; sel_idx++) {
        result_data[sel.get_index(sel_idx)] =
            UnsafeNumericCast<int64_t>(current_row + sel.get_index(sel_idx));
    }
}
```

### 2.2 内置表扫描（table_scan）的注册

`table_scan` 在初始化时将自身标记为支持延迟物化，并注册 `get_row_id_columns` 回调：

```cpp
// src/function/table/table_scan.cpp
static vector<column_t> TableScanGetRowIdColumns(
    ClientContext &context, optional_ptr<FunctionData> bind_data) {
    vector<column_t> result;
    result.emplace_back(COLUMN_IDENTIFIER_ROW_ID);  // 只有一个行 ID 列
    return result;
}

// 函数注册阶段
scan_function.late_materialization = true;          // 声明支持延迟物化
scan_function.filter_pushdown      = true;
scan_function.filter_prune         = true;
scan_function.projection_pushdown  = true;
scan_function.get_row_id_columns   = TableScanGetRowIdColumns;
```

### 2.3 TableFunction 元数据结构

`TableFunction` 结构体（`src/include/duckdb/function/table_function.hpp`）中与延迟物化相关的字段：

```cpp
struct TableFunction {
    // ...

    //! （可选）返回构成"行 ID"的列 ID 列表
    //! 返回的 column_t 必须是虚拟列 ID（如 COLUMN_IDENTIFIER_ROW_ID）
    table_function_get_row_id_columns get_row_id_columns;  // 默认 nullptr

    //! 为 true 时声明该函数支持延迟物化优化
    //! 优化器只在此标志为 true 时才会尝试对该扫描做计划改写
    bool late_materialization;  // 默认 false

    //! 支持谓词下推
    bool filter_pushdown;

    //! 支持把仅用于过滤的列从输出中移除
    bool filter_prune;

    //! 支持投影下推（只扫描需要的列）
    bool projection_pushdown;
};
```

其中 `table_function_get_row_id_columns` 的类型定义为：

```cpp
typedef vector<column_t> (*table_function_get_row_id_columns)(
    ClientContext &context,
    optional_ptr<FunctionData> bind_data);
```

---

## 三、优化器对延迟物化的设计

### 3.1 优化 Pass 的触发时机

`LateMaterialization` 优化 Pass 在 `Optimizer::Optimize()` 中作为独立步骤调用（`src/optimizer/optimizer.cpp`，第 283 行）：

```cpp
LateMaterialization late_materialization(*this);
plan = late_materialization.Optimize(std::move(plan));
```

该 Pass 在其他主要优化（谓词下推、列裁剪等）完成之后执行，递归地遍历整个逻辑计划，寻找可以应用延迟物化的节点。

### 3.2 触发条件

`Optimize()` 方法针对三类算子做延迟物化改写：

| 算子 | 触发条件 |
|------|---------|
| `LogicalTopN` | `limit <= late_materialization_max_rows`（默认 50） |
| `LogicalLimit` | 小 Limit（有 offset）或满足特定条件的大 Limit（无过滤、仅投影/Get 路径） |
| `LogicalSample` | 非百分比采样 且 `sample_size <= late_materialization_max_rows` |

```cpp
// src/optimizer/late_materialization.cpp
case LogicalOperatorType::LOGICAL_TOP_N: {
    auto &top_n = op->Cast<LogicalTopN>();
    if (top_n.limit > max_row_count) { break; }
    if (TryLateMaterialization(op)) { return op; }
    break;
}
```

`max_row_count` 来自 `LateMaterializationMaxRowsSetting`（默认值 `50`），可通过 SQL 动态调整：

```sql
SET late_materialization_max_rows = 100;
```

### 3.3 收益评估（TryLateMaterialization 分析阶段）

进入 `TryLateMaterialization()` 后，首先遍历 TopN/Limit/Sample 以下的算子栈，统计"实际需要的列数"。支持穿透的算子仅限：

- `LogicalProjection`：记录被上层引用的投影列，并向下追踪其依赖
- `LogicalFilter`：记录过滤谓词所需列
- 任何其他算子类型：**直接放弃优化**，返回 `false`

```cpp
// 分析：追踪被引用的列
VisitOperatorExpressions(*op);  // 访问 TopN/Limit 自身的列引用（如排序键）
reference<LogicalOperator> child = *op->children[0];
while (child.get().type != LogicalOperatorType::LOGICAL_GET) {
    switch (child.get().type) {
    case LogicalOperatorType::LOGICAL_PROJECTION: { /* 只访问被引用的投影列 */ }
    case LogicalOperatorType::LOGICAL_FILTER:     { /* 访问过滤谓词列 */ }
    default: return false;  // 不支持其他算子
    }
}
auto &get = child.get().Cast<LogicalGet>();
// 收益检查：引用列数 < 总列数 才值得优化
if (column_references.size() >= get.GetColumnIds().size()) {
    return false;
}
// 检查扫描函数是否支持延迟物化
if (!get.function.late_materialization) { return false; }
```

**不触发延迟物化的场景：**
- 需要的列数等于或超过总列数（没有收益）
- 扫描函数未设置 `late_materialization = true`
- 算子链中含有不支持的算子（Join、Aggregate 等）
- TopN 的 `limit` 超过 `max_row_count`

### 3.4 计划改写：从线性计划到半连接计划

当确定可以优化时，`TryLateMaterialization()` 将原始线性计划改写为**半连接（SEMI JOIN）计划**：

**改写前（原始计划）：**

```
LogicalTopN (ORDER BY ts LIMIT 5)
  └── LogicalFilter (...)
        └── LogicalProjection
              └── LogicalGet (扫描全部列: id, ts, col1, col2, ...)
```

**改写后（延迟物化计划）：**

```
LogicalOrder (ORDER BY ts)
  └── LogicalProjection (最终输出列)
        └── LogicalComparisonJoin (SEMI, ON lhs.rowid = rhs.rowid)
              ├── LHS: LogicalGet (只扫描 ts + rowid)   ← 小表
              │         TopN 或 Limit 过滤 → 得到少量 rowid
              └── RHS: LogicalTopN/Limit
                          └── LogicalFilter
                                └── LogicalProjection
                                      └── LogicalGet (扫描全部列)
```

#### 3.4.1 LHS 构建（CreateLHSGet）

LHS 是原始 `LogicalGet` 的一个**克隆副本**，使用新的 `table_index`，然后向列列表中插入行 ID 列：

```cpp
// src/optimizer/late_materialization_helper.cpp
unique_ptr<LogicalGet> LateMaterializationHelper::CreateLHSGet(
    const LogicalGet &rhs, Binder &binder) {
    auto table_index = binder.GenerateTableIndex();
    auto new_get = make_uniq<LogicalGet>(
        table_index, rhs.function, rhs.bind_data->Copy(),
        rhs.returned_types, rhs.names, rhs.virtual_columns);
    new_get->GetMutableColumnIds() = rhs.GetColumnIds();
    new_get->projection_ids        = rhs.projection_ids;
    // ... 拷贝其他参数 ...
    return new_get;
}

// 插入行 ID 列（如不存在则追加）
vector<idx_t> LateMaterializationHelper::GetOrInsertRowIds(
    LogicalGet &get,
    const vector<column_t> &row_id_column_ids,
    const vector<TableColumn> &row_id_columns) {
    auto &column_ids = get.GetMutableColumnIds();
    vector<idx_t> result;
    for (idx_t r_idx = 0; r_idx < row_id_column_ids.size(); ++r_idx) {
        // 检查是否已在投影列中
        optional_idx row_id_index;
        for (idx_t i = 0; i < column_ids.size(); ++i) {
            if (column_ids[i].GetPrimaryIndex() == row_id_column_ids[r_idx]) {
                row_id_index = i; break;
            }
        }
        if (row_id_index.IsValid()) {
            result.push_back(row_id_index.GetIndex());
            continue;
        }
        // 追加行 ID 列
        column_ids.push_back(ColumnIndex(row_id_column_ids[r_idx]));
        if (!get.projection_ids.empty()) {
            get.projection_ids.push_back(column_ids.size() - 1);
        }
        result.push_back(column_ids.size() - 1);
    }
    return result;
}
```

#### 3.4.2 RHS 构建（ConstructRHS）

RHS 保留原始的算子链（TopN/Limit → Filter → Projection → Get），同时在 `LogicalGet` 中追加行 ID 列，并将行 ID 的 `ColumnBinding` 逐层向上传播：

```cpp
// src/optimizer/late_materialization.cpp
vector<ColumnBinding> LateMaterialization::ConstructRHS(
    unique_ptr<LogicalOperator> &op) {
    // 遍历算子链，收集中间算子
    vector<reference<LogicalOperator>> stack;
    reference<LogicalOperator> child = *op->children[0];
    while (child.get().type != LogicalOperatorType::LOGICAL_GET) {
        stack.push_back(child);
        child = *child.get().children[0];
    }
    auto &get = child.get().Cast<LogicalGet>();
    // 在 Get 中插入行 ID 列
    auto row_id_indexes = LateMaterializationHelper::GetOrInsertRowIds(
        get, row_id_column_ids, row_id_columns);

    // 初始 binding 指向 get
    vector<ColumnBinding> row_id_bindings;
    for (auto &idx : row_id_indexes)
        row_id_bindings.emplace_back(get.table_index, idx);

    // 逐层向上传播 binding
    for (idx_t i = stack.size(); i > 0; i--) {
        auto &op = stack[i - 1].get();
        switch (op.type) {
        case LogicalOperatorType::LOGICAL_PROJECTION: {
            // 在投影列表末尾添加行 ID 表达式
            auto &proj = op.Cast<LogicalProjection>();
            for (idx_t r_idx = 0; r_idx < row_id_columns.size(); r_idx++) {
                proj.expressions.push_back(
                    make_uniq<BoundColumnRefExpression>(
                        row_id_columns[r_idx].name,
                        row_id_columns[r_idx].type,
                        row_id_bindings[r_idx]));
                row_id_bindings[r_idx] = ColumnBinding(
                    proj.table_index, proj.expressions.size() - 1);
            }
            break;
        }
        case LogicalOperatorType::LOGICAL_FILTER: {
            // 如果 Filter 有投影映射，需要把新的行 ID 列加入映射
            auto &filter = op.Cast<LogicalFilter>();
            if (filter.HasProjectionMap()) {
                filter.projection_map.push_back(column_count - 1);
            }
            break;
        }
        }
    }
    return row_id_bindings;
}
```

#### 3.4.3 半连接构建

```cpp
// 构建 SEMI JOIN
auto join = make_uniq<LogicalComparisonJoin>(JoinType::SEMI);
join->children.push_back(std::move(lhs));
join->children.push_back(std::move(op));  // op = RHS（原始算子链）

for (idx_t r_idx = 0; r_idx < row_id_columns.size(); r_idx++) {
    JoinCondition condition;
    condition.comparison = ExpressionType::COMPARE_EQUAL;
    condition.left  = make_uniq<BoundColumnRefExpression>(
        row_id_col.name, row_id_col.type, lhs_bindings[r_idx]);
    condition.right = make_uniq<BoundColumnRefExpression>(
        row_id_col.name, row_id_col.type, rhs_bindings[r_idx]);
    join->conditions.push_back(std::move(condition));
}
```

#### 3.4.4 最终投影与排序

对于 **TopN**（`ORDER BY ... LIMIT`）：

```
Order (ORDER BY ts)          ← 最终按排序键重排（join 后行顺序可能乱）
  └── Projection (id, ts, col1, ...)  ← 去掉行 ID，输出最终列
        └── SEMI JOIN (lhs.rowid = rhs.rowid)
```

对于 **Limit/Sample**（仅限行数，无排序要求）：

```
Projection (id, ts, col1, ...)   ← 去掉行 ID，输出最终列
  └── Order (ORDER BY rowid ASC)  ← 按行 ID 排序以恢复原始顺序
        └── SEMI JOIN (lhs.rowid = rhs.rowid)
```

### 3.5 列裁剪后处理

计划改写完成后，立即调用 `RemoveUnusedColumns` 优化器，从 RHS 的扫描中删去现在不再需要的列（即那些只在 LHS 中使用的列）：

```cpp
RemoveUnusedColumns unused_optimizer(optimizer);
unused_optimizer.VisitOperator(*op);
```

这一步是延迟物化真正减少扫描列数的关键——RHS 中的 `LogicalGet` 在此步骤后只保留输出所需列。

---

## 四、执行器对延迟物化的支持

延迟物化在逻辑优化阶段完成计划改写，执行器层面直接运行改写后的物理计划，无需额外感知"延迟物化"。执行分为两个阶段：

### 4.1 Phase 1：行 ID 收集阶段（LHS Pipeline）

LHS 侧的 `PhysicalTableScan` 只扫描排序/过滤所需的少量列以及行 ID 列。以 TopN 为例：

```
PhysicalTopN
  └── PhysicalTableScan (columns: [ts, rowid])
```

执行时，`TableScan` 利用 `projection_pushdown` 只读取 `ts` 和 `rowid` 两列，TopN 完成后得到最多 `max_row_count` 行的行 ID 集合。

### 4.2 Phase 2：完整列读取阶段（SEMI JOIN 探测）

RHS 侧是原始的完整扫描，经过 `RemoveUnusedColumns` 后仍保留所有输出列。半连接（`PhysicalHashJoin(SEMI)`）用 LHS 的行 ID 集合作为 Build 侧（小的哈希表），用 RHS 的行 ID 作为 Probe 侧：

- **Build 阶段**：将 LHS 的少量行 ID 加载到哈希表（小内存开销）
- **Probe 阶段**：RHS 扫描全表，对每一行检查其行 ID 是否在哈希表中，命中则输出

**注意：** 这种方式 RHS 仍需全表扫描以比对行 ID，因此适用于数据库本地格式（支持 `Fetch` 随机读）或较小的文件格式。对于支持随机行读取的存储引擎，未来可以进一步优化为直接按行 ID 随机读，完全跳过全表扫描。

### 4.3 DuckDB 内置表扫描的索引扫描路径

当查询触发索引扫描（如 `WHERE pk = 1`）时，`table_scan` 函数内部本身也使用类似"先收集行 ID，再按行 ID Fetch"的两阶段模式：

```cpp
// src/function/table/table_scan.cpp
// Phase 1: 索引扫描，收集行 ID
auto row_id_data = reinterpret_cast<data_ptr_t>(row_ids + offset);
Vector local_vector(LogicalType::ROW_TYPE, row_id_data);

// Phase 2: 按行 ID Fetch 各列
storage.Fetch(tx, output, column_ids, local_vector, scan_count, fetch_state);
```

这是存储引擎自身内置的"延迟物化"，与优化器的计划改写优化相互独立，但共享同一套行 ID 机制。

---

## 五、Extension 如何实现延迟物化支持

要让自定义 Extension 的表函数支持延迟物化优化，需要完成以下步骤：

### 5.1 设计行 ID 方案

首先确定扩展使用哪种行 ID 方案。常见选项：

| 方案 | 适用场景 | 示例 |
|------|---------|------|
| 单列行 ID（`COLUMN_IDENTIFIER_ROW_ID`） | 单文件/单表，行号全局唯一 | DuckDB 内置表扫描 |
| 组合行 ID（文件索引 + 文件内行号） | 多文件场景，需要区分文件 | Parquet、read_duckdb |

对于多文件场景，DuckDB 提供两个保留虚拟列 ID：

```cpp
// src/include/duckdb/common/multi_file/multi_file_reader.hpp
static constexpr column_t COLUMN_IDENTIFIER_FILE_ROW_NUMBER =
    UINT64_C(9223372036854775809);  // = MAX_UINT64 - 1

static constexpr column_t COLUMN_IDENTIFIER_FILE_INDEX =
    UINT64_C(9223372036854775810);  // = MAX_UINT64 - 2
```

### 5.2 声明虚拟列

在 `get_virtual_columns` 回调中声明行 ID 相关的虚拟列及其类型：

```cpp
static virtual_column_map_t MyExtensionGetVirtualColumns(
    ClientContext &context, optional_ptr<FunctionData> bind_data) {
    virtual_column_map_t result;
    // 声明文件索引虚拟列（BIGINT 类型）
    result[MultiFileReader::COLUMN_IDENTIFIER_FILE_INDEX] =
        TableColumn("file_index", LogicalType::BIGINT);
    // 声明文件内行号虚拟列（BIGINT 类型）
    result[MultiFileReader::COLUMN_IDENTIFIER_FILE_ROW_NUMBER] =
        TableColumn("file_row_number", LogicalType::BIGINT);
    return result;
}
```

> 如果使用单列行 ID 方案，声明 `COLUMN_IDENTIFIER_ROW_ID` 并返回 `LogicalType::BIGINT`。

### 5.3 实现 get_row_id_columns 回调

该回调告诉优化器哪些虚拟列共同构成一行的唯一标识：

```cpp
static vector<column_t> MyExtensionGetRowIdColumns(
    ClientContext &context, optional_ptr<FunctionData> bind_data) {
    vector<column_t> result;
    // 多文件：文件索引 + 文件内行号 共同唯一标识一行
    result.emplace_back(MultiFileReader::COLUMN_IDENTIFIER_FILE_INDEX);
    result.emplace_back(MultiFileReader::COLUMN_IDENTIFIER_FILE_ROW_NUMBER);
    return result;
    // 单文件：只返回 COLUMN_IDENTIFIER_ROW_ID
    // result.emplace_back(COLUMN_IDENTIFIER_ROW_ID);
}
```

**重要约束：**
- 返回的列 ID 必须是 `get_virtual_columns` 中声明过的虚拟列 ID
- 返回多列时，这些列的**组合值**必须在扫描结果中全局唯一标识一行
- 列 ID 列表不可为空（`row_id_column_ids.empty()` 会触发 `InternalException`）

### 5.4 注册到 TableFunction

```cpp
TableFunction MyExtensionScanFunction("my_scan", ...);

// 必须项
MyExtensionScanFunction.late_materialization  = true;
MyExtensionScanFunction.get_row_id_columns    = MyExtensionGetRowIdColumns;
MyExtensionScanFunction.get_virtual_columns   = MyExtensionGetVirtualColumns;

// 建议同时开启（与延迟物化配合效果更好）
MyExtensionScanFunction.filter_pushdown       = true;
MyExtensionScanFunction.filter_prune          = true;
MyExtensionScanFunction.projection_pushdown   = true;
```

### 5.5 在扫描函数中处理行 ID 列请求

扫描函数执行时，`column_ids`（通过 `bind_data` 的 `projected_columns` 或 `TableScanLocalState` 中获取）中可能出现行 ID 对应的虚拟列 ID。需要正确输出对应的行 ID 值：

```cpp
void MyExtensionScan(ClientContext &context,
                     TableFunctionInput &data_p,
                     DataChunk &output) {
    auto &bind_data  = data_p.bind_data->Cast<MyExtensionBindData>();
    auto &local_state = data_p.local_state->Cast<MyExtensionLocalState>();

    idx_t out_col = 0;
    for (auto &col_id : bind_data.column_ids) {
        if (col_id == MultiFileReader::COLUMN_IDENTIFIER_FILE_INDEX) {
            // 输出当前文件的索引（整数序号）
            output.data[out_col].Reference(Value::BIGINT(local_state.file_index));
        } else if (col_id == MultiFileReader::COLUMN_IDENTIFIER_FILE_ROW_NUMBER) {
            // 输出文件内行号（Sequence 向量）
            output.data[out_col].Sequence(
                local_state.current_row_in_file, 1, output.size());
        } else {
            // 正常扫描业务列
            ScanColumn(local_state, col_id, output.data[out_col], output.size());
        }
        out_col++;
    }
}
```

### 5.6 完整示例参考

| Extension | 源文件 | 行 ID 方案 |
|-----------|--------|-----------|
| DuckDB 内置表扫描 | `src/function/table/table_scan.cpp` | 单列：`COLUMN_IDENTIFIER_ROW_ID` |
| Parquet | `extension/parquet/parquet_multi_file_info.cpp` | 双列：`FILE_INDEX + FILE_ROW_NUMBER` |
| read_duckdb | `src/function/table/read_duckdb.cpp` | 双列：`FILE_INDEX + COLUMN_IDENTIFIER_ROW_ID` |

---

## 六、端到端示例

### 6.1 查询与计划变化

```sql
-- 示例查询：宽表（含多个数据列），只需 ORDER BY 一列取 TOP 5
SELECT id, ts, col1, col2, col3, col4
FROM my_wide_table
ORDER BY ts
LIMIT 5;
```

**未启用延迟物化时的逻辑计划：**

```
LogicalTopN (ORDER BY ts, LIMIT 5)
  └── LogicalGet [id, ts, col1, col2, col3, col4]
```

执行时需要将全表的 6 列全部读入内存，再做 TopN。

**启用延迟物化后的逻辑计划：**

```
LogicalOrder (ORDER BY ts)
  └── LogicalProjection [id, ts, col1, col2, col3, col4]
        └── LogicalComparisonJoin (SEMI, ON lhs.rowid = rhs.rowid)
              ├── LHS:
              │     LogicalTopN (ORDER BY ts, LIMIT 5)
              │       └── LogicalGet [ts, rowid]     ← 只扫描 2 列
              └── RHS:
                    LogicalGet [id, ts, col1, col2, col3, col4, rowid]
```

执行时：
1. **LHS**：只扫描 `ts + rowid`，做 TopN 得到 5 个行 ID
2. **SEMI JOIN**：用 5 个行 ID 构建哈希表，RHS 全表扫描时只让命中的 5 行通过
3. **最终**：只有 5 行完整数据进入 Projection，I/O 节省约 `(N-5)/N * (1 - 2/6)` 的列读取

### 6.2 通过 EXPLAIN 验证

```sql
EXPLAIN SELECT id, ts, col1, col2, col3
FROM my_table
ORDER BY ts
LIMIT 5;
```

改写后的计划中可以看到 `SEMI` 连接节点，LHS 的 `SEQ_SCAN` 只包含少量列。

### 6.3 调试与配置

```sql
-- 查看当前阈值
SELECT current_setting('late_materialization_max_rows');

-- 调整阈值（增大可对更大的 LIMIT 启用延迟物化）
SET late_materialization_max_rows = 200;

-- 临时禁用延迟物化（设为 0）
SET late_materialization_max_rows = 0;
```

---

## 七、设计权衡与局限

### 7.1 收益场景

| 场景 | 收益 |
|------|------|
| 宽表 + 小 LIMIT/TOPN | 显著减少读取列数和内存占用 |
| 列存格式（DuckDB、Parquet） | 结合列存 I/O 跳过，效果尤为明显 |
| 含过滤条件的 TOPN | LHS 过滤后行 ID 更少，RHS 读取进一步减少 |

### 7.2 局限与不触发场景

| 场景 | 原因 |
|------|------|
| `LIMIT` 值超过 `late_materialization_max_rows` 且不满足大 Limit 条件 | 行 ID 集合过大，半连接开销超过收益 |
| 算子链中含 Join / Aggregate 等 | 优化器无法安全穿透这些算子做行 ID 传播 |
| 扫描函数未设置 `late_materialization = true` | 函数未声明支持该优化 |
| 选取列数 ≥ 全部列数（如 `SELECT *` 且表列数极少） | 无减少列扫描的收益 |
| `preserve_insertion_order = false` 且无 offset 的大 Limit | 并行 Limit 时无需此优化 |

### 7.3 RHS 仍需全表扫描的问题

当前实现中 RHS 的扫描仍需全表遍历以比对行 ID（通过半连接哈希探测）。对于支持按行 ID 随机读的存储格式（如 DuckDB 内置表的 `Fetch` 接口），这是一个可以进一步优化的方向：在 RHS 直接按行 ID 列表随机读取，完全跳过顺序扫描。

---

## 八、关键数据流总结

```
查询解析与绑定
     │
     ▼
逻辑计划（LogicalTopN / LogicalLimit / LogicalSample）
     │
     ▼
Optimizer::Optimize()
  ├── [其他优化 Pass: 谓词下推、列裁剪等]
  └── LateMaterialization::Optimize()
        ├── 检查触发条件（算子类型、limit 阈值、函数标志）
        ├── TryLateMaterialization()
        │     ├── 分析引用列 vs 总列数
        │     ├── CreateLHSGet() → 克隆 + 插入行 ID
        │     ├── ConstructRHS() → 原始链 + 传播行 ID binding
        │     ├── 构建 LogicalComparisonJoin(SEMI)
        │     ├── 构建最终 Projection + Order
        │     └── RemoveUnusedColumns（裁剪 RHS 中不需要的列）
        └── 返回改写后的逻辑计划
     │
     ▼
物理计划（PhysicalTopN + PhysicalHashJoin(SEMI) + PhysicalTableScan）
     │
     ▼
执行引擎
  ├── Phase 1（LHS Pipeline）: 扫描少量列 → TopN/Limit → 输出行 ID 集合
  └── Phase 2（SEMI JOIN Probe）: 全表扫描 + 行 ID 匹配 → 输出完整列值
```
