# DuckDB ART 索引设计与实现文档

## 概述

本文档整理了 DuckDB 内部 ART（Adaptive Radix Tree，自适应基数树）索引的核心设计与实现，涵盖 ART 算法原理、键编码、查询加速、唯一性约束、索引与数据一致性、事务支持以及持久化存储等关键模块，为理解或扩展 DuckDB 索引系统提供参考。

---

## 一、源码文件总览

### 头文件（`src/include/duckdb/execution/index/art/`）

| 文件 | 核心类 | 职责说明 |
|------|--------|----------|
| `art.hpp` | `ART` | 索引入口类，继承 `BoundIndex`，对外暴露所有索引操作接口 |
| `art_key.hpp` | `ARTKey` | 键的字节序列表示，负责各类型到可比较字节序列的编码 |
| `node.hpp` | `Node` | 统一节点指针，携带类型元数据，是整棵树的"指针类" |
| `prefix.hpp` | `Prefix` | 路径压缩节点，存储公共前缀字节序列 |
| `leaf.hpp` | `Leaf` | 叶子节点，存储 row ID（已废弃的链表形式及新的嵌套 ART 形式） |
| `base_node.hpp` | `BaseNode<C,T>`, `Node4`, `Node16` | 容量 4/16 的内部节点，按 key 字节排序存储子节点 |
| `node48.hpp` | `Node48` | 容量 48 的内部节点，256 字节的间接索引数组 |
| `node256.hpp` | `Node256` | 容量 256 的内部节点，直接以 key 字节索引子节点 |
| `base_leaf.hpp` | `BaseLeaf<C,T>`, `Node7Leaf`, `Node15Leaf` | 嵌套叶（nested leaf）的小容量位图节点 |
| `node256_leaf.hpp` | `Node256Leaf` | 嵌套叶的 256 位 bitmask 节点 |
| `art_operator.hpp` | `ARTOperator` | 无状态工具类：`Lookup`、`Insert`、`Delete` 核心算法 |
| `art_scanner.hpp` | `ARTScanner` | 全树遍历（用于 Vacuum、Verify 等） |
| `art_builder.hpp` | `ARTBuilder` | 批量有序键构建 ART（CREATE INDEX 路径） |
| `art_merger.hpp` | `ARTMerger` | 合并两棵 ART（事务提交时使用） |
| `iterator.hpp` | `Iterator`, `IteratorKey` | 有序迭代器，支持范围扫描 |

### 实现文件（`src/execution/index/art/`）

与头文件一一对应，另有 `plan_art.cpp` 负责将逻辑 `CREATE INDEX` 算子转换为物理执行计划。

---

## 二、ART 算法原理

### 2.1 Adaptive Radix Tree 核心思想

ART 是一种**基数树（Trie）**变体，与 B+-Tree 不同，它按**键的字节逐层分支**，不依赖比较函数，因而具备以下特性：

- **O(k) 查找复杂度**（k 为键的字节长度），与树中键的数量无关。
- **字典序天然有序**，支持高效范围扫描。
- **路径压缩**：使用 Prefix 节点消除单链分支，避免空间浪费。
- **自适应节点容量**：根据实际子节点数量在 4/16/48/256 之间动态切换。

### 2.2 节点类型体系

```
NType 枚举
├── PREFIX        (路径压缩节点，存储公共前缀字节)
├── LEAF_INLINED  (叶子：row_id 直接内联在 Node 指针的低 56 位)
├── LEAF          (已废弃：linked-list 形式的叶子)
├── NODE_4        (内部节点，最多 4 个子节点，key[] 有序排列)
├── NODE_16       (内部节点，最多 16 个子节点，key[] 有序排列)
├── NODE_48       (内部节点，最多 48 个子节点，256 字节间接索引)
├── NODE_256      (内部节点，最多 256 个子节点，直接按字节索引)
├── NODE_7_LEAF   (嵌套叶节点，最多 7 个字节，sorted array)
├── NODE_15_LEAF  (嵌套叶节点，最多 15 个字节，sorted array)
└── NODE_256_LEAF (嵌套叶节点，256 位 bitmask)
```

#### 内部节点容量切换阈值

| 从 → 到 | 增长触发 | 收缩触发 |
|---------|---------|---------|
| Node4 → Node16 | count == 4 | — |
| Node16 → Node4 | — | count < 4 |
| Node16 → Node48 | count == 16 | — |
| Node48 → Node16 | — | count <= 12 (`SHRINK_THRESHOLD`) |
| Node48 → Node256 | count == 48 | — |
| Node256 → Node48 | — | count <= 36 (`SHRINK_THRESHOLD`) |

### 2.3 Node 指针编码

`Node` 继承自 `IndexPointer`，是一个 8 字节整数，各段含义如下：

```
bit 63        : Gate 标志（1 = 进入嵌套 ART 的入口节点）
bit 56..62    : 节点类型元数据（NType）
bit 0..55     : 存储位置（LEAF_INLINED 时为 row_id，其他为 buffer_id + offset）
```

`LEAF_INLINED` 是最优化的叶子形式：row_id 直接嵌入指针本身，无需额外内存分配。

### 2.4 路径压缩（Prefix 节点）

Prefix 节点存储多个连续字节（最多 `prefix_count` 个）加一个字节计数，并持有一个子节点指针。遍历时，Prefix 节点的每个字节都必须与查询键的对应字节完全匹配，否则立即返回"未找到"。

```
key[0..prefix_count-1]  : 压缩的字节序列
key[prefix_count]       : 实际存储的字节数 count
ptr                     : 下一个节点的指针
```

Prefix 节点可以**链式排列**，支持任意长度的公共前缀压缩，有效降低内存占用。

### 2.5 嵌套 ART（Gate Node）与多值叶子

对于**非唯一索引**，同一个键可能对应多个 row_id。DuckDB 的实现方式是：

1. 当第二个 row_id 需要插入同一键时，将 `LEAF_INLINED` 转换为一个 **Gate 节点**。
2. Gate 节点（通过 `Node` 指针的最高位标识）是嵌套 ART 的入口。
3. 嵌套 ART 以 **row_id 本身作为键**，因为 row_id 总是唯一的，嵌套 ART 内部永远不存在重复。
4. 嵌套叶节点使用专用的 `Node7Leaf`、`Node15Leaf`、`Node256Leaf`，仅存储字节（row_id 的最后一个字节），节省空间。

---

## 三、键编码（ARTKey）

ART 要求键以**字典序可比较的大端字节序**表示。`ARTKey` 类通过 `Radix::EncodeData<T>()` 完成各类型的编码：

### 3.1 支持的数据类型

| 逻辑类型 | 编码方式 |
|---------|---------|
| `BOOL`, `UINT8/16/32/64/128` | 直接大端字节序（无符号，无需翻转） |
| `INT8/16/32/64/128` | 大端字节序，**符号位取反**（将负数映射到小值） |
| `FLOAT`, `DOUBLE` | 特殊编码：正数直接大端，负数所有位取反（保持排序语义） |
| `VARCHAR` | 原始字节 + 特殊转义（`\x00` → `\x01\x01`，`\x01` → `\x01\x02`）+ `\x00` 终止符 |
| 复合键（多列索引） | 各列键依次拼接，末尾附加 row_id 编码 |

> 为保证 VARCHAR 类型键的字典序与字节序一致，空字节（`\x00`）和转义字节（`\x01`）会被特殊编码，以避免提前截断。

### 3.2 键长度限制

单个键的最大长度为 `MAX_KEY_LEN * prefix_count`（`MAX_KEY_LEN = 8192`）。多列索引和 VARCHAR 列会触发键长度验证（`verify_max_key_len = true`）。

---

## 四、支持哪些查询的加速

### 4.1 查询类型

ART 索引通过 `ART::TryInitializeScan()` 判断是否可以使用索引，支持以下谓词：

| 谓词 | 对应的扫描函数 | 说明 |
|-----|-------------|------|
| `col = value` | `SearchEqual()` | 点查：`Lookup` 直接找到叶子，再用 `Iterator::Scan` 收集所有 row_id |
| `col > value` | `SearchGreater(equal=false)` | 范围扫描：`Iterator::LowerBound` 定位起点，无上界扫到底 |
| `col >= value` | `SearchGreater(equal=true)` | 同上，含等于 |
| `col < value` | `SearchLess(equal=false)` | 范围扫描：从最小值开始，`Iterator::Scan` 直到上界 |
| `col <= value` | `SearchLess(equal=true)` | 同上，含等于 |
| `val1 < col < val2` | `SearchCloseRange()` | 双端范围扫描 |
| `col BETWEEN a AND b` | `SearchCloseRange()` | 同上，闭区间 |

### 4.2 扫描流程

```
ART::Scan()
  ├── 单谓词 ─→ SearchEqual / SearchGreater / SearchLess
  └── 双谓词 ─→ SearchCloseRange
           │
           ▼
     Iterator::LowerBound()  (确定起始叶子)
           │
           ▼
     Iterator::Scan()        (逐叶有序遍历，收集 row_id，直到 upper_bound 或 max_count)
```

`Iterator` 维护一个从根到当前叶的节点栈，`IteratorKey` 记录当前键的字节，支持高效的有序遍历。

### 4.3 不支持的查询

- `LIKE` 模式匹配（除非可以转换为前缀范围，如 `LIKE 'abc%'`）。
- 对索引列施加函数的谓词（如 `LOWER(col) = 'abc'`）。
- 多列 OR 谓词。

---

## 五、如何支持 UNIQUE 和 PRIMARY KEY

### 5.1 索引约束类型

```cpp
// src/include/duckdb/common/enums/index_constraint_type.hpp
enum class IndexConstraintType : uint8_t {
    NONE    = 0,  // 普通索引
    UNIQUE  = 1,  // UNIQUE 约束
    PRIMARY = 2,  // PRIMARY KEY（内部也是 UNIQUE）
    FOREIGN = 3,  // FOREIGN KEY（检查引用存在性）
};
```

`ART::IsUnique()` 当 `index_constraint_type` 为 `UNIQUE` 或 `PRIMARY` 时返回 `true`。

### 5.2 插入时的约束检查

**路径 1：`ART::Insert()`**（事务本地存储写入）

```
ARTOperator::Insert()
  └── 遇到 LEAF_INLINED（已有键）
        └── InsertIntoInlined()
              ├── 非唯一索引 ─→ MergeInlined() 创建 Gate/嵌套 ART，NO_CONFLICT
              ├── 唯一索引，无 delete_art ─→ CONSTRAINT（冲突）
              ├── 唯一索引，有 delete_art，被删除的 row_id 与当前相同 ─→ NO_CONFLICT（允许 UPDATE）
              └── 唯一索引，有 delete_art，row_id 不同 ─→ CONSTRAINT（冲突）
```

**路径 2：`ART::VerifyConstraint()`**（提交前的完整性验证）

```
VerifyConstraint()
  ├── 对每个键，执行 ARTOperator::Lookup()
  ├── 找到叶子 ─→ VerifyLeaf()
  │     ├── LEAF_INLINED（无 delete_art）─→ 报告冲突行 row_id
  │     ├── LEAF_INLINED（有 delete_art，同 row_id）─→ 允许（DELETE + INSERT 同一行）
  │     └── Gate 节点（两个 row_id）─→ 扫描叶子，与 delete_art 比对
  └── 存在冲突 ─→ 抛出 ConstraintException
```

### 5.3 FOREIGN KEY 的 Lookup 验证

外键检查使用 `VerifyExistenceType::APPEND_FK`（被引用表中必须存在该键）和 `DELETE_FK`（删除时引用表中不能还有该键的引用）。均通过 `ARTOperator::Lookup()` 完成，不涉及写操作。

---

## 六、索引与数据的一致性

### 6.1 整体一致性机制

DuckDB 使用**事务本地存储（LocalStorage）**来隔离未提交的写入，保证索引和数据的一致性：

```
事务写入流程
  ├── LocalTableStorage::append_indexes   (事务本地 ART，接受新插入的键)
  ├── LocalTableStorage::delete_indexes   (事务本地 ART，记录被删除的键)
  │
  ▼
事务提交时
  └── LocalStorage::Flush()
        ├── AppendToIndexes() → 合并 append_indexes 到全局 ART（MergeIndexes）
        └── 全局 DataTable 的 row_groups 也同步更新
```

### 6.2 delete_art 的作用（UPDATE 的原子性）

UPDATE 操作在内部被拆分为 DELETE + INSERT：

1. 旧行的键写入 `delete_indexes`（`delete_art`）。
2. 新行的键写入 `append_indexes`。
3. 提交时，Insert 检查 `delete_art` 中是否有同 key、同 row_id 的记录：
   - 相同 row_id → 允许（同一逻辑行的更新）。
   - 不同 row_id → 唯一约束冲突。

### 6.3 MergeIndexes（提交时的索引合并）

提交时，`LocalStorage::Flush()` 调用 `DataTable::MergeStorage()`，再由 `TableIndexList::CommitAppend()` 调用 `BoundIndex::MergeIndexes()`。ART 的合并通过 `ARTMerger` 完成：

```cpp
// ARTMerger::Merge()
// 使用显式栈遍历两棵 ART，将 right 合并入 left：
// - 两个 LEAF_INLINED：非唯一直接合并为 Gate；唯一检查冲突
// - PREFIX 节点：对齐、分裂或连接
// - 内部节点：逐字节合并子树，递归入栈
```

### 6.4 Vacuum（空间回收）

删除操作不立即回收节点内存，而是标记为空闲；`ART::Vacuum()` 在合适时机（由上层调度）触发，通过 `ARTScanner` 全树遍历，将活跃节点移动到紧凑的 buffer 中，回收碎片空间（触发阈值：`FixedSizeAllocator::VACUUM_THRESHOLD = 10%`）。

---

## 七、事务支持

### 7.1 写-写冲突检测（write-write conflict）

唯一索引在插入时会检测写-写冲突：

```cpp
// ARTOperator::Insert() 中
if (art.IsUnique() && node.GetGateStatus() == GateStatus::GATE_SET) {
    // 已经有两个 row_id（Gate 节点），意味着另一个事务也 DELETE + INSERT 了同一键
    return ARTConflictType::TRANSACTION;
}
```

当 `Insert()` 返回 `ARTConflictType::TRANSACTION` 时，抛出：

```
TransactionException("write-write conflict on key: \"...\"")
```

这实现了**乐观并发控制（OCC）**：冲突在提交时检测，而非持有锁等待。

### 7.2 事务隔离与本地索引

每个事务拥有独立的 `LocalTableStorage`，其中包含：

| 结构 | 说明 |
|------|------|
| `append_indexes` | 本地 ART，仅对当前事务可见，记录本次插入的键 |
| `delete_indexes` | 本地 ART，记录本次删除（或 UPDATE 的旧值）的键 |
| `row_groups` | 本地行数据，未提交前不对其他事务可见 |

事务回滚时，`LocalTableStorage` 整体丢弃，无需对全局 ART 做任何修改。

### 7.3 锁机制

`ART` 继承了 `Index` 的 `mutex lock`：

- 所有扫描操作（`Scan()`）持有 `lock_guard<mutex>`。
- `VerifyConstraint()` 也在持锁状态下执行。
- `Insert()`、`Delete()` 通过上层传入的 `IndexLock`（也是 `lock_guard<mutex>`）保护。
- 本地索引（`append_indexes` / `delete_indexes`）仅在单事务内使用，无并发竞争，不需要锁。

### 7.4 事务提交的完整流程

```
事务 COMMIT
  │
  ├── LocalStorage::Flush(table, storage, commit_state)
  │     ├── PushAppend(table, row_start, append_count)  → Undo Buffer 记录可回滚信息
  │     ├── AppendToIndexes()                            → 将本地 append_indexes 合并到全局 ART
  │     └── MergeStorage()                              → 将本地 row_groups 合并到全局 DataTable
  │
  └── 若失败 → Rollback() → LocalStorage 整体丢弃，全局状态不变
```

---

## 八、索引构建

### 8.1 CREATE INDEX 的物理计划

`ART::CreatePlan()` 在 `plan_art.cpp` 中将逻辑 `LogicalCreateIndex` 转换为：

```
PhysicalProjection        (提取索引列和 row_id)
  └── PhysicalFilter      (过滤 NULL，CREATE INDEX 时 NULL 不入索引)
        └── PhysicalOrder (排序，仅单列非 VARCHAR 启用)
              └── PhysicalCreateARTIndex (批量构建 ART)
```

排序后的键通过 `ARTBuilder` 批量构建，利用有序输入的特性（公共前缀共享）大幅提升构建效率。

### 8.2 ARTBuilder 批量构建

`ARTBuilder` 使用显式栈处理有序键数组，通过递归分治：

1. 确定当前 `[start, end)` 范围内键在 `depth` 层的字节分组。
2. 对每个字节组递归构建子树。
3. 若范围内只有一个不同键（公共前缀），则创建 Prefix 节点压缩。
4. 叶子以 `LEAF_INLINED` 或 Gate 节点（非唯一重复键）表示。

---

## 九、持久化存储

### 9.1 FixedSizeAllocator 与 Buffer 管理

ART 的每种节点类型由独立的 `FixedSizeAllocator` 管理，共 9 个：

| 分配器索引 | 节点类型 | 段大小 |
|-----------|---------|--------|
| 0 | PREFIX | `prefix_count + METADATA_SIZE` 字节 |
| 1 | LEAF（已废弃） | `sizeof(Leaf)` |
| 2 | NODE_4 | `sizeof(Node4)` |
| 3 | NODE_16 | `sizeof(Node16)` |
| 4 | NODE_48 | `sizeof(Node48)` |
| 5 | NODE_256 | `sizeof(Node256)` |
| 6 | NODE_7_LEAF | `sizeof(Node7Leaf)` |
| 7 | NODE_15_LEAF | `sizeof(Node15Leaf)` |
| 8 | NODE_256_LEAF | `sizeof(Node256Leaf)` |

每个 `FixedSizeAllocator` 管理若干 `FixedSizeBuffer`，缓冲区与磁盘块（Block）对应，支持 buffer manager 的换入/换出。

### 9.2 序列化到磁盘（Checkpoint）

`ART::SerializeToDisk()` 在 Checkpoint 时调用：

1. 调用 `PrepareSerialize()` 准备 `IndexStorageInfo`（包含 root 指针和各分配器信息）。
2. 调用 `WritePartialBlocks()` 将各分配器的 buffer 写入磁盘的 partial block。
3. 每个分配器调用 `SerializeBuffers()` 将内存 buffer 序列化到连续的磁盘块。

### 9.3 序列化到 WAL

`ART::SerializeToWAL()` 在 WAL 写入时调用，各分配器调用 `InitSerializationToWAL()`，将 buffer 直接写入 WAL 文件，不经过 partial block manager。

### 9.4 反序列化

从磁盘加载时，`ART::Deserialize()` 按顺序读取各分配器的 `BlockPointer`，恢复内存状态。

### 9.5 向后兼容（v1.0.0 存储格式）

旧版 DuckDB（v1.0.0）使用链表形式的 `LEAF` 节点而非嵌套 ART。序列化时通过 `v1_0_0_storage` 选项控制是否转换为旧格式（`TransformToDeprecated()`），确保兼容性。

---

## 十、关键源码位置

| 文件 | 说明 |
|------|------|
| `src/execution/index/art/art.cpp` | ART 主实现：Scan、Insert、Delete、VerifyConstraint、Serialize |
| `src/execution/index/art/art_operator.hpp` | 核心算法：Lookup、Insert、Delete（无状态模板） |
| `src/execution/index/art/art_key.cpp` | 各类型键编码实现 |
| `src/execution/index/art/iterator.cpp` | 范围扫描迭代器 |
| `src/execution/index/art/art_builder.cpp` | 批量有序构建 |
| `src/execution/index/art/art_merger.cpp` | 两棵 ART 的合并 |
| `src/execution/index/art/plan_art.cpp` | CREATE INDEX 物理计划生成 |
| `src/storage/local_storage.cpp` | 事务本地存储：append_indexes / delete_indexes 管理 |
| `src/storage/data_table.cpp` | AppendToIndexes、MergeStorage（提交时同步） |
| `src/execution/index/fixed_size_allocator.hpp` | 节点内存分配器 |
