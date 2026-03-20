# DuckDB 启动流程与 Crash Recovery 设计文档

## 概述

本文档整理了 DuckDB 数据库的启动流程，重点阐述 Crash Recovery（崩溃恢复）机制，包括 WAL（Write-Ahead Log，预写日志）重放、Checkpoint（检查点）加载以及双 Header 原子切换等关键设计，为理解或扩展 DuckDB 存储引擎提供参考。

---

## 一、源码文件总览

### 核心实现文件

| 文件 | 核心类 | 职责说明 |
|------|--------|----------|
| `src/main/database.cpp` | `DuckDB`, `DatabaseInstance` | 数据库入口：构造函数、全局初始化 |
| `src/main/attached_database.cpp` | `AttachedDatabase` | 已挂载数据库的初始化（Catalog + StorageManager） |
| `src/storage/storage_manager.cpp` | `SingleFileStorageManager` | 存储管理器：判断新建 / 加载已有数据库，驱动 checkpoint 加载和 WAL 重放 |
| `src/storage/single_file_block_manager.cpp` | `SingleFileBlockManager` | 单文件块管理器：读写 FileHeader / DatabaseHeader，加载 FreeList |
| `src/storage/checkpoint_manager.cpp` | `SingleFileCheckpointWriter`, `SingleFileCheckpointReader` | Checkpoint 的写入与读取 |
| `src/storage/wal_replay.cpp` | `WriteAheadLog`, `WriteAheadLogDeserializer` | WAL 重放（Crash Recovery 核心） |
| `src/storage/write_ahead_log.cpp` | `WriteAheadLog` | WAL 写入（事务提交路径） |

### 关键头文件

| 文件 | 说明 |
|------|------|
| `src/include/duckdb/main/database.hpp` | `DuckDB` / `DatabaseInstance` 声明 |
| `src/include/duckdb/storage/storage_manager.hpp` | `StorageManager` 抽象接口 |
| `src/include/duckdb/storage/single_file_block_manager.hpp` | 单文件块管理器声明 |
| `src/include/duckdb/storage/write_ahead_log.hpp` | `WriteAheadLog` 完整接口 |
| `src/include/duckdb/storage/checkpoint_manager.hpp` | CheckpointWriter / CheckpointReader 声明 |
| `src/include/duckdb/common/enums/wal_type.hpp` | `WALType` 枚举（WAL 条目类型） |

---

## 二、总体启动流程

```
DuckDB(path, config)                          ← 用户入口
    │
    ├─ DatabaseInstance::Initialize()
    │       │
    │       ├─ DatabaseFileSystem / BufferManager / TaskScheduler
    │       ├─ LogManager::Initialize()
    │       ├─ ExtensionManager / SecretManager
    │       ├─ DatabaseManager::InitializeSystemCatalog()
    │       └─ CreateMainDatabase()
    │               │
    │               └─ AttachedDatabase::Initialize()
    │                       │
    │                       ├─ DuckCatalog::Initialize()
    │                       └─ StorageManager::Initialize()
    │                               │
    │                               └─ SingleFileStorageManager::LoadDatabase()
    │                                       │
    │                               ┌───────┴────────┐
    │                         新建数据库          已有数据库
    │                               │                │
    │                    CreateNewDatabase()    LoadExistingDatabase()
    │                    创建空 WAL              SingleFileCheckpointReader::LoadFromStorage()
    │                                           WriteAheadLog::Replay()  ← Crash Recovery
    │
    ├─ ExtensionHelper::LoadAllExtensions()
    └─ DatabaseManager::FinalizeStartup()
```

---

## 三、各阶段详细说明

### 3.1 DatabaseInstance::Initialize()

**文件**：`src/main/database.cpp:269`

初始化所有基础设施组件：

```cpp
void DatabaseInstance::Initialize(const char *database_path, DBConfig *user_config) {
    Configure(*config_ptr, database_path);

    db_file_system   = make_uniq<DatabaseFileSystem>(*this);
    db_manager       = make_uniq<DatabaseManager>(*this);
    buffer_manager   = make_uniq<StandardBufferManager>(*this, ...);
    log_manager      = make_uniq<LogManager>(*this, LogConfig());
    scheduler        = make_uniq<TaskScheduler>(*this);
    extension_manager = make_uniq<ExtensionManager>(*this);
    config.secret_manager->Initialize(*this);

    db_manager->InitializeSystemCatalog();   // 内置系统函数、类型等
    CreateMainDatabase();                    // 挂载主数据库
    scheduler->SetThreads(...);              // 存储初始化完成后再启动线程池
}
```

> **关键时序**：线程池（TaskScheduler）必须在存储初始化完成后才能增加工作线程，避免 Catalog 并发竞争。

---

### 3.2 AttachedDatabase::Initialize()

**文件**：`src/main/attached_database.cpp:187`

```cpp
void AttachedDatabase::Initialize(optional_ptr<ClientContext> context) {
    catalog->Initialize(context, false);   // 初始化 DuckCatalog（内存中的元数据树）
    if (storage) {
        storage->Initialize(QueryContext(context));  // 调用 StorageManager
    }
}
```

---

### 3.3 SingleFileStorageManager::LoadDatabase()

**文件**：`src/storage/storage_manager.cpp:195`

这是存储层的核心调度函数，区分两条路径：

#### 路径 A：新建数据库（文件不存在且非只读）

```
1. 清除残留的 WAL 文件（若存在）
2. SingleFileBlockManager::CreateNewDatabase()
   └─ 写入 MainHeader（魔数 + 版本号）
   └─ 写入两个空 DatabaseHeader（h1, h2）
   └─ handle->Sync()（确保落盘）
3. 创建空 WriteAheadLog 对象（尚未写入文件）
```

#### 路径 B：加载已有数据库（文件存在或只读模式）

```
1. SingleFileBlockManager::LoadExistingDatabase()
   └─ 打开文件，校验 MainHeader 魔数
   └─ 读取 h1 和 h2 两个 DatabaseHeader，选 iteration 较大者为活跃 Header
   └─ LoadFreeList()（加载空闲块列表）

2. SingleFileCheckpointReader::LoadFromStorage()
   └─ 从活跃 Header 取 meta_block 指针
   └─ MetadataReader 反序列化所有 Catalog 条目（表、视图、索引等）

3. WriteAheadLog::Replay()  ← Crash Recovery 入口
```

---

## 四、文件格式：Header 区域

DuckDB 单文件数据库的头部布局如下：

```
┌──────────────────────────────┐  偏移 0
│        MainHeader            │  魔数（"DUCK"）、版本号、DB标识符、加密标志
├──────────────────────────────┤  偏移 FILE_HEADER_SIZE (4096B)
│      DatabaseHeader h1       │  iteration、meta_block、free_list、block_count
├──────────────────────────────┤  偏移 FILE_HEADER_SIZE × 2
│      DatabaseHeader h2       │  iteration、meta_block、free_list、block_count
├──────────────────────────────┤  偏移 FILE_HEADER_SIZE × 3
│      数据块区域 ...           │
└──────────────────────────────┘
```

**双 Header 原子切换**：每次写入 Checkpoint 时交替更新 h1/h2，通过 `iteration` 计数器标记哪个是最新有效的。即使写 Header 时崩溃，另一个 Header 仍有效，不会出现半写状态。

```cpp
// 加载时选择 iteration 较大的 Header
if (h1.iteration > h2.iteration) {
    active_header = 0;
    Initialize(h1, ...);
} else {
    active_header = 1;
    Initialize(h2, ...);
}
```

---

## 五、Checkpoint 机制

### 5.1 Checkpoint 写入

**文件**：`src/storage/checkpoint_manager.cpp:133`

`SingleFileCheckpointWriter::CreateCheckpoint()` 执行以下步骤：

```
1. 构建 MetadataWriter + TableMetadataWriter
2. 遍历所有已提交的 Catalog 条目（Schema、Table、View、Index 等）
3. BinarySerializer 序列化所有元数据 → 写入元数据块链
4. 向 WAL 写入 CHECKPOINT 条目（记录 meta_block 地址）
5. WAL::Flush()（确保 CHECKPOINT 条目落盘）
6. 写入新的 DatabaseHeader（更新 meta_block 指针）
7. block_manager->Truncate()（回收不再使用的块）
8. storage_manager->ResetWAL()（清空 WAL 文件）
```

> **关键设计**：先写 WAL 中的 CHECKPOINT 标记，再写 DatabaseHeader。若在步骤 5~6 之间崩溃，下次启动时 WAL 重放会检测到 CHECKPOINT 条目，并与文件 Header 中的 meta_block 比对，判断 Checkpoint 是否已成功持久化。

### 5.2 Checkpoint 读取

**文件**：`src/storage/checkpoint_manager.cpp:275`

```cpp
void SingleFileCheckpointReader::LoadFromStorage() {
    MetaBlockPointer meta_block(block_manager.GetMetaBlock(), 0);
    if (!meta_block.IsValid()) {
        return;   // 空数据库，跳过
    }
    MetadataReader reader(metadata_manager, meta_block);
    auto transaction = CatalogTransaction::GetSystemTransaction(...);
    LoadCheckpoint(transaction, reader);  // 反序列化所有 Catalog 条目
}
```

序列化格式（简化）：
```json
{
  "catalog_entries": [
    { "catalog_type": "SCHEMA_ENTRY", ... },
    { "catalog_type": "TABLE_ENTRY",  ... },
    { "catalog_type": "INDEX_ENTRY",  ... },
    ...
  ]
}
```

---

## 六、WAL 结构与写入

### 6.1 WAL 文件位置

WAL 文件路径：`{数据库路径}.wal`，例如 `mydb.db.wal`。

### 6.2 WAL 条目类型

**文件**：`src/include/duckdb/common/enums/wal_type.hpp`

| 类型值 | 枚举名 | 含义 |
|--------|--------|------|
| 1 | `CREATE_TABLE` | 创建表 |
| 2 | `DROP_TABLE` | 删除表 |
| 3 | `CREATE_SCHEMA` | 创建 Schema |
| 4 | `DROP_SCHEMA` | 删除 Schema |
| 5 | `CREATE_VIEW` | 创建视图 |
| 6 | `DROP_VIEW` | 删除视图 |
| 8 | `CREATE_SEQUENCE` | 创建序列 |
| 9 | `DROP_SEQUENCE` | 删除序列 |
| 10 | `SEQUENCE_VALUE` | 序列当前值 |
| 11 | `CREATE_MACRO` | 创建宏 |
| 12 | `DROP_MACRO` | 删除宏 |
| 13 | `CREATE_TYPE` | 创建自定义类型 |
| 14 | `DROP_TYPE` | 删除自定义类型 |
| 20 | `ALTER_INFO` | 表结构变更（ALTER） |
| 21 | `CREATE_TABLE_MACRO` | 创建表宏 |
| 22 | `DROP_TABLE_MACRO` | 删除表宏 |
| 23 | `CREATE_INDEX` | 创建索引 |
| 24 | `DROP_INDEX` | 删除索引 |
| 25 | `USE_TABLE` | 指定后续 DML 操作的目标表 |
| 26 | `INSERT_TUPLE` | 插入数据 |
| 27 | `DELETE_TUPLE` | 删除数据 |
| 28 | `UPDATE_TUPLE` | 更新数据 |
| 29 | `ROW_GROUP_DATA` | 批量行组数据 |
| 98 | `WAL_VERSION` | WAL 版本号条目 |
| 99 | `CHECKPOINT` | Checkpoint 标记（含 meta_block 地址） |
| 100 | `WAL_FLUSH` | 事务提交刷盘标记 |

### 6.3 WAL 写入流程（正常事务提交）

```
事务提交
    │
    ├─ DuckTransaction::Commit()
    │       └─ 写 DDL 条目（CREATE/DROP/ALTER）
    │       └─ 写 USE_TABLE + INSERT/DELETE/UPDATE 条目
    │       └─ 写 WAL_FLUSH（事务结束标记）
    │
    └─ SingleFileStorageCommitState::FlushCommit()
            └─ WriteAheadLog::Flush()（缓冲区 → 磁盘）
```

> `WAL_FLUSH` 是事务的"提交点"，WAL 重放时只有遇到 `WAL_FLUSH` 才会 `Commit()`，确保原子性。

### 6.4 事务回滚时的 WAL 处理

```cpp
// SingleFileStorageCommitState::RevertCommit()
if (wal.GetTotalWritten() > initial_written) {
    wal.Truncate(initial_wal_size);   // 截断到事务开始前的大小
}
```

回滚时，直接将 WAL 文件截断到事务开始前的偏移量，本次事务的所有 WAL 写入被丢弃。

---

## 七、Crash Recovery：WAL 重放

### 7.1 总体流程图

```
WriteAheadLog::Replay(fs, db, wal_path)
    │
    ├─ [WAL 文件不存在] → 返回空 WAL，跳过恢复
    │
    └─ [WAL 文件存在] → ReplayInternal(db, handle)
            │
            ├─ [WAL 文件为空] → 返回 nullptr（删除空 WAL）
            │
            ├─ ── 第一阶段：扫描 Checkpoint 标记 ─────────────────────────
            │   BeginTransaction()
            │   ReplayState checkpoint_state（deserialize_only = true）
            │   逐条读取 WAL 条目（仅反序列化，不执行）
            │   捕获序列化异常（标志 WAL 尾部不完整，即"torn WAL"）
            │
            ├─ [找到 CHECKPOINT 条目]
            │       ├─ IsCheckpointClean(checkpoint_id)?
            │       │       ├─ YES → 返回 nullptr（WAL 内容已在 Checkpoint 中，可安全删除）
            │       │       └─ NO  → 继续第二阶段
            │       └─ [expected_checkpoint_id 不匹配] → 抛出版本错误
            │
            ├─ ── 第二阶段：完整重放 ──────────────────────────────────────
            │   reader.Reset()（从文件头重新开始读）
            │   ReplayState state（真正执行操作）
            │   successful_offset = 0
            │
            │   循环：
            │       读取 WAL 条目 → ReplayEntry()
            │       若遇到 WAL_FLUSH：
            │           con.Commit()
            │           提交待处理的索引（replay_index_infos）
            │           successful_offset = reader.CurrentOffset()
            │           若文件结束 → all_succeeded = true，退出循环
            │           否则 con.BeginTransaction()
            │
            │   [异常处理]：
            │       序列化异常（torn WAL）→ Rollback，忽略（除非 abort_on_wal_failure=true）
            │       其他异常 → Rollback，重新抛出
            │
            └─ 返回 WriteAheadLog(wal_path, successful_offset,
                   all_succeeded ? UNINITIALIZED : UNINITIALIZED_REQUIRES_TRUNCATE)
```

### 7.2 关键设计决策

#### （1）两阶段读取

WAL 重放分为两次读取：
- **第一阶段**（`deserialize_only=true`）：只解析不执行，专门查找 `CHECKPOINT` 条目，判断数据是否已持久化。
- **第二阶段**：若需要恢复，从头重新读取并真正执行每个操作。

这样避免了在"数据已 Checkpoint"场景下的不必要重放，同时保证准确性。

#### （2）WAL_FLUSH 作为事务提交点

WAL 中每个事务以 `WAL_FLUSH` 结尾。重放时，遇到 `WAL_FLUSH` 才调用 `con.Commit()`，未到达 `WAL_FLUSH` 的条目（即未完成提交的事务）不会被应用，天然实现原子性。

#### （3）Torn WAL 容错

若数据库在写 WAL 过程中崩溃（例如断电），WAL 文件末尾可能存在不完整的序列化数据。WAL 重放将序列化异常（`ExceptionType::SERIALIZATION`）视为"WAL 截断信号"，静默回滚当前未提交事务，并将文件截断到最后一个成功提交点（`successful_offset`）。

```cpp
auto init_state = all_succeeded
    ? WALInitState::UNINITIALIZED
    : WALInitState::UNINITIALIZED_REQUIRES_TRUNCATE;
return make_uniq<WriteAheadLog>(database, wal_path, successful_offset, init_state);
```

下次启动时，若检测到 `UNINITIALIZED_REQUIRES_TRUNCATE`，会先执行 `wal.Truncate(successful_offset)` 再初始化新的写入器。

#### （4）Checkpoint 后 WAL 已无用的判断

```cpp
// IsCheckpointClean() 检查 WAL 中记录的 meta_block 是否与文件 Header 中的一致
bool SingleFileStorageManager::IsCheckpointClean(MetaBlockPointer checkpoint_id) {
    return block_manager->IsRootBlock(checkpoint_id);
}
```

若一致，说明 Checkpoint 已成功写入文件 Header，WAL 中的所有数据均已持久化，可以安全删除 WAL。

### 7.3 崩溃场景分析

| 崩溃时机 | 文件状态 | 恢复行为 |
|----------|----------|----------|
| 写 WAL 期间（未到 WAL_FLUSH） | WAL 有不完整条目 | 截断到上一个 WAL_FLUSH，本次事务丢失 |
| WAL_FLUSH 写入后、Checkpoint 前 | WAL 有完整事务 | WAL 重放，恢复全部已提交事务 |
| Checkpoint 写元数据后、写 Header 前 | WAL 有 CHECKPOINT 条目，Header 未更新 | IsCheckpointClean() 返回 false → WAL 重放 |
| 写 Header 后、清空 WAL 前 | WAL 有 CHECKPOINT 条目，Header 已更新 | IsCheckpointClean() 返回 true → 跳过 WAL，直接从 Checkpoint 加载 |
| 清空 WAL 后 | WAL 为空或不存在 | 直接从 Checkpoint 加载，无需恢复 |

---

## 八、WAL 初始化状态机

```
WALInitState 枚举：
    NO_WAL                      ← 首次构造（无文件）
    UNINITIALIZED               ← 重放完成，尚未打开写入器
    UNINITIALIZED_REQUIRES_TRUNCATE ← 重放完成，下次写入前需先截断
    INITIALIZED                 ← 写入器已打开，可正常追加写入
```

首次向 WAL 写入时，`WriteAheadLog::Initialize()` 会：
1. 若状态为 `UNINITIALIZED_REQUIRES_TRUNCATE`，先截断文件到 `successful_offset`
2. 打开 `BufferedFileWriter`，写入 `WAL_VERSION` 头部条目
3. 切换到 `INITIALIZED` 状态

---

## 九、完整启动时序图

```
用户代码: DuckDB db("mydb.db");
          │
          ▼
DuckDB::DuckDB()
  │  instance->Initialize("mydb.db", config)
  │    │
  │    ├─ 初始化基础设施（FS、BufferManager、Scheduler 等）
  │    │
  │    └─ CreateMainDatabase()
  │         │
  │         └─ AttachedDatabase::Initialize()
  │              │
  │              ├─ DuckCatalog::Initialize()
  │              │
  │              └─ SingleFileStorageManager::LoadDatabase()
  │                   │
  │                   ├─ [新数据库]
  │                   │   SingleFileBlockManager::CreateNewDatabase()
  │                   │   │ 写 MainHeader（魔数、版本、DB标识符）
  │                   │   │ 写 DatabaseHeader h1（iteration=0，空）
  │                   │   │ 写 DatabaseHeader h2（iteration=0，空）
  │                   │   │ Sync()
  │                   │   └─ 创建空 WriteAheadLog
  │                   │
  │                   └─ [已有数据库]
  │                       SingleFileBlockManager::LoadExistingDatabase()
  │                       │ 校验 MainHeader 魔数
  │                       │ 读 h1、h2，选 iteration 大者为活跃 Header
  │                       │ LoadFreeList()
  │                       │
  │                       SingleFileCheckpointReader::LoadFromStorage()
  │                       │ 读 meta_block 指针
  │                       │ MetadataReader 反序列化所有 Schema/Table/Index/...
  │                       │
  │                       WriteAheadLog::Replay()  ← Crash Recovery
  │                           │
  │                           ├─ [无 WAL 文件] → 空 WAL，完成
  │                           │
  │                           └─ [有 WAL 文件]
  │                               ReplayInternal()
  │                               │
  │                               ├─ Phase 1: 扫描 CHECKPOINT 标记
  │                               │     是否已 Checkpoint? → 若是，删 WAL，完成
  │                               │
  │                               └─ Phase 2: 完整重放
  │                                     逐条执行 WAL 条目
  │                                     遇 WAL_FLUSH → Commit
  │                                     异常 → Rollback + 截断
  │                                     返回新 WAL 对象
  │
  ├─ ExtensionHelper::LoadAllExtensions()
  └─ DatabaseManager::FinalizeStartup()

数据库就绪，开始接受连接。
```

---

## 十、相关配置选项

| 配置项 | 类型 | 说明 |
|--------|------|------|
| `abort_on_wal_failure` | bool | 为 true 时，WAL 重放遇到任何错误都抛出异常（默认 false，torn WAL 静默截断） |
| `checkpoint_on_shutdown` | bool | 关闭时是否自动执行 Checkpoint（默认 true） |
| `wal_autocheckpoint` | idx_t | WAL 超过此大小（字节）时自动触发 Checkpoint |
| `use_direct_io` | bool | 是否使用 Direct I/O 绕过 OS 缓存 |
| `read_only` | bool | 只读模式下不会写入 WAL 或 Checkpoint |

---

## 十一、设计要点总结

1. **双 Header 原子切换**：h1/h2 交替更新，通过 `iteration` 计数器保证 Header 写入的原子性，崩溃不会导致 Header 损坏。

2. **WAL + Checkpoint 双保险**：正常运行时所有提交写 WAL，定期 Checkpoint 将数据固化到主文件并清空 WAL；恢复时先加载最新 Checkpoint，再重放 WAL 中 Checkpoint 之后的操作。

3. **两阶段 WAL 重放**：先扫描是否有 CHECKPOINT 标记且已持久化（避免重复重放），再执行完整重放。

4. **WAL_FLUSH 原子性**：以 `WAL_FLUSH` 为事务提交界限，保证重放时的原子性，未完成的事务天然被丢弃。

5. **Torn WAL 容错**：序列化异常视为文件截断信号，静默截断到最后成功点，不影响已提交事务的恢复。

6. **CHECKPOINT 标记保护**：Checkpoint 时先向 WAL 写入含 meta_block 地址的 CHECKPOINT 条目，再更新 Header。即使在两步之间崩溃，下次恢复时也能正确判断 Checkpoint 是否完整。
