# DuckDB Profile 指标含义文档

> 源码参考：`src/common/enums/metric_type.json`、`src/main/query_profiler.cpp`、`src/main/profiling_utils.cpp`

---

## 一、概述

DuckDB 的 Profiler 系统通过 `PRAGMA enable_profiling` 开启，支持多种输出格式（文本树、JSON、HTML、Graphviz、Mermaid）。指标按**作用域**分为：

- **Query Root（查询级）**：整条 SQL 的全局指标，出现在 JSON 顶层对象中。
- **Operator（算子级）**：每个物理算子节点的指标，出现在 `children` 子树中。

指标通过 `profiler_settings_t`（一个 `unordered_set<MetricType>`）管理，分为以下几组：Core、Execution、File、Operator、Phase Timing、Optimizer。

---

## 二、启用方式

```sql
-- 开启 profiler（默认文本树格式）
PRAGMA enable_profiling;

-- 指定 JSON 格式
PRAGMA enable_profiling = 'json';

-- 设置模式
SET profiling_mode = 'standard';   -- 标准模式（默认指标集）
SET profiling_mode = 'detailed';   -- 详细模式（含优化器子阶段文本树）
SET profiling_mode = 'all';        -- 全量模式，含每个优化器单独耗时

-- 输出到文件
PRAGMA profiling_output = '/path/to/file.json';

-- 关闭
PRAGMA disable_profiling;

-- 自定义指标（仅开启指定指标）
SET custom_profiling_settings = '{"OPERATOR_TIMING": "true", "BLOCKED_THREAD_TIME": "true"}';
```

---

## 三、指标分组详解

### 3.1 Core（核心指标）

| 指标名 | 类型 | 单位 | 作用域 | 含义 |
|---|---|---|---|---|
| `QUERY_NAME` | string | — | Query Root | 当前查询的 SQL 文本字符串 |
| `LATENCY` | double | 秒 | Query Root | 整条查询从开始到结束的总耗时（包含规划、优化、执行） |
| `CPU_TIME` | double | 秒 | Query Root | 所有算子 `OPERATOR_TIMING` 的累计之和，代表纯 CPU 执行时间 |
| `CUMULATIVE_CARDINALITY` | uint64 | 行数 | Query Root | 所有算子 `OPERATOR_CARDINALITY` 的累计之和，代表整棵执行树输出的总行数 |
| `CUMULATIVE_ROWS_SCANNED` | uint64 | 行数 | Query Root | 所有算子 `OPERATOR_ROWS_SCANNED` 的累计之和，代表整棵执行树扫描的总行数 |
| `RESULT_SET_SIZE` | uint64 | 字节 | Query Root | 查询结果集占用的内存大小 |
| `ROWS_RETURNED` | uint64 | 行数 | Query Root | 查询最终返回给客户端的行数（取自根算子的 `OPERATOR_CARDINALITY`） |
| `EXTRA_INFO` | map | — | Operator | 算子特有的额外元信息（如扫描过滤条件、Join 类型等），以键值对形式展示 |

> **注意**：`CPU_TIME` 与 `LATENCY` 的差值代表等待、规划等非执行开销。`LATENCY` ≥ `CPU_TIME`。

---

### 3.2 Execution（执行指标）

| 指标名 | 类型 | 单位 | 作用域 | 含义 |
|---|---|---|---|---|
| `BLOCKED_THREAD_TIME` | double | 秒 | Query Root | 线程等待其他线程释放资源的累计阻塞时间（并发执行时可能出现） |
| `SYSTEM_PEAK_BUFFER_MEMORY` | uint64 | 字节 | Query Root | 查询执行过程中缓冲池（Buffer Manager）的峰值内存占用 |
| `SYSTEM_PEAK_TEMP_DIR_SIZE` | uint64 | 字节 | Query Root | 查询执行过程中临时目录（磁盘溢写）的峰值大小，不为 0 说明发生了内存溢写 |
| `TOTAL_MEMORY_ALLOCATED` | uint64 | 字节 | Query Root | Buffer Manager 在此查询期间分配的总内存量 |

> **注意**：`SYSTEM_PEAK_TEMP_DIR_SIZE` 不为 0 表示查询触发了磁盘 spill，是调优的重要信号。

---

### 3.3 File（文件/存储指标）

| 指标名 | 类型 | 单位 | 作用域 | 含义 |
|---|---|---|---|---|
| `TOTAL_BYTES_READ` | uint64 | 字节 | Query Root | 文件系统层面读取的总字节数（含 Parquet、CSV 等文件读取） |
| `TOTAL_BYTES_WRITTEN` | uint64 | 字节 | Query Root | 文件系统层面写入的总字节数 |
| `ATTACH_LOAD_STORAGE_LATENCY` | double | 秒 | Query Root | `ATTACH` 数据库时从存储加载的耗时 |
| `ATTACH_REPLAY_WAL_LATENCY` | double | 秒 | Query Root | `ATTACH` 数据库时重放 WAL 文件的耗时 |
| `WAITING_TO_ATTACH_LATENCY` | double | 秒 | Query Root | 等待 `ATTACH` 操作完成的阻塞时间（多连接并发 attach 时可能不为 0） |
| `WAL_REPLAY_ENTRY_COUNT` | uint64 | 条目数 | Query Root | 本次需要重放的 WAL 条目总数 |
| `CHECKPOINT_LATENCY` | double | 秒 | Query Root | 执行 Checkpoint（将内存数据持久化到磁盘）的耗时 |
| `COMMIT_LOCAL_STORAGE_LATENCY` | double | 秒 | Query Root | 提交事务本地存储（local storage）的耗时 |
| `WRITE_TO_WAL_LATENCY` | double | 秒 | Query Root | 将事务写入 WAL 的耗时 |

---

### 3.4 Operator（算子级指标）

每个物理算子节点单独采集，出现在 JSON `children` 树中每个节点上。

| 指标名 | 类型 | 单位 | 含义 |
|---|---|---|---|
| `OPERATOR_NAME` | string | — | 物理算子的名称（如 `HASH_JOIN`、`TABLE_SCAN`、`FILTER` 等） |
| `OPERATOR_TYPE` | string（枚举） | — | 物理算子的类型枚举值（`PhysicalOperatorType`），与 `OPERATOR_NAME` 对应 |
| `OPERATOR_TIMING` | double | 秒 | 该算子执行所花费的 CPU 时间（不含子算子，仅此节点） |
| `OPERATOR_CARDINALITY` | uint64 | 行数 | 该算子输出的行数（即该算子向父节点传递的数据量） |
| `OPERATOR_ROWS_SCANNED` | uint64 | 行数 | 该算子从存储层实际扫描的原始行数（主要在 `TABLE_SCAN` 算子上有效） |
| `RESULT_SET_SIZE` | uint64 | 字节 | 该算子每次输出 DataChunk 的内存大小之和 |
| `EXTRA_INFO` | map | — | 算子特有额外信息，如 TABLE_SCAN 的过滤条件、Join 的键表达式等 |

> **注意**：`OPERATOR_ROWS_SCANNED` 只在 `TABLE_SCAN` 算子上有意义；`OPERATOR_CARDINALITY` 是经过过滤/聚合后的输出行数，可用于判断选择率。

---

### 3.5 Phase Timing（规划阶段耗时）

均为 **Query Root** 作用域，记录查询规划各阶段的耗时，用于分析慢规划问题。

| 指标名 | 类型 | 单位 | 含义 |
|---|---|---|---|
| `PLANNER` | double | 毫秒 | 将解析后的 SQL AST 转化为逻辑计划的总耗时 |
| `PLANNER_BINDING` | double | 毫秒 | 逻辑计划中列/表绑定（Binding）阶段的耗时 |
| `ALL_OPTIMIZERS` | double | 毫秒 | 所有优化器通道的总耗时（也是一次性启用全部 `OPTIMIZER_*` 的快捷方式） |
| `CUMULATIVE_OPTIMIZER_TIMING` | double | 毫秒 | 所有已启用的 `OPTIMIZER_*` 指标之和（编程式累加） |
| `PHYSICAL_PLANNER` | double | 毫秒 | 将逻辑计划转化为物理执行计划的总耗时 |
| `PHYSICAL_PLANNER_COLUMN_BINDING` | double | 毫秒 | 物理计划中列绑定（逻辑列 → 物理列）的耗时 |
| `PHYSICAL_PLANNER_RESOLVE_TYPES` | double | 毫秒 | 物理计划中类型解析（逻辑类型 → 物理类型）的耗时 |
| `PHYSICAL_PLANNER_CREATE_PLAN` | double | 毫秒 | 物理计划中实际创建物理算子树的耗时 |

---

### 3.6 Optimizer（各优化器耗时）

格式为 `OPTIMIZER_<名称>`，类型 `double`（毫秒），Query Root 作用域。可用 `ALL_OPTIMIZERS` 或 `profiling_mode = 'all'` 一次性全部启用。

| 指标名 | 含义 |
|---|---|
| `OPTIMIZER_EXPRESSION_REWRITER` | 表达式规范化/化简（常量折叠、冗余消除等） |
| `OPTIMIZER_FILTER_PULLUP` | 将过滤条件从子计划上移 |
| `OPTIMIZER_FILTER_PUSHDOWN` | 将过滤条件下推到数据源附近（减少扫描量的关键优化） |
| `OPTIMIZER_EMPTY_RESULT_PULLUP` | 识别并消除必然产生空结果的子计划 |
| `OPTIMIZER_CTE_FILTER_PUSHER` | 向 CTE 内部下推过滤条件 |
| `OPTIMIZER_REGEX_RANGE` | 将 LIKE/正则匹配转换为范围扫描 |
| `OPTIMIZER_IN_CLAUSE` | 优化 `IN (...)` 子句（转哈希或范围扫描） |
| `OPTIMIZER_JOIN_ORDER` | Join 重排序（选择最优 Join 顺序） |
| `OPTIMIZER_DELIMINATOR` | 消除 delim join（横切连接转常规连接） |
| `OPTIMIZER_UNNEST_REWRITER` | 将 UNNEST 操作重写为更高效形式 |
| `OPTIMIZER_UNUSED_COLUMNS` | 消除未使用的列（列裁剪） |
| `OPTIMIZER_STATISTICS_PROPAGATION` | 基于统计信息推断/传播基数估计 |
| `OPTIMIZER_COMMON_SUBEXPRESSIONS` | 公共子表达式消除（CSE） |
| `OPTIMIZER_COMMON_AGGREGATE` | 合并相同的聚合表达式 |
| `OPTIMIZER_COLUMN_LIFETIME` | 分析列的生命周期，提前释放不再需要的列 |
| `OPTIMIZER_BUILD_SIDE_PROBE_SIDE` | 选择 Hash Join 的 Build 侧和 Probe 侧 |
| `OPTIMIZER_LIMIT_PUSHDOWN` | 将 LIMIT 下推以减少上游算子的计算量 |
| `OPTIMIZER_TOP_N` | 将 ORDER BY + LIMIT 转为 Top-N 算法 |
| `OPTIMIZER_COMPRESSED_MATERIALIZATION` | 对中间结果使用压缩存储以节省内存 |
| `OPTIMIZER_DUPLICATE_GROUPS` | 消除重复的分组键 |
| `OPTIMIZER_REORDER_FILTER` | 对多个过滤条件排序以优先执行选择率高的条件 |
| `OPTIMIZER_SAMPLING_PUSHDOWN` | 将 SAMPLE 子句下推，减少处理行数 |
| `OPTIMIZER_JOIN_FILTER_PUSHDOWN` | 将 Join 过滤条件下推至 Build/Probe 侧 |
| `OPTIMIZER_EXTENSION` | 扩展插件注册的自定义优化器耗时 |
| `OPTIMIZER_MATERIALIZED_CTE` | 判断 CTE 是否应被物化 |
| `OPTIMIZER_SUM_REWRITER` | 将某些 SUM 表达式重写为更高效形式 |
| `OPTIMIZER_LATE_MATERIALIZATION` | 延迟物化优化（先过滤再取列值） |
| `OPTIMIZER_CTE_INLINING` | 将 CTE 内联展开（避免重复物化） |
| `OPTIMIZER_ROW_GROUP_PRUNER` | 基于统计信息裁剪 Parquet Row Group |
| `OPTIMIZER_TOP_N_WINDOW_ELIMINATION` | 将窗口函数的 Top-N 场景转化为更高效实现 |
| `OPTIMIZER_COMMON_SUBPLAN` | 公共子计划共享（避免重复执行相同子计划） |
| `OPTIMIZER_JOIN_ELIMINATION` | 消除不必要的 Join |
| `OPTIMIZER_WINDOW_SELF_JOIN` | 将窗口函数与自连接合并优化 |

---

## 四、指标依赖与展开关系

部分指标启用时会自动展开（内部依赖其他指标才能计算）：

| 高层指标 | 自动展开依赖 |
|---|---|
| `CPU_TIME` | 自动启用 `OPERATOR_TIMING` |
| `CUMULATIVE_CARDINALITY` | 自动启用 `OPERATOR_CARDINALITY` |
| `CUMULATIVE_ROWS_SCANNED` | 自动启用 `OPERATOR_ROWS_SCANNED` |
| `CUMULATIVE_OPTIMIZER_TIMING` | 自动启用所有 `OPTIMIZER_*` 指标 |
| `ALL_OPTIMIZERS` | 自动启用所有 `OPTIMIZER_*` 指标 |

---

## 五、profiling_mode 预设

| 模式 | 包含指标集 |
|---|---|
| `standard`（默认） | 所有 `is_default: true` 的指标（Core + Execution + File + Operator 的常用项） |
| `detailed` | standard + 优化器子阶段（打印 Query Tree Optimizer 视图） |
| `all` | 全量指标，含所有优化器单独耗时 |

**standard 模式默认包含的 26 个指标**：
`QUERY_NAME`, `LATENCY`, `CPU_TIME`, `CUMULATIVE_CARDINALITY`, `CUMULATIVE_ROWS_SCANNED`, `EXTRA_INFO`, `RESULT_SET_SIZE`, `ROWS_RETURNED`, `BLOCKED_THREAD_TIME`, `SYSTEM_PEAK_BUFFER_MEMORY`, `SYSTEM_PEAK_TEMP_DIR_SIZE`, `TOTAL_MEMORY_ALLOCATED`, `TOTAL_BYTES_READ`, `TOTAL_BYTES_WRITTEN`, `ATTACH_LOAD_STORAGE_LATENCY`, `ATTACH_REPLAY_WAL_LATENCY`, `CHECKPOINT_LATENCY`, `COMMIT_LOCAL_STORAGE_LATENCY`, `WAITING_TO_ATTACH_LATENCY`, `WAL_REPLAY_ENTRY_COUNT`, `WRITE_TO_WAL_LATENCY`, `OPERATOR_NAME`, `OPERATOR_TYPE`, `OPERATOR_TIMING`, `OPERATOR_CARDINALITY`, `OPERATOR_ROWS_SCANNED`

---

## 六、数据类型说明

| 内部类型 | JSON 输出类型 | 说明 |
|---|---|---|
| `double` | number（浮点） | 时间类指标，单位为秒（phase_timing 系列为毫秒） |
| `uint64` | number（无符号整数） | 计数类指标（行数、字节数） |
| `string` | string | 名称类指标 |
| `Value::MAP` | object | `EXTRA_INFO`，键值对形式的算子特有信息 |
| `uint8`（枚举） | string | `OPERATOR_TYPE`，将枚举值转为名称字符串输出 |

---

## 七、多线程（threads）对算子影响的关键指标

当通过 `SET threads = N` 调整并发线程数时，以下指标最能反映并行化效果与代价，建议重点关注。

### 7.1 核心对比指标

| 指标 | 类型 | 关注原因 |
|---|---|---|
| `LATENCY` | double（秒） | **挂钟时间**。线程增多时应下降；如果不下降甚至上升，说明并行化收益低于调度开销或存在严重竞争。 |
| `CPU_TIME` | double（秒） | **所有算子 CPU 时间之和**。多线程时同一算子的多个并行任务的耗时会叠加，`CPU_TIME` 会随线程增多而增大（因为多线程做了更多总工作），但 `LATENCY` 应缩短。若 `CPU_TIME / LATENCY` 接近线程数，说明并行效率高。 |
| `BLOCKED_THREAD_TIME` | double（秒） | **线程阻塞等待时间**（源码：`src/parallel/executor.cpp` 中 `WaitForTask()` 累积）。随线程增多，线程争抢任务调度锁的等待时间可能上升；若此值过大，说明任务调度成为瓶颈，继续加线程收益下降。 |

### 7.2 算子级关键指标

| 指标 | 类型 | 关注原因 |
|---|---|---|
| `OPERATOR_TIMING` | double（秒） | 单个算子的执行时间。并行算子（如 `HASH_JOIN` Build 阶段、`HASH_GROUP_BY`）随线程增多耗时应下降；单线程算子不变。通过对比不同线程数下各算子的 `OPERATOR_TIMING` 可以定位**并行瓶颈算子**（耗时未随线程增多而减少的算子）。 |
| `OPERATOR_CARDINALITY` | uint64（行数） | 算子输出行数。不受线程数影响，可用于**结果正确性验证**；也可帮助计算每行处理的时间代价（`OPERATOR_TIMING / OPERATOR_CARDINALITY`）。 |
| `OPERATOR_ROWS_SCANNED` | uint64（行数） | TABLE_SCAN 算子扫描的原始行数。多线程会将扫描任务拆分（Row Group 级别并行），各线程各扫各自分片，汇总后此值不变，但每个线程的 `OPERATOR_TIMING` 应缩短。 |

### 7.3 内存相关指标

| 指标 | 类型 | 关注原因 |
|---|---|---|
| `SYSTEM_PEAK_BUFFER_MEMORY` | uint64（字节） | 线程增多时，多个算子可能同时将数据保存在缓冲池中，**峰值内存会上升**。若超过 `memory_limit`，会触发磁盘溢写。 |
| `SYSTEM_PEAK_TEMP_DIR_SIZE` | uint64（字节） | 磁盘溢写峰值大小。增大线程数可能导致内存压力增大，此值从 0 变为非 0 是内存不足的明确信号，此时增加线程反而可能降低性能。 |
| `TOTAL_MEMORY_ALLOCATED` | uint64（字节） | 总内存分配量。随线程增多一般会增大（每个线程需要自己的工作区）。 |

### 7.4 分析建议

```
并行效率 = LATENCY(1 thread) / LATENCY(N threads) / N
```

- **理想情况**（线性加速）：并行效率 → 1，`CPU_TIME ≈ N × LATENCY`，`BLOCKED_THREAD_TIME` 接近 0。
- **调度瓶颈**：`BLOCKED_THREAD_TIME` 随线程数显著增大，说明任务过细或锁竞争严重。
- **内存瓶颈**：`SYSTEM_PEAK_TEMP_DIR_SIZE` > 0，说明增加线程导致内存溢写，应先增大 `memory_limit` 或减少线程。
- **并行瓶颈算子**：对比不同线程数下各算子的 `OPERATOR_TIMING`，找到耗时未下降的算子，该算子是串行化瓶颈。

### 7.5 推荐配置（多线程对比实验）

```sql
-- 方法1：使用 standard 模式（含所有关键指标）
PRAGMA enable_profiling = 'json';
PRAGMA profiling_output = '/tmp/profile_t1.json';
SET threads = 1;
<your_query>;
PRAGMA disable_profiling;

PRAGMA enable_profiling = 'json';
PRAGMA profiling_output = '/tmp/profile_t8.json';
SET threads = 8;
<your_query>;
PRAGMA disable_profiling;

-- 方法2：仅开启多线程相关指标，减少采集开销
SET custom_profiling_settings = '{
  "LATENCY": "true",
  "CPU_TIME": "true",
  "BLOCKED_THREAD_TIME": "true",
  "OPERATOR_TIMING": "true",
  "OPERATOR_CARDINALITY": "true",
  "OPERATOR_ROWS_SCANNED": "true",
  "SYSTEM_PEAK_BUFFER_MEMORY": "true",
  "SYSTEM_PEAK_TEMP_DIR_SIZE": "true",
  "TOTAL_MEMORY_ALLOCATED": "true",
  "OPERATOR_NAME": "true",
  "OPERATOR_TYPE": "true"
}';
PRAGMA enable_profiling = 'json';
```

---

## 附录：指标速查表

| 指标名 | 组 | 作用域 | 类型 | 单位 | 是否默认 |
|---|---|---|---|---|---|
| `QUERY_NAME` | core | Query Root | string | — | ✓ |
| `LATENCY` | core | Query Root | double | 秒 | ✓ |
| `CPU_TIME` | core | Query Root | double | 秒 | ✓ |
| `CUMULATIVE_CARDINALITY` | core | Query Root | uint64 | 行 | ✓ |
| `CUMULATIVE_ROWS_SCANNED` | core | Query Root | uint64 | 行 | ✓ |
| `RESULT_SET_SIZE` | core | Query Root | uint64 | 字节 | ✓ |
| `ROWS_RETURNED` | core | Query Root | uint64 | 行 | ✓ |
| `EXTRA_INFO` | core | Operator | map | — | ✓ |
| `BLOCKED_THREAD_TIME` | execution | Query Root | double | 秒 | ✓ |
| `SYSTEM_PEAK_BUFFER_MEMORY` | execution | Query Root | uint64 | 字节 | ✓ |
| `SYSTEM_PEAK_TEMP_DIR_SIZE` | execution | Query Root | uint64 | 字节 | ✓ |
| `TOTAL_MEMORY_ALLOCATED` | execution | Query Root | uint64 | 字节 | ✓ |
| `TOTAL_BYTES_READ` | file | Query Root | uint64 | 字节 | ✓ |
| `TOTAL_BYTES_WRITTEN` | file | Query Root | uint64 | 字节 | ✓ |
| `ATTACH_LOAD_STORAGE_LATENCY` | file | Query Root | double | 秒 | ✓ |
| `ATTACH_REPLAY_WAL_LATENCY` | file | Query Root | double | 秒 | ✓ |
| `WAITING_TO_ATTACH_LATENCY` | file | Query Root | double | 秒 | ✓ |
| `WAL_REPLAY_ENTRY_COUNT` | file | Query Root | uint64 | 条目 | ✓ |
| `CHECKPOINT_LATENCY` | file | Query Root | double | 秒 | ✓ |
| `COMMIT_LOCAL_STORAGE_LATENCY` | file | Query Root | double | 秒 | ✓ |
| `WRITE_TO_WAL_LATENCY` | file | Query Root | double | 秒 | ✓ |
| `OPERATOR_NAME` | operator | Operator | string | — | ✓ |
| `OPERATOR_TYPE` | operator | Operator | string | — | ✓ |
| `OPERATOR_TIMING` | operator | Operator | double | 秒 | ✓ |
| `OPERATOR_CARDINALITY` | operator | Operator | uint64 | 行 | ✓ |
| `OPERATOR_ROWS_SCANNED` | operator | Operator | uint64 | 行 | ✓ |
| `PLANNER` | phase_timing | Query Root | double | 毫秒 | — |
| `PLANNER_BINDING` | phase_timing | Query Root | double | 毫秒 | — |
| `ALL_OPTIMIZERS` | phase_timing | Query Root | double | 毫秒 | — |
| `CUMULATIVE_OPTIMIZER_TIMING` | phase_timing | Query Root | double | 毫秒 | — |
| `PHYSICAL_PLANNER` | phase_timing | Query Root | double | 毫秒 | — |
| `PHYSICAL_PLANNER_COLUMN_BINDING` | phase_timing | Query Root | double | 毫秒 | — |
| `PHYSICAL_PLANNER_RESOLVE_TYPES` | phase_timing | Query Root | double | 毫秒 | — |
| `PHYSICAL_PLANNER_CREATE_PLAN` | phase_timing | Query Root | double | 毫秒 | — |
| `OPTIMIZER_*`（34 个） | optimizer | Query Root | double | 毫秒 | — |
