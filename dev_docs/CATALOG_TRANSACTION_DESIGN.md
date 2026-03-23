# DuckDB 元数据（Catalog）管理与事务支持设计文档

## 概述

本文档整理了 DuckDB 内部元数据（Catalog）管理系统的核心设计，重点说明事务支持机制，为开发需要元数据管理能力的插件提供参考。

---

## 一、总体架构

DuckDB 的元数据管理系统（Catalog）负责跟踪数据库中所有对象（表、视图、函数、类型、序列、模式等）的定义信息。其核心层次结构如下：

```
DatabaseInstance
  └── AttachedDatabase
        └── DuckCatalog          ← 具体的 Catalog 实现
              ├── CatalogSet (schemas)    ← 所有 Schema 的集合
              │     └── SchemaCatalogEntry
              │           └── CatalogSet (tables/views/functions/...)
              │                 └── CatalogEntry (具体对象)
              └── DependencyManager     ← 依赖关系管理
```

**关键源码位置：**

| 文件 | 说明 |
|------|------|
| `src/include/duckdb/catalog/catalog.hpp` | Catalog 抽象基类 |
| `src/include/duckdb/catalog/duck_catalog.hpp` | DuckDB 具体 Catalog 实现 |
| `src/include/duckdb/catalog/catalog_entry.hpp` | Catalog 条目基类 |
| `src/include/duckdb/catalog/catalog_set.hpp` | 带版本管理的条目集合 |
| `src/include/duckdb/catalog/catalog_transaction.hpp` | Catalog 操作的事务上下文 |
| `src/include/duckdb/catalog/dependency_manager.hpp` | 对象间依赖关系管理 |
| `src/catalog/catalog_set.cpp` | MVCC 版本链核心逻辑 |
| `src/transaction/undo_buffer.hpp` | 回滚所需的 Undo Buffer |
| `src/include/duckdb/transaction/duck_transaction.hpp` | 事务对象（含 Undo Buffer） |

---

## 二、Catalog 事务支持

### 2.1 事务上下文：CatalogTransaction

所有 Catalog 操作（创建、删除、修改对象）都通过 `CatalogTransaction` 传递事务上下文。

```cpp
// src/include/duckdb/catalog/catalog_transaction.hpp
struct CatalogTransaction {
    optional_ptr<DatabaseInstance> db;
    optional_ptr<ClientContext>   context;
    optional_ptr<Transaction>     transaction;
    transaction_t transaction_id;  // 当前事务 ID
    transaction_t start_time;      // 事务开始时间戳
};
```

- `transaction_id`：活跃事务的唯一标识，值 `>= TRANSACTION_ID_START`（精确值 `4611686018427388000`，约 2^62，定义于 `src/common/constants.cpp`）。
- `start_time`：事务开始时的全局时间戳，用于快照隔离判断。

### 2.2 MVCC：基于版本链的多版本并发控制

`CatalogSet` 中每个条目通过 **版本链（version chain）** 实现 MVCC：

```
map["table_name"]
  └── CatalogEntry (最新版本，root)    timestamp = 正在提交的事务ID 或 已提交时间戳
        └── child: CatalogEntry (上一版本)
              └── child: CatalogEntry (更早版本)
```

- **root 节点** = 最新版本（或当前活跃写事务创建的版本）
- **child 链** = 历史版本，用于旧事务的快照读

**时间戳语义（`src/catalog/catalog_set.cpp`）：**

```cpp
// 已提交的条目：timestamp < TRANSACTION_ID_START（通常为提交时的 commit_id）
// 未提交的条目：timestamp == 当前事务的 transaction_id（>= TRANSACTION_ID_START）

bool CatalogSet::UseTimestamp(CatalogTransaction transaction, transaction_t timestamp) {
    if (timestamp == transaction.transaction_id) {
        return true;  // 当前事务自己创建的版本，可见
    }
    if (timestamp < transaction.start_time) {
        return true;  // 在本事务启动之前已提交，可见
    }
    return false;     // 其他事务提交的（比本事务晚），不可见
}
```

**版本查找（快照读）：**

```cpp
CatalogEntry &CatalogSet::GetEntryForTransaction(CatalogTransaction transaction, CatalogEntry &current) {
    reference<CatalogEntry> entry(current);
    while (entry.get().HasChild()) {
        if (UseTimestamp(transaction, entry.get().timestamp)) {
            return entry.get();  // 找到对本事务可见的版本
        }
        entry = entry.get().Child();  // 沿版本链向历史方向遍历
    }
    return entry.get();
}
```

### 2.3 写写冲突检测

当两个并发事务试图修改同一 Catalog 对象时，DuckDB 使用**乐观并发控制**检测冲突：

```cpp
bool CatalogSet::HasConflict(CatalogTransaction transaction, transaction_t timestamp) {
    // 另一个活跃事务已修改此条目（未提交）
    bool by_other_active = (timestamp >= TRANSACTION_ID_START &&
                             timestamp != transaction.transaction_id);
    // 另一个事务在本事务启动后提交了修改
    bool committed_after = (timestamp < TRANSACTION_ID_START &&
                             timestamp > transaction.start_time);
    return by_other_active || committed_after;
}
```

如果检测到冲突，会抛出 `TransactionException`（write-write conflict），当前事务必须中止。

### 2.4 创建新条目的完整流程

以 `CatalogSet::CreateEntry()` 为例（`src/catalog/catalog_set.cpp`）：

```
1. 将新 entry 的 timestamp 设为 transaction.transaction_id（标记为"未提交"）
2. 获取 DuckCatalog::write_lock（互斥写锁，防止并发写）
3. 获取 CatalogSet::catalog_lock（读锁，防止读写竞争）
4. 调用 DependencyManager::AddObject() 注册依赖关系
5. 调用 CatalogEntryMap::UpdateEntry()，将新 entry 插入版本链头部
6. 将旧 entry（child）压入事务的 Undo Buffer（用于回滚）
```

### 2.5 Undo Buffer：支持回滚

`DuckTransaction` 内含一个 `UndoBuffer`，用于在事务回滚时还原 Catalog 状态。

```cpp
// src/include/duckdb/transaction/duck_transaction.hpp
class DuckTransaction : public Transaction {
    UndoBuffer undo_buffer;
    void PushCatalogEntry(CatalogEntry &entry,
                          data_ptr_t extra_data, idx_t extra_data_size);
    ...
};
```

**回滚流程（`CatalogSet::Undo()`）：**

```
1. 从 Undo Buffer 取出被替换的旧 entry
2. 调用 CatalogSet::Undo(old_entry)
3. 在版本链中移除新 entry（由当前事务创建）
4. 将旧 entry 恢复为 root（当前可见版本）
```

### 2.6 提交流程

```
1. DuckTransaction::Commit() 被调用
2. UndoBuffer::WriteToWAL()：将 Catalog 变更写入 WAL（Write-Ahead Log）
3. UndoBuffer::Commit()：将所有 entry 的 timestamp 更新为 commit_id（< TRANSACTION_ID_START）
4. DuckTransactionManager 更新 catalog_version（全局版本号）
5. UndoBuffer::Cleanup()：清理不再需要的旧版本
```

---

## 三、WAL（Write-Ahead Log）与 Catalog

每次提交 Catalog 变更时，DuckDB 都会将操作记录到 WAL，以支持崩溃恢复。

WAL 中 Catalog 相关的操作类型（`src/include/duckdb/common/enums/wal_type.hpp`）：

| WAL 类型 | 值 | 说明 |
|----------|----|------|
| `CREATE_TABLE` | 1 | 创建表 |
| `DROP_TABLE` | 2 | 删除表 |
| `CREATE_SCHEMA` | 3 | 创建 Schema |
| `DROP_SCHEMA` | 4 | 删除 Schema |
| `CREATE_VIEW` | 5 | 创建视图 |
| `DROP_VIEW` | 6 | 删除视图 |
| *(7 号值不存在于枚举，为历史保留的空位)* | 7 | — |
| `CREATE_SEQUENCE` | 8 | 创建序列 |
| `DROP_SEQUENCE` | 9 | 删除序列 |
| `SEQUENCE_VALUE` | 10 | 序列当前值更新 |
| `CREATE_MACRO` | 11 | 创建宏 |
| `DROP_MACRO` | 12 | 删除宏 |
| `CREATE_TYPE` | 13 | 创建类型 |
| `DROP_TYPE` | 14 | 删除类型 |
| `ALTER_INFO` | 20 | 修改对象 |
| `CREATE_TABLE_MACRO` | 21 | 创建表宏 |
| `DROP_TABLE_MACRO` | 22 | 删除表宏 |
| `CREATE_INDEX` | 23 | 创建索引 |
| `DROP_INDEX` | 24 | 删除索引 |

**注意：** 标记了 `temporary = true` 的 Catalog 条目不会写入 WAL。

---

## 四、依赖管理（DependencyManager）

`DependencyManager`（`src/include/duckdb/catalog/dependency_manager.hpp`）维护 Catalog 对象间的依赖关系，保证以下语义：

- **级联删除（CASCADE）**：删除父对象时自动删除依赖对象
- **阻止删除（RESTRICT）**：存在依赖时阻止删除父对象
- **所有权（OWNERSHIP）**：一个对象"拥有"另一个对象（被拥有者随所有者生命周期）

依赖关系本身也存储在两个 `CatalogSet` 中（`subjects`、`dependents`），因此**依赖关系的创建和删除也参与事务**，与普通 Catalog 操作具有相同的 ACID 语义。

---

## 五、Catalog 条目类型

DuckDB 支持以下 Catalog 对象类型（`src/include/duckdb/common/enums/catalog_type.hpp`）：

| 类型 | 说明 |
|------|------|
| `TABLE_ENTRY` | 普通表 |
| `SCHEMA_ENTRY` | Schema（命名空间） |
| `VIEW_ENTRY` | 视图 |
| `INDEX_ENTRY` | 索引 |
| `SEQUENCE_ENTRY` | 序列 |
| `TYPE_ENTRY` | 自定义类型 |
| `SCALAR_FUNCTION_ENTRY` | 标量函数 |
| `AGGREGATE_FUNCTION_ENTRY` | 聚合函数 |
| `TABLE_FUNCTION_ENTRY` | 表值函数 |
| `PRAGMA_FUNCTION_ENTRY` | Pragma 函数 |
| `MACRO_ENTRY` / `TABLE_MACRO_ENTRY` | 宏 |
| `COLLATION_ENTRY` | 排序规则 |
| `DATABASE_ENTRY` | 附加数据库 |
| `SECRET_ENTRY` | 密钥/认证信息 |
| `DEPENDENCY_ENTRY` | 依赖关系（内部） |

---

## 六、插件（Extension）元数据管理指南

### 6.1 DuckDB 插件元数据现状

插件可以通过以下方式与 Catalog 集成：

1. **注册函数**（最常见）：通过 `CreateScalarFunction`、`CreateTableFunction` 等将函数注册到 Catalog，**自动获得事务支持**。
2. **注册自定义类型**：通过 `CreateType` 注册类型，**自动获得事务支持**。
3. **注册表**：插件可以通过 `CreateTable` 在用户 Schema 中创建元数据表。
4. **使用 Secret Manager**：`duckdb_secrets` 系统表管理认证信息（如云存储的 key/secret）。

### 6.2 是否需要在插件中自行实现事务支持？

**结论：通常不需要。** 推荐复用 DuckDB 的 Catalog 事务机制。

| 场景 | 建议 |
|------|------|
| 插件元数据是"函数/类型/视图"定义 | 直接注册到 DuckDB Catalog，自动获得 MVCC 和事务支持 |
| 插件需要持久化少量配置/元数据 | 在用户 Schema 中创建普通表存储，使用标准 DML，享受完整事务语义 |
| 插件需要持久化大量复杂状态 | 可以在内部使用 DuckDB 嵌入一个内存/文件数据库，或使用标准表 |
| 插件元数据是临时的（进程生命周期内） | 注册 `temporary = true` 的 Catalog 条目，不写 WAL，不持久化 |
| 插件需要管理外部系统的元数据 | 考虑使用 `AttachDatabase` 机制，或自行维护外部存储（这时需要自行实现事务） |

### 6.3 推荐的插件元数据管理方案

**方案 A（推荐）：将元数据存储在 DuckDB 表中**

```sql
-- 在插件初始化时创建元数据表（在用户数据库中）
CREATE TABLE IF NOT EXISTS my_extension_metadata (
    key   VARCHAR PRIMARY KEY,
    value VARCHAR,
    updated_at TIMESTAMP DEFAULT now()
);
```

- 优点：完全复用 DuckDB 的 ACID 事务、WAL、MVCC
- 缺点：元数据与用户数据混在一起（可通过独立 Schema 隔离）

**方案 B：注册为 Catalog 对象**

将插件自定义类型、函数、宏等直接通过 Catalog API 注册，DuckDB 会自动管理这些对象的生命周期和事务一致性。

```cpp
// 在插件加载时注册
auto &catalog = Catalog::GetSystemCatalog(*db);
catalog.CreateFunction(context, create_function_info);
```

**方案 C：使用独立附加数据库**

对于需要隔离的插件元数据，可以附加一个专用数据库文件：

```sql
ATTACH 'my_extension_state.db' AS ext_db;
-- 之后所有写操作发生在 ext_db 中，有独立的事务和 WAL
```

### 6.4 需要自行实现事务的场景

以下情况**可能需要**在插件中自行实现事务逻辑：

1. **外部系统同步**：元数据需要与 DuckDB 外部的系统（如 Hive Metastore、外部注册中心）保持一致，需要实现两阶段提交或补偿事务。
2. **自定义 Catalog 实现**：如果插件实现了自定义 `Catalog` 接口（如 `iceberg`、`postgres` 插件），需要在 `CreateEntry`/`AlterEntry`/`DropEntry` 中自行处理外部元数据事务。
3. **高频写入元数据**：如果插件元数据写入频率极高，标准 Catalog 的写锁可能成为瓶颈，需要评估是否需要自定义并发控制。

---

## 七、关键设计原则总结

| 原则 | DuckDB 的实现 |
|------|---------------|
| **原子性（Atomicity）** | Undo Buffer 保证事务内所有 Catalog 变更要么全部提交，要么全部回滚 |
| **一致性（Consistency）** | 写写冲突检测（`HasConflict`）+ DependencyManager 保证约束 |
| **隔离性（Isolation）** | MVCC 版本链 + `start_time` 快照隔离，不同事务看到各自一致的视图 |
| **持久性（Durability）** | 提交前写 WAL，崩溃后可通过 WAL 重放恢复 Catalog 状态 |
| **并发写** | 同一时间只有一个事务能修改同一 Catalog 对象（乐观锁 + write_lock） |
| **并发读** | MVCC 保证读操作无阻塞 |

---

## 八、参考源码

- `src/catalog/catalog_set.cpp` — MVCC 核心逻辑（`GetEntryForTransaction`, `Undo`, `CreateEntry`）
- `src/transaction/duck_transaction.cpp` — 事务提交/回滚流程
- `src/transaction/undo_buffer.cpp` — Undo Buffer 的写入与回滚
- `src/transaction/commit_state.cpp` — 提交时的 WAL 写入
- `src/transaction/rollback_state.cpp` — 回滚时恢复 Catalog 状态
- `src/catalog/dependency_manager.cpp` — 依赖关系的事务性创建和删除
