# DuckDB 启动流程与 Crash Recovery 设计文档

> 适用源码：`v2.0-cyanoptera` @ `c1cd2470a455`；核对日期：2026-10-23。核对方式：静态源码审查，未执行本文示例或性能测试。

## 概述

内置单文件存储启动时先加载 checkpoint，再按 WAL 状态恢复。当前代码还支持 checkpoint 期间并发提交：主 WAL、`.wal.checkpoint` 和必要时 `.wal.recovery` 需要协调。不能再将恢复简化为“读一个 WAL，checkpoint 后一律清空”。本文只描述内置存储，扩展数据库类型有自己的启动入口。

## 一、核心源码

| 源码 | 符号 |
|---|---|
| [database.cpp](../src/main/database.cpp) | `DuckDB::DuckDB`、`DatabaseInstance::Initialize/InitializeInstance/CreateMainDatabase/StartScheduler` |
| [attached_database.cpp](../src/main/attached_database.cpp) | `AttachedDatabase::Initialize`、AttachOptions |
| [storage_manager.cpp](../src/storage/storage_manager.cpp) | `LoadDatabase`、`WALStartCheckpoint/WALFinishCheckpoint`、`SingleFileStorageCommitState` |
| [single_file_block_manager.cpp](../src/storage/single_file_block_manager.cpp) | MainHeader/DatabaseHeader 编解码、`LoadExistingDatabase/WriteHeader` |
| [storage_info.hpp](../src/include/duckdb/storage/storage_info.hpp) | 头结构、FILE_HEADER_SIZE、StorageVersion |
| [checkpoint_manager.cpp](../src/storage/checkpoint_manager.cpp) | `ActiveCheckpointWrapper`、`SingleFileCheckpointWriter/Reader` |
| [write_ahead_log.cpp](../src/storage/write_ahead_log.cpp) | WAL 初始化、头、条目封装、Flush |
| [wal_replay.cpp](../src/storage/wal_replay.cpp) | `WriteAheadLogReplayer::Replay/ReplayLog/MergeIntoRecoveryWAL`、版本检查 |

## 二、启动时序

以下为主要控制流示意，省略错误处理、加密准备、扩展回调和 profiling：

```text
DuckDB::DuckDB
  → DatabaseInstance::Initialize
    → InitializeInstance
      → Configure / linked extension callbacks
      → 文件系统、DatabaseManager、BufferManager、LogManager、Scheduler 等
      → SecretManager / System Catalog
      → 解析数据库类型，必要时加载存储扩展
    → 若尚无 attached database：CreateMainDatabase（通过内部连接 ATTACH 事务）
      → AttachedDatabase::Initialize
        → Catalog::Initialize
        → StorageManager::Initialize → LoadDatabase
    → 设置 default database
    → StartScheduler（设置常规/async线程并 RelaunchThreads）
  → 按构造入口加载所需扩展
  → DatabaseManager::FinalizeStartup
```

`InitializeEmpty` 有单独入口，不创建普通主数据库。`CreateMainDatabase` 也可能由存储扩展提前完成，不能将上述内置路径当成所有构造的强制步骤。线程池扩展在主要存储初始化之后，但不得仅凭这段顺序宣称全局无任何并发。

## 三、LoadDatabase 的分支

### 3.1 内存库

建立 InMemoryBlockManager 与 TableIOManager，使用最新存储版本，标记 load_complete 后返回；没有主数据库文件或可写 WAL。内存库只读模式在 `StorageManager::Initialize` 拒绝。

### 3.2 新建文件库

条件是 `!read_only && !FileExists(path)`：删除残留主 WAL，解析 block/row-group/storage compatibility/encryption 等选项，`CreateNewDatabase` 写主头与两个初始 DatabaseHeader 并同步，再建立延迟初始化的 WAL 对象。创建对象不意味着此时已经创建空 WAL 文件。

行组大小必须非零且可被 STANDARD_VECTOR_SIZE 整除；更大行组还受目标 StorageVersion 兼容限制。文件/块头大小与编译 vector size 并非可以随意互换的常量。

### 3.3 已有文件库

`LoadExistingDatabase` 校验文件 magic/checksum、加密条件和版本，读两个 DatabaseHeader，按 iteration 选择，初始化块管理器并 LoadFreeList。之后：

```text
SingleFileCheckpointReader::LoadFromStorage
  → 若 meta_block 无效：空存储
  → 否则 MetadataReader + BinaryDeserializer
  → LoadCheckpoint / ReadEntry 恢复 Catalog 与表/索引元数据
WriteAheadLog::Replay
load_complete = true
```

这里恢复的索引可处于 UnboundIndex，后续 Bind 再创建运行时实例；不是每棵树启动时都完整重建。读取/绑定及缓冲回放见 [CUSTOM_INDEX_DESIGN.md](CUSTOM_INDEX_DESIGN.md)。

## 四、文件头与 2.0 存储版本

物理文件的三个头区域各占 `Storage::FILE_HEADER_SIZE=4096` 字节，数据块从 3×4096 开始。各区包含 checksum/块头封装，不能把结构体字段直接按 C++ 内存布局写入，也不能把文件偏移 0 当成 magic 字节的精确位置。

| 区域 | 主要内容 |
|---|---|
| MainHeader | DUCK magic、版本槽、flags、构建版本/源 ID、DB identifier、加密元信息/canary/IV/tag |
| DatabaseHeader h1 | iteration、meta_block、free_list、block_count、block_alloc_size、vector_size、storage_compatibility |
| DatabaseHeader h2 | 同上，交替更新 |

### 4.1 版本编码条件

[MainHeader::Write](../src/storage/single_file_block_manager.cpp) 对 `version_number >= V2_0_0` 写 DEPRECATED 标记（999），实际存储版本由 DatabaseHeader 表达；`MainHeader::Read` 遇该标记跳过旧 main-header 版本区间检查。

`DatabaseHeader::Write` 对目标 `< V2_0_0` 写旧 serialization version；对 `>= V2_0_0` 写 StorageVersion 数值。`SetStorageVersionInDatabaseHeader` 在 main version 为 DEPRECATED 或读出版本 >= V2_0_0 时按新规则解释，否则兼容旧 serialization/storage 混合编码。未知新版本仍会拒绝，不能将“跳过 main-header 检查”误解成接受任意文件。

`DatabaseHeader::Read` 对旧文件中零 block_alloc_size/vector_size 补兼容默认；非零 vector_size 与当前编译值不一致则报错。

### 4.2 双 Header 的保证边界

`WriteHeader` 先刷 metadata/free-list 并 Sync，再把 iteration 加一后的头写到非 active 槽，切换 active_header，最后再次 Sync。加载时先对两个槽逐个 ReadAndChecksum/Deserialize，然后选较大 iteration（相同则 h2）。

这提供交替发布 checkpoint 根的机制，但当前加载函数**没有捕获某槽校验失败后退回另一槽**的分支。不能写成“任意 torn header 都自动回退，绝不会损坏”。磁盘原子写与故障恢复能力不能仅由 D_ASSERT 或双槽结构推出；本文也没有做断电测试。

## 五、WAL 格式、初始化与提交

### 5.1 路径与状态

`StorageManager::GetWALPath/GetCheckpointWALPath/GetRecoveryWALPath` 分别使用 `.wal`、`.wal.checkpoint`、`.wal.recovery` 后缀。应使用这些生成函数理解路径，避免根据源码注释里的另一种后缀顺序手工定位文件。

WALInitState 包括 NO_WAL、UNINITIALIZED、UNINITIALIZED_REQUIRES_TRUNCATE、INITIALIZED。`Initialize` 延迟打开 append writer；需要截断时以 storage manager 保存的成功偏移截断。WAL 头由首个条目序列化器触发 `WriteHeader`，并非每次 Initialize 都重复写头。

### 5.2 头与条目

`WriteHeader` 仅在文件为空时写不带普通条目 checksum 的 WAL_VERSION。当前非加密 WAL 版本为 2、加密为 3。main file version 满足至少 V1_3_0 时，头还写 16 字节 db_identifier 和 checkpoint_iteration；旧 WAL 缺这些字段时 ReplayVersion 保留兼容分支。

普通条目通过 WriteAheadLogSerializer/ChecksumWriter 封装。类型见 [wal_type.hpp](../src/include/duckdb/common/enums/wal_type.hpp)：

| 类型 | 内容 |
|---|---|
| CREATE/DROP/ALTER | Catalog 变更，包括 CREATE_TRIGGER=30 / DROP_TRIGGER=31 |
| USE_TABLE / INSERT_TUPLE / DELETE_TUPLE / UPDATE_TUPLE | 表选择与行变更 |
| ROW_GROUP_DATA=29 | 可引用预写行组块的批量数据 |
| WAL_VERSION=98 | 文件版本/身份信息 |
| CHECKPOINT=99 | 计划发布的 checkpoint 根 |
| WAL_FLUSH=100 | 恢复时的事务提交边界 |

### 5.3 提交顺序与回滚

[DuckTransactionManager::CommitTransaction](../src/transaction/duck_transaction_manager.cpp) 先在 commit 锁之前预刷并同步可能被 ROW_GROUP_DATA 引用的 bulk 块，再在 WAL 锁保护下 `WriteToWAL`；后者先提交 LocalStorage 到共享物理结构并生成 Undo，随后写 Undo WAL。分配 commit_id 后，`DuckTransaction::Commit` 提交 Undo 版本，成功后 `FlushCommit → WriteAheadLog::Flush` 写 WAL_FLUSH 并 writer.Sync。

因此不是“所有变更先写 WAL 并 fsync，然后才更改任何共享数据”，而是用锁、未提交版本、Undo 与最终同步协作。WAL 引用的数据块需要先持久化，不能只分析 WAL 文件。

`SingleFileStorageCommitState::RevertCommit` 仅在 IN_PROGRESS 状态且实际写入增加时截断到 initial_wal_size，并标记未使用的 optimistic blocks。成功 FLUSHED/TRUNCATED 不重复撤销。失败提交还有内存 RevertCommit 与 Rollback，恢复失败可 invalidate 数据库；不是所有错误都能仅靠 WAL 截断恢复。

内存/system/只读加载/NO_WAL_WRITES 等分支不写正常 WAL；满足条件的自动 checkpoint 可跳过本事务 WAL 并保持 WAL 锁直至 checkpoint。详见 [TRANSACTION_MVCC_DESIGN.md](TRANSACTION_MVCC_DESIGN.md)。

## 六、并发 Checkpoint 协议

[SingleFileCheckpointWriter::CreateCheckpoint](../src/storage/checkpoint_manager.cpp) 的主要时序：

```text
创建 metadata/table metadata writers，预取新根地址
→ WALStartCheckpoint（在遍历/写完全部数据之前）
   持 WAL 锁建立 checkpoint 快照/identity/visibility_bound
   主 WAL 写 CHECKPOINT(root) + Flush
   关闭主 WAL，切换到延迟初始化的 .wal.checkpoint
→ 按依赖顺序序列化 Catalog、表/索引和元数据
→ Flush metadata writers
→ WriteHeader 发布新根（数据前置 Sync + 头后置 Sync）
→ Truncate 主数据文件可回收尾部
→ 持 WAL 锁 WALFinishCheckpoint
   辅助 WAL 未初始化：删除旧主 WAL，创建新的空逻辑 WAL
   辅助 WAL 已写：关闭并替换主 WAL，再 Initialize
→ MergeCheckpointDeltas
→ 结束 checkpoint transaction / 清除 active checkpoint
```

WALStartCheckpoint 在主 WAL 大小为零或没有 WAL 时可不切换；上下文缺失时使用 last_commit 构造 bound。context-free checkpoint 若存在无法持久化的 UnboundIndex 缓冲回放会直接返回，保留 WAL，不能声称关闭时一定消除 WAL。

`ActiveCheckpointWrapper` 在有上下文时建立内部只读 checkpoint 事务，标记 is_checkpoint_transaction，记录 visibility_bound 和 checkpoint_id。它使 checkpoint 读取一个确定快照；期间成功的并发提交进入辅助 WAL。

checkpoint 并非排除全部活跃事务：共享 checkpoint 锁主要约束更新/DDL 等；追加/删除可走并发模式，vacuum 的独占锁另外协调 rowid/行组移动。索引的 ADDED/REMOVED_DATA_DURING_CHECKPOINT 在完成后合并，旧快照保留使用中的删除行。

## 七、WAL 重放：扫描、协调、应用

入口 `WriteAheadLog::Replay → WriteAheadLogReplayer::Replay`：主 WAL 不存在返回空逻辑 WAL；ReplayLog 返回空指针时，仅可写连接删除主 WAL；只读加载也可能在内存中恢复已提交内容，但不改文件。

### 7.1 第一遍：只反序列化

`ReplayLog` 开始恢复事务，以 deserialize_only 扫描条目，记录最后完整 WAL_FLUSH 的结束偏移、相应 ROW_GROUP_DATA 块、完整 checkpoint marker 的位置和结束位置。

SERIALIZATION 异常可作为 torn WAL 处理，除非 abort_on_wal_failure 被启用；其他异常重抛。只使用最后完整 WAL_FLUSH 之前的行组块，丢弃未提交尾部引用。只有完整消费的 checkpoint marker 才参与协调，且 marker 必须位于主 WAL 逻辑末尾，辅助 WAL 不允许自身再含 checkpoint marker。

### 7.2 checkpoint marker 与辅助 WAL 分支

`IsCheckpointClean(root)` 比较 block manager 的当前根，不仅是“看文件是否存在”。

| 主头已发布该根？ | 有辅助 WAL？ | 当前处理 |
|---|---|---|
| 是 | 否 | 主 WAL 已被 checkpoint 覆盖，返回空指针 |
| 是 | 是 | 只读：直接读辅助 WAL；可写：辅助替换主 WAL，再重放 |
| 否 | 否 | 重放旧主 WAL；可写先截到 marker 前完整提交边界（并 Sync），避免残留 marker 重新成为可追加内容 |
| 否 | 是 | 可写：合并 marker 前主 WAL + 去头辅助 WAL 到 recovery 文件，同步后替换主 WAL、删辅助，再重放；只读：先重放主 WAL，成功结束后再重放辅助 |

`MergeIntoRecoveryWAL` 验证两 WAL 的版本一致；它复制到新 recovery 文件，Sync 后 MoveFile 替换主 WAL。不能把这个流程等同于简单拼接任意 WAL，也不应据路径后缀手工删除恢复文件。

### 7.3 身份与 iteration 校验

`ReplayVersion` 在字段存在时校验 db_identifier 相同。iteration 通常必须一致，但保留两个分支：

- WAL iteration 比文件低 1：记录 expected_checkpoint_id，要求后续 checkpoint marker 能解释该情况，否则报错。
- 正在回放 CHECKPOINT_WAL 且 WAL iteration 比文件高 1：允许正在 checkpoint 的对应状态。

不是“任何 iteration 不同都拒绝”，更不是“相差 1 永远允许”。

### 7.4 第二遍：仅应用已提交前缀

决定需要回放后，先将第一遍确认的 ROW_GROUP_DATA 块 MarkBlockAsUsed，防止早期重放分配覆盖后面要引用的块。若无完整 WAL_FLUSH，回滚并返回需截到零的 WAL 状态。

随后重置 reader，只执行到 last_wal_flush_end：遇 WAL_FLUSH 才提交恢复事务，安装待处理索引，更新 successful_offset；还有后续已提交条目才开始下一事务。错误时回滚当前事务，序列化错误按配置处理，其他错误抛出。

文件末尾有 torn/uncommitted tail 时，返回 UNINITIALIZED_REQUIRES_TRUNCATE，下一次写入前截断到成功偏移；读完完整文件才是 UNINITIALIZED。某些失败 checkpoint-marker 分支会在回放前立即截断，不能全部描述为“下次启动才截断”。

## 八、故障时序的阅读方法

| 位置 | 源码意图与限制 |
|---|---|
| 无完整 WAL_FLUSH 的事务尾部 | 不发布该事务，保留已完成前缀；只对允许的序列化错误容错 |
| 完整 WAL 提交、尚未 checkpoint | 重放提交记录及所需预写块 |
| checkpoint 未发布 Header | 旧 checkpoint + 主/辅助 WAL 协调恢复 |
| Header 已发布，尚未替换 WAL | 主 WAL 可被跳过，但辅助 WAL 的并发提交仍需恢复 |
| 头 checksum、身份、版本或非序列化错误 | 可能直接报错，不承诺自动回退/修复 |

表中描述控制流，不是实测故障矩阵；WAL_FLUSH 字节出现与已经完成同步不是同一事件，持久性还取决于存储同步返回语义。

## 九、配置与剩余边界

当前 [settings.hpp](../src/include/duckdb/main/settings.hpp) 可定位 `debug_abort_on_wal_failure`（写入 config.options.abort_on_wal_failure）、`checkpoint_threshold`、`auto_checkpoint_skip_wal_threshold`、`wal_autocheckpoint_entries`、`checkpoint_on_detach` 等设置。文件访问模式、加密、IO_MODE、存储兼容性还经 AttachOptions/StorageManagerOptions 解析，旧文档的 `use_direct_io`、`wal_autocheckpoint` 表格不能代替当前配置接口。

`RecoveryMode::NO_WAL_WRITES` 明确禁用 WAL 持久性，声明见 [attached_database.hpp](../src/include/duckdb/main/attached_database.hpp)；只读模式仍可能在内存中回放，不能简单解释为“不进行恢复”。本文未执行 SQL、启动服务、构建、故障注入或文件修复，也没有验证加密/旧格式的端到端兼容性。
