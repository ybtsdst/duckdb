# DependencyManager 设计文档

> 适用源码：`v2.0-cyanoptera` @ `c1cd2470a455`；核对日期：2026-10-23。核对方式：静态源码审查，未执行本文示例或性能测试。

## 概述

`DependencyManager` 管理内置 DuckCatalog 已登记的对象依赖，决定 DROP/ALTER 的阻塞、自动删除与所有权传播。每个 DuckCatalog 各有一个 manager，不能称作整个数据库实例唯一的管理器；它也不是 SQL 文本引用的通用全量依赖分析器。

## 一、源码与双向结构

| 源码 | 职责 |
|---|---|
| [dependency_manager.hpp](../src/include/duckdb/catalog/dependency_manager.hpp) / [dependency_manager.cpp](../src/catalog/dependency_manager.cpp) | 双向存储、创建/删除/修改、提交验证、导出排序 |
| [dependency.hpp](../src/include/duckdb/catalog/dependency.hpp) | CatalogEntryInfo、subject/dependent flags |
| [dependency_list.hpp](../src/include/duckdb/catalog/dependency_list.hpp) | 创建入口传入的 LogicalDependencyList |
| [dependency_catalog_set.cpp](../src/catalog/dependency_catalog_set.cpp) | 前缀适配、Create/Get/Drop/Scan |
| [serialize_dependency.cpp](../src/storage/serialization/serialize_dependency.cpp) | 依赖身份/标志的存储版本条件 |
| [catalog_set.cpp](../src/catalog/catalog_set.cpp) | 创建/删除/ALTER 调用方与提交可见性 |

对于 A 依赖 B：dependent=A，subject=B。

```text
subjects：以 A 的 mangled 名为前缀，保存 A 所依赖的 B
 dependents：以 B 的 mangled 名为前缀，保存依赖 B 的 A
每条边写两条 DependencyEntry，均参与 CatalogSet 版本链
```

这不是一个键映射到边向量，而是各依赖对各自有完整复合键。前缀检索缩小范围，但不能宣称两个方向 O(1) 查全量依赖，复杂度还取决于 CatalogEntryMap 的搜索与匹配记录数。

## 二、身份与名称编码：2.0 的变化

[dependency.hpp](../src/include/duckdb/catalog/dependency.hpp) 的 `CatalogEntryInfo` 当前包含：

- `CatalogType type`。
- `vector<Identifier> schema_path`：从外到内的包含 schema，schema 自身不包括在自己的路径中。
- `Identifier name`。
- `Identifier table`：触发器等 schema 内不唯一条目的所属表。

相等性比较使用 Identifier 与完整 schema_path/table；不是旧 `(type, string schema, string name)`。

`MangledEntryName` 的实现格式为：

```text
Type\0[Schema\0 ...]Name[\0Table]
MangledDependencyName = Mangled(from)\0Mangled(to)
```

NULL 分隔符数量随 schema 深度和 table 字段变化，不固定为 2 和 5。`AssertMangledName` 的计数校验在 DEBUG 条件下；不是运行时保证。header 中旧格式注释不能代替当前构造函数。

序列化在 V2_0_0 起写 schema_path 与 table；更旧目标写 LegacySchema，读取兼容旧单 schema 名。`LogicalDependency` 的 flags 也从 V2_0_0 起写入，缺失时默认 BLOCKING。目标存储版本不是二进制分支名，必须保留这些条件。

## 三、标志与所有权方向

| 所在端 | 标志 | 含义 |
|---|---|---|
| Subject | OWNERSHIP (bit 0) | dependent 拥有此 subject |
| Dependent | BLOCKING (bit 0) | 默认 DROP 阻塞 |
| Dependent | OWNED_BY (bit 1) | 所有权关系中的特殊删除保护 |
| Dependent | ALTER_BLOCKING (bit 2) | 独立表达 ALTER 阻塞，当前触发器判断使用 |

`AddOwnership(owner, entry)` 实际构造 dependent=owner、subject=entry，分别设 OWNED_BY/OWNERSHIP。命名容易产生方向误读，应该依构造及 CheckDropDependencies 解释，而非只读 OWNED_BY 英文字面。它检查 owner 不已被拥有、entry 不已拥有其他对象、entry 不已被其他 owner 拥有。

`CascadeDrop` 的真实判断顺序：cascade=true 返回 true；否则 OWNED_BY 返回 false；其他返回 `!IsBlocking()`。删除 owner 时还会沿 subjects 上 OWNERSHIP 删除它拥有的 entry。这两部分合在一起才构成完整所有权语义。

内部对象、DEPENDENCY_ENTRY、DATABASE_ENTRY、RENAMED_ENTRY 由 `IsSystemEntry` 跳过，防止依赖记录递归依赖自己。

## 四、创建依赖

来源：`AddObject/CreateDependencies/CreateDependency`，调用方为 `CatalogSet::CreateEntry`。

```text
为新对象取得完整身份
→ 检查依赖所属 catalog 一致（拒绝跨 catalog）
→ 为每条边保留调用者 flags
→ 查找 subject，保存其 oid（找不到则内部错误）
→ 合并旧 flags，事务性删除旧双向记录
→ 创建 dependent 侧记录
→ 创建 subject 侧记录
```

当前不再给“所有非索引对象”硬编码 BLOCKING；LogicalDependencyList 本身携带 flags。仅有一个兼容修正：INDEX_ENTRY 的 flags **恰好**等于旧默认 BLOCKING 时，改为无标志。

[IndexBinder::BindCreateIndex](../src/planner/expression_binder/index_binder.cpp) 对索引与其表使用无标志依赖，使删表自动删索引；对索引表达式使用的其他对象（例如宏）使用 BLOCKING|ALTER_BLOCKING，防止 drop/replace/alter。不能概括为“索引所有依赖都不阻塞”。

## 五、DROP 与 ALTER

### 5.1 DROP

`CheckDropDependencies` 扫描 dependents，先 Lookup 当前事务可见对象：阻塞的收集为错误，允许级联的加入 to_drop；再扫描 subjects，将 OWNERSHIP 对象加入删除集合。`DropObject` 清理本对象的双向记录后，对 to_drop 递归调用目标集合 DropEntry。

`CatalogSet::DropEntry` 的依赖处理位于安装墓碑的写锁临界区之外，实际集合操作各自锁定并参与 Undo。MVCC 不消除底层 mutex。

### 5.2 ALTER

`AlterObject` 默认拒绝存在 dependent 的 ALTER，以下分支允许：

- ALTER TABLE 的 FOREIGN_KEY_CONSTRAINT、ADD_COLUMN、SET_DEFAULT。
- SET_COLUMN_COMMENT、SET_COMMENT。
- 依赖对象为 TRIGGER_ENTRY 且未设 ALTER_BLOCKING，且不是重命名 owning table。

其他分支仍可被更上层约束拒绝；此处允许不意味着 SQL 操作整体必成功。

依赖更新还读取 `alter_info.new_dependencies`：若提供新依赖，跳过旧非 ownership subject 边，清理旧记录、加入新依赖，再重建需保留的边。重命名同样清理旧身份。旧文档“总是完整保留原依赖，仅名称变更才重建”已不成立。

触发器 Binder 对所属表建立自动依赖，body 读取等额外引用可设 ALTER_BLOCKING；见 [bind_create.cpp](../src/planner/binder/statement/bind_create.cpp) 的 trigger 绑定路径。不要将所有视图都假设成 manager 已收集的依赖；以实际创建路径登记的边为准。

## 六、提交时的竞态验证

### 6.1 依赖创建：VerifyExistence

[CatalogSet::VerifyExistenceOfDependency](../src/catalog/catalog_set.cpp) 构造 `transaction_id=MAX_TRANSACTION_ID`、`visibility_bound=Through(commit_id)` 的已提交视图；[CommitState::CommitEntry](../src/transaction/commit_state.cpp) 仅对新 SUBJECT 侧依赖调用它。

`DependencyManager::VerifyExistence` 导航完整 schema_path，区分嵌套 schema 容器和普通对象。若 lookup reason 为 DELETED 则报依赖目标已删除；非 ownership 且记录了 subject oid 时，还比较当前同名对象 oid，拒绝并发 DROP 后重建的替代对象。它不只是检查名字仍存在。

### 6.2 对象删除：VerifyCommitDrop

`CatalogSet::CommitDrop` 使用 `transaction_id=MAX_TRANSACTION_ID`、`visibility_bound=Before(commit_id)`，调用 `VerifyCommitDrop` 时同时传原事务的 visibility_bound。若已提交 dependent 的 timestamp `>= visibility_bound`，说明新依赖不在原快照中，拒绝提交；subjects 方向只对 OWNED_BY 关系做同类检查。

普通事务 bound=Before(start_time)，但提交/系统上下文不同，不能把比较一律改成 `> start_time`。Through/Before 的区分保证检查创建依赖与提交删除时使用各自需要的提交集合。

## 七、导出排序、调试检查与能力边界

`ReorderEntry` 先递归 subjects（被当前对象依赖的条目），再插入 visited 并输出当前对象，因此依赖目标先输出，依赖者后输出。带 context 的 ReorderEntries 使用当前快照并排除 internal；无 context 版本用于 checkpoint，读取已提交对象且允许 internal。

它依赖现有图的不变量，不提供可从任意循环图安全返回的通用拓扑排序保证；visited 标记在递归之后，D_ASSERT 的条目数一致性也不能当作生产环境循环检测。

`ScanSetInternal` 在 DEBUG 验证双向记录对称；普通执行仍按 CatalogSet 事务视图读取。`ColumnDependencyManager` 管理表内生成列等列依赖，随表定义管理，不等于这套跨对象边。

本文保留双向存储、名称编码、所有权、DROP/ALTER、提交竞态和排序调用链；未运行 DDL 并发、嵌套 schema、触发器或存储兼容测试。相关视图边界见 [CATALOG_TRANSACTION_DESIGN.md](CATALOG_TRANSACTION_DESIGN.md) 与 [TRANSACTION_MVCC_DESIGN.md](TRANSACTION_MVCC_DESIGN.md)。
