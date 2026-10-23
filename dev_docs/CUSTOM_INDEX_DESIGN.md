# DuckDB 自定义索引（Custom Index）设计文档

> 适用源码：`v2.0-cyanoptera` @ `c1cd2470a455`；核对日期：2026-10-23。核对方式：静态源码审查，未执行本文示例或性能测试。

## 概述

扩展索引由 `IndexType` 描述构建/恢复回调，由 `BoundIndex` 实现运行时数据结构。本文依据当前 C++ 内部接口，不将它视为跨版本稳定 ABI。内置 ART 可作参考，但“能 CREATE INDEX”不等于自动获得查询规划支持或完整事务能力。

## 一、整体架构与生命周期

```text
IndexTypeSet：类型注册表
  → IndexType：build_* / create_plan / create_instance
    → CREATE INDEX：PhysicalCreateIndex → BoundIndex
    → 持久化加载：UnboundIndex → IndexBinder → create_instance → BoundIndex
表的 TableIndexList / IndexEntry：管理实例、绑定状态、锁、增量与回放
```

源码：[index_type_set.cpp](../src/execution/index/index_type_set.cpp) 的 `RegisterIndexType/FindByName`；[unbound_index.cpp](../src/execution/index/unbound_index.cpp) 的 `UnboundIndex::Bind`；[index_binder.cpp](../src/planner/expression_binder/index_binder.cpp) 的 `IndexBinder::BindIndex`；[index_entry.cpp](../src/storage/index_entry.cpp) 的 `IndexEntry`。

类型名通过 `Identifier` 查找，重复注册会抛 `CatalogException`，不会覆盖已有类型。构造注册表时注册 ART。缺少类型时，绑定已有索引会报错；不存在“重启后自动重建空索引”的通用机制。

## 二、IndexType 构建接口

以下函数指针声明摘自 [index_type.hpp](../src/include/duckdb/execution/index/index_type.hpp)（仅省略 typedef 语法，保留参数/返回类型）：

```cpp
unique_ptr<IndexBuildBindData> build_bind(IndexBuildBindInput &);
bool build_sort(IndexBuildSortInput &);
unique_ptr<IndexBuildGlobalState> build_global_init(IndexBuildInitGlobalStateInput &);
unique_ptr<IndexBuildLocalState> build_local_init(IndexBuildInitLocalStateInput &);
void build_sink(IndexBuildSinkInput &, DataChunk &key_chunk, DataChunk &row_chunk);
void build_combine(IndexBuildCombineInput &);
unique_ptr<BoundIndex> build_finalize(IndexBuildFinalizeInput &);
PhysicalOperator &create_plan(PlanIndexInput &);
unique_ptr<BoundIndex> create_instance(CreateIndexInput &);
```

这些是接口签名说明，不是一组可直接编译的自由函数实现。

| 输入/阶段 | 内容与调用方 |
|---|---|
| Bind | context、DuckTableEntry、CreateIndexInfo、unbound expressions；在物理计划生成中调用，不是 SQL binder 阶段 |
| Sort | optional bind_data；只有该回调非空时询问是否排序 |
| Global/Local init | optional bind_data、context、table、info、expressions、物理 storage_ids |
| Sink | optional bind_data、global/local state、table、info；另外传 key_chunk 与单列 ROW_TYPE row_chunk |
| Combine | 与 Sink 的状态输入相同；调用可并发，扩展负责同步共享状态 |
| Finalize | 仅 global_state；返回最终索引，之后框架执行验证和注册 |
| Plan | context、LogicalCreateIndex、planner、table_scan、可选 index_info |

来源：[plan_create_index.cpp](../src/execution/physical_plan/plan_create_index.cpp) 的 `PhysicalPlanGenerator::CreatePlan(LogicalCreateIndex&)` 与 [physical_create_index.cpp](../src/execution/operator/schema/physical_create_index.cpp) 的各阶段。

### 2.1 默认构建链

```text
检查索引是否已存在 / DuckDB 表 / 表达式一致性 / 类型是否已注册
  → 创建 scan
  → 若 create_plan 非空：直接交给它，返回
  → 否则 build_bind
  → 可选 build_sort
  → Projection（索引表达式 + rowid）
  → Filter（通常过滤任何键列为 NULL 的行）
  → 可选 Sort（键列升序，rowid 作为 payload）
  → PhysicalCreateIndex
       global/local init → Sink → Combine → Finalize → 验证/注册
```

默认路径直接调用 `build_bind`、global/local init、sink、combine、finalize，不能将这些字段全部留空。`create_plan` 位于 build_bind 之前，因此默认的所有 build_* 回调都被绕过；自定义计划可以自行安排操作，但不能假定框架仍会调用 build_bind。

NULL 过滤有明确例外：`ALTER TABLE ADD PRIMARY KEY` 必须让 NULL 到达 Sink 并拒绝；ADD UNIQUE 与普通 CREATE INDEX 过滤 NULL。自定义 create_plan 则自行承担同等要求。

### 2.2 当前 ART 参考实现

[art_index.cpp](../src/execution/index/art/art_index.cpp) 的 `ARTBuildBind` 无条件设 `sorted=true`，新排序实现已包括 VARCHAR 和多列键；旧版“只对单列非 VARCHAR 排序”不再成立。BuildSink 接收已经求值的键并直接编码，不能将它误当成表布局输入再执行索引表达式。

Finalize 返回实例后，`PhysicalCreateIndex::Finalize` 无条件调用 `Vacuum()`、`Verify()`、`VerifyAllocations()`；只有 `ToString` 的非空断言受 `D_ASSERT` 影响。因此验证方法不能笼统写成“只在 debug 调用”。之后检查表仍是主存储版本；普通索引创建 catalog entry 并 `AddIndex`，ALTER ADD PRIMARY/UNIQUE 还更新表约束。

## 三、BoundIndex 接口与真实默认行为

声明：[bound_index.hpp](../src/include/duckdb/execution/index/bound_index.hpp)，默认实现：[bound_index.cpp](../src/execution/index/bound_index.cpp)。

实例名与构造参数使用 `Identifier`。基类保存物理/逻辑键类型、unbound/bound expressions 和表达式执行器；`Index` 保存 column IDs、IO manager 和数据库引用。

### 3.1 写入与表达式布局

| 接口 | 语义 |
|---|---|
| `Append(IndexLock &, DataChunk &, Vector &)` | 纯虚；ART 接收表的物理列布局，内部 ExecuteExpressions 后调用 Insert |
| `Append(..., IndexAppendInfo &)` | 默认退回旧三参数 Append，会忽略 info；需要模式/删除增量语义时必须覆写 |
| `Insert(IndexLock &, DataChunk &, Vector &)` | 纯虚；ART 接收已经求值的键，不再执行表达式 |
| `Insert(..., IndexAppendInfo &)` | 基类直接抛 NotImplementedException，不会自动退回三参数 Insert |
| `MergeIndexes(IndexLock &, BoundIndex &)` | 纯虚；目标已锁，调用者还要独占源索引；bool 返回失败必须处理 |

`Append(DataChunk&, Vector&, ...)` 与无锁参数的 `MergeIndexes` 包装会自行创建 `IndexLock`。不能在持目标锁的实现内部再次调用这些包装。`IndexAppendInfo` 现在包含 `append_mode` 与多个 `delete_indexes`（`vector<reference<const BoundIndex>>`），不是单一 delete_art 指针。

`DEFAULT`、`IGNORE_DUPLICATES`、`INSERT_DUPLICATES` 是底层插入策略；IGNORE_DUPLICATES 还用于删除索引记录，INSERT_DUPLICATES 还用于回放和 checkpoint 增量，不能与某一 SQL 语句一一对应。ART 的冲突失败通过 `ErrorData` 返回，但其他路径也会抛异常，不能保证统一“不抛异常”。

### 3.2 删除、清空与资源回收

```cpp
virtual void ResetStorage(IndexLock &) = 0;
virtual idx_t TryDelete(IndexLock &, DataChunk &, Vector &,
    optional_ptr<SelectionVector> deleted_sel = nullptr,
    optional_ptr<SelectionVector> non_deleted_sel = nullptr);
virtual void Delete(IndexLock &, DataChunk &, Vector &);
```

这是省略线程注解的真实接口声明。基类 `TryDelete` 抛 `InternalException`；`Delete` 调用 TryDelete，若删除数不足则抛 `InvalidInputException`。不存在相互回退或“默认全部成功”。应实现正确的 TryDelete（或完整覆写相关路径）。

本版本没有 `BoundIndex::CommitDrop`；资源重置接口为 `ResetStorage`，DROP 的延迟资源回收由外围 `IndexEntry`/事务 `CommitDropState` 管理。不能用旧 CommitDrop 示例适配。

### 3.3 约束验证

`VerifyAppend(DataChunk&, IndexAppendInfo&, optional_ptr<ConflictManager>)` 与 `VerifyConstraint(DataChunk&, IndexAppendInfo&, ConflictManager&)` 默认都抛 `NotImplementedException`。它们在普通 DML 约束/冲突探测中使用，不仅在 COMMIT 才出现。

`GetConstraintViolationMessage(VerifyExistenceType, idx_t, DataChunk &) const` 是纯虚；ART 可记录 ConflictManager 命中，也会按 manager 语义抛约束异常。主键 NOT NULL 还由表约束与构建路径检查，不能只靠索引唯一性。

### 3.4 其他必须实现的接口

下列为省略锁注解的声明摘录：

```cpp
virtual void Vacuum(IndexLock &) = 0;
virtual idx_t GetInMemorySize(IndexLock &) const = 0;
virtual void Verify(IndexLock &) = 0;
virtual string ToString(IndexLock &, bool display_ascii = false) = 0;
virtual void VerifyAllocations(IndexLock &) = 0;
virtual string GetConstraintViolationMessage(VerifyExistenceType, idx_t, DataChunk &) const = 0;
```

`VerifyBuffers(IndexLock&)` 不是默认空实现，而是抛 `NotImplementedException`；需要支持调用该方法的路径。Vacuum 的实际调用见索引构建/存储路径，不能理解为只由 SQL VACUUM 或系统空闲触发。

## 四、持久化、恢复与增量

### 4.1 序列化接口

```cpp
virtual IndexStorageInfo SerializeToDisk(QueryContext, const case_insensitive_map_t<Value> &);
virtual IndexStorageInfo SerializeToWAL(const case_insensitive_map_t<Value> &);
```

两者默认均抛 `NotImplementedException`，不是返回空 IndexStorageInfo。`SerializeToDisk` 的实现负责自身同步；`SerializeToWAL` 的接口要求调用者独占索引。

[IndexStorageInfo](../src/include/duckdb/storage/index_storage_info.hpp) 包含 name、root、options、allocator_infos、WAL buffers 和旧格式 root_block_ptr。block_pointers 在各 `FixedSizeAllocatorInfo` 内，不是顶层字段。`IsValid()` 只检查旧 root_block_ptr 或 allocator_infos；空索引可能为 false，所以恢复构造必须能正确初始化空索引。

`create_instance` 的 [CreateIndexInput](../src/include/duckdb/execution/index/index_type.hpp) 提供 context、IO manager、db、constraint_type、`const Identifier &name`、column_ids、unbound_expressions、storage_info、options。恢复必须正确还原已有内容；返回空树不是重建协议，会破坏正确性。

### 4.2 延迟回放与 checkpoint 增量是两套职责

`UnboundIndex::BufferChunk` 按稳定的物理列映射缓冲 INSERT/DELETE，记录交错范围；Bind 后 `ApplyBufferedReplays` 按范围顺序应用。无论索引是否支持 checkpoint delta，都不能据此推断“WAL 回放改用 LOCAL_APPEND/LOCAL_DELETE 枚举”。

当前 `IndexDeltaType` 仅有：

- `DELETED_ROWS_IN_USE`：旧快照可能仍需的删除行。
- `ADDED_DATA_DURING_CHECKPOINT`。
- `REMOVED_DATA_DURING_CHECKPOINT`。

没有旧文档中的 `DeltaIndexType` 实例字段或 `CreateDeltaIndex` 方法。现在由 `IndexEntry`/`IndexDeltas` 管理，`SupportsDeltaIndexes()` 默认 false；扩展若返回 true，需实现受保护的 `CreateEmptyCopy(IndexConstraintType) const` 和 `MergeCheckpointDelta(IndexDeltaType, BoundIndex&)`，默认都抛内部错误。事务本地约束索引的创建也使用这套能力声明；它不只是 WAL 性能选项。

来源：[index_entry.cpp](../src/storage/index_entry.cpp) 的 `InitializeLocalIndexes`、`ApplyIndexRemoval`、`IndexDeltas::GetOrCreate/MergeCheckpointDeltas`，以及 [unbound_index.cpp](../src/execution/index/unbound_index.cpp)。

## 五、实现步骤与常见陷阱

建议按以下交付顺序设计扩展；这是检查清单，不是已验证的完整教程：

1. 明确键类型、NULL、唯一性/外键、表达式布局、并发与磁盘格式，再实现 BoundIndex 的纯虚接口和会被实际调用的默认抛错接口。
2. 定义共享的 bind/global/local 派生类型，供所有回调使用。不要在不同函数里各定义一个同名局部 struct 后交叉 Cast；它们是不同 C++ 类型。
3. 实现默认 build_* 回调，或提供完整 create_plan；Sink 使用已求值键，Append 使用表布局，两条入口不可混用。
4. 注册 `IndexType`，确保构建与已有索引 Bind 时该类型已可用；重名是错误。
5. 完整实现序列化和 create_instance，再核对空索引、重启、回放、checkpoint、回滚、旧快照和失败恢复。
6. 单独设计查询访问路径。当前 [table_scan.cpp](../src/function/table/table_scan.cpp) 的 `TableScanInitGlobal` 显式筛选 ART；注册其他类型不会自动进入通用索引扫描。

省略数据结构、删除逻辑、持久化与恢复的“返回成功”骨架不能作为可用扩展。旧版文档那类 MyIndex 示例已移除，以免将缺失接口、错误 const 签名与静默丢数据的工厂当成可直接使用的实现。

## 六、事务与审查边界

[local_storage.cpp](../src/storage/local_storage.cpp) 的 `LocalStorage::Flush` 会扫描本地数据追加到全局索引，再合并/追加表数据；不能统一画成 `MergeIndexes(local→global)`。该接口也用于 CREATE INDEX 的树合并，其存在不代表所有 COMMIT 都采用结构合并。

锁、数据页、MVCC 可见性、WAL 与失败回滚共同保证内置实现的行为，扩展仍需遵循相应契约。详见 [ART_INDEX_DESIGN.md](ART_INDEX_DESIGN.md)、[TRANSACTION_MVCC_DESIGN.md](TRANSACTION_MVCC_DESIGN.md)。本文只核对声明、实现和调用方，没有编译自定义索引或验证 SQL/持久化兼容性。
