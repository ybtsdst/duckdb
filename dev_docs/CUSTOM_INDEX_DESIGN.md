# DuckDB 自定义索引（Custom Index）设计文档

## 概述

本文档整理了 DuckDB 索引扩展机制的核心接口与设计，重点说明 `IndexType` 各字段的含义、`BoundIndex` 各虚接口的语义，以及实现一个自定义索引所需的完整步骤与注意事项。内置 ART 索引是目前唯一的参考实现，本文档以 ART 的实际代码为基础进行讲解。

---

## 一、整体架构

```
┌──────────────────────────────────────────────────┐
│                   IndexTypeSet                   │  全局注册表（大小写不敏感）
│  RegisterIndexType() / FindByName()              │
└───────────────────────┬──────────────────────────┘
                        │  注册 / 查找
                        ▼
┌──────────────────────────────────────────────────┐
│                   IndexType                      │  描述一种索引"类型"
│  name / build_* 回调 / create_instance / ...     │
└───────────────────────┬──────────────────────────┘
                        │  build_finalize / create_instance 返回
                        ▼
┌──────────────────────────────────────────────────┐
│               BoundIndex  (Index 子类)           │  已绑定的运行时索引实例
│  Append / Insert / Delete / MergeIndexes / ...   │
└──────────────────────────────────────────────────┘
```

索引的生命周期分为两个阶段：

1. **未绑定阶段（UnboundIndex）**：数据库启动时，从 Catalog / WAL / Checkpoint 反序列化，此时尚无活跃的内存数据结构，仅保存 `CreateIndexInfo` 和 `IndexStorageInfo`。
2. **已绑定阶段（BoundIndex）**：首次扫描或 DML 触发绑定，通过 `IndexType::create_instance` 创建真正的内存索引实例。

---

## 二、IndexType 各接口详解

源文件：`src/include/duckdb/execution/index/index_type.hpp`

### 2.1 字段总览

```cpp
class IndexType {
public:
    string name;                             // 索引类型名称（大小写不敏感）

    index_build_bind_t      build_bind         = nullptr;
    index_build_sort_t      build_sort         = nullptr;
    index_build_global_init_t build_global_init = nullptr;
    index_build_local_init_t  build_local_init  = nullptr;
    index_build_sink_t      build_sink         = nullptr;
    index_build_combine_t   build_combine      = nullptr;
    index_build_finalize_t  build_finalize     = nullptr;

    shared_ptr<IndexTypeInfo> index_info = nullptr;  // 可选：类型级别的附加信息

    index_build_plan_t     create_plan     = nullptr; // 逃生舱：自定义物理计划（可选）
    index_create_function_t create_instance = nullptr; // 直接实例化（加载已有索引时使用）
};
```

---

### 2.2 `name`

**类型**：`string`（注册时大小写不敏感）

索引类型的唯一标识符。用户在 SQL 中通过 `USING <name>` 指定：

```sql
CREATE INDEX idx ON t USING my_index (col);
```

系统在 `IndexTypeSet::FindByName(name)` 中查找对应的 `IndexType`。内置类型名为 `"ART"`。

> ⚠️ 同名注册会覆盖已有类型，内置 `ART` 类型在 `IndexTypeSet` 构造函数中预先注册，自定义类型应避免与其重名。

---

### 2.3 `build_bind`

**函数签名**：
```cpp
typedef unique_ptr<IndexBuildBindData> (*index_build_bind_t)(IndexBuildBindInput &input);
```

**调用时机**：`CREATE INDEX` 逻辑计划生成阶段（Bind 阶段），**每次 `CREATE INDEX` 调用一次**。

**作用**：类似 TableFunction 的 `bind` 回调。在这里可以：
- 检验索引类型与目标列/表达式的兼容性（类型检查）。
- 初始化构建过程中需要的元数据（如 ART 的 `sorted` 标志，用于决定是否对键排序）。
- 返回的 `IndexBuildBindData` 子类实例会被传递给后续所有 `build_*` 回调。

**输入结构**（`IndexBuildBindInput`）：
```
context        — 当前 ClientContext
table          — 目标表（DuckTableEntry）
info           — CreateIndexInfo（包含索引名、列、约束类型、WITH 选项等）
expressions    — 解析并绑定后的索引表达式（可能是列引用或函数表达式）
```

**ART 的实现**：检查表达式数量和返回类型，若为单列非 VARCHAR，则标记为可排序（`sorted = true`）以启用排序加速路径。

---

### 2.4 `build_sort`

**函数签名**：
```cpp
typedef bool (*index_build_sort_t)(IndexBuildSortInput &input);
```

**调用时机**：物理计划生成阶段，`CREATE INDEX` 的物理算子确定阶段。

**作用**：返回 `true` 时，系统会在扫描数据后自动插入排序算子（`PhysicalOrder`），将键按字典序排好序再送入 `build_sink`。

**输入结构**（`IndexBuildSortInput`）：
```
bind_data — build_bind 返回的 IndexBuildBindData（只读）
```

**注意**：
- 排序算子的开销较大，只在确实能利用有序输入时才返回 `true`。
- ART 对单列非 VARCHAR 返回 `true`，利用有序键可以加速 `ARTBuilder` 的批量构建。
- 若返回 `false`，数据将以任意顺序流入 `build_sink`，索引实现需自己处理无序输入。

---

### 2.5 `build_global_init`

**函数签名**：
```cpp
typedef unique_ptr<IndexBuildGlobalState> (*index_build_global_init_t)(IndexBuildInitGlobalStateInput &input);
```

**调用时机**：并行扫描开始前，**全局初始化一次**。

**作用**：创建并行构建过程中的全局共享状态。ART 的实现在此创建空的全局 `BoundIndex`，作为最终合并目标。

**输入结构**（`IndexBuildInitGlobalStateInput`）：
```
bind_data     — build_bind 返回的数据
context       — 当前 ClientContext
table         — 目标表
info          — CreateIndexInfo
expressions   — 绑定后的表达式
storage_ids   — 列的物理存储 ID（对应 column_ids 的物理位置）
```

---

### 2.6 `build_local_init`

**函数签名**：
```cpp
typedef unique_ptr<IndexBuildLocalState> (*index_build_local_init_t)(IndexBuildInitLocalStateInput &input);
```

**调用时机**：每个并行工作线程启动时，**每线程初始化一次**。

**作用**：为每个线程创建独立的本地构建状态，避免并发写入冲突。ART 在每线程创建一个本地 `BoundIndex` 实例和键缓冲区。

**输入结构**（`IndexBuildInitLocalStateInput`）：与 `build_global_init` 相同。

---

### 2.7 `build_sink`

**函数签名**：
```cpp
typedef void (*index_build_sink_t)(IndexBuildSinkInput &input, DataChunk &key_chunk, DataChunk &row_chunk);
```

**调用时机**：**每个线程**处理每个数据块时调用（并行，热路径）。

**作用**：将一批键（`key_chunk`）和对应的 row ID（`row_chunk`）写入本地索引。

**参数说明**：
- `key_chunk`：索引表达式执行后的键值（已按 `build_sort` 结果决定是否排序）。
- `row_chunk`：对应的物理 row ID，每行 1 个，类型为 `ROW_TYPE`（row_chunk.data[0]）。
- `input.local_state`：通过 `Cast<MyLocalState>()` 获取线程本地状态。

**注意**：
- 此函数在并行环境下被多个线程同时调用，不同线程调用的是各自的 `local_state`，无需加锁。
- 不要直接写入 `global_state`，合并在 `build_combine` 中进行。
- NULL 值已被上层过滤（`CREATE INDEX` 时 NULL 不入索引）。

---

### 2.8 `build_combine`

**函数签名**：
```cpp
typedef void (*index_build_combine_t)(IndexBuildCombineInput &input);
```

**调用时机**：每个工作线程完成所有 Sink 操作后，将本地结果合并到全局状态。

**作用**：将线程本地的部分索引合并到全局索引。ART 通过 `MergeIndexes()` 将本地 ART 合并入全局 ART。

**输入结构**（`IndexBuildCombineInput`）：
```
bind_data     — 全局 bind_data
global_state  — 全局状态（需加锁保护，或使用 lock-free 合并）
local_state   — 本线程的本地状态
table         — 目标表
info          — CreateIndexInfo
```

> ⚠️ 多线程并发调用 `build_combine` 时需对 `global_state` 进行互斥保护，或使用原子合并。ART 通过 `BoundIndex::MergeIndexes()` 内部持有的 `mutex` 保证安全。

---

### 2.9 `build_finalize`

**函数签名**：
```cpp
typedef unique_ptr<BoundIndex> (*index_build_finalize_t)(IndexBuildFinalizeInput &input);
```

**调用时机**：所有线程合并完成后，**最终调用一次**，完成索引构建。

**作用**：从 `global_state` 中提取最终的 `BoundIndex` 实例，注册到表的索引列表中。

**输入结构**（`IndexBuildFinalizeInput`）：
```
global_state — 全局状态
```

**ART 的实现**：直接 `move` 出 `global_state.global_index`。

---

### 2.10 `index_info`

**类型**：`shared_ptr<IndexTypeInfo>`

可选字段，用于存储此类型索引的**全局元信息**（非实例级别）。例如：索引类型的版本号、能力标志、默认参数等。通过 `Cast<MyIndexTypeInfo>()` 访问派生类字段。在 `PlanIndexInput` 中被传入自定义物理计划。ART 暂未使用此字段。

---

### 2.11 `create_plan`（逃生舱）

**函数签名**：
```cpp
typedef PhysicalOperator &(*index_build_plan_t)(PlanIndexInput &input);
```

**调用时机**：`CREATE INDEX` 的物理计划生成（`PhysicalPlanGenerator::CreatePlan(LogicalCreateIndex)` 中）。

**作用**：完全自定义索引构建的物理执行计划，绕过默认的 Scan → Sort → Sink → Combine → Finalize 流程。

**何时使用**：只有当标准的并行 Pipeline 无法满足你的索引构建需求时才使用，如需要特殊的 Join、子查询或非标准数据流。

> ⚠️ 设置 `create_plan` 后，`build_sort`、`build_global_init`、`build_local_init`、`build_sink`、`build_combine`、`build_finalize` 均不会被调用。二者只能选其一。

---

### 2.12 `create_instance`

**函数签名**：
```cpp
typedef unique_ptr<BoundIndex> (*index_create_function_t)(CreateIndexInput &input);
```

**调用时机**：
1. 数据库启动时，`UnboundIndex` 首次绑定（从 Checkpoint / Catalog 恢复）。
2. WAL 回放完成后，索引从未绑定状态转为已绑定状态。

**作用**：从已有的存储信息（`IndexStorageInfo`）直接创建 `BoundIndex` 实例，不需要重新扫描数据。相当于反序列化入口。

**输入结构**（`CreateIndexInput`）：
```
context              — ClientContext
table_io_manager     — 与表关联的 IO 管理器（用于分配/读取数据块）
db                   — AttachedDatabase（数据库实例）
constraint_type      — NONE / UNIQUE / PRIMARY / FOREIGN
name                 — 索引名
column_ids           — 被索引的物理列 ID 列表
unbound_expressions  — 未绑定的索引表达式
storage_info         — 持久化存储信息（block 指针等），若为新建则为空
options              — WITH (...) 中的索引选项
```

> ⚠️ `create_instance` 是**必填**字段。没有它，数据库重启后无法恢复已有索引。

---

## 三、BoundIndex 各接口详解

源文件：`src/include/duckdb/execution/index/bound_index.hpp`

`BoundIndex` 继承自 `Index`，是自定义索引需要继承的核心基类。下面按功能分组介绍各接口。

### 3.1 基础属性（从构造函数初始化）

| 字段 | 类型 | 说明 |
|------|------|------|
| `name` | `string` | 索引实例名（如 `idx_name`） |
| `index_type` | `string` | 索引类型名（如 `"ART"`） |
| `index_constraint_type` | `IndexConstraintType` | 约束类型：NONE / UNIQUE / PRIMARY / FOREIGN |
| `types` | `vector<PhysicalType>` | 索引列的物理类型（`INT32`、`VARCHAR` 等） |
| `logical_types` | `vector<LogicalType>` | 索引列的逻辑类型 |
| `unbound_expressions` | `vector<unique_ptr<Expression>>` | 未绑定表达式（用于重新绑定） |
| `delta_index_type` | `DeltaIndexType` | 若非 `NONE` 则为 Delta 索引（WAL 回放专用） |

---

### 3.2 数据写入接口

#### `Append`（追加）

```cpp
virtual ErrorData Append(IndexLock &l, DataChunk &chunk, Vector &row_ids) = 0;
virtual ErrorData Append(IndexLock &l, DataChunk &chunk, Vector &row_ids, IndexAppendInfo &info);
```

**调用时机**：`INSERT` 语句执行期间，将新行写入索引。

**语义**：
- `chunk`：包含索引列数据的数据块（已经过 `ExecuteExpressions` 处理）。
- `row_ids`：与 `chunk` 中每行对应的物理 row ID（`ROW_TYPE` 向量）。
- `IndexAppendInfo`：携带追加模式（`DEFAULT` / `IGNORE_DUPLICATES` / `INSERT_DUPLICATES`）以及 delta 删除索引引用。
- 返回 `ErrorData`，若有约束冲突返回错误（不抛出异常），由上层决定如何处理。

**注意**：
- 带锁版本（`IndexLock &l`）要求调用者已持锁。
- 不带锁的重载（`Append(DataChunk &, Vector &)`）内部自动加锁。
- 若 `IndexAppendMode::IGNORE_DUPLICATES`，遇到重复键时静默跳过。

---

#### `Insert`（插入，事务本地）

```cpp
virtual ErrorData Insert(IndexLock &l, DataChunk &chunk, Vector &row_ids) = 0;
virtual ErrorData Insert(IndexLock &l, DataChunk &chunk, Vector &row_ids, IndexAppendInfo &info);
```

**语义**：将数据写入**事务本地索引**（`append_indexes`），语义与 `Append` 相同，但场景不同：`Insert` 用于事务提交前的本地写入，`Append` 用于最终合并到全局索引。

> ART 中 `Insert` 和 `Append` 实现相同，均委托给内部 `ARTOperator::Insert()`。

---

### 3.3 数据删除接口

#### `TryDelete`（尝试删除）

```cpp
virtual idx_t TryDelete(IndexLock &state, DataChunk &entries, Vector &row_identifiers,
                        optional_ptr<SelectionVector> deleted_sel = nullptr,
                        optional_ptr<SelectionVector> non_deleted_sel = nullptr);
```

**调用时机**：`DELETE`/`UPDATE` 时尝试从索引中删除行。

**语义**：
- 返回成功删除的行数。
- `deleted_sel`：如果提供，填入成功删除行的下标（便于上层差异处理）。
- `non_deleted_sel`：如果提供，填入未能删除行的下标（如非唯一索引中键不存在的情况）。

**默认实现**：基类提供默认实现，调用 `Delete()`，返回所有行均删除成功（`TryDelete` 语义更宽松，不强制要求每行都存在）。

---

#### `Delete`（强制删除）

```cpp
virtual void Delete(IndexLock &state, DataChunk &entries, Vector &row_identifiers);
```

**语义**：删除 `entries` 中的所有行，若有行未找到则**抛出异常**。

**注意**：大多数情况下只需实现 `TryDelete`，`Delete` 可依赖基类的默认实现（基类 `Delete` 内部调用 `TryDelete`，若未全部删除则 throw）。

---

### 3.4 索引合并

```cpp
virtual bool MergeIndexes(IndexLock &state, BoundIndex &other_index) = 0;
```

**调用时机**：
1. 事务提交时，将事务本地索引（`append_indexes`）合并入全局索引。
2. `CREATE INDEX` 的并行构建结束时，将各线程本地索引合并入全局索引（`build_combine`）。

**语义**：将 `other_index` 的所有内容合并入 `this`。若合并过程发现唯一性冲突，返回 `false`（通常抛出 `ConstraintException`）；成功则返回 `true`。合并后 `other_index` 可被废弃。

> ⚠️ `other_index` 与 `this` 应为**相同类型**的索引。需要通过 `Cast<MyIndex>()` 获取具体类型。

---

### 3.5 约束验证

```cpp
virtual void VerifyAppend(DataChunk &chunk, IndexAppendInfo &info, optional_ptr<ConflictManager> manager);
virtual void VerifyConstraint(DataChunk &chunk, IndexAppendInfo &info, ConflictManager &manager);
```

**调用时机**：提交前对待写入数据做完整性检查（UNIQUE / PRIMARY KEY 约束）。

**语义**：
- `VerifyAppend`：检查 `chunk` 中的键是否与现有索引冲突，冲突信息记录在 `ConflictManager` 中（不抛异常）。
- `VerifyConstraint`：同上，但 `ConflictManager` 为非空强制参数，通常会对冲突做更严格的处理（如结合 ON CONFLICT 语义）。

**约束冲突消息**：
```cpp
virtual string GetConstraintViolationMessage(VerifyExistenceType verify_type, idx_t failed_index, DataChunk &input) = 0;
```
返回人类可读的错误消息，如 `"Duplicate key \"42\" violates unique constraint"`。`verify_type` 说明检查类型：`APPEND`（正常插入）、`APPEND_FK`（外键约束检查目标存在）、`DELETE_FK`（外键约束检查引用是否释放）。

---

### 3.6 生命周期管理

#### `CommitDrop`（提交删除）

```cpp
virtual void CommitDrop(IndexLock &index_lock) = 0;
```

**调用时机**：`DROP INDEX` 或 `DROP TABLE` 确认提交时调用。

**语义**：清理索引占用的所有持久化资源（如 Block）。内存资源由析构函数负责，此处只需释放磁盘/Buffer 资源。

---

#### `Vacuum`（空间回收）

```cpp
virtual void Vacuum(IndexLock &l) = 0;
```

**调用时机**：系统空闲时或 `VACUUM` 命令触发。

**语义**：对索引进行碎片整理/压缩，回收因删除而产生的空洞内存/磁盘空间。若索引底层使用了 `FixedSizeAllocator`，可调用 `allocator.Vacuum()` 完成整理。不支持 Vacuum 的索引可以空实现。

---

### 3.7 内存与验证

```cpp
virtual idx_t GetInMemorySize(IndexLock &state) = 0;  // 返回索引当前内存占用（字节）
virtual void Verify(IndexLock &l) = 0;                // 验证索引内部一致性（调试/测试用）
virtual string ToString(IndexLock &l, bool display_ascii = false) = 0;  // 返回索引的文本表示
virtual void VerifyAllocations(IndexLock &l) = 0;     // 验证分配器统计数量与实际节点数一致
virtual void VerifyBuffers(IndexLock &l);              // 验证 Buffer 状态（有默认空实现）
```

**注意**：`Verify`、`VerifyAllocations`、`VerifyBuffers` 仅在调试/测试模式下调用（通常通过 `D_ASSERT` 和 `DUCKDB_DEBUG` 宏保护），生产环境中可以提供轻量级实现或断言。

---

### 3.8 序列化（持久化）

```cpp
virtual IndexStorageInfo SerializeToDisk(QueryContext context, const case_insensitive_map_t<Value> &options);
virtual IndexStorageInfo SerializeToWAL(const case_insensitive_map_t<Value> &options);
```

**调用时机**：
- `SerializeToDisk`：Checkpoint 时将索引数据写入数据文件。
- `SerializeToWAL`：WAL 写入时将索引数据记录到预写日志。

**返回值**（`IndexStorageInfo`）：记录索引数据在磁盘/WAL 上的位置（block 指针列表），供 `create_instance` 恢复时读取。

**基类默认实现**：返回空的 `IndexStorageInfo`（适用于纯内存索引，不持久化）。若需持久化，必须覆写这两个方法并在 `create_instance` 中正确读取。

---

### 3.9 Delta 索引支持（WAL 回放专用）

```cpp
virtual bool SupportsDeltaIndexes() const;  // 默认 false
virtual unique_ptr<BoundIndex> CreateDeltaIndex(DeltaIndexType delta_index_type) const;
```

**作用**：Delta 索引是为 WAL 回放优化引入的机制。当数据库崩溃恢复时，索引可能处于 `UnboundIndex` 状态，WAL 的 INSERT/DELETE 操作需要"缓冲"而非立即应用。若索引声明支持 Delta 索引，系统会为其创建 `LOCAL_APPEND` 和 `LOCAL_DELETE` 类型的 Delta 索引实例，先将操作收集到 Delta 索引，在索引真正 Bind 后统一回放（`ApplyBufferedReplays`）。

**`DeltaIndexType` 枚举含义**：

| 值 | 含义 |
|----|------|
| `NONE` | 非 Delta 索引，普通运行时索引 |
| `LOCAL_APPEND` | WAL 回放时本地追加的行（INSERT） |
| `LOCAL_DELETE` | WAL 回放时本地删除的行（DELETE） |
| `ADDED_DURING_CHECKPOINT` | Checkpoint 期间新增的行 |
| `REMOVED_DURING_CHECKPOINT` | Checkpoint 期间删除的行 |
| `DELETED_ROWS_IN_USE` | 标记为删除但仍被事务使用的行 |

简单的自定义索引可以不实现 Delta 索引，返回 `SupportsDeltaIndexes() = false`，系统会改用 `BufferedIndexReplays` 机制（在 `UnboundIndex` 中缓冲操作，Bind 后批量回放）。

---

### 3.10 辅助方法（基类已提供，无需覆写）

| 方法 | 说明 |
|------|------|
| `InitializeLock(IndexLock &)` | 获取索引的互斥锁 |
| `ExecuteExpressions(DataChunk &, DataChunk &)` | 对输入数据执行索引表达式，生成键 |
| `IndexIsUpdated(column_ids)` | 判断给定列 ID 是否影响此索引（UPDATE 时跳过不相关索引） |
| `AppendRowError(DataChunk &, idx_t)` | 生成行错误信息（"In row …"） |
| `IsUnique()` / `IsPrimary()` / `IsForeign()` | 约束类型判断 |
| `GetColumnIds()` / `GetColumnIdSet()` | 返回被索引的物理列 ID |
| `IsBound()` | 始终返回 `true`（BoundIndex 特化） |

---

## 四、实现一个自定义索引的完整步骤

### 步骤 1：继承 `BoundIndex`，实现所有纯虚方法

```cpp
#include "duckdb/execution/index/bound_index.hpp"

class MyIndex : public BoundIndex {
public:
    static constexpr const char *TYPE_NAME = "MY_INDEX";

    // 构造函数：转发给 BoundIndex
    MyIndex(const string &name, IndexConstraintType constraint_type,
            const vector<column_t> &column_ids,
            TableIOManager &table_io_manager,
            const vector<unique_ptr<Expression>> &unbound_expressions,
            AttachedDatabase &db)
        : BoundIndex(name, TYPE_NAME, constraint_type, column_ids,
                     table_io_manager, unbound_expressions, db) {}

    // 工厂方法：从存储信息恢复实例（对应 create_instance）
    static unique_ptr<BoundIndex> Create(CreateIndexInput &input) {
        auto idx = make_uniq<MyIndex>(
            input.name, input.constraint_type, input.column_ids,
            input.table_io_manager, input.unbound_expressions, input.db);
        // 若 input.storage_info 非空，从磁盘读取索引数据
        return std::move(idx);
    }

    // === 必须实现的纯虚方法 ===

    ErrorData Append(IndexLock &l, DataChunk &chunk, Vector &row_ids) override {
        DataChunk key_chunk;
        ExecuteExpressions(chunk, key_chunk);  // 执行索引表达式生成键
        // 将 key_chunk 中的键与 row_ids 写入内部数据结构
        return ErrorData();  // 无错误
    }

    ErrorData Insert(IndexLock &l, DataChunk &chunk, Vector &row_ids) override {
        return Append(l, chunk, row_ids);  // 通常与 Append 相同
    }

    bool MergeIndexes(IndexLock &state, BoundIndex &other_index) override {
        auto &other = other_index.Cast<MyIndex>();
        // 将 other 的所有键合并入 this
        return true;
    }

    void CommitDrop(IndexLock &index_lock) override {
        // 释放持久化资源（Block 等）
    }

    void Vacuum(IndexLock &l) override {
        // 回收碎片空间，可为空实现
    }

    idx_t GetInMemorySize(IndexLock &state) override {
        return /* 估算内存占用 */ 0;
    }

    void Verify(IndexLock &l) override {
        // 调试验证，可为空实现
    }

    string ToString(IndexLock &l, bool display_ascii) override {
        return "MyIndex()";
    }

    void VerifyAllocations(IndexLock &l) override {
        // 调试验证，可为空实现
    }

    string GetConstraintViolationMessage(VerifyExistenceType verify_type,
                                         idx_t failed_index,
                                         DataChunk &input) override {
        return "Duplicate key violates unique constraint on MyIndex";
    }
};
```

---

### 步骤 2：定义构建回调

```cpp
// Bind：检查列类型，初始化构建元数据
unique_ptr<IndexBuildBindData> MyIndexBuildBind(IndexBuildBindInput &input) {
    auto bind_data = make_uniq<IndexBuildBindData>();
    // 可以在此检查列类型是否受支持，记录配置参数等
    return bind_data;
}

// Sort：是否需要对键排序
bool MyIndexBuildSort(IndexBuildSortInput &input) {
    return false;  // 若不需要有序输入，返回 false
}

// 全局状态初始化
unique_ptr<IndexBuildGlobalState> MyIndexBuildGlobalInit(IndexBuildInitGlobalStateInput &input) {
    struct MyGlobalState : public IndexBuildGlobalState {
        unique_ptr<BoundIndex> global_index;
    };
    auto state = make_uniq<MyGlobalState>();
    auto &storage = input.table.GetStorage();
    state->global_index = make_uniq<MyIndex>(
        input.info.index_name, input.info.constraint_type, input.storage_ids,
        TableIOManager::Get(storage), input.expressions, storage.db);
    return state;
}

// 线程本地状态初始化
unique_ptr<IndexBuildLocalState> MyIndexBuildLocalInit(IndexBuildInitLocalStateInput &input) {
    struct MyLocalState : public IndexBuildLocalState {
        unique_ptr<BoundIndex> local_index;
    };
    auto state = make_uniq<MyLocalState>();
    auto &storage = input.table.GetStorage();
    state->local_index = make_uniq<MyIndex>(
        input.info.index_name, input.info.constraint_type, input.storage_ids,
        TableIOManager::Get(storage), input.expressions, storage.db);
    return state;
}

// Sink：处理数据块
void MyIndexBuildSink(IndexBuildSinkInput &input, DataChunk &key_chunk, DataChunk &row_chunk) {
    struct MyLocalState : public IndexBuildLocalState { unique_ptr<BoundIndex> local_index; };
    auto &lstate = input.local_state.Cast<MyLocalState>();
    lstate.local_index->Append(key_chunk, row_chunk.data[0]);
}

// Combine：合并线程本地结果到全局
void MyIndexBuildCombine(IndexBuildCombineInput &input) {
    struct MyGlobalState : public IndexBuildGlobalState { unique_ptr<BoundIndex> global_index; };
    struct MyLocalState : public IndexBuildLocalState { unique_ptr<BoundIndex> local_index; };
    auto &gstate = input.global_state.Cast<MyGlobalState>();
    auto &lstate = input.local_state.Cast<MyLocalState>();
    gstate.global_index->MergeIndexes(*lstate.local_index);
}

// Finalize：返回最终索引实例
unique_ptr<BoundIndex> MyIndexBuildFinalize(IndexBuildFinalizeInput &input) {
    struct MyGlobalState : public IndexBuildGlobalState { unique_ptr<BoundIndex> global_index; };
    auto &gstate = input.global_state.Cast<MyGlobalState>();
    return std::move(gstate.global_index);
}
```

---

### 步骤 3：组装 `IndexType` 并注册

```cpp
// 获取自定义索引的 IndexType 描述符
IndexType MyIndex::GetIndexType() {
    IndexType my_index_type;
    my_index_type.name            = MyIndex::TYPE_NAME;   // "MY_INDEX"
    my_index_type.create_instance = MyIndex::Create;
    my_index_type.build_bind      = MyIndexBuildBind;
    my_index_type.build_sort      = MyIndexBuildSort;
    my_index_type.build_global_init = MyIndexBuildGlobalInit;
    my_index_type.build_local_init  = MyIndexBuildLocalInit;
    my_index_type.build_sink      = MyIndexBuildSink;
    my_index_type.build_combine   = MyIndexBuildCombine;
    my_index_type.build_finalize  = MyIndexBuildFinalize;
    return my_index_type;
}

// 在 Extension 的 Load 函数中注册
void MyExtension::Load(DuckDB &db) {
    db.instance->config.GetIndexTypes().RegisterIndexType(MyIndex::GetIndexType());
}
```

---

### 步骤 4：在 SQL 中使用

```sql
-- 使用自定义索引类型
CREATE INDEX my_idx ON my_table USING MY_INDEX (col1);

-- 使用 WITH 传递索引选项（通过 CreateIndexInfo::options 访问）
CREATE INDEX my_idx ON my_table USING MY_INDEX (col1) WITH (my_param = 'value');
```

---

## 五、注意事项与常见陷阱

### 5.1 并发安全

- `BoundIndex` 基类已提供 `mutex lock`。所有接收 `IndexLock &` 的方法已持锁，不要在其内部再次加锁（死锁）。
- `build_sink` 在多线程中并发调用，每线程只访问自己的 `local_state`，无需加锁。
- `build_combine` 可能被多个线程并发调用，对 `global_state` 的写入需要保护，可复用 `global_index` 的 `InitializeLock()`。

### 5.2 `create_instance` 是必须实现的

如果不实现 `create_instance`，数据库重启后无法从 Checkpoint 恢复索引，会导致索引数据丢失。即使是纯内存索引，也应实现该函数（返回一个空索引并标记为"需要重建"，或直接在 `Create` 中重新扫描表数据）。

### 5.3 不要在 `build_sink`/`build_combine` 中持有长时间锁

这两个回调在并行 Pipeline 的热路径中被调用，锁的粒度应尽量小。

### 5.4 `IndexAppendMode` 的处理

在 `Append`/`Insert` 中需要正确处理 `IndexAppendMode`：

| 模式 | 含义 | 期望行为 |
|------|------|---------|
| `DEFAULT` | 正常插入，唯一索引遇重复键报错 | 返回 `ErrorData` 错误 |
| `IGNORE_DUPLICATES` | `INSERT OR IGNORE` 时，遇重复键静默跳过 | 跳过该行，不报错 |
| `INSERT_DUPLICATES` | 非唯一索引，允许重复键 | 插入重复键 |

### 5.5 约束检查的时机

- `Append`/`Insert` 在写入时**立即检查**约束，适合轻量级本地检查。
- `VerifyConstraint` 在事务**提交前**做最终检查，是防止并发冲突的最后一道防线。
- 两者都需要实现，不要只实现其中一个。

### 5.6 `ExecuteExpressions` 的使用

索引支持基于表达式的键（如 `CREATE INDEX ON t (lower(name))`），需要在 `Append`/`Insert` 中调用 `ExecuteExpressions(input_chunk, key_chunk)` 将输入数据转换为键数据，而不是直接使用原始列数据。

### 5.7 NULL 值处理

`CREATE INDEX` 时，系统会在物理计划中自动插入 `PhysicalFilter` 过滤掉 NULL 键（`IS NOT NULL`），索引实现**不需要**自行处理 NULL 键的过滤（但运行时 `INSERT` 时仍可能接到 NULL，需要在 `Append` 中决定是否忽略）。

### 5.8 持久化的实现要点

若需要持久化：
1. 在 `SerializeToDisk` 中将内存数据写入 `BlockManager` 管理的 Block，返回 `IndexStorageInfo`（包含 block 指针列表）。
2. 在 `SerializeToWAL` 中将数据写入 WAL 文件。
3. 在 `create_instance` 中检查 `storage_info.IsValid()`，若有效则从 Block 读取数据恢复索引，否则返回空索引。
4. 推荐使用 `FixedSizeAllocator` 管理节点内存，它原生支持 Buffer Manager 的换入/换出和序列化。

### 5.9 `IndexStorageInfo` 与 `TableIOManager`

- `TableIOManager::Get(storage)` 返回与表关联的 IO 管理器，用于分配数据块。
- `IndexStorageInfo` 中的 `block_pointers` 字段存储序列化后的块指针，每次 Checkpoint 后可能变化，需在 `SerializeToDisk` 返回时更新。

### 5.10 扩展注册的时机

`RegisterIndexType` 应在数据库打开（`Load` 函数）时调用，**必须**在任何 `CREATE INDEX` 或 `UnboundIndex::Bind()` 之前完成注册，否则系统无法找到对应类型。

---

## 六、回调调用流程图

### 6.1 `CREATE INDEX` 流程

```
SQL: CREATE INDEX idx ON t USING MY_INDEX (col)
         │
         ▼
  Bind 阶段
  ├── IndexTypeSet::FindByName("MY_INDEX") → IndexType
  └── build_bind(IndexBuildBindInput)      → IndexBuildBindData
         │
         ▼
  物理计划生成
  ├── build_sort(IndexBuildSortInput)      → bool（是否插入排序算子）
  └── [可选] create_plan(PlanIndexInput)   → PhysicalOperator（完全自定义）
         │
         ▼  （标准流程）
  Pipeline 执行
  ├── build_global_init(...)               → IndexBuildGlobalState
  ├── [并行，每线程] build_local_init(...) → IndexBuildLocalState
  ├── [并行，每 chunk] build_sink(...)     → void
  ├── [每线程完成] build_combine(...)      → void（合并到 global_state）
  └── build_finalize(...)                  → unique_ptr<BoundIndex>
         │
         ▼
  BoundIndex 注册到表的索引列表
```

### 6.2 数据库重启后的恢复流程

```
数据库启动
  │
  ▼
从 Catalog/Checkpoint 读取索引元数据
  └── 创建 UnboundIndex（仅持有 CreateIndexInfo + IndexStorageInfo）
         │
         ▼  （首次访问/DML 触发 Bind）
  IndexTypeSet::FindByName(index_type) → IndexType
  └── create_instance(CreateIndexInput) → unique_ptr<BoundIndex>
         │                               （读取 storage_info，恢复内存结构）
         ▼
  BoundIndex 替换 UnboundIndex，开始服务查询
```

### 6.3 `INSERT` 事务流程

```
INSERT INTO t VALUES (...)
  │
  ▼
LocalStorage（事务本地存储）
  └── append_indexes（本地索引）
        └── BoundIndex::Insert(...)    ← 写入本地索引
                                         检查唯一约束（本地）
  │
  ▼  事务 COMMIT
LocalStorage::Flush()
  ├── VerifyConstraint(...)            ← 提交前完整性验证（对全局索引）
  └── MergeIndexes(local → global)    ← 将本地索引合并入全局索引
```

---

## 七、关键源码位置

| 文件 | 说明 |
|------|------|
| `src/include/duckdb/execution/index/index_type.hpp` | `IndexType`、所有 `Input` 结构体、函数指针类型定义 |
| `src/include/duckdb/execution/index/bound_index.hpp` | `BoundIndex` 基类定义、`IndexAppendMode`、`DeltaIndexType` |
| `src/include/duckdb/storage/index.hpp` | `Index` 基类定义 |
| `src/include/duckdb/execution/index/index_type_set.hpp` | `IndexTypeSet`（注册与查找） |
| `src/execution/index/index_type_set.cpp` | `IndexTypeSet` 构造（默认注册 ART） |
| `src/execution/index/art/art_index.cpp` | ART 的 `IndexType` 注册完整示例（所有回调实现） |
| `src/execution/index/art/art.cpp` | ART 的 `BoundIndex` 实现参考 |
| `src/include/duckdb/execution/index/fixed_size_allocator.hpp` | 索引节点内存管理（推荐复用） |
| `src/include/duckdb/execution/index/unbound_index.hpp` | `UnboundIndex`（未绑定阶段）、WAL 回放缓冲机制 |
| `src/storage/local_storage.cpp` | 事务本地索引（`append_indexes`/`delete_indexes`）管理 |
| `src/storage/data_table.cpp` | `AppendToIndexes`、`MergeStorage`（提交时索引同步） |
