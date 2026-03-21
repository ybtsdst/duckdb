# DuckDB v1.4.3 → v1.5.0 主要改动对比

> **v1.5.0 发布名称**："Variegata"（以新西兰天堂鸭 *Tadorna variegata* 命名）
>
> **发布公告**：https://duckdb.org/2026/03/09/announcing-duckdb-150.html
>
> **完整变更列表**：https://github.com/duckdb/duckdb/compare/v1.4.4...v1.5.0

---

## 概述

- **v1.4.3** 是 v1.4.x 系列的 **缺陷修复版本**，主要解决 v1.4.2 之后发现的各类 Bug。
- **v1.5.0** 是一个 **重大功能版本**，引入了大量新特性、性能优化、CLI 全面重构以及存储层改进。

---

## 一、新增功能

### 1.1 SQL 新功能

| 功能 | 描述 |
|------|------|
| `read_duckdb()` | 新增函数，支持读取和 glob 匹配 DuckDB 数据库文件，并支持后期物化和过滤下推 |
| `ALTER DATABASE … RENAME TO …` | 支持重命名已附加的数据库 |
| `SHOW SCHEMAS` | 新增 `SHOW SCHEMAS` 语句，方便列出当前 Schema |
| `array_intersect()` | 新增数组交集函数 |
| `sleep()` / `sleep_ms()` | 新增休眠标量函数（无线程支持时自动禁用） |
| `struct_values()` | 返回 STRUCT 所有字段值的函数 |
| `parse_formatted_bytes()` | 解析人类可读字节大小字符串的函数（如 `'1.5 GiB'`） |
| `days_in_month` | 获取指定月份天数的内部宏 |
| `AGO` 宏 | 用于日期计算的 `AGO` 时间偏移宏 |
| 别名引用支持 | 支持 `alias.<name>` 语法进行别名引用 |
| `COLUMNS()` 展开用于 `DISTINCT ON` | 在 `DISTINCT ON` 子句中支持 `COLUMNS()` 展开 |
| `NOT SIMILAR TO` 模式 | 支持 `* NOT SIMILAR TO 'pattern'` 语法 |
| `ATTACH` 恢复模式 | `ATTACH` 选项新增恢复模式，并支持 `NO_WAL` 模式 |
| `TIME_NS` 类型 + Arrow 支持 | 新增纳秒时间类型，并集成 Arrow 格式支持 |
| `parquet_full_metadata()` | 新增函数，用于获取 Parquet 文件的完整元数据 |
| 递归 `UNNEST` 保留列名 | 修复递归展开时列名被丢弃的问题 |
| `WITH ORDINALITY` 虚拟列修复 | 修复 `WITH ORDINALITY` 的虚拟列处理 |
| `TRY` 表达式禁止聚合 | 在 `TRY` 子表达式中不允许使用聚合函数 |
| `EXPLAIN` Mermaid 图输出 | 新增将 `EXPLAIN` 结果输出为 Mermaid 流程图的 Transformer |
| `UNION ALL` 多子节点重构 | 将 `UNION (ALL)` 算子重构为支持多个子节点 |
| 友好的 `SWITCH` 语句 | 新增更友好的 `SWITCH CASE` 语法 |
| `duckdb_profiling_settings()` | 新增性能分析设置宏 |
| `enable_profiling()` 表函数 | 新增可编程方式启用 Profiling 的表函数 |

### 1.2 VARIANT 类型支持（重大新功能）

- **VARIANT 类型存储**：为 VARIANT 列实现专用存储引擎
- **Parquet VARIANT 支持**：
  - 支持在 `COPY TO` 时写入非切片（unshredded）VARIANT
  - 支持在 `COPY TO` 时写入切片（shredded）VARIANT
  - 支持自动切片写入 VARIANT 列
  - 从 Parquet VARIANT 列读取时直接输出 VARIANT 类型（而非 JSON）
- **VARIANT 比较操作**：为 VARIANT 列实现比较运算符
- **VARIANT 统计信息**：改进 VariantStats 类，支持合并和更好的可视化

### 1.3 GEOMETRY 类型重构（共 5 部分）

v1.5.0 对 GEOMETRY 类型进行了系统性重构：

| 阶段 | 内容 |
|------|------|
| Part 1 | 逻辑类型重构 |
| Part 2 | 统计信息支持 |
| Part 3 | 过滤下推 |
| Part 4 | 修复 Parquet 扩展 + 增加 Arrow 支持；调整 WKB 转换函数 |
| Part 5 | 坐标参考系统（CRS）支持 |

---

## 二、性能优化

### 2.1 查询优化器

| 优化 | 描述 |
|------|------|
| **公共子计划消除（Common Subplan Elimination）** | 识别并消除重复的子计划，减少重复计算 |
| **侧向信息传递（Sideways Information Passing）** | 利用 Bloom Filter 进行 Join 时的数据过滤 |
| **Bloom Filter 行组跳过** | 在扫描行组时利用 Bloom Filter 进行数据跳过 |
| **外连接消除（Outer Join Elimination）** | 实现外连接消除优化 |
| **TopN 改进** | 包括偏移剪枝（Offset Pruning）、行组排除、动态过滤 `NULLS FIRST` 支持 |
| **TopN 窗口函数转聚合** | 将分组 Top-N 窗口函数重写为聚合 |
| **延迟物化（Late Materialization）** | 在 TopNWindowElimination 和 Parquet 中支持延迟物化 |
| **常量阶次规范化** | 支持常量排序的规范化优化 |
| **NOT 消除** | 实现 `NOT` 表达式的消除优化 |
| **Min/Max 聚合提前执行** | 对统计信息直接进行 Min/Max 聚合，避免全量扫描 |
| **自定义行组扫描顺序** | 支持按自定义顺序扫描行组 |
| **struct_extract 下推存储** | 将 `struct_extract` 及其 CAST 表达式下推到存储层 |
| **variant_extract 下推存储** | 将 `variant_extract` + CAST 下推到存储层 |
| **数组比较优化** | 优化数组类型的比较操作 |

### 2.2 Join 性能

| 优化 | 描述 |
|------|------|
| **AsOf Join 全面改进** | Pipeline、排序、并行化、线程处理、前缀比较、任意谓词支持 |
| **IEJoin 性能** | 线程锁优化、并行 L1/L2 处理、统一 L1/L2 |
| **Hash Join** | 基于 join_keys 的构建去重；Hash 缓存线程安全；Perfect Hash Join 输出字典向量 |
| **跨/侧向 Join 过滤下推** | 将过滤条件下推到含 UNNEST 或 JSON 的 Cross/Lateral Join |
| **连接过滤下推改进** | 改进 ON 子句条件的 Join 过滤下推 |
| **Mark Join 去关联** | 修复 Mark Join 的去关联处理 |

### 2.3 窗口函数性能

| 优化 | 描述 |
|------|------|
| **流式窗口序列** | 实现流式 Window 序列处理 |
| **流式 IGNORE NULLS** | 实现流式 IGNORE NULLS 窗口计算 |
| **CountWindowElimination** | 消除不必要的 COUNT 窗口计算 |
| **HashedSort 内存优化** | 优化 HashedSort 的内存使用 |
| **DENSE_RANK 性能** | 大幅提升 DENSE_RANK 性能 |
| **Window ArenaAllocator** | 窗口计算中使用 ArenaAllocator 减少内存分配 |
| **Window 自连接优化** | 实现 Window 自连接（Self-Join）的多阶段优化 |

### 2.4 存储与压缩

| 优化 | 描述 |
|------|------|
| **Roaring Booleans 压缩** | 新增 Roaring Bitmap 压缩方式用于布尔列 |
| **ALP 非压缩模式** | ALP 算法新增非压缩（uncompressed）模式 |
| **Dictionary/DICT_FSST 提速** | 用 PrimitiveDictionary 替换 std::unordered_map，大幅提速 |
| **块分配器（Block Allocator）** | 新增内存块分配器 |
| **并行行组销毁** | 支持并行销毁行组 |
| **每列独立 PartialBlockManager** | 每列使用独立的 PartialBlockManager 减少锁竞争 |
| **Parquet 元数据 LRU 缓存** | 对 Parquet 元数据引入 LRU 缓存 |
| **Parquet 统计信息返回** | COPY 时为布尔和 128 位数值类型返回统计信息 |

### 2.5 并发与检查点

| 优化 | 描述 |
|------|------|
| **检查点期间允许并发读取** | 检查点期间读操作可以并发进行 |
| **检查点期间允许并发提交** | 允许在检查点运行时并发提交事务 |
| **检查点期间允许并发删除** | 允许在检查点运行时并发删除 |
| **检查点期间允许并发索引写入** | 带索引的表在检查点期间可以并发插入 |
| **减少乐观写入触发的频繁检查点** | 避免乐观写入导致过多的检查点触发 |
| **乐观写入列式批量落盘** | 收集 N 个行组后，按列逐一写入 |
| **RowVersionManager 使用 FixedSizeAllocator** | 减少 RowVersionManager 的内存碎片 |
| **并行 TupleDataCollection 析构** | 并行销毁 TupleDataCollection |
| **并行 SortedRunMerger 析构** | 并行销毁 SortedRunMerger |
| **WAL 批量回放删除** | WAL 中的删除操作改为批量回放 |

---

## 三、CLI 全面重构（重大变更）

v1.5.0 对命令行界面（CLI）进行了**全面重构**，从 SQLite API 迁移到 C++ API，并引入大量新特性：

### 3.1 核心重构

- **从 SQLite API 迁移至 C++ API**，移除所有 SQLite API 封装层
- 所有 CLI 全局变量被移除，重构为结构化配置
- 自动完成、渲染、命令处理分拆为独立模块

### 3.2 新增 CLI 特性

| 特性 | 描述 |
|------|------|
| 动态提示符 | 支持可配置的动态提示符（`prompt`） |
| 语法高亮增强 | 统一高亮颜色代码，支持 8 位颜色扩展，提供 `.display_colors` 命令 |
| 暗色/亮色模式自动检测 | 自动检测终端背景色并切换配色方案 |
| 鼠标点击支持 | `Ctrl+Q` 允许通过鼠标单击改变光标位置 |
| 分页输出支持 | 新增对长输出的分页显示功能 |
| 自动完成改进 | 类 `zsh` 的补全行为，支持 Tab 键浏览建议，支持 Dollar 引用字符串内容排除 |
| `_` 上次查询结果 | 可通过 `_` 标记引用上次查询结果并再次查询 |
| `.last` 命令 | 重新渲染上次查询结果 |
| `.startup_text` 命令 | 可配置启动时的显示文本 |
| 进度条可配置 | `progress_bar` 支持自定义配置 |
| 表格元数据渲染 | `.tables` 和 `DESCRIBE` 结果按数据库/Schema 分组渲染 |
| 嵌套类型美化打印 | 对嵌套类型、JSON、VARIANT 进行高亮和格式化显示 |
| 宽值渲染优化 | 改进超宽值的渲染，避免截断 |
| Windows 全面支持 | Linenoise 在 Windows 上正式可用，修复 Windows 输入处理 |
| Ctrl+C 不退出 | 按 Ctrl+C 不再直接退出 shell |
| `.import` 使用内置读取器 | `.import` 命令改用内置 CSV/JSON 等读取器 |
| `.open --sql` 选项 | `.open` 支持 `--sql` 参数 |
| 帮助信息输出到 stdout | `--help` 输出改为 stdout |
| `.help` 语法高亮 | `.help` 菜单自动从命令列表生成，并附语法高亮 |

---

## 四、C API 改进

| 改进 | 描述 |
|------|------|
| 文件系统访问 | 初步支持通过 C API 访问文件系统 |
| 自定义 COPY 函数 | 支持在 C API 中定义 `COPY` 函数 |
| 自定义配置选项 | 支持在 C API 中定义配置项（Settings） |
| 目录条目查找 | 支持通过 C API 查找 Catalog 条目 |
| 标量函数局部状态 | 支持标量函数的本地（Local）状态 |
| 安全字符串赋值 | 新增安全字符串赋值函数 |
| 日志存储暴露 | 通过 C API 暴露基本自定义日志存储 |
| 表描述扩展 | 暴露列数量和类型给 C API |
| 函数分组文档 | 为函数分组生成描述、废弃标记和替代建议 |
| 窗口函数暴露 | 在 `duckdb_functions` 中增加窗口函数 |

---

## 五、性能分析（Profiling）改进

| 改进 | 描述 |
|------|------|
| `EXTRA_INFO` 移入 metrics 映射 | 统一 Profiling 信息的存储结构 |
| ATTACH / CHECKPOINT / WAL 回放指标 | 新增并默认开启相关 Profiling 指标 |
| WAL 相关新指标 | `WAL_REPLAY_ENTRY_COUNT`、`COMMIT_WRITE_WAL_LATENCY` 等 |
| 提交延迟细分 | 将 `COMMIT_WRITE_WAL_LATENCY` 拆分为 `COMMIT_LOCAL_STORAGE_LATENCY` 和 `WRITE_TO_WAL_LATENCY` |
| `TOTAL_MEMORY_ALLOCATED` 指标 | 新增总内存分配量指标 |
| `BLOCKED_THREADS_TIME` 改进 | 将等待锁的时间也计入阻塞线程时间 |
| `query_name` 可隐藏 | 可通过设置 `query_name` 为 false 隐藏 Profiling 输出中的查询内容 |
| Metric 子分组 | 生成更多 metric 代码并支持 metric 子分组 |
| `rows_scanned` 修复 | 修复 Profiling 中 `rows_scanned` 的统计错误 |
| `duckdb_profiling_settings()` 宏 | 新增查询 Profiling 配置的宏 |
| `enable_profiling()` 表函数 | 新增通过表函数启用 Profiling 的方式 |

---

## 六、扩展更新

### v1.5.0 新增 / 升级的扩展

| 扩展 | 变更 |
|------|------|
| `iceberg` | 升级并默认可用 |
| `ducklake` | 升级，支持宏 |
| `delta` | 升级 |
| `spatial` | 升级 |
| `mysql_scanner` | 升级 |
| `httpfs` | 升级 |
| `azure` | 升级 |
| `unity_catalog` | 新增 |
| `vortex` | 升级至 0.56.0 |
| Windows ARM64 架构 | 主要扩展新增 Windows ARM64 支持 |

---

## 七、存储格式变更

- v1.5.0 引入了新的存储格式版本，包含：
  - 跳过 `DataPointer` 中 `row_start` 的序列化（当目标是最新存储时）
  - 移除行组（RowGroup）、列数据（ColumnData）和列段（ColumnSegment）中的 `start` 字段
  - 检查点生成新的 RowGroup/ColumnData 而非原地修改
  - 全量重写检查点时的统计信息

---

## 八、v1.4.3 主要修复（对比参考）

v1.4.3 是纯缺陷修复版本，主要修复包括：

| 类别 | 修复内容 |
|------|---------|
| 查询正确性 | `HAVING` 无 `GROUP BY` 时的行为修复 |
| 查询正确性 | 宏参数绑定修复（无类型宏） |
| 查询正确性 | 约束违反 Bug 修复 |
| 查询正确性 | `APPROX_QUANTILE` 对 TIME 类型的错误处理 |
| 查询正确性 | `INSERT OR REPLACE BY NAME` 部分列的修复 |
| 查询正确性 | Mark Join 去关联修复 |
| 查询正确性 | `ORDER BY` 子句优化器错误移除的修复 |
| 查询正确性 | 关联列绑定（CorrelatedColumnBinding）修复 |
| 查询正确性 | 无关依赖 Join 改写修复 |
| 压缩 | 防止 `COMPRESSION_EMPTY` 被 `COMPRESSION_CONSTANT` 覆盖 |
| 压缩 | 修复 DICT_FSST 空值更新问题 |
| 压缩 | 修复 FetchRow 在 dict_fsst 压缩后更新的 Bug |
| 索引（ART） | WAL 中未绑定的索引分配修复 |
| 索引（ART） | Node4 删除子节点时门控状态传递修复 |
| CSV 读取 | Sniffer 候选选择修复；严格模式下避免不必要的错误 |
| 加密 | 修复访问 EncryptionKeyManager 时的竞态条件 |
| 缓存 | 新增 `CacheBehavior::AUTOMATIC` 自动缓存行为 |
| 版本 | 本地文件版本标签，用于健壮的外部文件缓存验证 |
| WASM | 修复 WASM 时区问题 |
| 内存 | 修复 PreparedStatement 复用时的内存泄漏 |
| 性能 | 移除大 LIMIT 查询在有过滤时的错误优化 |
| Parquet | 使用 `PLAIN_DICTIONARY` 修复 Parquet v1 写入 |
| Parquet | 修复预处理的 COPY 选项参数 |
| 元数据 | 即使存在删除操作也可复用元数据 |
| 统计信息 | `has_no_null` 不再在 `BaseStatistics::CreateEmpty` 中默认初始化为 true |

---

## 九、总结

| 维度 | v1.4.3 | v1.5.0 |
|------|--------|--------|
| 版本性质 | 缺陷修复 | 重大功能版本 |
| 主要亮点 | 修复约 60 个 Bug | 数百项新功能、优化和重构 |
| CLI | 无变化 | **全面重构**，迁移至 C++ API |
| 新数据类型 | 无 | `VARIANT`、`TIME_NS`；`GEOMETRY` 大幅重构 |
| 查询优化 | 无 | CSE、Bloom Filter SIP、外连接消除等 |
| 并发支持 | 无 | 检查点期间支持并发读写提交 |
| C API | 无 | 文件系统、COPY 函数、Config 等大量扩展 |
| Profiling | 无 | 新增多项指标、子分组、表函数等 |
| 存储格式 | 无 | 多项存储结构优化与变更 |
| ADBC | 无 | 部分支持 ADBC 1.1.0 |
| 平台支持 | 无 | 新增 Windows ARM64 |
