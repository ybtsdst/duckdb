# DuckDB TableFunction 接口设计文档

## 概述

本文档整理了 DuckDB `src/include/duckdb/function/table_function.hpp` 中 `TableFunction` 的完整接口定义，详细说明每个方法（回调函数指针）的逻辑含义、调用时机和线程模型，并给出扩展时需要注意的关键事项，为编写自定义表函数（UDTF）或理解内置扫描函数（`read_csv`、`read_parquet` 等）提供参考。

---

## 一、源码文件总览

| 文件 | 说明 |
|------|------|
| `src/include/duckdb/function/table_function.hpp` | TableFunction 类及所有相关结构体、回调类型的声明 |
| `src/function/table_function.cpp` | 构造函数、`operator==`、`Equal` 的实现 |
| `src/function/table/` | 内置表函数实现（`range`、`query` 等） |
| `extension/parquet/`、`extension/json/` 等 | 扩展中的表函数实现示例 |

---

## 二、执行生命周期总览

`TableFunction` 在一次查询中按以下四个阶段被调用：

```
SQL 解析
    │
    ▼
1. BIND 阶段（规划期，单线程）
   bind / bind_replace / bind_operator
   - 校验参数，决定输出列名与列类型
   - 返回不可变的 FunctionData（"bind data"）
    │
    ▼
2. GLOBAL INIT 阶段（执行前，单线程）
   init_global
   - 分配 GlobalTableFunctionState（跨线程共享）
   - MaxThreads() 决定并行度
    │
    ▼
3. LOCAL INIT 阶段（每个工作线程一次）
   init_local
   - 分配 LocalTableFunctionState（线程私有）
   - 从全局状态中领取本线程的工作任务
    │
    ▼
4. SCAN 阶段（热循环，每线程反复调用直至耗尽）
   function（纯源函数）
   OR in_out_function / in_out_function_final（管道内函数）
   - 填充 DataChunk，返回空 Chunk 表示 EOF
```

---

## 三、核心结构体

### 3.1 TableFunctionInfo

```cpp
struct TableFunctionInfo {
    virtual ~TableFunctionInfo();
    template <class TARGET> TARGET &Cast();
};
```

**用途：** 注册函数时附加的静态元数据，通过 `TableFunction::function_info` 持有，并在每次 `bind` 调用时以 `TableFunctionBindInput::info` 传入。

**典型使用场景：** 文件格式变种的选项（如 CSV 分隔符）、插件上下文对象。

**扩展注意：**
- 子类化后挂载到 `TableFunction::function_info`（`shared_ptr`）。
- 该对象被所有 `bind` 调用共享，**注册后必须视为只读**，若需可变则自行加锁。

---

### 3.2 GlobalTableFunctionState

```cpp
struct GlobalTableFunctionState {
    constexpr static int64_t MAX_THREADS = 999999999; // 表示"使用全部可用线程"的哨兵值（与源码中的实际常量一致）
    virtual ~GlobalTableFunctionState();
    virtual idx_t MaxThreads() const { return 1; }
    template <class TARGET> TARGET &Cast();
};
```

**用途：** 单次查询执行期间各线程共享的可变状态，由 `init_global` 创建。

**典型内容：**
- 待扫描的工作单元列表（文件、行组、分区等），用于线程间任务分配。
- 原子计数器或互斥锁保护的进度指针。

**扩展注意：**
- `MaxThreads()` 在 `init_global` 调用时被查询一次，用于决定并行线程数。返回 `MAX_THREADS` 表示"使用所有可用线程"，返回 `1` 表示单线程执行。
- 所有可变字段**必须用 `mutex` 保护**——多线程会并发访问。

---

### 3.3 LocalTableFunctionState

```cpp
struct LocalTableFunctionState {
    virtual ~LocalTableFunctionState();
    template <class TARGET> TARGET &Cast();
};
```

**用途：** 每个工作线程私有的执行状态，由 `init_local` 创建。

**典型内容：** 当前文件句柄、行组迭代器、线程本地缓冲区。

**扩展注意：**
- 该状态永远不会被其他线程访问，**无需加锁**。
- `init_local` 应在此处（持锁地）从 `GlobalTableFunctionState` 中领取本线程的工作片段。若全局已无工作，需将本地状态标记为"已耗尽"，以便 `function()` 立即返回空 Chunk。

---

### 3.4 输入辅助结构体

#### TableFunctionBindInput

传递给 `bind` / `bind_replace` / `bind_operator` 回调：

| 字段 | 类型 | 说明 |
|------|------|------|
| `inputs` | `vector<Value> &` | 用户传入的位置参数值 |
| `named_parameters` | `named_parameter_map_t &` | 用户传入的关键字参数 |
| `input_table_types` | `vector<LogicalType> &` | 输入关系的列类型（仅 in-out 函数） |
| `input_table_names` | `vector<string> &` | 输入关系的列名（仅 in-out 函数） |
| `info` | `optional_ptr<TableFunctionInfo>` | 注册时附加的静态元数据 |
| `binder` | `optional_ptr<Binder>` | 当前活跃的 Binder，可用于子绑定/目录查找 |
| `table_function` | `TableFunction &` | 正在绑定的 TableFunction 本身 |
| `ref` | `const TableFunctionRef &` | 解析器产生的原始 AST 节点 |

#### TableFunctionInitInput

传递给 `init_global` 和 `init_local` 回调：

| 字段 | 类型 | 说明 |
|------|------|------|
| `bind_data` | `optional_ptr<const FunctionData>` | `bind` 返回的只读数据 |
| `column_ids` | `vector<column_t>` | 需要物化的列索引列表（兼容接口） |
| `column_indexes` | `vector<ColumnIndex>` | 含子列路径的列描述符（嵌套格式使用，如 Parquet） |
| `projection_ids` | `const vector<idx_t>` | 实际需要从扫描算子输出的列子集（用于 `filter_prune`） |
| `filters` | `optional_ptr<TableFilterSet>` | 下推的过滤谓词（仅当 `filter_pushdown = true`） |
| `sample_options` | `optional_ptr<SampleOptions>` | 采样参数（仅当 `sampling_pushdown = true`） |
| `op` | `optional_ptr<const PhysicalOperator>` | 物理算子节点，高级场景使用 |

辅助方法 `CanRemoveFilterColumns()` 返回 `true` 时，表示部分列仅为过滤计算而扫描，可在输出中裁掉（需配合 `filter_prune = true`）。

#### TableFunctionInput

传递给 `function` / `in_out_function` 扫描回调：

| 字段 | 类型 | 说明 |
|------|------|------|
| `bind_data` | `optional_ptr<const FunctionData>` | 只读的 bind 数据 |
| `local_state` | `optional_ptr<LocalTableFunctionState>` | 当前线程的可变本地状态 |
| `global_state` | `optional_ptr<GlobalTableFunctionState>` | 跨线程共享的可变全局状态 |

---

## 四、回调函数接口详解

### 4.1 Bind 阶段

#### `bind`（必须设置）

```cpp
typedef unique_ptr<FunctionData> (*table_function_bind_t)(
    ClientContext &context,
    TableFunctionBindInput &input,
    vector<LogicalType> &return_types,
    vector<string> &names);
```

**调用时机：** 查询规划期，单线程，每次查询调用一次。

**职责：**
1. 校验 `input.inputs` / `input.named_parameters` 中的参数合法性
2. 填充 `return_types`（输出列类型）和 `names`（输出列名）
3. 返回一个 `FunctionData` 子类实例，封装运行时需要的不可变配置

**扩展注意：**
- 参数非法时应抛出 `BinderException`；
- 返回的 `FunctionData` 在执行期间**不可再修改**（可变运行时状态应放在 `GlobalTableFunctionState`）；
- 不应返回 `nullptr`（若要替换整个计划节点，使用 `bind_replace` 或 `bind_operator`）。

---

#### `bind_replace`（可选）

```cpp
typedef unique_ptr<TableRef> (*table_function_bind_replace_t)(
    ClientContext &context,
    TableFunctionBindInput &input);
```

**调用时机：** 早于 `bind`，单线程。若返回非空，则以返回的 `TableRef` 生成逻辑计划，**替换**原来的 `LogicalGet` 节点；若返回 `nullptr`，则回退到 `bind` 正常路径。

**典型使用场景：** 将函数调用完全重写为子查询（如内置的 `query()` 函数用此机制直接展开 SQL 字符串）。

**扩展注意：**
- `bind_replace` 与 `bind_operator` 互斥，只设一个。

---

#### `bind_operator`（可选）

```cpp
typedef unique_ptr<LogicalOperator> (*table_function_bind_operator_t)(
    ClientContext &context,
    TableFunctionBindInput &input,
    idx_t bind_index,
    vector<string> &return_names);
```

**调用时机：** 与 `bind_replace` 相同，但返回的是原始的 `LogicalOperator` 节点，提供更强的计划控制能力。

**扩展注意：** 仅在需要完全自定义逻辑计划节点时使用，大多数情况优先考虑 `bind_replace`。

---

### 4.2 初始化阶段

#### `init_global`（可选）

```cpp
typedef unique_ptr<GlobalTableFunctionState> (*table_function_init_global_t)(
    ClientContext &context,
    TableFunctionInitInput &input);
```

**调用时机：** 执行前，单线程。若未提供则 DuckDB 使用内置的单线程空状态。

**控制并行度：** 返回状态的 `MaxThreads()` 决定并发线程数。

**扩展注意：**
- 在此处建立所有工作单元队列（如文件列表、行组范围）；
- 若未设置 `init_global`，则 `init_local` 的 `global_state` 参数为 `nullptr`，扫描默认单线程；
- 调用时机受 `global_initialization` 枚举控制（见第六节）。

---

#### `init_local`（可选）

```cpp
typedef unique_ptr<LocalTableFunctionState> (*table_function_init_local_t)(
    ExecutionContext &context,
    TableFunctionInitInput &input,
    GlobalTableFunctionState *global_state);
```

**调用时机：** 每个工作线程启动时，并发调用。

**职责：** 从 `global_state` 中领取本线程的工作片段，初始化本地迭代器/缓冲区。

**扩展注意：**
- 领取工作片段时需对 `global_state` 加锁；
- 若全局已无可分配工作，应将本地状态标记为"无工作"，这样后续 `function()` 调用能立即返回空 Chunk 而不会多余地扫描。

---

### 4.3 扫描阶段

#### `function`（Source 函数，二者选一）

```cpp
typedef void (*table_function_t)(
    ClientContext &context,
    TableFunctionInput &data,
    DataChunk &output);
```

**调用时机：** 每线程反复调用，直至所有线程均返回空 Chunk。

**EOF 信号：** 令 `output` 的行数为 0（即不调用 `output.SetCardinality(N)` 或令 N=0）。

**扩展注意：**
- 函数体内访问 `data.global_state` 时若需要分配新工作则必须加锁；
- 每次调用最多填充 `STANDARD_VECTOR_SIZE`（默认 2048）行；
- 不应与 `in_out_function` 同时设置。

---

#### `in_out_function`（In-Out 函数，二者选一）

```cpp
typedef OperatorResultType (*table_in_out_function_t)(
    ExecutionContext &context,
    TableFunctionInput &data,
    DataChunk &input,
    DataChunk &output);
```

**用途：** 既接受输入关系（`input` Chunk）又产出行的"管道内"函数（Pipeline Breaker）。

**返回值语义：**

| 返回值 | 含义 |
|--------|------|
| `NEED_MORE_INPUT` | 当前 input Chunk 已处理完，需要下一个 |
| `HAVE_MORE_OUTPUT` | 当前 input 还可以产出更多 output，不需要新 input |
| `BLOCKED` | 异步阻塞，任务暂停并等待回调重新调度 |
| `FINISHED` | 函数执行完毕 |

---

#### `in_out_function_final`（In-Out 收尾，可选）

```cpp
typedef OperatorFinalizeResultType (*table_in_out_function_final_t)(
    ExecutionContext &context,
    TableFunctionInput &data,
    DataChunk &output);
```

**调用时机：** 所有输入已消费完毕后调用一次，用于刷新内部缓冲。返回 `FINISHED` 表示完成。

---

### 4.4 统计与优化阶段

#### `statistics`（可选）

```cpp
typedef unique_ptr<BaseStatistics> (*table_statistics_t)(
    ClientContext &context,
    const FunctionData *bind_data,
    column_t column_index);
```

**用途：** 返回指定列的统计信息（最小值、最大值、NULL 计数等），供优化器用于过滤选择率估计。

**扩展注意：** 无法获取时返回 `nullptr`；统计信息不必精确，近似值同样有益。

---

#### `cardinality`（可选）

```cpp
typedef unique_ptr<NodeStatistics> (*table_function_cardinality_t)(
    ClientContext &context,
    const FunctionData *bind_data);
```

**用途：** 估算输出行数（可标记为精确或近似），优化器用于 Join 顺序决策与哈希表内存预分配。

**扩展注意：** 哪怕粗略估计也比 `nullptr` 好；`nullptr` 表示完全未知。

---

#### `dependency`（可选）

```cpp
typedef void (*table_function_dependency_t)(
    LogicalDependencyList &dependencies,
    const FunctionData *bind_data);
```

**用途：** 向 `dependencies` 列表中注册本函数依赖的目录对象（基础表、序列等）。

**扩展注意：** 若不声明依赖，DuckDB 可能在查询仍在运行时允许 `DROP TABLE`，导致访问悬空引用。

---

### 4.5 Filter 下推

#### `pushdown_complex_filter`（可选）

```cpp
typedef void (*table_function_pushdown_complex_filter_t)(
    ClientContext &context,
    LogicalGet &get,
    FunctionData *bind_data,
    vector<unique_ptr<Expression>> &filters);
```

**前提：** `filter_pushdown = true`。

**用途：** 接收任意过滤表达式列表。函数可将能处理的表达式从 `filters` 中移除（函数内部处理），剩余的由 DuckDB 在扫描后追加过滤算子。

**⚠️ 关键注意：** 从列表中移除表达式意味着**函数必须保证该条件**——若移除后实际未过滤，则会产生语义错误的结果。不确定时保留在列表中（慢但正确，不影响结果正确性）。

---

#### `pushdown_expression`（可选）

```cpp
typedef bool (*table_function_pushdown_expression_t)(
    ClientContext &context,
    const LogicalGet &get,
    Expression &expr);
```

**用途：** 细粒度判断单个表达式是否能被转换为 `TableFilter` 下推。返回 `true` 则允许下推，`false` 则保留为后置过滤。

---

#### `supports_pushdown_type`（可选）

```cpp
typedef bool (*table_function_supports_pushdown_type_t)(
    const FunctionData &bind_data,
    idx_t col_idx);
```

**用途：** 在 `filter_pushdown = true` 的前提下，进一步限制哪些列支持过滤下推。返回 `false` 表示该列的过滤仍作为后置算子处理。

---

### 4.6 类型与投影下推

#### `type_pushdown`（可选）

```cpp
typedef void (*table_function_type_pushdown_t)(
    ClientContext &context,
    optional_ptr<FunctionData> bind_data,
    const unordered_map<idx_t, LogicalType> &new_column_types);
```

**用途：** 优化器发现某列实际使用类型比声明类型更窄时（如 CAST 折叠），通知扫描器以更窄的类型直接读取，减少类型转换开销。

---

### 4.7 输出字符串（EXPLAIN / Profile）

#### `to_string`（可选）

```cpp
typedef InsertionOrderPreservingMap<string> (*table_function_to_string_t)(
    TableFunctionToStringInput &input);
```

**调用时机：** 执行前（EXPLAIN 阶段），只能访问 `bind_data`。

**用途：** 返回键值对映射，显示在 `EXPLAIN` 输出和查询 Profile 中（如扫描文件路径、选项）。

---

#### `dynamic_to_string`（可选）

```cpp
typedef InsertionOrderPreservingMap<string> (*table_function_dynamic_to_string_t)(
    TableFunctionDynamicToStringInput &input);
```

**调用时机：** 执行后（Profile 阶段），可访问 `bind_data`、`local_state`、`global_state`。

**用途：** 在 Profile 中追加运行时统计（已读行数、扫描字节数、缓存命中率等）。

---

### 4.8 进度与分区

#### `table_scan_progress`（可选）

```cpp
typedef double (*table_function_progress_t)(
    ClientContext &context,
    const FunctionData *bind_data,
    const GlobalTableFunctionState *global_state);
```

**用途：** 返回 `[0, 100]` 的扫描进度百分比，用于进度条和 `duckdb_progress()` 系统函数。

**扩展注意：** 无法计算时返回 `-1`；此函数可能被高频调用，不应有阻塞操作。

---

#### `get_partition_data`（可选）

```cpp
typedef OperatorPartitionData (*table_function_get_partition_data_t)(
    ClientContext &context,
    TableFunctionGetPartitionInput &input);
```

**用途：** 返回当前本地扫描线程所处位置对应的分区数据（如排序键列值），供分区 Pipeline 基础设施将行路由到正确的分区。

---

#### `get_partition_info`（可选）

```cpp
typedef TablePartitionInfo (*table_function_get_partition_info_t)(
    ClientContext &context,
    TableFunctionPartitionInput &input);
```

**用途：** 描述扫描输出本身的分区特性（如已按某列排序），优化器据此避免在扫描节点上方插入冗余的重分区算子。

---

#### `get_partition_stats`（可选）

```cpp
typedef vector<PartitionStatistics> (*table_function_get_partition_stats_t)(
    ClientContext &context,
    GetPartitionStatsInput &input);
```

**用途：** 返回每个分区的统计信息（行起始偏移、行数、行数精确性）。用于：
- Zone Map / Min-Max 过滤（分区级）
- 自适应并行执行时的分区均衡分配

---

### 4.9 虚拟列与行 ID

#### `get_virtual_columns`（可选）

```cpp
typedef virtual_column_map_t (*table_function_get_virtual_columns_t)(
    ClientContext &context,
    optional_ptr<FunctionData> bind_data);
```

**用途：** 枚举扫描器能按需合成的虚拟列（如 `row_id`、`filename`、`file_row_number`）。这些列不在声明的输出 Schema 中，但可出现在 `SELECT` 列表或 `WHERE` 子句里。

---

#### `get_row_id_columns`（可选）

```cpp
typedef vector<column_t> (*table_function_get_row_id_columns)(
    ClientContext &context,
    optional_ptr<FunctionData> bind_data);
```

**用途：** 返回构成本扫描逻辑行标识符的列索引列表，用于 `UPDATE` / `DELETE` 语句的重写（将目标行定位回源数据）。

---

### 4.10 MultiFileReader 扩展

#### `get_multi_file_reader`（可选）

```cpp
typedef unique_ptr<MultiFileReader> (*table_function_get_multi_file_reader_t)(const TableFunction &);
```

**用途：** 注入自定义 `MultiFileReader` 实现。若不设置，DuckDB 使用内置的默认实现（支持通配符、Hive 分区等）。

**适用场景：** 需要特殊文件发现逻辑（如从对象存储列表 API 获取文件列表）的扫描函数。

---

### 4.11 序列化

#### `serialize` / `deserialize`（可选，需成对设置）

```cpp
typedef void (*table_function_serialize_t)(
    Serializer &serializer,
    const optional_ptr<FunctionData> bind_data,
    const TableFunction &function);

typedef unique_ptr<FunctionData> (*table_function_deserialize_t)(
    Deserializer &deserializer,
    TableFunction &function);
```

**用途：** 将 `bind_data` 持久化到序列化流，以支持预编译语句缓存和查询跨进程复用。

**扩展注意：**
- 两个函数**必须成对设置**，缺一不可；
- `deserialize` 返回的数据必须与原始 `bind` 调用对相同参数时的结果语义等价；
- `verify_serialization = true`（默认）时，DuckDB 会在调试模式下验证序列化正确性。

---

### 4.12 元数据查询

#### `get_bind_info`（可选）

```cpp
typedef BindInfo (*table_function_get_bind_info_t)(
    const optional_ptr<FunctionData> bind_data);
```

**用途：** 返回 `BindInfo` 描述符（含 `ScanType` 和 options 键值对），供 `EXPLAIN` 和优化器规则检查扫描元数据。

---

## 五、TableFunction 类字段速查

### 5.1 回调函数指针

| 字段名 | 类型别名 | 是否必须 | 说明 |
|--------|----------|----------|------|
| `bind` | `table_function_bind_t` | ✅ 必须 | 参数校验 + 输出 Schema + 返回 bind data |
| `bind_replace` | `table_function_bind_replace_t` | 可选 | 返回 TableRef 替换整个计划节点（与 bind_operator 二选一） |
| `bind_operator` | `table_function_bind_operator_t` | 可选 | 返回自定义 LogicalOperator（与 bind_replace 二选一） |
| `init_global` | `table_function_init_global_t` | 可选 | 分配跨线程共享状态，决定并行度 |
| `init_local` | `table_function_init_local_t` | 可选 | 分配线程本地状态，领取工作片段 |
| `function` | `table_function_t` | ✅（与 in_out 二选一） | 纯源扫描主循环 |
| `in_out_function` | `table_in_out_function_t` | 可选（与 function 二选一） | 管道内 in-out 扫描循环 |
| `in_out_function_final` | `table_in_out_function_final_t` | 可选 | in-out 函数的收尾刷新 |
| `statistics` | `table_statistics_t` | 可选 | 返回列统计信息 |
| `dependency` | `table_function_dependency_t` | 可选 | 声明目录依赖项 |
| `cardinality` | `table_function_cardinality_t` | 可选 | 估算输出行数 |
| `pushdown_complex_filter` | `table_function_pushdown_complex_filter_t` | 可选 | 消费/改写任意过滤表达式 |
| `pushdown_expression` | `table_function_pushdown_expression_t` | 可选 | 判断单个表达式是否可下推 |
| `to_string` | `table_function_to_string_t` | 可选 | EXPLAIN 输出（执行前） |
| `dynamic_to_string` | `table_function_dynamic_to_string_t` | 可选 | Profile 输出（执行后，含运行时统计） |
| `table_scan_progress` | `table_function_progress_t` | 可选 | 返回扫描进度 [0,100]，-1 表示未知 |
| `get_partition_data` | `table_function_get_partition_data_t` | 可选 | 当前线程位置的分区数据 |
| `get_bind_info` | `table_function_get_bind_info_t` | 可选 | 返回 BindInfo 元数据描述符 |
| `type_pushdown` | `table_function_type_pushdown_t` | 可选 | 接受优化器推断的更窄列类型 |
| `get_multi_file_reader` | `table_function_get_multi_file_reader_t` | 可选 | 注入自定义 MultiFileReader |
| `supports_pushdown_type` | `table_function_supports_pushdown_type_t` | 可选 | 细粒度控制哪些列支持 filter 下推 |
| `get_partition_info` | `table_function_get_partition_info_t` | 可选 | 描述输出分区特性 |
| `get_partition_stats` | `table_function_get_partition_stats_t` | 可选 | 每分区统计信息（行偏移 + 行数） |
| `get_virtual_columns` | `table_function_get_virtual_columns_t` | 可选 | 枚举可按需合成的虚拟列 |
| `get_row_id_columns` | `table_function_get_row_id_columns` | 可选 | 构成行 ID 的列索引列表 |
| `serialize` | `table_function_serialize_t` | 可选（与 deserialize 成对） | 序列化 bind data |
| `deserialize` | `table_function_deserialize_t` | 可选（与 serialize 成对） | 反序列化 bind data |

### 5.2 Pushdown 标志位

| 字段名 | 类型 | 默认 | 语义 |
|--------|------|------|------|
| `projection_pushdown` | `bool` | `false` | 为 `true` 时，`init_global/init_local` 的 `column_ids` 仅包含实际需要的列，扫描器跳过其余列以减少 I/O |
| `filter_pushdown` | `bool` | `false` | 为 `true` 时，`init_global/init_local` 的 `filters` 包含下推的过滤条件，扫描器在读取时直接过滤 |
| `filter_prune` | `bool` | `false` | 为 `true` 时，仅用于过滤的列不需要出现在输出中，需配合 `CanRemoveFilterColumns()` 使用 |
| `sampling_pushdown` | `bool` | `false` | 为 `true` 时，采样参数下推给扫描器处理，而不是在扫描后再采样 |
| `late_materialization` | `bool` | `false` | 为 `true` 时，支持延迟物化（先通过行 ID 过滤，再按需取列值） |

**⚠️ 关键注意：** 以上标志位设为 `true`、但实现未正确处理时，将产生**错误结果或不必要的数据传输**。仅在实现确实遵守相应语义时才开启。

### 5.3 其他字段

| 字段名 | 类型 | 说明 |
|--------|------|------|
| `function_info` | `shared_ptr<TableFunctionInfo>` | 注册时附加的静态元数据，传递给 bind |
| `verify_serialization` | `bool` | 默认 `true`，在调试模式下校验序列化一致性 |
| `global_initialization` | `TableFunctionInitialization` | 控制 `init_global` 的调用时机（见下节） |

---

## 六、TableFunctionInitialization 枚举

```cpp
enum class TableFunctionInitialization {
    INITIALIZE_ON_EXECUTE,   // 默认：Pipeline 就绪时调用 init_global
    INITIALIZE_ON_SCHEDULE,  // Pipeline 调度时（查询规划后立即）调用 init_global
};
```

| 枚举值 | 调用时机 | 适用场景 |
|--------|----------|----------|
| `INITIALIZE_ON_EXECUTE`（默认） | Pipeline 即将开始执行时 | 绝大多数场景 |
| `INITIALIZE_ON_SCHEDULE` | 查询首次被调度时，早于所有 Pipeline 执行 | `init_global` 有较高延迟（如建立远程连接），需要提前隐藏延迟 |

---

## 七、扩展实现指南

### 7.1 最小可用示例

```cpp
// 1. 定义 bind data（不可变配置）
struct MyBindData : public FunctionData {
    string file_path;
    unique_ptr<FunctionData> Copy() const override {
        auto result = make_uniq<MyBindData>();
        result->file_path = file_path;
        return result;
    }
    bool Equals(const FunctionData &other) const override {
        return file_path == other.Cast<MyBindData>().file_path;
    }
};

// 2. 定义全局状态（线程间共享，需加锁）
struct MyGlobalState : public GlobalTableFunctionState {
    mutex lock;
    vector<string> files;
    idx_t file_index = 0;

    idx_t MaxThreads() const override {
        return files.size(); // 每个文件一个线程
    }
};

// 3. 定义本地状态（线程私有）
struct MyLocalState : public LocalTableFunctionState {
    string current_file;
    bool exhausted = false;
};

// 4. 实现 bind
static unique_ptr<FunctionData> MyBind(
        ClientContext &context, TableFunctionBindInput &input,
        vector<LogicalType> &return_types, vector<string> &names) {
    auto result = make_uniq<MyBindData>();
    result->file_path = input.inputs[0].GetValue<string>();
    // 填充输出 Schema
    return_types = { LogicalType::VARCHAR };
    names = { "line" };
    return result;
}

// 5. 实现 init_global
static unique_ptr<GlobalTableFunctionState> MyInitGlobal(
        ClientContext &context, TableFunctionInitInput &input) {
    auto &bind_data = input.bind_data->Cast<MyBindData>();
    auto state = make_uniq<MyGlobalState>();
    state->files = { bind_data.file_path }; // 简化：单文件
    return state;
}

// 6. 实现 init_local（从全局状态领取工作）
static unique_ptr<LocalTableFunctionState> MyInitLocal(
        ExecutionContext &context, TableFunctionInitInput &input,
        GlobalTableFunctionState *global_state) {
    auto &gstate = global_state->Cast<MyGlobalState>();
    auto lstate = make_uniq<MyLocalState>();
    lock_guard<mutex> lock(gstate.lock);
    if (gstate.file_index < gstate.files.size()) {
        lstate->current_file = gstate.files[gstate.file_index++];
    } else {
        lstate->exhausted = true;
    }
    return lstate;
}

// 7. 实现主扫描函数
static void MyScan(ClientContext &context, TableFunctionInput &data, DataChunk &output) {
    auto &lstate = data.local_state->Cast<MyLocalState>();
    if (lstate.exhausted) return; // 空 Chunk = EOF
    // ... 读取 lstate.current_file 并填充 output ...
    lstate.exhausted = true; // 示例：读完即标记
}

// 8. 注册
// TableFunction 构造函数参数顺序：(函数名, 位置参数类型列表, 扫描函数, bind, init_global, init_local)
// 后三个回调可省略（传 nullptr），但省略 bind 时输出 Schema 将为空。
TableFunction MyFunction("my_scan", { LogicalType::VARCHAR }, MyScan, MyBind, MyInitGlobal, MyInitLocal);
MyFunction.projection_pushdown = true;
```

### 7.2 常见陷阱

| 陷阱 | 后果 | 解决方案 |
|------|------|----------|
| 修改 `FunctionData`（bind data）中的字段 | 多线程并发读写，数据竞争 | 将可变状态移入 `GlobalTableFunctionState` |
| `GlobalTableFunctionState` 无锁并发写 | 数据竞争、结果错误 | 用 `mutex` 保护所有可变字段 |
| `pushdown_complex_filter` 中错误地移除了无法处理的表达式 | 查询返回错误结果（过滤失效） | 仅移除**确保能处理**的表达式 |
| 设置 `filter_pushdown = true` 但不使用 `filters` | 无安全问题，但下推无效（额外增加了过滤算子） | 在 `init_global/init_local` 中读取并应用 `input.filters` |
| `serialize`/`deserialize` 只实现一个 | 序列化功能静默失效 | 总是成对实现 |
| `init_local` 不加锁地读取全局工作队列 | 多线程数据竞争，工作片段重复分配 | 在 `init_local` 中对 `global_state` 加锁 |

---

## 八、文件源码位置速查

| 概念 | 关键源文件 |
|------|-----------|
| TableFunction 接口定义 | `src/include/duckdb/function/table_function.hpp` |
| TableFunction 基础实现 | `src/function/table_function.cpp` |
| 内置表函数（range、query 等） | `src/function/table/` |
| Parquet 扫描函数 | `extension/parquet/` |
| JSON 扫描函数 | `extension/json/` |
| 绑定流程入口 | `src/planner/binder/tableref/bind_table_function.cpp` |
| 物理扫描算子 | `src/execution/operator/scan/physical_table_scan.cpp` |
| MultiFileReader | `src/include/duckdb/common/multi_file/multi_file_reader.hpp` |
| C API 绑定（扩展接口） | `src/main/capi/table_function-c.cpp` |
