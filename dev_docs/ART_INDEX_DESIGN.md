# DuckDB ART 索引设计与实现文档

> 适用源码：`v2.0-cyanoptera` @ `c1cd2470a455`；核对日期：2026-10-23。核对方式：静态源码审查，未执行本文示例或性能测试。

## 概述

ART（Adaptive Radix Tree）按编码后键的字节分支，用压缩前缀与不同容量节点减少空间开销。内置 `ART` 继承 `BoundIndex`，参与扫描、约束检查、构建、checkpoint 与事务索引增量。不能仅从树算法推导 SQL 可见性或恢复保证。

## 一、源码导航

| 文件 | 符号与职责 |
|---|---|
| [art.hpp](../src/include/duckdb/execution/index/art/art.hpp) / [art.cpp](../src/execution/index/art/art.cpp) | `ART` 接口、扫描、写入、约束、序列化 |
| [art_key.cpp](../src/execution/index/art/art_key.cpp) | `ARTKey` 类型编码、字符串转义、复合键拼接 |
| [node.hpp](../src/include/duckdb/execution/index/art/node.hpp) | `NodePtr`、NType、GateStatus |
| [art_operator.hpp](../src/include/duckdb/execution/index/art/art_operator.hpp) | `ARTOperator::Lookup/Insert/Delete`，实现就在头文件 |
| [prefix.hpp](../src/include/duckdb/execution/index/art/prefix.hpp) | 压缩前缀与前缀大小 |
| [iterator.cpp](../src/execution/index/art/iterator.cpp) | `Iterator` 的有序遍历 |
| [art_builder.cpp](../src/execution/index/art/art_builder.cpp) / [art_merger.cpp](../src/execution/index/art/art_merger.cpp) | 批量构建、树合并 |
| [art_index.cpp](../src/execution/index/art/art_index.cpp) | `ART::GetARTIndexType`、build_* 回调 |
| [plan_create_index.cpp](../src/execution/physical_plan/plan_create_index.cpp) | 通用 CREATE INDEX 物理计划 |
| [index_entry.cpp](../src/storage/index_entry.cpp) | `IndexEntry`、`IndexDeltas` 的锁与生命周期 |

旧文档中的 `Node` 类型名已变成 `NodePtr`；构建规划也不在 `plan_art.cpp`。

## 二、节点与指针

```text
NType
  PREFIX                公共前缀，可串联
  LEAF_INLINED          指针内嵌 rowid
  LEAF                  旧链式叶，兼容旧持久化布局
  NODE_4 / 16 / 48 / 256 字节分支节点
  NODE_7_LEAF / 15_LEAF / 256_LEAF  嵌套 rowid 树的叶
```

`NodePtr` 继承 [IndexPointer](../src/include/duckdb/execution/index/index_pointer.hpp)：底层 64 位布局为 metadata 8 位、offset 24 位、buffer ID 32 位。ART 的 metadata 最高位是 gate，其余位表示节点类型；LEAF_INLINED 时低 56 位保存 rowid。

Node4/16 用有序 key 数组与 child 数组，Node48 用 256 字节查表映射到 48 个 child，Node256 直接按字节定位。增长在容量满后需插入新 child 时发生；收缩有滞后阈值，Node48 删除后 count < 12 才收缩，Node256 删除后 count <= 36 收缩。具体见 [base_node.cpp](../src/execution/index/art/base_node.cpp)、[node48.cpp](../src/execution/index/art/node48.cpp)、[node256.cpp](../src/execution/index/art/node256.cpp)，不要把声明注释替代删除分支的精确比较。

重复键可由 gate 导向以 rowid 编码为键的嵌套 ART，末字节使用 7/15 个元素的小数组或 Node256Leaf 的位掩码。唯一索引在 DELETE+INSERT 提交的短暂阶段也可能包含两个 rowid，不能把 gate 等同于非唯一索引。

当前节点访问还有 [node_handle.hpp](../src/include/duckdb/execution/index/art/node_handle.hpp) 的 handle 抽象；buffer 可能换入/换出，不能把 NodePtr 误解为始终可解引用的原始地址。

## 三、键编码与类型范围

来源：`ART` 构造、`GenerateKeysInternal/GenerateKeyVectors`、`ARTKey::CreateKey/CreateARTKey`。

- 支持的物理类型为 BOOL、有符号/无符号 8/16/32/64/128 位整数、FLOAT、DOUBLE、VARCHAR。按物理表示支持不等于支持任意嵌套逻辑类型，构造函数对其他类型抛错。
- 固定宽度类型通过 [radix.hpp](../src/include/duckdb/common/radix.hpp) 的 `Radix::EncodeData` 转成可比较字节；浮点还需处理符号与特殊值，不能描述为“正数直接保持原始位”即可。
- 字符串对原字节 0 和 1 前置字节 1：`0 → [1,0]`，`1 → [1,1]`，最后追加 0。旧文档的 `[1,1]`/`[1,2]` 映射错误。
- 复合键拼接各键列编码；rowid 单独生成 row_id_keys，存入叶或嵌套树，不是统一追加到顶层复合键末尾。
- 任一索引键列为 NULL 时不生成普通键。主键 NOT NULL 由表约束与构建路径另行检查。
- GEOMETRY 在旧于 V1_5_0 或版本未知的索引中有旧表示转换分支；构建/恢复不能忽略索引自己的 storage_version。

此版本不再具有旧文档给出的 `MAX_KEY_LEN * prefix_count` 接口限制，不能据旧常量宣称固定最大键长或由本文保证无限长键可用。

## 四、扫描能力与 SQL 调用方

`ART::TryInitializeScan` 可识别与索引表达式匹配的常量比较、BETWEEN 与相应组合；非 NULL 的 `IS NOT DISTINCT FROM` 可转为等值，NULL 不在索引中。`ART::Scan` 分发 SearchEqual、SearchGreater、SearchLess、SearchCloseRange 或内部全扫，持 `IndexLock` 收集 rowid。

但 SQL 是否用索引还受 [table_scan.cpp](../src/function/table/table_scan.cpp) 的 `TryScanIndex/TableScanInitGlobal` 限制：

1. 仅尝试已绑定 ART；复合 ART（多个表达式）拒绝扫描。
2. 只能有一个被引用的物理列，并需找到相应下推 filter；多列表达式不支持。
3. 索引表达式必须与提取出的过滤表达式匹配；表达式索引不是一概不支持，也不是任意函数都能加速。
4. `max_count = max(index_scan_max_count, total_rows * index_scan_percentage)`；候选 rowid 过多可回退顺序扫描。
5. 同时探测 `DELETED_ROWS_IN_USE`、`ADDED_DATA_DURING_CHECKPOINT` 增量，保留可能仍需的候选，再由表读取的 MVCC 判断最终可见性。
6. 可能移动 rowid 的 vacuum 配置下，从探测到 fetch 期间持共享 vacuum 锁，保证 rowid 与 row-group 树配对。

因此不将 LIKE、OR 或索引列上的函数简单列为绝对支持/不支持；优化器如何转换、filter 如何下推以及上述调用方条件都必须成立。索引返回候选 rowid，不独立提供事务快照或 SQL 输出排序承诺。

## 五、写入与约束

[art.cpp](../src/execution/index/art/art.cpp) 的 `Append` 接收表布局并执行索引表达式；`Insert` 接收已求值键，`GenerateKeyVectors` 后调用 `InsertKeys`。两者不能笼统称为相同实现或按“全局/本地”划分接口。

`InsertKeys` 遇约束冲突会撤销本批此前插入的键，并返回带 `ConstraintException` 的 `ErrorData`。`ARTOperator::InsertIntoInlined` 结合 `IndexAppendMode` 与多个删除索引判断是否允许复用键。唯一索引已有 gate 时，当前 Insert 会抛 `FatalException`，源码将其当成不应发生的状态；旧文档“返回 TRANSACTION 后抛 write-write conflict”的代码已经不适用。

`VerifyAppend` 创建或复用 `ConflictManager`，转给 `VerifyConstraint`；后者持锁、执行表达式、逐键 Lookup、`VerifyLeaf`、FinishLookup，按 manager 的检查模式生成结果或抛错。VerifyLeaf 会排除删除索引中的相同 rowid，并处理短暂双 rowid 叶。外键使用 APPEND_FK/DELETE_FK 的存在性检查；源码仍有外键与 delete ART 支持的 FIXME，不能推广成所有复合场景均无边界。

UNIQUE 与 PRIMARY 都满足 `IsUnique()`，PRIMARY 的非 NULL 要求不由 IsUnique 单独表达。约束类型定义见 [index_constraint_type.hpp](../src/include/duckdb/common/enums/index_constraint_type.hpp)。

## 六、事务一致性、提交与回滚

来源：[local_storage.cpp](../src/storage/local_storage.cpp) 的 `LocalTableStorage::AppendToIndexes`、`LocalStorage::Flush`，以及 [index_entry.cpp](../src/storage/index_entry.cpp) 的索引操作。

```text
普通 INSERT → LocalStorage 行数据 / 必要的本地约束索引
提交准备 → AppendToIndexes 扫描数据追加到全局索引
         → MergeStorage 或 AppendToTable
         → PushAppend 记录已追加范围
事务 Commit → 发布 commit_id、WAL 同步（具体分支见事务文档）
失败 → RevertCommit / Rollback / RevertAppend 等恢复已改共享状态
```

不是每个表都拥有完整的本地普通索引副本：`InitializeLocalIndexes` 只为已绑定、非 NONE 约束且支持 delta 的索引建副本。也不能把所有 UPDATE 描述为 DELETE+INSERT；普通列更新由 UpdateSegment 处理，只有相关计划路径改写为删除插入。

`MergeIndexes` 用于构建等树合并路径，但当前 LocalStorage 提交不统一通过“CommitAppend → MergeIndexes”合并本地树。回滚可能需要撤销已改动的全局索引和数据，绝非总是“丢弃 LocalStorage 即可”。

索引操作有 `IndexEntry` 外围锁与 `BoundIndex` 的 `IndexLock`；本地状态由所属执行路径管理，不能据单事务就断言永远没有并发访问或无需同步。详见 [CUSTOM_INDEX_DESIGN.md](CUSTOM_INDEX_DESIGN.md) 和 [TRANSACTION_MVCC_DESIGN.md](TRANSACTION_MVCC_DESIGN.md)。

## 七、CREATE INDEX 与批量构建

[plan_create_index.cpp](../src/execution/physical_plan/plan_create_index.cpp) 的数据流为：

```text
Scan → Projection（键表达式 + rowid）→ 通常 Filter NULL
     → Sort（ARTBuildSort 为真）→ PhysicalCreateIndex
```

当前 `ARTBuildBind` 总是 sorted=true，包括 VARCHAR/多列。每个 Sink chunk 生成键向量，`ARTBuilder` 构建子树并与 local ART 合并，Combine 再合并到 global ART；不能因为有 Sort 就推断 Sink 按单线程输入或整个树一次性构建。

ALTER ADD PRIMARY KEY 不过滤 NULL，交由 `PhysicalCreateIndex::Sink` 拒绝。Finalize 执行 Vacuum/Verify/VerifyAllocations，核对表未被 alter/drop 后再注册实例，见 [physical_create_index.cpp](../src/execution/operator/schema/physical_create_index.cpp)。这些调用不能统一当成 debug-only。

## 八、持久化与 checkpoint 增量

`ART` 为各节点种类配置 9 个 `FixedSizeAllocator`；旧格式 LEAF 槽仍保留。实际 Node256Leaf segment size 还有存储版本兼容分支，不总是简单 `sizeof(Node256Leaf)`。

`SerializeToDisk` 持锁，PrepareSerialize 后 WritePartialBlocks，再写入 allocator_infos。`SerializeToWAL` 按调用方独占要求准备 buffers 和 allocator_infos，由 WAL 层序列化这些缓冲区；它本身不等于直接 fsync WAL。

`v1_0_0_storage` 缺省或不是 false 时会转换旧叶布局，仅当显式 false 时采用新布局；这由调用方的存储兼容选项决定，不等于当前二进制版本一定写最新格式。恢复构造按 `root_block_ptr` 走旧 Deserialize，或按 root + allocator_infos 初始化；同时恢复 storage_version。

当前 delta 由 `IndexEntry/IndexDeltas` 持有，包含 DELETED_ROWS_IN_USE、ADDED_DATA_DURING_CHECKPOINT、REMOVED_DATA_DURING_CHECKPOINT。ART 提供 `CreateEmptyCopy`、`MergeCheckpointDelta`；checkpoint 结束合并增量时先处理移除，再处理新增，新增合并允许临时重复。它们不是旧版实例上的 `DeltaIndexType` 字段。

Vacuum 通过分配器阈值选 buffer，遍历并调整活跃指针以回收碎片；不要将其与 MVCC 删除行清理、表行组 vacuum 或 SQL VACUUM 触发条件混为一谈。本文没有验证内存换出、文件兼容或并发恢复结果。
