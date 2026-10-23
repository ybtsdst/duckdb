# DuckDB 元数据（Catalog）管理与事务支持设计文档

> 适用源码：`v2.0-cyanoptera` @ `c1cd2470a455`；核对日期：2026-10-23。核对方式：静态源码审查，未执行本文示例或性能测试。

## 概述

本文描述内置 `DuckCatalog` 的版本链、锁、依赖验证与事务提交。`Catalog` 是扩展接口，其他存储扩展的实现不自动继承全部内置行为；函数注册、进程配置与外部系统状态也不能一概视作可回滚、可 WAL 持久化的用户 Catalog 对象。

## 一、总体架构

```text
DatabaseInstance
  → 多个 AttachedDatabase
    → 各自的 DuckCatalog（或扩展 Catalog）
       → schema CatalogSet
         → SchemaCatalogEntry（可有嵌套 schema）
           → 各类 CatalogSet → CatalogEntry 版本链
       → DependencyManager（subjects/dependents 两个 CatalogSet）
```

每个 DuckCatalog 管理自己的依赖，非整个 DatabaseInstance 唯一的一套。入口见 [duck_catalog.hpp](../src/include/duckdb/catalog/duck_catalog.hpp)、[catalog_set.hpp](../src/include/duckdb/catalog/catalog_set.hpp)、[catalog_entry.hpp](../src/include/duckdb/catalog/catalog_entry.hpp)。

## 二、CatalogTransaction 与可见性

[CatalogTransaction](../src/include/duckdb/catalog/catalog_transaction.hpp) 当前保存 db/context/transaction 可选引用与 `SnapshotView view`，不再直接持有 `transaction_id/start_time` 两个字段。构造实现见 [catalog_transaction.cpp](../src/catalog/catalog_transaction.cpp)：有 ClientContext 时取得对应 Catalog 的事务及快照；system transaction 使用专门构造的可见性边界。

[transaction_data.hpp](../src/include/duckdb/transaction/transaction_data.hpp) 的真实规则是：

```cpp
// SnapshotView::Sees 的函数体摘录
return timestamp < visibility_bound || timestamp == transaction_id;
```

[constants.hpp](../src/include/duckdb/common/constants.hpp) 的 `VisibilityBound::Before(t)` 表示 `< t`，`Through(t)` 表示 `< t+1`。普通新事务以 Before(start_time) 开始，但提交验证和系统扫描会构造不同 bound，不能把所有调用方统一代回 start_time。

[catalog_set.cpp](../src/catalog/catalog_set.cpp) 中：

- `UseTimestamp` 调用 `view.Sees(timestamp)`。
- `HasConflict` 返回 `!view.Sees(timestamp)`，覆盖其他活跃事务和快照之外的提交。
- `GetEntryForTransaction` 沿 root→child 查找可见版本。带 visible 输出的重载在走到底层 dummy 时置 false；返回引用不单独代表该对象存在且可见，调用方还要检查 deleted/lookup 状态。

```text
名称映射 → 最新 CatalogEntry（可能未提交/删除墓碑）
            → child：前一版本 → 更早版本 → 初始 dummy
```

这里的冲突基于版本可见性，不能继续用旧伪代码的 `timestamp > start_time` 代替当前边界比较。

## 三、DDL 创建、修改、删除与锁

来源：[catalog_set.cpp](../src/catalog/catalog_set.cpp) 的 `CreateEntry/CreateEntryInternal`、`AlterEntry`、`DropDependencies/DropEntry`、`Undo`。

### 3.1 创建路径

```text
检查 entry 不变量
→ timestamp = 当前 transaction_id，set = 本集合
→ DependencyManager::AddObject（先于下面的写锁）
→ DuckCatalog::GetWriteLock（mutex）
→ CatalogSet::catalog_lock（mutex，阻止本集合读取）
→ 检查空位/冲突、必要时创建 dummy 链
→ map.UpdateEntry 将新版本置为链头
→ 将旧 child 压入事务 Undo Buffer
```

旧文档把 AddObject 放在持双锁期间，还把 catalog_lock 称为读锁，都不符合当前实现。变量名 `read_lock` 不改变它是互斥锁的事实。

### 3.2 ALTER / DROP

ALTER 创建新 CatalogEntry 版本并处理重命名、依赖更新和 Undo 信息；DROP 先检查并处理依赖，再持 Catalog 写锁和集合锁安装删除版本。锁并非贯穿整个用户事务，也不是所有事务只允许一个 DDL；它们保护具体元数据操作的临界区，版本冲突另行检测。

普通查找/扫描也取得 `catalog_lock`，因此 MVCC 避免等候其他事务结束，不等于所有读操作完全无锁或永不阻塞。依赖调整可能访问多个集合，不能根据局部流程图推导任意外部调用的锁顺序。

### 3.3 回滚与清理

[duck_transaction.cpp](../src/transaction/duck_transaction.cpp) 的 `PushCatalogEntry` 在 Undo 中记录旧 entry 指针与可选 ALTER 数据；[undo_buffer.cpp](../src/transaction/undo_buffer.cpp) 逆序 Rollback，由 [rollback_state.cpp](../src/transaction/rollback_state.cpp) 调用 `CatalogSet::Undo` 移除本事务新版本、恢复链。

成功提交不会立即销毁所有旧版本；无快照仍需要时，cleanup 才调用 `CatalogSet::CleanupEntry`。已有读者仍可能需要历史 CatalogEntry。详见 [TRANSACTION_MVCC_DESIGN.md](TRANSACTION_MVCC_DESIGN.md)。

## 四、提交与依赖竞态检查

入口：[duck_transaction_manager.cpp](../src/transaction/duck_transaction_manager.cpp) 的 `CommitTransaction`；内存提交：[duck_transaction.cpp](../src/transaction/duck_transaction.cpp) 的 `WriteToWAL/Commit`；条目处理：[commit_state.cpp](../src/transaction/commit_state.cpp) 的 `CommitState::CommitEntry`。

1. 视 WAL/checkpoint 分支准备 LocalStorage 与 WAL，分配 commit_id。
2. `UndoBuffer::Commit` 处理版本发布前的检查。
3. 新建 SUBJECT 依赖记录调用 `VerifyExistenceOfDependency`；DROP 调用 `CommitDrop`，验证并发新增依赖。
4. 持 Catalog 写锁与集合锁将新 entry timestamp 改为 commit_id；相关物理资源删除进入 CommitDropState。
5. 有 WAL commit_state 时，成功处理 Undo 后 FlushCommit；之后 FinalizeCommit 释放延迟资源。
6. 失败通过 RevertCommit/事务 Rollback 恢复；恢复本身失败可使数据库失效，不能承诺任何故障都无条件回滚成功。

提交验证有精确不同边界：

| 调用 | 构造的已提交视图 |
|---|---|
| `CatalogSet::VerifyExistenceOfDependency` | transaction_id=`MAX_TRANSACTION_ID`，bound=`Through(commit_id)`，包含当前 commit_id |
| `CatalogSet::CommitDrop` | transaction_id=`MAX_TRANSACTION_ID`，bound=`Before(commit_id)`，不包含当前 commit_id |

`DependencyManager::VerifyExistence` 除检查被删除，还对非 ownership 且保存了 subject OID 的记录验证身份，拒绝“同名对象被 drop/recreate”。`VerifyCommitDrop` 与原事务 visibility_bound 比较，拒绝快照之外新提交的依赖。更多见 [DEPENDENCY_MANAGER_DESIGN.md](DEPENDENCY_MANAGER_DESIGN.md)。

## 五、WAL 与对象类型边界

[wal_write_state.cpp](../src/transaction/wal_write_state.cpp) 的 `WriteCatalogEntry` 会跳过 entry 或其 parent 为 temporary 的记录，并按具体 CatalogType 写支持的记录。内存库、系统库、只读加载/恢复模式、自动 checkpoint 替代 WAL 等还影响是否实际写 WAL，不能概括为“每次 Catalog 修改都写日志”。

[wal_type.hpp](../src/include/duckdb/common/enums/wal_type.hpp) 包含 CREATE/DROP TABLE、SCHEMA、VIEW、SEQUENCE、MACRO、TYPE、TABLE_MACRO、INDEX，ALTER_INFO，以及当前新增的 `CREATE_TRIGGER=30`、`DROP_TRIGGER=31`；WAL_FLUSH=100 是事务重放边界。无需把 SQL/内部所有 CatalogType 都假定映射为独立 WAL 类型。

持久化加载还受目标 StorageVersion、Catalog 条目各自序列化逻辑和扩展可用性限制。头格式、并发 checkpoint、主/辅助 WAL 的恢复见 [STARTUP_AND_CRASH_RECOVERY_DESIGN.md](STARTUP_AND_CRASH_RECOVERY_DESIGN.md)。

## 六、依赖、嵌套 schema 与触发器

当前对象身份包含类型、`schema_path`（从外到内的包含 schema）、name，以及触发器的 owning table；不能只用一段 schema 字符串识别所有对象。依赖标志新增 ALTER_BLOCKING，DROP 与 ALTER 阻塞策略并不总是相同。

`DuckSchemaEntry` 为表、索引、嵌套 schema 等建立相应依赖；Binder 为触发器和索引表达式收集实际依赖。不能仅从“视图查询了表”推导所有视图引用都被 DependencyManager 完整追踪，应该以创建路径提交的 LogicalDependencyList 为准。详见 [duck_schema_entry.cpp](../src/catalog/catalog_entry/duck_schema_entry.cpp)、[bind_create.cpp](../src/planner/binder/statement/bind_create.cpp)、[index_binder.cpp](../src/planner/expression_binder/index_binder.cpp)。

## 七、扩展元数据管理建议

| 元数据 | 可复用的机制与限制 |
|---|---|
| 普通表中的数据 | 复用内置表 DML、约束、MVCC、WAL；仍需事务与持久库条件成立 |
| 原生可持久化 Catalog 对象 | 复用对应对象实现的 Undo/依赖/序列化；新增类型需接入完整路径 |
| 函数/类型注册 | 复用注册入口，不能据此假定函数指针可 WAL 序列化、重启自动恢复 |
| 外部系统对象 / 自定义 Catalog | 由其 TransactionManager、存储与协调协议决定，不自动获得 DuckCatalog 的原子性 |
| Secret Manager | 独立的 secret 存储语义，不等同于普通用户元数据表或通用事务容器 |

例如可选择普通表存储插件状态，以下仅是未经执行的 SQL 示意，不规定加载扩展时自动建表：

```sql
CREATE SCHEMA IF NOT EXISTS extension_state;
CREATE TABLE IF NOT EXISTS extension_state.metadata (
    key VARCHAR PRIMARY KEY,
    value VARCHAR,
    updated_at TIMESTAMP DEFAULT now()
);
```

使用附加数据库可隔离文件，但不能推导跨多个持久库的原子写入；`MetaTransaction::ModifyDatabase` 当前限制一个事务只修改一个普通 attached database，system/temp 例外。不存在可供扩展直接套用的全局两阶段提交保证。
