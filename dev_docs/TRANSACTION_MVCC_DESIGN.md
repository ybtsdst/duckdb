# DuckDB 事务实现机制与 MVCC 设计文档

> 适用源码：`v2.0-cyanoptera` @ `c1cd2470a455`；核对日期：2026-10-23。核对方式：静态源码审查，未执行本文示例或性能测试。

## 概述

内置 DuckDB 事务使用快照可见性、Undo、本地追加存储、索引约束和 WAL/checkpoint 协作。当前实现以 `SnapshotView` 和 `VisibilityBound` 表达可见性，并支持与追加/删除并发的 checkpoint；不能沿用“所有写操作只改 LocalStorage”“checkpoint 时没有活跃事务”的模型。

## 一、ACID 的组成与边界

| 属性 | 主要机制 |
|---|---|
| 原子性 | LocalStorage 回滚、UndoBuffer 逆序撤销、失败提交的 RevertCommit |
| 一致性 | 表约束、索引、Catalog/依赖提交检查；不自动表达应用的全部业务约束 |
| 隔离性 | SnapshotView + 行插入/删除版本、列更新 Undo 链、Catalog 版本链 |
| 持久性 | 符合条件的 WAL 同步，或自动 checkpoint 替代 WAL 的分支 |

这是机制划分，不是对所有扩展、外部系统、文件系统故障的无条件保证。内存库、临时库、恢复模式与自定义 TransactionManager 有各自边界。

## 二、事务对象与统一可见性

[duck_transaction.hpp](../src/include/duckdb/transaction/duck_transaction.hpp) 的 `DuckTransaction` 保存 start_time、`SnapshotView view`、commit_id、catalog_version、UndoBuffer、LocalStorage，以及 checkpoint/vacuum/table 锁；不再有旧文档中的直接 transaction_id、highest_active_query 字段或名为 write_lock 的共享锁字段。

[transaction_data.hpp](../src/include/duckdb/transaction/transaction_data.hpp) 的真实源码摘录：

```cpp
bool Sees(transaction_t timestamp) const {
    return timestamp < visibility_bound || timestamp == transaction_id;
}
```

[constants.hpp](../src/include/duckdb/common/constants.hpp) 定义 `VisibilityBound::Before(t)` 为排他 `< t`，`Through(t)` 为 `< t+1`；只提供 timestamp 与 bound 的 `<`、`>=` 比较，避免错误混用包含/排除边界。

[constants.cpp](../src/common/constants.cpp) 中 `SYSTEM_TRANSACTION_TIMESTAMP=1`、`TRANSACTION_ID_START=4611686018427388000ULL`、`MAX_COMMIT_ID=TRANSACTION_ID_START-1`。应以常量定义为准，不用约数 2^62 替代精确值。`IsCommitted(t)` 实际判断 `t <= MAX_COMMIT_ID`；未删除 sentinel 等特殊值不应直接当成某个活跃事务。

普通事务由 [DuckTransactionManager::StartTransaction](../src/transaction/duck_transaction_manager.cpp) 创建：分配单调 start_time 和 transaction_id，view 为 `SnapshotView(id, Before(start_time))`。Catalog 提交校验和 checkpoint 可构造其他 view，所以通用规则必须使用 view，而非硬编码 start_time。

## 三、行插入/删除版本：ChunkVectorInfo

当前 [chunk_info.hpp](../src/include/duckdb/storage/table/chunk_info.hpp) **内存中只有 ChunkVectorInfo**。`CONSTANT_INFO`、`EMPTY_INFO` 是序列化 tag，不再存在旧版 ChunkInfo→ChunkConstantInfo/ChunkVectorInfo 的内存继承体系。

`RowVersionManager` 管理行组各 vector 的版本对象。STANDARD_VECTOR_SIZE 来自构建常量（默认 2048），不能把固定 2048 当作所有二进制的保证。

| 版本侧 | 内存表示 |
|---|---|
| 插入 | constant_insert_id 或分配器中的 per-row inserted_data |
| 删除 CONSTANT | 全 vector 共用 constant_delete_id，未删除用 NOT_DELETED_ID |
| 删除 MASKED | deleted_mask 指示删除行，mask_delete_id 保存共享的已提交删除版本 |
| 删除 ARRAY | 分配器中每行独立删除版本 |

MASKED 的 valid bit 表示“已删除”，方向不是“活行”；mask_delete_id 可是仍需快照区分的非零提交号，不能把 mask 等同于所有事务都已看到的删除。

`CompressVersionIds(lowest_visibility_bound)` 只在对所有快照等价时压缩；FULLY_COMPRESSED/PENDING/SETTLED 与 recheck_compression 避免无效重复扫描。版本数组由 FixedSizeAllocator/IndexPointer 管理，不是对象内固定两组 2048 项数组。

普通快照读取在 [chunk_info.cpp](../src/storage/table/chunk_info.cpp) 使用 `StandardInsertOperator` / `StandardDeleteOperator`：

```text
visible(row) = view.Sees(insert_version) && !view.Sees(delete_version)
```

这是正常事务扫描的规则示意；全行扫描、checkpoint 等 ScanOptions 使用不同 operator，不能将其套给全部内部扫描。

## 四、UPDATE：最新值与 Undo 链

[update_info.hpp](../src/include/duckdb/transaction/update_info.hpp) 中 `UpdateInfo` 保存 segment、DuckTableEntry、column_index、row_group_start、atomic version_number、vector_index、N、容量 max、prev/next UndoBufferPointer；其后连续存储 tuple IDs 与旧值，容量可紧凑分配，不总是固定 STANDARD_VECTOR_SIZE。

[update_segment.cpp](../src/storage/table/update_segment.cpp) 的 `UpdateSegment::Update/FetchUpdates` 维护更新段的当前值与各事务旧值：读取先取得 base/current 内容，再按 view 应用所需 Undo。不能描述为“UPDATE 不修改任何当前数据，只加一条新值链”。

`UpdateInfo::AppliesToTransaction(view)` 对 root 的 MAX_COMMIT_ID 哨兵返回 true，对普通节点返回 `!view.Sees(version_number)`。所以 callback 应用的是不可见更新的旧值；本事务自己的版本可见，不需要用该 Undo 撤销自己。`UpdatesForTransaction` 沿 next 遍历，不应把 prev/next 方向写反。

普通列更新通过该路径；影响索引/特定语义的 UPDATE 计划可能改写成 DELETE+INSERT，不能把所有 UPDATE 都统一成删除插入。

## 五、执行期写入与冲突

- INSERT 通常写事务私有 LocalStorage 行组，允许 optimistic writer 提前写块。`PushAppend` 在 LocalStorage::Flush 将本地数据交入共享表后记录追加范围，不是每个 Sink chunk 到达时就统一记录全局 INSERT Undo。
- 对共享表 DELETE 修改 RowVersionManager/ChunkVectorInfo 的删除版本并写 DeleteInfo；删除本事务本地行走本地存储分支。
- 对共享列 UPDATE 创建 UpdateInfo 与 Undo 链；本地行更新由相应本地路径处理。
- DDL 创建共享 Catalog 版本链节点，但通过 view 隔离未提交版本。

`ChunkVectorInfo::Delete` 对本事务已删除的行跳过；另一事务已标记删除则冲突，包括 constant/array 分支。更新的 `CheckForConflicts` 会比较其他版本是否 `>= visibility_bound`，再检查 tuple ID 是否相交；独占锁只保护结构，冲突检测还拒绝快照之外已提交更新，绝非“有锁就不会写写冲突”。

源码：[local_storage.cpp](../src/storage/local_storage.cpp)、[chunk_info.cpp](../src/storage/table/chunk_info.cpp) 的 `Delete`、[update_segment.cpp](../src/storage/table/update_segment.cpp) 的 `CheckForConflicts`、[catalog_set.cpp](../src/catalog/catalog_set.cpp) 的 `HasConflict`。

## 六、提交生命周期

### 6.1 正常 WAL 分支

以下为省略日志与异常细节的控制流示意，依据 [duck_transaction_manager.cpp](../src/transaction/duck_transaction_manager.cpp) 的 `CommitTransaction` 与 [duck_transaction.cpp](../src/transaction/duck_transaction.cpp)：

```text
PreFlushOptimisticBlocks（取得 commit 锁之前）
  → bulk append 块 Flush + 必要的数据库 FileSync
取得 transaction_lock，评估 checkpoint
需要写 WAL？
  释放 transaction_lock → 取得并保持 WAL lock
  WriteToWAL
    LocalStorage::Commit → 全局索引/表数据 + PushAppend
    UndoBuffer::WriteToWAL
  重新取得 transaction_lock
分配 commit_id
DuckTransaction::Commit
  LocalStorage::Commit（之前已移走的本地项不会重复 flush）
  UndoBuffer::Commit（可见性/约束/依赖检查与版本号发布）
  commit_state.FlushCommit → WAL_FLUSH + writer.Sync
  CommitDropState::FinalizeCommit
移出 active_transactions → 排队/执行 Cleanup
必要时 CreateCheckpoint
```

不能写成“先 fsync WAL，再应用所有内存 commit”。当前代码先提交 Undo 版本，在 transaction_lock 保持期间 FlushCommit；失败再 RevertCommit。也不能写成“分配 commit_id 后才始终 WriteToWAL”：管理器的常规 WAL 准备发生在分配 commit_id 前。

### 6.2 LocalStorage 如何转入共享存储

`LocalStorage::Flush` 对 bulk append，或空表且不可写盘、无本地删除的特定路径，先 FlushBlocks、AppendToIndexes，再 MergeStorage；其他路径撤销不适用的 optimistic blocks 后，AppendToIndexes、AppendToTable。最后 PushAppend。

全局索引通过扫描数据追加，不是所有事务都直接 MergeIndexes。数据可能已转入共享结构但仍带本事务未提交版本，因此“共享物理位置”与“其他快照可见”不同。

### 6.3 无 WAL 与自动 checkpoint 分支

`ShouldWriteToWAL` 排除无修改、system、NO_WAL_WRITES、没有可写 WAL 的情形。自动 checkpoint 满足条件且变更估计达到 AutoCheckpointSkipWalThreshold 时，可选择跳过本事务 WAL，由 checkpoint 提供持久化；此时保持 WAL 锁阻止后续提交越过它。若重新评估不能 checkpoint，会补写 WAL。

checkpoint 失败时，已写 WAL 的分支记录 autocheckpoint error；未写 WAL 的分支合并返回错误。不能简单归纳成“每次提交必 fsync WAL”或“所有 checkpoint 错误都代表原事务已撤销”。

## 七、失败回滚与延迟资源回收

`DuckTransaction::Commit` 捕获错误后逆序 `UndoBuffer::RevertCommit` 恢复未提交版本，commit_state 尝试撤回 WAL 写入；管理器再执行 Rollback。恢复过程本身失败会 invalidate 数据库，阻止继续假设状态一致。

`DuckTransaction::Rollback` 先 LocalStorage::Rollback，再 UndoBuffer::Rollback；后者在 [rollback_state.cpp](../src/transaction/rollback_state.cpp) 分别恢复 Catalog、RevertAppend、撤销删除和更新。已经进入共享表/索引的数据需要相应撤销，不能仅丢弃本地存储。

当前管理器维护 active_transactions、recently_committed_transactions 与 cleanup_queue，不再有旧文档的 old_transactions 列表。`UpdateLowestVisibilityBound` 计算所有活跃快照最小 bound；`SweepCommittedTransactions` 将 commit_id 小于该 bound 的保留事务移入 cleanup info。`CleanupTransactions` 在释放 transaction_lock 后，由 cleanup_lock 串行按队列处理，不能宣称每次 GC 都由独立异步线程执行。

[cleanup_state.cpp](../src/transaction/cleanup_state.cpp) 清理 Catalog 旧 entry、追加版本信息、删除/更新 Undo；当前删除与索引 delta 的处理还涉及提交时移除及旧读者保留，不能把所有索引删除都推迟到 Cleanup。

## 八、checkpoint 与锁的粒度

[DuckTransaction::SetModifications](../src/transaction/duck_transaction.cpp) 按修改类型申请锁：UpdateData/AlterTable/CreateCatalogEntry/DropCatalogEntry/Sequence/CreateIndex 需要共享 checkpoint 锁；InsertData/DeleteData 申请共享 vacuum 锁。它不是所有读写事务启动就统一持共享 checkpoint 锁。

| 锁 | 作用 |
|---|---|
| transaction_lock | 事务列表、时间戳、提交期间的协调；WAL 写入期间可暂时释放 |
| WAL lock | 序列化相关提交与 WAL/checkpoint 切换 |
| start_transaction_lock | FORCE CHECKPOINT 与事务开启协调 |
| checkpoint/vacuum StorageLock | 阻止冲突修改或移动 rowid；两种锁职责不同 |
| RowVersionManager / UpdateSegment 锁 | 版本结构访问，具体锁型以实现为准 |
| Catalog write_lock + set catalog_lock | 元数据写临界区、读写集合保护 |
| cleanup_lock | 按序清理 |

`CanCheckpoint/GetCheckpointType` 在其他事务活跃且本事务含更新或删除 Catalog 条目时可能拒绝自动 checkpoint；可接受的追加/删除场景使用 CONCURRENT_CHECKPOINT。存储层还可因取不到 vacuum 独占锁将 FULL 降为 CONCURRENT。详见 [STARTUP_AND_CRASH_RECOVERY_DESIGN.md](STARTUP_AND_CRASH_RECOVERY_DESIGN.md)。

## 九、MetaTransaction 与隔离范围

[meta_transaction.cpp](../src/transaction/meta_transaction.cpp) 的 `GetTransaction` 按 AttachedDatabase 延迟创建子事务，`ModifyDatabase` 限制一个事务只能写一个普通 attached database，system/temp 例外。Commit 逆序逐个提交；遇错对尚未提交的子事务回滚，不会反向撤销已经提交的子事务。因此它不是通用两阶段提交，也不能宣称“任一失败则所有库全部回滚”。

对内置表的普通事务读取，快照规则排除其他事务的未提交版本，并维持固定 view；这不等于可串行化，也不覆盖所有 volatile 函数、外部数据源与跨库延迟子事务的统一全局快照。本文没有运行隔离级别异常测试，避免用“绝不幻读”的泛化表格替代具体可见性规则。

相关文档：[CATALOG_TRANSACTION_DESIGN.md](CATALOG_TRANSACTION_DESIGN.md)、[DEPENDENCY_MANAGER_DESIGN.md](DEPENDENCY_MANAGER_DESIGN.md)、[ART_INDEX_DESIGN.md](ART_INDEX_DESIGN.md)。
