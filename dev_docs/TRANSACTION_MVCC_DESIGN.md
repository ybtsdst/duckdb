# DuckDB 事务实现机制与 MVCC 设计文档

## 概述

本文档整理 DuckDB 的事务实现机制，说明 ACID 四个属性分别如何保证，重点分析基于 MVCC（Multi-Version Concurrency Control，多版本并发控制）的隔离性实现。

---

## 一、ACID 总览

| 属性 | 保证机制 |
|------|---------|
| **原子性（Atomicity）** | `UndoBuffer` — 所有变更统一记录，Rollback 时逆向撤销 |
| **一致性（Consistency）** | 约束检查（主键/外键/唯一索引） + `DependencyManager` 依赖关系验证 |
| **隔离性（Isolation）** | MVCC 快照隔离（Snapshot Isolation）— `ChunkInfo` / `RowVersionManager` / `UpdateInfo` 版本链 |
| **持久性（Durability）** | Write-Ahead Log（WAL）— 提交前先写日志，崩溃后可重放恢复 |

---

## 二、关键数据结构与源码位置

### 2.1 事务对象

**`DuckTransaction`**（`src/include/duckdb/transaction/duck_transaction.hpp`）

```cpp
class DuckTransaction : public Transaction {
public:
    transaction_t start_time;        // 事务开始时的全局时间戳（用于快照读）
    transaction_t transaction_id;    // 事务唯一 ID（>= TRANSACTION_ID_START ≈ 2^62）
    transaction_t commit_id;         // 提交后赋值的提交时间戳
    transaction_t highest_active_query; // 用于 GC 判断

private:
    UndoBuffer undo_buffer;          // 存储旧版本数据（供回滚和可见性判断使用）
    unique_ptr<LocalStorage> storage; // 事务本地未提交数据
    unique_ptr<StorageLockKey> write_lock; // 持有共享 Checkpoint 锁
};
```

**`DuckTransactionManager`**（`src/include/duckdb/transaction/duck_transaction_manager.hpp`）

```cpp
class DuckTransactionManager : public TransactionManager {
    transaction_t current_start_timestamp;  // 自增，为每个新事务分配 start_time（从 2 开始）
    transaction_t current_transaction_id;   // 自增，为每个新事务分配 transaction_id（从 TRANSACTION_ID_START 开始）
    atomic<transaction_t> lowest_active_id;   // 当前最低活跃事务 ID（用于 GC）
    atomic<transaction_t> lowest_active_start; // 当前最低活跃 start_time（用于 GC）

    vector<unique_ptr<DuckTransaction>> active_transactions;            // 当前活跃事务
    vector<unique_ptr<DuckTransaction>> recently_committed_transactions; // 最近提交的事务（等待 GC）
    vector<unique_ptr<DuckTransaction>> old_transactions;               // 待 GC 的旧事务

    mutex transaction_lock;         // 保护活跃事务列表
    mutex start_transaction_lock;   // 串行化读写事务的开启
    StorageLock checkpoint_lock;    // 协调事务与 Checkpoint
};
```

**时间戳语义关键设计**：
- `start_time` 从 2 开始单调递增（普通时间戳域）
- `transaction_id` 从 `TRANSACTION_ID_START`（约 2^62）开始单调递增

这一设计保证：若某个版本号 `id < TRANSACTION_ID_START`，则它一定是已提交的 commit_id；若 `id >= TRANSACTION_ID_START`，则它是某个活跃事务的 transaction_id（未提交）。

---

### 2.2 行版本信息（MVCC 核心）

DuckDB 存储层以 **RowGroup → Vector（每向量 STANDARD_VECTOR_SIZE = 2048 行）** 为单位组织数据。每个 Vector 的行可见性由 `ChunkInfo` 管理。

**`ChunkInfo` 继承体系**（`src/include/duckdb/storage/table/chunk_info.hpp`）：

```
ChunkInfo（抽象基类）
├── ChunkConstantInfo   // 整个 Vector 所有行的 insert_id / delete_id 相同（批量插入常见）
└── ChunkVectorInfo     // 每行独立记录 inserted[i] 和 deleted[i]
```

```cpp
class ChunkConstantInfo : public ChunkInfo {
    transaction_t insert_id;    // 该 Vector 所有行的插入版本号
    transaction_t delete_id;    // 该 Vector 所有行的删除版本号（NOT_DELETED_ID 表示未删除）
};

class ChunkVectorInfo : public ChunkInfo {
    transaction_t inserted[STANDARD_VECTOR_SIZE]; // 每行的插入版本号
    transaction_t deleted[STANDARD_VECTOR_SIZE];  // 每行的删除版本号
    transaction_t insert_id;     // 快速路径：所有行 insert_id 相同时的缓存值
    bool same_inserted_id;       // 标记是否所有行 insert_id 一致
    bool any_deleted;            // 标记是否有任何行被删除
};
```

**`RowVersionManager`** （`src/include/duckdb/storage/table/row_version_manager.hpp`）：管理一个 RowGroup 内所有 Vector 的版本信息。

---

### 2.3 更新版本链（Update Chain）

UPDATE 操作不直接修改原始数据，而是通过版本链保存历史值。

**`UpdateInfo`**（`src/include/duckdb/transaction/update_info.hpp`）：

```cpp
struct UpdateInfo {
    UpdateSegment *segment;       // 所属的 UpdateSegment
    DataTable *table;             // 所属表
    idx_t column_index;           // 修改的列
    atomic<transaction_t> version_number; // 该版本的事务 ID（未提交）或 commit_id（已提交）
    idx_t vector_index;           // 在 segment 内的 Vector 索引
    sel_t N;                      // 本条目更新的行数
    UndoBufferPointer prev;       // 指向更老版本（undo buffer 中）
    UndoBufferPointer next;       // 指向更新版本（undo buffer 中）
    // 紧随其后的内存：[sel_t rows[max]][T values[max]]
};
```

版本链遍历逻辑（`UpdateInfo::UpdatesForTransaction`）：

```cpp
// 从最新版本向旧版本遍历，找到对当前事务可见的版本集合
bool AppliesToTransaction(transaction_t start_time, transaction_t transaction_id) {
    // version_number > start_time 表示该更新发生在本事务开始之后（不可见）
    // version_number == transaction_id 表示该更新是本事务自己做的（也需要应用）
    return version_number > start_time && version_number != transaction_id;
}
```

---

### 2.4 Undo Buffer

**`UndoBuffer`**（`src/include/duckdb/transaction/undo_buffer.hpp`）：每个 `DuckTransaction` 独占一个 `UndoBuffer`，按顺序记录该事务所做的所有变更，用于回滚和版本可见性。

Undo Buffer 内存布局（按写入顺序线性存放）：

```
[UndoFlags (4B)][Length (4B)][Entry Data ...]
[UndoFlags (4B)][Length (4B)][Entry Data ...]
...
```

Entry 类型（`src/include/duckdb/common/enums/undo_flags.hpp`）：

| UndoFlags | 对应结构 | 说明 |
|-----------|---------|------|
| `CATALOG_ENTRY` | `CatalogEntry *` | Catalog 对象变更（建表/删表/改表等） |
| `INSERT_TUPLE` | `AppendInfo` | 追加行（记录 start_row + count） |
| `DELETE_TUPLE` | `DeleteInfo` | 删除行 |
| `UPDATE_TUPLE` | `UpdateInfo` | 更新列值（含版本链头指针） |
| `SEQUENCE_VALUE` | `SequenceValue` | 序列值变更 |
| `ATTACHED_DATABASE` | `AttachedDatabase *` | 附加数据库操作 |

---

## 三、事务生命周期

### 3.1 开始事务（StartTransaction）

```
1. 若为读写事务，获取 start_transaction_lock（防止 FORCE CHECKPOINT 期间新事务开启）
2. 获取 transaction_lock
3. 分配 start_time = current_start_timestamp++
4. 分配 transaction_id = current_transaction_id++
5. 若 active_transactions 为空，更新 lowest_active_start / lowest_active_id
6. 创建 DuckTransaction（含空 UndoBuffer 和 LocalStorage）
7. 加入 active_transactions
```

### 3.2 执行期间

所有写操作先作用于事务的 `LocalStorage`（内存中未提交数据），同时向 `UndoBuffer` 写入对应条目：

- **INSERT**：追加到 LocalStorage 的本地 RowGroupCollection；调用 `PushAppend` 写 `INSERT_TUPLE` 到 Undo Buffer；在 `ChunkInfo` 中，该行的 `inserted[i] = transaction_id`（未提交标记）
- **DELETE**：在 `ChunkVectorInfo::Delete` 中将 `deleted[row] = transaction_id`；调用 `PushDelete` 写 `DELETE_TUPLE` 到 Undo Buffer
- **UPDATE**：在 `UpdateSegment` 中创建新的 `UpdateInfo`，`version_number = transaction_id`；调用 `CreateUpdateInfo` 写 `UPDATE_TUPLE` 到 Undo Buffer；原始数据保存在 UpdateInfo 链中

**写写冲突检测**（乐观锁）：  
删除时若发现 `deleted[row] != NOT_DELETED_ID`（即已被另一事务删除），立即抛出 `TransactionException("Conflict on tuple deletion!")`。更新时通过 `UpdateSegment` 中的独占锁防止并发更新同一 UpdateInfo。

### 3.3 提交（Commit）

```
1. DuckTransactionManager::CommitTransaction()
   a. 获取 transaction_lock
   b. 调用 GetCommitTimestamp() 分配 commit_id（= current_start_timestamp++）
   c. 调用 DuckTransaction::WriteToWAL() — 将 Undo Buffer 中的变更序列化到 WAL 文件
   d. 调用 DuckTransaction::Commit(commit_id)
      i.  storage->Commit() — 将 LocalStorage 的追加数据合并到全局 RowGroup
      ii. undo_buffer.Commit(commit_id) — 遍历 Undo Buffer：
          - INSERT_TUPLE：调用 ChunkInfo::CommitAppend(commit_id)，将 inserted[i] 由 transaction_id 改为 commit_id
          - DELETE_TUPLE：调用 ChunkVectorInfo::CommitDelete(commit_id)，将 deleted[i] 由 transaction_id 改为 commit_id
          - UPDATE_TUPLE：将 UpdateInfo::version_number 由 transaction_id 改为 commit_id
          - CATALOG_ENTRY：将 CatalogEntry::timestamp 改为 commit_id
      iii. 若有 WAL 写入，flush 到磁盘
2. 从 active_transactions 移出，加入 recently_committed_transactions
3. 更新 lowest_active_start / lowest_active_id
4. 触发 GC（见 3.5）
```

### 3.4 回滚（Rollback）

```
1. storage->Rollback() — 丢弃 LocalStorage（所有未提交追加）
2. undo_buffer.Rollback() — 逆序遍历 Undo Buffer：
   - CATALOG_ENTRY：调用 CatalogSet::Undo() 恢复旧版本条目
   - INSERT_TUPLE：调用 DataTable::RevertAppend() 撤销追加
   - DELETE_TUPLE：调用 ChunkVectorInfo::CommitDelete(NOT_DELETED_ID) 恢复为"未删除"
   - UPDATE_TUPLE：调用 UpdateSegment::RollbackUpdate() 恢复原始值
3. 从 active_transactions 移出
```

### 3.5 清理（Cleanup / GC）

当一个已提交事务的数据对所有当前活跃事务都不再需要时（`commit_id < lowest_active_start`），可安全清理其 Undo Buffer：

```
1. 满足清理条件的事务进入 old_transactions
2. 异步执行 DuckTransaction::Cleanup(lowest_active_transaction)
3. undo_buffer.Cleanup() 遍历：
   - INSERT_TUPLE：调用 DataTable::CleanupAppend() 移除 ChunkConstantInfo（不再需要版本信息）
   - DELETE_TUPLE：从 ART 索引中删除对应条目
   - UPDATE_TUPLE：调用 UpdateSegment::CleanupUpdate() 从版本链中移除已无用的 UpdateInfo
   - CATALOG_ENTRY：调用 CatalogSet::CleanupEntry() 删除旧版本的 CatalogEntry
```

---

## 四、MVCC 可见性判断

### 4.1 核心可见性规则

DuckDB 实现的是 **快照隔离（Snapshot Isolation）**：每个事务看到一个一致的数据快照，该快照对应事务开始时（`start_time`）已提交的所有数据。

**`TransactionVersionOperator`**（`src/storage/table/chunk_info.cpp`）：

```cpp
struct TransactionVersionOperator {
    // 判断一行是否对当前事务"可插入可见"（即该行的插入是可见的）
    static bool UseInsertedVersion(transaction_t start_time, transaction_t transaction_id, transaction_t id) {
        return id < start_time       // 该行在本事务开始前已提交（commit_id < start_time）
            || id == transaction_id; // 该行是本事务自己插入的（尚未提交也可见）
    }

    // 判断一行的删除是否对当前事务可见（若删除可见，则该行对本事务不可见）
    static bool UseDeletedVersion(transaction_t start_time, transaction_t transaction_id, transaction_t id) {
        return !UseInsertedVersion(start_time, transaction_id, id);
    }
};
```

**一行对当前事务可见的完整条件**：

```
visible = UseInsertedVersion(insert_id) && UseDeletedVersion(delete_id)
         = (insert_id < start_time || insert_id == transaction_id)
           && !(delete_id < start_time || delete_id == transaction_id)
```

即：
- 该行的**插入**发生在本事务快照之前（已提交），或者是本事务自己插入的；
- 该行的**删除**对本事务不可见（删除发生在本事务开始之后，或尚未提交且不是本事务删除的）。

### 4.2 UPDATE 的可见性（UpdateInfo 版本链）

读取某行某列时，从列段（UpdateSegment）的最新 UpdateInfo 开始向旧版本遍历，找到所有对当前事务"应该应用"的更新：

```cpp
bool AppliesToTransaction(transaction_t start_time, transaction_t transaction_id) {
    // version_number > start_time：该 UPDATE 在本事务快照之后发生 → 需要用旧值（跳过该更新，用链中更旧的版本）
    // version_number == transaction_id：本事务自己做的更新 → 本事务可以看到自己的更新
    return version_number > start_time && version_number != transaction_id;
}
```

实际语义：若 `AppliesToTransaction` 为 true，则该 UpdateInfo 存储的是"从该版本的值还原到更旧值所需的旧数据"（即 undo 数据），需要应用以得到本事务应看到的值。

### 4.3 快照隔离的隔离级别分析

| 异常 | DuckDB 是否存在 |
|------|---------------|
| 脏读（Dirty Read） | **不存在** — 未提交数据（transaction_id >= TRANSACTION_ID_START）对其他事务不可见 |
| 不可重复读（Non-Repeatable Read） | **不存在** — 同一事务使用固定 start_time 快照 |
| 幻读（Phantom Read） | **不存在（通常）** — 新插入行的 insert_id > start_time，对已开始事务不可见 |
| 写偏（Write Skew） | **理论上存在** — 快照隔离的固有特性，DuckDB 不提供串行化（Serializable）隔离 |

---

## 五、原子性（Atomicity）详解

原子性由 `UndoBuffer` 的回滚机制保证：

1. 事务执行的每一步变更都被记录为 Undo Buffer 中的一个条目
2. 发生回滚时，**逆序**遍历 Undo Buffer 并逐条撤销：
   - Catalog 变更：恢复旧版本条目进入版本链
   - 行追加：将已插入的行标记为回滚（`RevertAppend`）
   - 行删除：将 `deleted[row]` 重置为 `NOT_DELETED_ID`
   - 行更新：从 UpdateInfo 版本链中移除本事务的版本，恢复原始值
3. 所有撤销完成后，事务的所有变更对外均不可见

---

## 六、持久性（Durability）详解

持久性通过 **Write-Ahead Log（WAL）** 实现：

```
提交流程：
1. DuckTransaction::WriteToWAL()
   ↓
2. 遍历 Undo Buffer，将变更写入 WAL 文件
   - Catalog 变更：写 CREATE/DROP/ALTER 记录
   - 行追加：写 INSERT 记录
   - 行删除：写 DELETE 记录
   - 行更新：写 UPDATE 记录
   ↓
3. Flush WAL 文件到磁盘（fsync）
   ↓
4. 内存中应用 commit（更新所有 ChunkInfo 版本号为 commit_id）
```

崩溃恢复时，DuckDB 重放 WAL 文件中未 Checkpoint 的记录，将数据库恢复到崩溃前最后一次成功提交的状态。

**Checkpoint**：WAL 文件积累到一定大小后，DuckDB 将全部内存数据持久化到主数据库文件（`.db`），然后截断 WAL。Checkpoint 需要获取独占的 `checkpoint_lock`，与所有读写事务共享锁互斥，保证 Checkpoint 时无未提交事务。

---

## 七、并发控制与锁

| 锁 | 位置 | 用途 |
|---|------|------|
| `transaction_lock` | `DuckTransactionManager` | 保护 `active_transactions` 等列表的并发访问 |
| `start_transaction_lock` | `DuckTransactionManager` | 读写事务开始时串行化，防止 FORCE CHECKPOINT 期间新事务开启 |
| `version_lock` | `RowVersionManager` | 保护 `vector_info` 数组的并发修改 |
| `StorageLock (checkpoint_lock)` | `DuckTransactionManager` | 协调事务（共享锁）与 Checkpoint（独占锁） |
| `DuckCatalog::write_lock` | `DuckCatalog` | Catalog 写操作互斥（防止并发 DDL） |
| `cleanup_lock` | `DuckTransactionManager` | 保证 GC 串行执行（防止乱序 Cleanup 引发 Catalog 错误） |

**乐观并发控制（Optimistic Concurrency Control）**：  
DuckDB 的数据行版本更新不使用悲观锁，而是在写入时检测冲突。对于 DELETE 操作，若发现目标行已被另一活跃事务删除（`deleted[row] != NOT_DELETED_ID`），直接抛出异常回滚当前事务，而不是等待。

---

## 八、LocalStorage（事务本地存储）

`LocalTableStorage` （`src/include/duckdb/transaction/local_storage.hpp`）是事务期间存储未提交追加数据的结构：

- 每个被修改的表对应一个 `LocalTableStorage`
- 内部使用独立的 `RowGroupCollection`（与全局 RowGroup 隔离）
- 事务扫描时会合并全局存储与 LocalStorage 的结果
- 提交时，LocalStorage 的数据通过 `OptimisticDataWriter` 写入全局 RowGroup
- 回滚时，直接丢弃 LocalStorage

---

## 九、跨数据库事务（MetaTransaction）

**`MetaTransaction`**（`src/include/duckdb/transaction/meta_transaction.hpp`）管理跨多个 Attached Database 的事务：

```cpp
class MetaTransaction {
    timestamp_t start_timestamp;      // 全局开始时间
    transaction_t global_transaction_id; // 全局事务 ID
    reference_map_t<AttachedDatabase, TransactionReference> transactions; // 每个 DB 的子事务
};
```

提交时按数据库逐一提交，若任一失败则全部回滚（尽力而为的原子性，非严格两阶段提交）。

---

## 十、关键源码索引

| 文件 | 说明 |
|------|------|
| `src/transaction/duck_transaction.cpp` | 事务开始/提交/回滚/清理主逻辑 |
| `src/transaction/duck_transaction_manager.cpp` | 事务管理器：分配时间戳、管理活跃事务、触发 GC |
| `src/transaction/undo_buffer.cpp` | Undo Buffer 的写入、Commit、Rollback、Cleanup 遍历 |
| `src/transaction/commit_state.cpp` | Commit 时处理各类 Undo Entry（写 WAL、更新版本号） |
| `src/transaction/rollback_state.cpp` | Rollback 时处理各类 Undo Entry（逆向撤销） |
| `src/transaction/cleanup_state.cpp` | Cleanup 时处理各类 Undo Entry（GC 旧版本） |
| `src/storage/table/chunk_info.cpp` | MVCC 核心：`TransactionVersionOperator` 可见性判断 |
| `src/storage/table/row_version_manager.cpp` | 管理一个 RowGroup 内所有 Vector 的版本信息 |
| `src/storage/table/update_segment.cpp` | UpdateInfo 版本链的写入、读取、回滚、清理 |
| `src/transaction/local_storage.cpp` | 事务本地未提交数据管理 |
| `src/catalog/catalog_set.cpp` | Catalog MVCC：`UseTimestamp`、`GetEntryForTransaction` |
