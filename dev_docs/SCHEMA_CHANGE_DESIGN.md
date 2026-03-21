# DuckDB Schema Change 操作设计文档

## 概述

DuckDB 支持完整的 DDL（数据定义语言）操作，涵盖对象的创建、修改和删除。所有 Schema 变更操作均通过事务机制保证原子性，并通过 WAL（Write-Ahead Log）保证持久性。

本文档整理了 DuckDB 支持的全部 Schema Change 操作，并对每类操作的设计思路和实现流程进行说明。

---

## 目录

1. [支持的 Schema Change 操作汇总](#1-支持的-schema-change-操作汇总)
2. [整体架构分层](#2-整体架构分层)
3. [CREATE 操作](#3-create-操作)
4. [DROP 操作](#4-drop-操作)
5. [ALTER 操作](#5-alter-操作)
6. [CATALOG 版本管理与 MVCC](#6-catalog-版本管理与-mvcc)
7. [事务支持与 Undo Buffer](#7-事务支持与-undo-buffer)
8. [WAL 持久化机制](#8-wal-持久化机制)
9. [依赖管理](#9-依赖管理)
10. [并发控制](#10-并发控制)
11. [典型操作完整执行流程示例](#11-典型操作完整执行流程示例)

---

## 1. 支持的 Schema Change 操作汇总

### CREATE 操作

| 操作 | 说明 |
|------|------|
| `CREATE TABLE` | 创建普通表或临时表，支持 `IF NOT EXISTS`、`AS SELECT` |
| `CREATE VIEW` | 创建视图或临时视图 |
| `CREATE SCHEMA` | 创建 Schema（命名空间） |
| `CREATE SEQUENCE` | 创建序列对象 |
| `CREATE INDEX` | 在表列上创建 ART（Adaptive Radix Tree）索引 |
| `CREATE TYPE` | 创建自定义数据类型（枚举、结构体等） |
| `CREATE MACRO` | 创建标量宏函数 |
| `CREATE TABLE MACRO` | 创建表宏（返回表的宏） |
| `CREATE FUNCTION` | 创建标量/聚合/复制/pragma 函数 |
| `CREATE COLLATION` | 创建自定义排序规则 |
| `CREATE SECRET` | 创建访问凭证 Secret（用于对象存储等） |

### DROP 操作

| 操作 | 说明 |
|------|------|
| `DROP TABLE` | 删除表，支持 `IF EXISTS`、`CASCADE/RESTRICT` |
| `DROP VIEW` | 删除视图 |
| `DROP SCHEMA` | 删除 Schema，支持 `CASCADE` |
| `DROP SEQUENCE` | 删除序列 |
| `DROP INDEX` | 删除索引 |
| `DROP TYPE` | 删除自定义类型 |
| `DROP MACRO` | 删除宏函数 |
| `DROP FUNCTION` | 删除函数 |

### ALTER TABLE 操作

| 操作 | `AlterTableType` 枚举值 | 说明 |
|------|------------------------|------|
| `RENAME COLUMN` | `RENAME_COLUMN = 1` | 重命名列 |
| `RENAME TABLE` | `RENAME_TABLE = 2` | 重命名表 |
| `ADD COLUMN` | `ADD_COLUMN = 3` | 添加新列，支持默认值 |
| `DROP COLUMN` | `REMOVE_COLUMN = 4` | 删除列，支持 `IF EXISTS/CASCADE` |
| `ALTER COLUMN TYPE` | `ALTER_COLUMN_TYPE = 5` | 修改列数据类型，支持 `USING` 转换表达式 |
| `SET DEFAULT` | `SET_DEFAULT = 6` | 设置列默认值 |
| `FOREIGN KEY CONSTRAINT` | `FOREIGN_KEY_CONSTRAINT = 7` | 添加/删除外键约束 |
| `SET NOT NULL` | `SET_NOT_NULL = 8` | 添加 NOT NULL 约束 |
| `DROP NOT NULL` | `DROP_NOT_NULL = 9` | 删除 NOT NULL 约束 |
| `SET COLUMN COMMENT` | `SET_COLUMN_COMMENT = 10` | 设置列注释 |
| `ADD CONSTRAINT` | `ADD_CONSTRAINT = 11` | 添加 CHECK/UNIQUE/PRIMARY KEY 约束 |
| `SET PARTITIONED BY` | `SET_PARTITIONED_BY = 12` | 设置分区键（扩展用） |
| `SET SORTED BY` | `SET_SORTED_BY = 13` | 设置排序键（扩展用） |
| `ADD FIELD` | `ADD_FIELD = 14` | 向嵌套 STRUCT 类型添加字段 |
| `REMOVE FIELD` | `REMOVE_FIELD = 15` | 从嵌套 STRUCT 类型删除字段 |
| `RENAME FIELD` | `RENAME_FIELD = 16` | 重命名嵌套 STRUCT 字段 |

### 其他 ALTER 操作

| 操作 | 说明 |
|------|------|
| `ALTER VIEW ... RENAME TO` | 重命名视图 |
| `ALTER TABLE ... OWNER TO` | 修改对象所有者 |
| `ALTER TABLE ... COMMENT = ...` | 设置表注释 |
| `ALTER SEQUENCE` | 修改序列属性 |
| `ALTER SCALAR FUNCTION` | 修改标量函数 |
| `ALTER TABLE FUNCTION` | 修改表函数 |

---

## 2. 整体架构分层

DuckDB 的 Schema Change 处理分为以下几个层次，每类 DDL 操作都自上而下经过这些层次：

```
SQL 语句
    │
    ▼
┌─────────────────────────────────────┐
│  Parser 层（词法/语法解析）           │
│  src/parser/transform/statement/     │
│  输出：ParsedStatement (AST)         │
└─────────────────────────────────────┘
    │
    ▼
┌─────────────────────────────────────┐
│  Binder 层（语义分析/绑定）           │
│  src/planner/binder/statement/       │
│  输出：BoundStatement (语义绑定后的AST)│
└─────────────────────────────────────┘
    │
    ▼
┌─────────────────────────────────────┐
│  Logical Plan 层（逻辑计划）          │
│  src/planner/operator/               │
│  输出：LogicalOperator               │
└─────────────────────────────────────┘
    │
    ▼
┌─────────────────────────────────────┐
│  Physical Plan 层（物理计划）         │
│  src/execution/physical_plan/        │
│  src/execution/operator/schema/      │
│  输出：PhysicalOperator              │
└─────────────────────────────────────┘
    │
    ▼
┌─────────────────────────────────────┐
│  Catalog 层（目录/元数据存储）         │
│  src/catalog/                        │
│  操作：CatalogSet 中的 Entry 版本链   │
└─────────────────────────────────────┘
    │
    ▼
┌─────────────────────────────────────┐
│  事务/持久化层                        │
│  UndoBuffer（回滚支持）               │
│  WAL（持久化）                        │
│  Storage（数据文件）                  │
└─────────────────────────────────────┘
```

### 关键源码目录

| 层次 | 目录 | 关键文件 |
|------|------|---------|
| Parser | `src/parser/transform/statement/` | `transform_create_table.cpp`, `transform_alter_table.cpp`, `transform_drop.cpp` |
| ParsedData | `src/include/duckdb/parser/parsed_data/` | `create_*.hpp`, `alter_table_info.hpp`, `drop_info.hpp` |
| Binder | `src/planner/binder/statement/` | `bind_create.cpp`, `bind_create_table.cpp`, `bind_drop.cpp` |
| Logical Plan | `src/planner/operator/` | `logical_create.hpp`, `logical_create_table.hpp`, `logical_create_index.hpp` |
| Physical Plan | `src/execution/operator/schema/` | `physical_create_table.cpp`, `physical_alter.cpp`, `physical_drop.cpp` 等 |
| Catalog | `src/catalog/` | `catalog.cpp`, `catalog_set.cpp`, `dependency_manager.cpp` |
| Catalog Entries | `src/catalog/catalog_entry/` | `duck_table_entry.cpp`, `duck_schema_entry.cpp` 等 |
| Transaction | `src/transaction/` | `duck_transaction.cpp`, `undo_buffer.cpp` |
| WAL | `src/storage/` | `write_ahead_log.cpp`, `wal_replay.cpp` |

---

## 3. CREATE 操作

### 3.1 设计思路

CREATE 操作创建新的 Catalog 对象（表、视图、Schema 等）。主要设计原则：

- **原子性**：对象要么完整创建，要么不创建，事务回滚时通过 Undo Buffer 移除。
- **版本隔离**：新创建的对象仅对当前事务（及其后的已提交事务）可见。
- **冲突检测**：若同名对象已存在，根据 `IF NOT EXISTS` 的设定决定报错或忽略。

### 3.2 实现流程

以 `CREATE TABLE` 为例：

```
1. Parser 阶段
   transform_create_table.cpp
   输入：SQL 字符串
   输出：CreateStatement{ CreateTableInfo{ columns, constraints, ... } }

2. Binder 阶段
   bind_create.cpp → Binder::Bind(CreateStatement &)
   bind_create_table.cpp → Binder::BindCreateTableInfo()
   - 解析目标 Schema，验证 Catalog 存在性
   - 绑定列类型（类型解析）
   - 绑定默认值表达式
   - 绑定 CHECK/UNIQUE/PRIMARY KEY 约束表达式
   - 调用 properties.RegisterDBModify(catalog) 标记数据库修改
   输出：BoundCreateTableInfo（含绑定后的列定义和约束）

3. Logical Plan 阶段
   输出：LogicalCreateTable 算子（包含 BoundCreateTableInfo）

4. Physical Plan 阶段
   plan_create_table.cpp → PhysicalPlanGenerator::CreatePlan(LogicalCreateTable)
   输出：PhysicalCreateTable 算子

5. 执行阶段
   PhysicalCreateTable::GetData() {
       catalog.CreateTable(context, *bound_create_info);
   }
   
   Catalog::CreateTable() → DuckCatalog::CreateTable()
   → DuckSchemaEntry::AddEntry() → CatalogSet::CreateEntry()
   - 在 CatalogSet 中插入新 CatalogEntry
   - 为新 Entry 设置当前事务 ID 作为 timestamp

6. 事务提交时
   - 若提交：将 Entry 的 timestamp 更新为 commit_id（全局可见）
   - 若回滚：UndoBuffer::Rollback() 从 CatalogSet 中移除该 Entry
   - WAL 记录：WriteCreateTable(entry) 写入持久化日志
```

### 3.3 CREATE INDEX 特殊性

`CREATE INDEX` 与其他 CREATE 不同之处在于需要扫描并索引现有数据：

```
1. Binder 阶段
   - 解析表引用和索引列
   - 生成读取表数据的逻辑计划（子计划）

2. Physical Plan 阶段
   plan_create_index.cpp
   - 生成 PhysicalCreateARTIndex 算子
   - 子计划：扫描表中所有数据行

3. 执行阶段
   PhysicalCreateARTIndex::Sink() {
       // 消费子计划产出的每个数据块
       // 逐行向 ART 索引插入 (key, row_id)
   }
   PhysicalCreateARTIndex::Finalize() {
       // 将 ART 索引注册到 Catalog
       catalog.CreateIndex(context, *info);
   }
```

---

## 4. DROP 操作

### 4.1 设计思路

DROP 操作删除 Catalog 中的对象。核心设计考量：

- **依赖检查**：删除对象前检查是否有其他对象依赖于它（如删除被视图引用的表）。
- **CASCADE 语义**：`DROP ... CASCADE` 会递归删除所有依赖对象。
- **RESTRICT 语义**：`DROP ... RESTRICT`（默认）若存在依赖则报错。
- **标记删除（Soft Delete）**：Drop 操作在 CatalogSet 中标记该 Entry 为 `deleted = true`，而非立即物理删除，支持事务回滚。

### 4.2 实现流程

```
1. Parser 阶段
   transform_drop.cpp
   输出：DropStatement{ DropInfo{ type, schema, name, if_exists, cascade } }

2. Binder 阶段
   bind_drop.cpp → Binder::Bind(DropStatement &)
   - 查找目标对象，验证存在性（考虑 IF EXISTS）
   - 调用 properties.RegisterDBModify(catalog) 标记修改

3. 执行阶段
   PhysicalDrop::GetData() {
       catalog.DropEntry(context, *info);
   }
   
   Catalog::DropEntry() → DuckCatalog::DropEntryInternal()
   → DuckSchemaEntry::DropEntry() → CatalogSet::DropEntry()
   
   CatalogSet::DropEntry():
   - 调用 DependencyManager::DropObject() 检查依赖关系
     - 若存在依赖且非 CASCADE：抛出错误
     - 若 CASCADE：递归 Drop 所有依赖对象
   - 在 CatalogSet 中创建一个 deleted=true 的新 Entry 版本
   - 事务回滚时，通过 UndoBuffer 恢复该 Entry

4. 事务提交/回滚
   - 提交：deleted 标记对所有后续事务可见
   - 回滚：UndoBuffer 恢复 Entry 为 deleted=false
   - WAL：WriteDropTable(entry) / WriteDropView(entry) 等写入日志
```

---

## 5. ALTER 操作

ALTER 操作是 Schema Change 中最复杂的部分。DuckDB 采用**整体替换（Copy-on-Write）**策略：每次 ALTER 操作都通过复制当前 Entry 并应用变更，生成一个新的 CatalogEntry 版本，而不是原地修改现有 Entry。

### 5.1 整体设计思路

```
旧 Entry (timestamp=T1) → 新 Entry (timestamp=T_current_txn)
           │                           │
           └──── child 指针 ───────────┘
                 （旧版本作为新版本的 child）
```

每次 ALTER：
1. 以旧 Entry 为基础创建新的 `CreateTableInfo`（复制所有列、约束）
2. 应用变更（添加/删除/修改 列或约束）
3. 创建新的 DuckTableEntry，设置 timestamp = 当前事务 ID
4. 在 CatalogSet 中通过 `UpdateEntry()` 将新 Entry 推到链表头部

回滚时：UndoBuffer 调用 `CatalogEntry::UndoAlter()` → `CatalogSet::DropEntry()` 移除新版本，旧版本自动重新成为链表头部（即当前版本）。

### 5.2 ADD COLUMN

**功能**：向已有表添加新列，支持默认值。

**实现要点**（`duck_table_entry.cpp: AddColumn()`）：

```
1. 若指定 IF NOT EXISTS 且列已存在，直接返回 nullptr（幂等）
2. 复制当前表所有列定义和约束
3. 绑定新列类型（BindLogicalType）
4. 为新列分配逻辑列号（LogicalColumnCount）和物理存储列号（PhysicalColumnCount）
5. 创建新的 DataTable 存储对象：
   DataTable(context, *old_storage, new_column, *default_expr)
   - 仅新增一个物理列，不复制旧数据
   - 旧数据行的新列值在查询时动态计算默认值（延迟物化）
6. 返回新的 DuckTableEntry（包含新列和新的 DataTable 引用）
```

**存储层的 ADD COLUMN 优化**：新列的旧行数据通过默认值表达式"虚拟"补全，不需要重写全部数据文件。仅在数据被修改或持久化时，新列才会出现在实际存储中。

### 5.3 DROP COLUMN

**功能**：删除表中的一列。

**实现要点**（`duck_table_entry.cpp: RemoveColumn()`）：

```
1. 查找被删除列的 LogicalIndex
2. 检查依赖：通过 column_dependency_manager 检查是否有生成列（generated column）依赖于此列
   - 若存在依赖且未指定 CASCADE，报错
   - 若指定 CASCADE，同时删除依赖的生成列
3. 复制除被删除列之外的所有列定义
4. 确保剩余列数 > 0（不能删除最后一列）
5. 更新约束：移除引用该列的 CHECK/UNIQUE/FOREIGN KEY 约束中的引用
6. 创建新的 DataTable 存储：
   DataTable(context, *old_storage, physical_column_index_to_remove)
   - 物理上标记该列为已删除，不再在后续操作中使用
7. 若被删除的是生成列，不需要修改存储（生成列无物理存储）
```

### 5.4 ALTER COLUMN TYPE

**功能**：修改列的数据类型，支持 `USING` 转换表达式。

**实现要点**（`duck_table_entry.cpp: ChangeColumnType()`）：

```
1. 绑定目标类型（BindLogicalType）
2. 解析并绑定 USING 表达式：
   - 表达式可以引用旧列的值进行类型转换
   - 若未提供 USING，默认生成 CAST(col AS new_type) 表达式
3. 约束兼容性检查：
   - 若列上有 CHECK 约束引用该列，拒绝类型变更（需先删除约束）
   - 若列上有 UNIQUE/PRIMARY KEY/FOREIGN KEY 约束，同样拒绝
4. 创建新 DataTable：
   DataTable(context, *old_storage, change_info, bound_expression)
   - 该调用触发存储层的列类型变更
   - 存储层会重写受影响的 Row Group 数据，应用 USING 表达式进行转换
```

**注意**：ALTER COLUMN TYPE 需要实际重写列数据，是代价最高的 ALTER 操作。

### 5.5 RENAME COLUMN

**功能**：重命名表中的列。

**实现要点**（`duck_table_entry.cpp: RenameColumn()`）：

```
1. 验证目标列存在
2. 复制所有列定义，在复制过程中将目标列名修改为新名称
3. 不修改存储层（仅元数据变更）
4. 更新 generated column 表达式中的列引用名称（若有）
5. 返回新的 DuckTableEntry
```

### 5.6 SET DEFAULT / DROP DEFAULT

**功能**：设置或清除列的默认值。

**实现要点**：

```
1. 找到目标列
2. 创建新的 ColumnDefinition，修改其 default_value 字段
3. 创建新的 DuckTableEntry（不修改存储，仅元数据变更）
```

### 5.7 SET NOT NULL / DROP NOT NULL

**功能**：添加或删除列的 NOT NULL 约束。

**SET NOT NULL 实现要点**：
```
1. 扫描全表验证目标列无 NULL 值（通过物理计划执行一次扫描）
2. 验证通过后，在约束列表中添加 NOT NULL 约束
3. 返回新的 DuckTableEntry
```

**DROP NOT NULL 实现要点**：
```
1. 找到目标列的 NOT NULL 约束，从约束列表中移除
2. 返回新的 DuckTableEntry（不修改存储）
```

### 5.8 ADD CONSTRAINT

**功能**：为表添加 CHECK、UNIQUE 或 PRIMARY KEY 约束。

**实现要点**：

```
1. 绑定约束表达式
2. 扫描全表验证所有现有数据满足约束条件
3. 对于 UNIQUE/PRIMARY KEY：
   - 创建对应的 ART 索引
   - 将索引与约束关联
4. 将新约束加入约束列表，返回新的 DuckTableEntry
```

### 5.9 RENAME TABLE / RENAME VIEW

**功能**：重命名表或视图。

**实现要点**：

```
1. 在 CatalogSet 中找到旧名称对应的 Entry
2. 在 CatalogSet 中以新名称创建新 Entry（复制旧 Entry 元数据）
3. 将旧名称的 Entry 标记为 deleted
4. 更新 DependencyManager 中的依赖映射关系（旧名称→新名称）
```

### 5.10 嵌套字段操作（ADD FIELD / REMOVE FIELD / RENAME FIELD）

**功能**：对 STRUCT 类型列的嵌套字段进行结构变更。

**设计要点**：

```
- 适用于 STRUCT 类型的列（含嵌套字段的复合类型）
- ADD FIELD：在 STRUCT 类型中添加新字段
- REMOVE FIELD：从 STRUCT 类型中删除字段
- RENAME FIELD：重命名 STRUCT 中的字段
- 操作路径通过 field_path 向量指定（支持多级嵌套）
- 同样采用 Copy-on-Write，生成新的列类型定义后重建 DuckTableEntry
```

---

## 6. CATALOG 版本管理与 MVCC

### 6.1 设计思路

DuckDB 的 Catalog 实现了 MVCC（多版本并发控制），使不同事务能够看到 Schema 的不同版本，从而支持事务隔离。

### 6.2 核心数据结构

**CatalogSet**（`src/catalog/catalog_set.cpp`）：

```
CatalogSet
    │
    └── CatalogEntryMap（B树）
            name → CatalogEntry 链表（版本链）

              HEAD（最新版本，当前事务可见）
               │
               ▼ child 指针
             旧版本（历史版本）
               │
               ▼
             更旧版本
               │
               ▼
              ...
```

**CatalogEntry.timestamp** 字段含义：

| timestamp 值 | 说明 |
|-------------|------|
| `< TRANSACTION_ID_START`（已提交） | 已提交的历史版本，所有在该时间点之后启动的事务都可见 |
| `>= TRANSACTION_ID_START`（未提交）| 该事务自己创建的版本，仅对该事务可见 |

### 6.3 可见性判断

```cpp
// CatalogSet::UseTimestamp()
bool UseTimestamp(CatalogTransaction transaction, transaction_t timestamp) {
    if (timestamp == transaction.transaction_id) {
        return true;  // 当前事务自己创建的，可见
    }
    if (timestamp < transaction.start_time) {
        return true;  // 在当前事务开始前已提交的，可见
    }
    return false;
}
```

一个事务读取某个 CatalogEntry 时，会沿版本链向下遍历，找到满足 `UseTimestamp()` 的最新版本。

### 6.4 写-写冲突检测

```cpp
// CatalogSet::HasConflict()
bool HasConflict(CatalogTransaction transaction, transaction_t timestamp) {
    // 如果该版本被另一个活跃事务修改，则冲突
    return CreatedByOtherActiveTransaction(transaction, timestamp) ||
           CommittedAfterStarting(transaction, timestamp);
}
```

当两个并发事务都尝试修改同一个 CatalogEntry 时：
- 先提交的事务成功
- 后到的事务收到 `TransactionException: Catalog write-write conflict`

---

## 7. 事务支持与 Undo Buffer

### 7.1 设计思路

DuckDB 使用 **Undo Buffer** 记录所有事务内的变更（包括 Schema 变更），支持：
- 事务回滚（Rollback）
- WAL 提交写入（Commit）

### 7.2 DuckTransaction 结构

```cpp
class DuckTransaction : public Transaction {
    transaction_t start_time;       // 事务开始时间戳
    transaction_t transaction_id;   // 事务唯一 ID
    transaction_t commit_id;        // 提交时间戳
    UndoBuffer undo_buffer;         // 该事务的所有变更记录
    // ...
};
```

`UndoBufferProperties` 记录变更类型：

```cpp
struct UndoBufferProperties {
    bool has_updates = false;           // 行数据更新
    bool has_deletes = false;           // 行数据删除
    bool has_catalog_changes = false;   // Schema 变更（DDL）
    bool has_dropped_entries = false;   // 删除对象
};
```

### 7.3 Schema 变更的记录流程

```
1. 执行 ALTER/CREATE/DROP 操作修改 CatalogSet
2. 在 CatalogSet 中，修改后调用：
   DuckTransactionManager::PushCatalogEntry(*transaction, old_entry)
   将旧的 Entry 版本推入当前事务的 UndoBuffer

3. UndoBuffer 以链表形式存储所有变更条目
   每个条目包含：UndoFlags 类型 + 数据指针（指向旧 CatalogEntry）
```

### 7.4 事务提交与回滚

**提交（顺序遍历 UndoBuffer）**：
```
UndoBuffer::Commit()
  → CommitState::CommitEntry(UndoFlags::CATALOG_ENTRY, data)
  → 将 CatalogEntry.timestamp 从 transaction_id 更新为 commit_id
  → 使 Schema 变更对所有后续事务可见
  → 将变更写入 WAL（WriteAheadLog）
```

**回滚（逆序遍历 UndoBuffer）**：
```
UndoBuffer::Rollback()
  → RollbackState::RollbackEntry(UndoFlags::CATALOG_ENTRY, data)
  → CatalogEntry::UndoAlter(context, *old_entry)
  → CatalogSet::DropEntry(new_entry)  — 移除新版本
  → 旧版本 Entry 重新成为链表头部（当前版本）
```

---

## 8. WAL 持久化机制

### 8.1 设计思路

Write-Ahead Log（WAL）保证数据库崩溃恢复时能重放所有已提交的 Schema 变更。

DuckDB 对每种 DDL 操作都定义了对应的 WAL 类型（`src/include/duckdb/common/enums/wal_type.hpp`）：

```cpp
enum class WALType : uint8_t {
    // Schema 变更
    CREATE_TABLE  = 1,   DROP_TABLE    = 2,
    CREATE_SCHEMA = 3,   DROP_SCHEMA   = 4,
    CREATE_VIEW   = 5,   DROP_VIEW     = 6,
    CREATE_SEQUENCE = 8, DROP_SEQUENCE = 9,
    CREATE_MACRO  = 11,  DROP_MACRO    = 12,
    CREATE_TYPE   = 13,  DROP_TYPE     = 14,
    ALTER_INFO    = 20,  // 所有 ALTER 操作统一使用此类型
    CREATE_TABLE_MACRO = 21, DROP_TABLE_MACRO = 22,
    CREATE_INDEX  = 23,  DROP_INDEX    = 24,
    // 数据操作
    USE_TABLE     = 25,  INSERT_TUPLE  = 26,
    DELETE_TUPLE  = 27,  UPDATE_TUPLE  = 28,
    // 控制
    CHECKPOINT    = 99,  WAL_FLUSH     = 100,
};
```

### 8.2 WAL 写入流程

事务提交时，通过 `UndoBuffer::WriteToWAL()` 将所有变更写入 WAL：

```
CREATE TABLE t (...);
COMMIT;
→ DuckTransaction::Commit()
  → UndoBuffer::WriteToWAL(wal, commit_state)
  → WriteAheadLog::WriteCreateTable(table_entry)
    → 序列化 CreateTableInfo 到 WAL 文件
    → WAL 格式：[WALType=1][序列化长度][CreateTableInfo 二进制数据]
```

ALTER 操作使用统一的 `ALTER_INFO` 类型：

```
ALTER TABLE t ADD COLUMN age INT;
COMMIT;
→ WriteAheadLog::WriteAlter(entry, alter_info)
  → 序列化 AlterInfo（多态，序列化具体子类）到 WAL
  → WAL 格式：[WALType=20][序列化长度][AlterTableInfo 二进制数据]
```

### 8.3 崩溃恢复（WAL Replay）

数据库重启时，`WriteAheadLog::Replay()` 重放 WAL：

```
1. 检查 WAL 文件是否存在
2. 第一遍扫描（DeserializeOnly）：找到最后一个 CHECKPOINT 标记
3. 若已 Checkpoint：当前存储文件已包含所有变更，WAL 可丢弃
4. 若未 Checkpoint：执行第二遍扫描，逐条重放

第二遍重放逻辑（wal_replay.cpp）：
   对每个 WAL 条目：
   ├── CREATE_TABLE  → ReplayCreateTable()  → catalog.CreateTable()
   ├── DROP_TABLE    → ReplayDropTable()    → catalog.DropEntry()
   ├── CREATE_VIEW   → ReplayCreateView()   → catalog.CreateView()
   ├── DROP_VIEW     → ReplayDropView()     → catalog.DropEntry()
   ├── CREATE_INDEX  → ReplayCreateIndex()  → 重建 ART 索引
   ├── ALTER_INFO    → ReplayAlter()        → catalog.Alter()
   │     └── 若 ADD PRIMARY KEY：同时重建索引存储数据
   ├── INSERT_TUPLE  → ReplayInsert()       → 追加行数据
   ├── DELETE_TUPLE  → ReplayDelete()       → 删除行数据
   ├── UPDATE_TUPLE  → ReplayUpdate()       → 更新行数据
   └── WAL_FLUSH     → 提交当前事务，开始下一轮

5. 若 WAL 文件中途损坏（torn write）：回滚到最后成功提交的位置
```

---

## 9. 依赖管理

### 9.1 设计思路

**DependencyManager**（`src/catalog/dependency_manager.cpp`）负责跟踪 Catalog 对象之间的依赖关系，防止因删除被依赖对象而导致引用悬空。

典型依赖场景：
- 视图（VIEW）依赖其引用的表（TABLE）
- 索引（INDEX）依赖其所在的表（TABLE）
- 外键（FOREIGN KEY）依赖目标表
- 宏（MACRO）依赖其引用的函数类型
- 生成列（Generated Column）依赖被引用的其他列

### 9.2 数据结构

DependencyManager 维护两个 CatalogSet（本身也是带版本的目录）：

```
DependencyManager
    ├── subjects（主体集合）：记录"谁依赖了谁"
    │     条目名称格式：
    │     "DEPENDENT_MANGLED_NAME\0DEPENDENCY_MANGLED_NAME"
    │
    └── dependents（被依赖集合）：记录"谁被谁依赖"
          条目名称格式：
          "DEPENDENCY_MANGLED_NAME\0DEPENDENT_MANGLED_NAME"

对象唯一标识（MangledEntryName）格式：
  "CatalogType\0SchemaName\0EntryName"
  例如：TABLE\0main\0users
```

### 9.3 依赖的创建与删除

**创建依赖**（对象创建时）：
```
catalog.CreateTable(table_info) 中的依赖列表被解析
DependencyManager::CreateDependencies(transaction, new_object, dependencies)
  → 对每个被依赖对象：
    subjects.CreateEntry(...)   // new_object 依赖于 dependency
    dependents.CreateEntry(...) // dependency 被 new_object 依赖
```

**删除时的依赖检查**：
```
catalog.DropEntry(drop_info)
  → DependencyManager::DropObject(transaction, entry, cascade)
    → 查询 dependents 中该对象的所有依赖者
    → 若 cascade=false 且存在依赖者：
        抛出异常："Cannot drop X because Y depends on it"
    → 若 cascade=true：
        递归调用 DropObject() 删除所有依赖者，再删除自身
```

---

## 10. 并发控制

### 10.1 DDL 并发模型

DuckDB 通过以下机制控制 Schema 变更的并发安全：

**事务 ID 时间戳**：

```
每个事务有唯一的 transaction_id（单调递增）
DDL 操作的 CatalogEntry 设置 timestamp = 当前事务 ID
只有该事务自身或后续已提交事务才能看到新版本
```

**写-写冲突检测**：

```
两个并发事务同时修改同一对象：
  事务 A 修改了 Entry（timestamp = A.transaction_id）
  事务 B 尝试修改同一 Entry：
    CatalogSet::HasConflict() 检测到冲突
    B 抛出 TransactionException（write-write conflict）
```

**存储级锁（StorageLock）**：

```cpp
// src/include/duckdb/storage/storage_lock.hpp
class StorageLock {
    unique_ptr<StorageLockKey> GetExclusiveLock();  // DDL 操作获取独占锁
    unique_ptr<StorageLockKey> GetSharedLock();     // 读操作获取共享锁
};
```

DDL 操作（特别是 Checkpoint 和物理数据重写）需要获取独占锁，读操作获取共享锁，写操作（DML）通常不阻塞读操作（通过行级 MVCC 实现）。

### 10.2 DDL 与 DML 的并发

DuckDB 目前对同一对象的 DDL 与 DML 并发有以下限制：

- 同一事务内：DDL 和 DML 可以混合（事务中先建表再插入数据）
- 不同事务间：
  - 读操作（SELECT）不阻塞 DDL
  - DDL 和 DDL 之间存在写-写冲突检测
  - ALTER TABLE 需要对目标表独占访问，其他事务对同一表的 DML 可能需要等待

---

## 11. 典型操作完整执行流程示例

### 示例：`ALTER TABLE users ADD COLUMN age INT DEFAULT 18`

```
┌─ SQL ─────────────────────────────────────────────┐
│ ALTER TABLE users ADD COLUMN age INT DEFAULT 18   │
└───────────────────────────────────────────────────┘
         │
         ▼ [Parser: transform_alter_table.cpp]
┌─ AST ─────────────────────────────────────────────┐
│ AlterStatement {                                   │
│   info: AddColumnInfo {                           │
│     table: "users",                               │
│     new_column: ColumnDef{ name:"age", type:INT } │
│     default_value: IntegerConstant(18)            │
│   }                                               │
│ }                                                 │
└───────────────────────────────────────────────────┘
         │
         ▼ [Binder: bind_create.cpp]
┌─ Binding ─────────────────────────────────────────┐
│ - 解析 "users" → 找到 main.users CatalogEntry     │
│ - 绑定 INT 类型                                    │
│ - 绑定默认值表达式: IntegerConstant(18)            │
│ - 注册 DB 修改 (RegisterDBModify)                  │
│ 输出: BoundStatement{ LogicalAlter }               │
└───────────────────────────────────────────────────┘
         │
         ▼ [Physical Plan: 生成 PhysicalAlter]
┌─ Execution: PhysicalAlter::GetData() ─────────────┐
│ catalog.Alter(context, add_column_info)            │
└───────────────────────────────────────────────────┘
         │
         ▼ [Catalog: duck_table_entry.cpp: AddColumn()]
┌─ Catalog Layer ────────────────────────────────────┐
│ 1. 复制所有现有列和约束                             │
│ 2. 追加新列 age:INT，绑定默认值 18                 │
│ 3. 创建新 DataTable（新增一个物理列，不重写旧数据） │
│ 4. 返回新 DuckTableEntry（新版本）                  │
└───────────────────────────────────────────────────┘
         │
         ▼ [CatalogSet: UpdateEntry()]
┌─ CatalogSet ───────────────────────────────────────┐
│ 新版本 Entry (timestamp=T_txn)                     │
│   └── child → 旧版本 Entry (timestamp=T_prev)      │
│ 当前事务可见新版本；其他并发事务仍看旧版本          │
└───────────────────────────────────────────────────┘
         │
         ▼ [Transaction Commit]
┌─ Commit ───────────────────────────────────────────┐
│ 1. UndoBuffer::Commit()                            │
│    - 将新 Entry timestamp 从 T_txn 改为 T_commit   │
│    - 新 Schema 对所有后续事务可见                   │
│ 2. WriteAheadLog::WriteAlter(entry, add_col_info)  │
│    - 序列化 AddColumnInfo 到 WAL 文件              │
│    - WAL: [ALTER_INFO][len][AddColumnInfo bytes]   │
└───────────────────────────────────────────────────┘
```

---

## 附录：主要源码文件索引

| 功能 | 源码路径 |
|------|---------|
| ALTER TABLE 类型定义 | `src/include/duckdb/parser/parsed_data/alter_table_info.hpp` |
| CREATE 信息数据结构 | `src/include/duckdb/parser/parsed_data/create_*.hpp` |
| DROP 信息数据结构 | `src/include/duckdb/parser/parsed_data/drop_info.hpp` |
| WAL 类型定义 | `src/include/duckdb/common/enums/wal_type.hpp` |
| Parser ALTER 转换 | `src/parser/transform/statement/transform_alter_table.cpp` |
| Parser CREATE 转换 | `src/parser/transform/statement/transform_create_table.cpp` |
| Binder CREATE | `src/planner/binder/statement/bind_create.cpp` |
| Binder CREATE TABLE | `src/planner/binder/statement/bind_create_table.cpp` |
| Binder DROP | `src/planner/binder/statement/bind_drop.cpp` |
| Physical ALTER | `src/execution/operator/schema/physical_alter.cpp` |
| Physical DROP | `src/execution/operator/schema/physical_drop.cpp` |
| Physical CREATE TABLE | `src/execution/operator/schema/physical_create_table.cpp` |
| Physical CREATE INDEX | `src/execution/operator/schema/physical_create_art_index.cpp` |
| Catalog 入口 | `src/catalog/catalog.cpp` |
| CatalogSet 版本管理 | `src/catalog/catalog_set.cpp` |
| Table ALTER 实现 | `src/catalog/catalog_entry/duck_table_entry.cpp` |
| Schema Entry | `src/catalog/catalog_entry/duck_schema_entry.cpp` |
| 依赖管理 | `src/catalog/dependency_manager.cpp` |
| 事务实现 | `src/transaction/duck_transaction.cpp` |
| Undo Buffer | `src/transaction/undo_buffer.cpp` |
| WAL 写入 | `src/storage/write_ahead_log.cpp` |
| WAL 回放 | `src/storage/wal_replay.cpp` |
