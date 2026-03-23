# DependencyManager 设计文档

## 概述

`DependencyManager` 是 DuckDB Catalog 系统的核心组件之一，负责追踪和管理 Catalog 对象之间的依赖关系。它确保在对象被删除或修改时，所有依赖该对象的其他对象能得到正确处理——或随之级联删除，或阻止操作并给出明确错误信息。

**关键源码位置：**

| 文件 | 说明 |
|------|------|
| `src/include/duckdb/catalog/dependency_manager.hpp` | DependencyManager 主类及相关结构体 |
| `src/include/duckdb/catalog/dependency.hpp` | 依赖标志位、CatalogEntryInfo、Dependency 结构体 |
| `src/include/duckdb/catalog/dependency_list.hpp` | 创建对象时使用的依赖列表 |
| `src/include/duckdb/catalog/dependency_catalog_set.hpp` | CatalogSet 的过滤适配器 |
| `src/include/duckdb/catalog/catalog_entry/dependency/dependency_entry.hpp` | 依赖记录的基类 |
| `src/include/duckdb/catalog/catalog_entry/dependency/dependency_subject_entry.hpp` | Subject 侧记录 |
| `src/include/duckdb/catalog/catalog_entry/dependency/dependency_dependent_entry.hpp` | Dependent 侧记录 |
| `src/catalog/dependency_manager.cpp` | 全部实现逻辑（824 行） |

---

## 一、总体架构

### 1.1 在 Catalog 层次中的位置

`DependencyManager` 由 `DuckCatalog` 持有，是整个数据库实例（`DatabaseInstance`）生命周期内唯一的依赖管理器：

```
DatabaseInstance
  └── AttachedDatabase
        └── DuckCatalog
              ├── CatalogSet (schemas)
              │     └── SchemaCatalogEntry
              │           └── CatalogSet (tables/views/functions/...)
              │                 └── CatalogEntry (具体对象)
              └── DependencyManager     ← 依赖关系管理（本文档主题）
                    ├── CatalogSet subjects   ← 记录"A 依赖于 B"（从 A 视角）
                    └── CatalogSet dependents ← 记录"B 被 A 依赖"（从 B 视角）
```

### 1.2 核心职责

1. **依赖追踪**：当 Catalog 对象创建时，记录其依赖的其他对象。
2. **删除保护**：删除对象前检查是否有其他对象依赖它，视情况阻止或级联删除。
3. **修改保护**：修改（ALTER）对象时，检查并更新依赖引用。
4. **所有权管理**：维护"A 拥有 B"关系，使 B 随 A 的删除而自动删除。
5. **导出排序**：为 EXPORT DATABASE 功能提供按依赖关系的拓扑排序。
6. **事务一致性**：提交时验证依赖的被依赖对象仍然存在，并检测并发创建的竞争条件。

---

## 二、核心数据结构

### 2.1 依赖关系的两端

每个依赖关系有两端：

```
DependencySubject（被依赖方，即"主体"）
  ├── entry: CatalogEntryInfo   // 被依赖的对象信息
  └── flags: DependencySubjectFlags
        └── OWNERSHIP（bit 0）: 该对象被 dependent 所拥有

DependencyDependent（依赖方，即"从属"）
  ├── entry: CatalogEntryInfo   // 存在依赖的对象信息
  └── flags: DependencyDependentFlags
        ├── BLOCKING（bit 0）: 阻塞型依赖（需要 CASCADE 才能删除）
        └── OWNED_BY（bit 1）: 该对象被 subject 所拥有
```

`DependencyInfo` 将两端合并为一个依赖描述：

```cpp
struct DependencyInfo {
    DependencyDependent dependent;  // 依赖方
    DependencySubject   subject;    // 被依赖方
};
```

### 2.2 对象标识：CatalogEntryInfo

所有依赖操作中对象的引用都通过 `CatalogEntryInfo` 传递（而不是 `CatalogEntry` 指针），以支持跨版本链的稳定识别：

```cpp
struct CatalogEntryInfo {
    CatalogType type;   // 对象类型（TABLE_ENTRY、VIEW_ENTRY 等）
    string      schema; // Schema 名称（不区分大小写）
    string      name;   // 对象名称（不区分大小写）
};
```

相等性比较使用 `StringUtil::CIEquals`（大小写不敏感）。

### 2.3 名称混淆（Name Mangling）

为了将多条依赖记录存入同一个 `CatalogSet`，`DependencyManager` 对键名进行特殊编码：

**MangledEntryName**（单对象键）：
```
格式：{CatalogTypeString}\0{Schema}\0{Name}
示例：TABLE\0main\0orders
含有 2 个 null 字节
```

**MangledDependencyName**（依赖对键）：
```
格式：{MangledEntryName_from}\0{MangledEntryName_to}
示例：VIEW\0main\0order_view\0TABLE\0main\0orders
含有 5 个 null 字节
```

> 在 DEBUG 模式下，`AssertMangledName` 会验证 null 字节数量以确保编码正确。

### 2.4 标志位：DependencyFlags

所有标志位类都继承自 `DependencyFlags`，使用 `uint8_t` 存储位掩码：

```
DependencySubjectFlags（被依赖方标志）
  bit 0 = OWNERSHIP：该 subject 被 dependent 所拥有

DependencyDependentFlags（依赖方标志）
  bit 0 = BLOCKING：标准阻塞依赖，删除 subject 时需 CASCADE
  bit 1 = OWNED_BY：该 dependent 被 subject 拥有，随 subject 一起生死
```

标志位支持合并（`Apply`/`Merge`），更新依赖时会合并新旧标志位，保留已有的特殊标志（如 OWNERSHIP）。

### 2.5 依赖记录条目

依赖关系存储为特殊的 `CatalogEntry` 子类（`DependencyEntry`），不对应真实的数据库对象，仅用于内部追踪：

```
DependencyEntry（抽象基类，继承自 InCatalogEntry）
  ├── DependencySubjectEntry：存储在 subjects CatalogSet，记录"A 依赖于 B"
  └── DependencyDependentEntry：存储在 dependents CatalogSet，记录"B 被 A 依赖"
```

每个 `DependencyEntry` 存储完整的 `DependencyDependent` 和 `DependencySubject` 信息，支持从任一侧重建完整依赖关系。

### 2.6 DependencyCatalogSet（过滤适配器）

`DependencyCatalogSet` 是对 `CatalogSet` 的轻量封装，它将操作范围限定在特定对象的依赖记录上：

```cpp
class DependencyCatalogSet {
    CatalogSet       &set;           // subjects 或 dependents CatalogSet
    CatalogEntryInfo  info;          // 过滤目标（哪个对象的依赖）
    MangledEntryName  mangled_name;  // 预计算的混淆键前缀
};
```

所有 `Create`/`Get`/`Drop`/`Scan` 操作都会自动添加前缀过滤，使外部代码无需感知内部键名编码细节。

---

## 三、内部实现机制

### 3.1 双向存储模式

一条依赖关系同时在两个 `CatalogSet` 中创建两条记录，实现 O(1) 双向查找：

```
依赖：视图 V 依赖于表 T（V → T）

subjects CatalogSet（键：V 的混淆名，值：V 依赖的所有对象）
  "VIEW\0main\0V" → [DependencySubjectEntry: subject=T, dependent=V]

dependents CatalogSet（键：T 的混淆名，值：所有依赖 T 的对象）
  "TABLE\0main\0T" → [DependencyDependentEntry: subject=T, dependent=V]
```

- 查询"V 依赖哪些对象"：在 subjects 中按 V 的混淆名扫描
- 查询"有哪些对象依赖 T"：在 dependents 中按 T 的混淆名扫描

### 3.2 SystemEntry 过滤

以下类型的条目不参与依赖管理，所有操作会提前返回：

- `entry.internal == true`（内部系统对象）
- `CatalogType::DEPENDENCY_ENTRY`（依赖记录本身）
- `CatalogType::DATABASE_ENTRY`（附加数据库）
- `CatalogType::RENAMED_ENTRY`（重命名中间状态）

### 3.3 CascadeDrop 判断逻辑

```
CascadeDrop(cascade, flags) → bool（是否自动删除该 dependent）
  if cascade == true         → true（CASCADE 模式，强制删除一切）
  if flags.IsOwnedBy()       → false（该对象被 subject 拥有，不在此处级联；另由 OWNED 逻辑处理）
  return !flags.IsBlocking() （非阻塞依赖可自动删除；阻塞依赖须报错）
```

索引（`INDEX_ENTRY`）创建时不设置 `BLOCKING` 标志，因此删除关联表时索引总是自动删除，无需 CASCADE。

### 3.4 DEBUG 模式下的一致性验证

在 `ScanSetInternal` 中，DEBUG 模式会验证双向记录的对称性：

- 扫描 subjects 时，确认每条记录在 dependents 中有对应的反向记录
- 扫描 dependents 时，确认每条记录在 subjects 中有对应的反向记录

---

## 四、关键操作流程

### 4.1 添加对象（AddObject）

在 `CatalogSet::CreateEntry` 时被调用，注册新对象的依赖关系。

```
AddObject(transaction, object, dependencies)
  if IsSystemEntry(object) → return（跳过系统对象）
  
  CreateDependencies(transaction, object, dependencies)
    对每个 dependency in dependencies.Set():
      验证 dependency 与 object 在同一个 catalog（跨 catalog 依赖不支持）
      构造 DependencyInfo:
        dependent = {object, flags}          // 索引: 非阻塞; 其他: 阻塞
        subject   = {dependency.entry, {}}
      CreateDependency(transaction, info)
        → 合并已有标志位（若存在旧记录）
        → 删除旧记录（若有）
        → CreateDependent(transaction, info)  // 在 dependents 中写入
        → CreateSubject(transaction, info)    // 在 subjects 中写入
```

### 4.2 删除对象（DropObject）

在 `CatalogSet::DropEntry` 时被调用。

```
DropObject(transaction, object, cascade)
  if IsSystemEntry(object) → return

  to_drop = CheckDropDependencies(transaction, object, cascade)
    ScanDependents(transaction, object):
      对每个 dep:
        if NOT CascadeDrop(cascade, dep.flags):
          加入 blocking_dependents（将报错）
        else:
          加入 to_drop（将级联删除）
    if blocking_dependents 非空:
      → 抛出 DependencyException（含详细依赖链信息）
    ScanSubjects(transaction, object):
      对每个 dep:
        if dep.Subject().flags.IsOwnership():
          加入 to_drop（被该对象拥有的对象也一并删除）

  CleanupDependencies(transaction, object)
    收集 object 的所有 subjects 和 dependents 记录
    对每条记录调用 RemoveDependency（双向删除）

  for entry in to_drop:
    entry.set.DropEntry(transaction, entry.name, cascade)（递归处理）
```

### 4.3 修改对象（AlterObject）

在 `CatalogSet::AlterEntryInternal` 时被调用，更新依赖引用。

```
AlterObject(transaction, old_obj, new_obj, alter_info)
  if IsSystemEntry(new_obj) → return

  ScanDependents(old_obj):
    对每个依赖 old_obj 的对象（dep）:
      检查 alter_info 类型，以下情况允许存在 dependent：
        - FOREIGN_KEY_CONSTRAINT（外键约束的添加/删除）
        - ADD_COLUMN（新增列）
        - SET_COMMENT / SET_COLUMN_COMMENT（修改注释）
      其他情况：抛出 DependencyException
      记录 dep_info（将 subject 替换为 new_info）

  ScanSubjects(old_obj):
    保留 old_obj 的所有 subjects 依赖，更新 dependent 为 new_info

  if old_obj.name != new_obj.name（名称变更）:
    CleanupDependencies(transaction, old_obj)  // 删除旧的依赖记录

  for dep in dependencies:
    CreateDependency(transaction, dep)          // 重建依赖记录
```

### 4.4 添加所有权（AddOwnership）

由 `COPY TABLE` 等语句触发，建立"owner 拥有 entry"关系。

```
AddOwnership(transaction, owner, entry)
  if IsSystemEntry → return

  // 验证：owner 自身不能已被别人拥有
  ScanDependents(owner):
    if dep.flags.IsOwnedBy() → throw（owner 已被拥有）

  // 验证：entry 不能已经拥有其他对象（防止循环所有权）
  ScanSubjects(entry):
    if dep.flags.IsOwnedBy() → throw（entry 已拥有别的对象）

  // 验证：entry 不能已被其他 owner 拥有
  ScanDependents(entry):
    if dep.flags.IsOwnership() AND dep != owner → throw（entry 已有 owner）

  创建 DependencyInfo:
    dependent = {owner, OWNED_BY}
    subject   = {entry, OWNERSHIP}
  CreateDependency(transaction, info)
```

### 4.5 导出排序（ReorderEntries）

为 `PhysicalExport` 提供满足依赖顺序的对象列表（依赖靠前、被依赖靠后）。

```
ReorderEntries(entries, transaction)
  for each entry in entries:
    ReorderEntry(transaction, entry, visited, reordered)
      if already visited → return
      ScanSubjects(entry):
        for each dep（该 entry 依赖的对象）:
          递归 ReorderEntry(dep, ...)    // 深度优先，依赖优先输出
      visited.insert(entry)
      order.push_back(entry)
  entries = reordered
```

该算法是标准的 DFS 拓扑排序，保证无依赖的对象先被导出，有依赖的对象在其依赖对象之后被导出。

---

## 五、事务集成

### 5.1 与 CatalogTransaction 的关系

所有 `DependencyManager` 操作都接受 `CatalogTransaction` 参数。依赖记录本身存储在 `CatalogSet`（subjects/dependents）中，因此**依赖关系的创建和删除参与完整的 MVCC 事务**，与普通 Catalog 对象具有相同的 ACID 语义。

- 依赖记录的 `timestamp` 语义与普通 Catalog 条目完全一致（参见 `CATALOG_TRANSACTION_DESIGN.md`）。
- 依赖记录支持通过 Undo Buffer 回滚。
- 依赖记录的创建参与写写冲突检测。

### 5.2 提交时验证（VerifyExistence）

在事务提交阶段，`CatalogSet` 会调用 `DependencyManager::VerifyExistence` 验证新创建的依赖是否合法：

```
VerifyExistence(transaction, dependency_entry)
  取出 subject 的 CatalogEntryInfo
  在已提交的 Catalog 状态中查找该对象
  if 对象状态为 DELETED:
    → throw DependencyException
      "Could not commit creation of dependency, subject has been deleted"
```

这防止了以下竞争场景：事务 A 创建了依赖 B 的对象，但在 A 提交前，并发事务已删除了 B。

### 5.3 提交时 DROP 验证（VerifyCommitDrop）

在 DROP 操作提交时，`CatalogSet` 调用 `DependencyManager::VerifyCommitDrop` 检测并发创建的依赖：

```
VerifyCommitDrop(transaction, start_time, object)
  ScanDependents(object):
    if dep.timestamp > start_time:
      → throw DependencyException
        "Could not commit DROP because a dependency was created after the transaction started"
  ScanSubjects(object):
    if dep.IsOwnedBy() AND dep.timestamp > start_time:
      → throw DependencyException（同上）
```

时间戳比较用于区分：
- 本事务开始前已知的依赖（将被级联删除，不应报错）
- 本事务开始后新创建的依赖（真正的并发冲突，应报错）

---

## 六、外部依赖关系

### 6.1 DependencyManager 依赖的组件

| 组件 | 依赖方式 |
|------|----------|
| `DuckCatalog` | 持有 DependencyManager 的引用，获取 Schema、写锁等 |
| `CatalogSet` | subjects/dependents 依赖记录的存储容器 |
| `CatalogTransaction` | 所有操作的事务上下文，用于 MVCC 可见性判断 |
| `CatalogEntry` | 所有被管理对象的基类 |
| `LogicalDependencyList` | 创建对象时传入的依赖列表 |
| `AlterInfo` | 修改操作的描述，决定是否允许有 dependent 存在 |
| `StringUtil::CIEquals` | 对象名大小写不敏感比较 |

### 6.2 依赖 DependencyManager 的组件

| 组件 | 调用方式 |
|------|----------|
| `CatalogSet::CreateEntry` | 调用 `AddObject`，注册新对象的依赖关系 |
| `CatalogSet::DropEntry` / `DropDependencies` | 调用 `DropObject`，执行依赖检查和级联删除 |
| `CatalogSet::AlterEntryInternal` | 调用 `AlterObject`，更新依赖引用 |
| `CatalogSet::VerifyExistenceOfDependency` | 调用 `VerifyExistence`，提交时验证 |
| `CatalogSet::CommitDrop` | 调用 `VerifyCommitDrop`，提交 DROP 时检测并发竞争 |
| `PhysicalExport` | 调用 `ReorderEntries`，获取拓扑排序后的对象列表 |
| `Pragma duckdb_dependencies` | 调用 `Scan`，向用户展示所有依赖关系 |
| `COPY TABLE` 语句处理 | 调用 `AddOwnership`，建立所有权关系 |

### 6.3 与 ColumnDependencyManager 的区别

DuckDB 还有一个 `ColumnDependencyManager`（位于 `src/include/duckdb/catalog/catalog_entry/column_dependency_manager.hpp`），它与 `DependencyManager` 是完全独立的两套机制：

| 维度 | DependencyManager | ColumnDependencyManager |
|------|-------------------|------------------------|
| 管理范围 | Catalog 对象之间（跨表） | 表内列之间（同一表） |
| 典型场景 | 视图依赖表、索引依赖表 | 生成列依赖其他列 |
| 存储位置 | `DuckCatalog` 持有 | `TableCatalogEntry` 持有 |
| 事务支持 | 完整 MVCC | 随表整体管理 |

---

## 七、关键设计决策

### 7.1 为什么用两个 CatalogSet 而不是一个？

双向存储（subjects + dependents）使两个方向的查询都是 O(k)（k 为匹配记录数），避免全量扫描。删除对象时需要"被谁依赖"（查 dependents），导出排序时需要"依赖谁"（查 subjects），两者都是常见操作。

### 7.2 为什么要名称混淆？

一个 `CatalogSet` 的键命名空间是扁平的，而每个对象可能有多条依赖记录。名称混淆将"(类型, schema, 名称)"三元组编码为单一字符串键，同时用 null 字节分隔字段以避免拼接歧义，再用双重混淆名区分不同的依赖对。

### 7.3 为什么索引不设 BLOCKING 标志？

索引是表的附属对象，语义上属于表的一部分。删除表时自动删除索引是符合 SQL 语义的（无需用户显式 CASCADE），因此索引依赖被设为非阻塞（AUTOMATIC），由 `CascadeDrop` 逻辑自动处理。

### 7.4 时间戳比较在提交验证中的作用

`VerifyCommitDrop` 使用 `dep.timestamp > start_time` 而非简单检查依赖是否存在，是因为：在 CASCADE 场景下，本事务已经知晓并计划删除的依赖对象（在 `start_time` 之前创建）不应导致提交失败，只有在事务开始后新增的依赖（其他并发事务创建的）才应触发冲突。

---

## 八、参考资料

- `src/catalog/dependency_manager.cpp` — 完整实现
- `src/catalog/catalog_set.cpp` — `CreateEntry`、`DropEntry`、`AlterEntryInternal` 中对 DependencyManager 的调用点
- `src/execution/operator/persistent/physical_export.cpp` — `ReorderEntries` 的调用方
- `dev_docs/CATALOG_TRANSACTION_DESIGN.md` — Catalog 事务与 MVCC 设计，为理解依赖记录的事务语义提供背景
