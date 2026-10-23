# DuckDB Profile 指标与采集流程

> 适用源码：`v2.0-cyanoptera` @ `c1cd2470a455`；核对日期：2026-10-23。核对方式：静态源码审查，未执行本文示例或性能测试。

## 一、2.0 的指标模型

当前实现以字符串指标名和 `GatheredMetrics` 为中心。指标按 `query.*`、`system.*`、`io.*`、`storage.*`、`operator.*`、规划与优化阶段分组。旧版文档中的大写 `MetricType` 名称、26 项默认集合和 `custom_profiling_settings` 不能继续作为当前 SQL 配置接口使用。

主要源码入口：

| 源码 | 职责 |
|---|---|
| [metrics.json](../src/common/metrics.json) | 内置指标名称、类型、单位与描述 |
| [metrics_manager.cpp](../src/main/profiler/metrics_manager.cpp) | `MetricsManager::GetAllMetrics`：内置描述符、优化器指标及扩展注册项 |
| [client_config.hpp](../src/include/duckdb/main/client_config.hpp) | Profiling 开关、输出格式和 `tracked_metrics` 默认值 |
| [gathered_metrics.cpp](../src/main/profiler/gathered_metrics.cpp) | 指标选择与分组结果树转换 |
| [query_profiler.cpp](../src/main/query_profiler.cpp) | 查询/算子采集、合并、终结与结果树 |
| [profiling_utils.cpp](../src/main/profiler/profiling_utils.cpp) | `QueryMetrics::FinalizeMetrics`：计时与计数转换 |
| [custom_settings.cpp](../src/main/settings/custom_settings.cpp) | SQL 设置校验与兼容设置行为 |
| [duckdb_metrics.cpp](../src/function/table/system/duckdb_metrics.cpp) | `duckdb_available_metrics()` 的四列输出 |

`MetricsManager` 描述“系统知道哪些指标”；`tracked_metrics` 决定保留哪些指标；采集调用点决定本次查询实际能产生哪些值。三者不能混为一谈。扩展注册描述符也不会自动生成测量值。

## 二、启用、选择指标与输出

以下 SQL 是按当前注册接口核对的使用示例，未运行。

```sql
PRAGMA enable_profiling = 'json';
SET profiling_coverage = 'SELECT';
SET tracked_metrics = ['query.*', 'operator.*', 'system.*', 'io.*'];
PRAGMA profiling_output = '/tmp/profile.json';
SELECT sum(i) FROM range(1000) t(i);
PRAGMA disable_profiling;
```

- 默认不开启 Profiling；启用后默认输出格式为 `query_tree`。
- 默认 `tracked_metrics = ['*']`，不是旧版的固定26项集合。
- `profiling_coverage` 默认为 `SELECT`。`QueryProfiler::OperatorRequiresProfiling` 根据物理算子类型判断是否需要采集；`ALL` 直接允许全部类型。不能将 `SELECT` 简化为对 SQL 首个关键字的匹配。
- [tree_renderer.cpp](../src/common/tree_renderer.cpp) 注册 text/query_tree、query_tree_optimizer、json、html、graphviz、mermaid 等 renderer；`EnableProfilingSetting::SetLocal` 在启用时检查格式。`no_output` 可用于采集但不自动打印。
- `ProfilingOutputSetting::SetLocal` 会检查输出文件扩展名和当前格式是否匹配；`.txt` 是接受的通用扩展名。设置 JSON 输出前先选择 JSON renderer。

### 2.1 指标匹配规则

`TrackedMetricsSetting::SetLocal` 接受 `LIST(VARCHAR)`。`GatheredMetrics::InitTrackedMetrics` 将模式分为精确名称、简单前缀和一般 glob；`SetMetric` 只保留匹配项。

```sql
-- 全部指标
SET tracked_metrics = ['*'];

-- 精确指标及一组优化器指标
SET tracked_metrics = ['query.total_time', 'operator.timing', 'optimizer.*'];

-- 静态目录的查询接口；本轮没有执行这条 SQL
SELECT metric_name, metric_type, description, unit
FROM duckdb_available_metrics()
ORDER BY metric_name;
```

不存在旧的“启用 CPU_TIME 自动展开 OPERATOR_TIMING”配置表：当前查询累计值来自内部测量合并，再按字符串模式选择输出。只选择 `query.cpu_time` 不代表结果树必须显示 `operator.timing`。

### 2.2 已弃用的模式设置

`profiling_mode = 'standard' / 'detailed' / 'all'` 仍被兼容接受，但三个值走相同路径：记录弃用警告并启用 Profiler；不会选择三套不同的指标集合。优化器明细通过 `tracked_metrics` 控制。新文档和脚本应直接使用 `enable_profiling`、`profiling_coverage` 和 `tracked_metrics`。

## 三、采集与生命周期

### 3.1 查询级

`QueryProfiler::StartQuery` / `Start` 初始化查询状态和 `query.total_time` 计时器；`Initialize` 创建与物理执行树对应的 `ProfilingNode` 树和 `GatheredMetrics`。`EndQuery` 调用 `FinalizeMetricsInternal`，结束计时、合并算子测量并终结查询级计数，然后按配置渲染和写日志。

规划、解析、存储等阶段通过 `MetricsTimer` 和计数接口记录。`QueryMetrics::FinalizeMetrics` 将纳秒计时除以 `1e9` 转为秒。不能沿用旧文档中“规划与优化指标单位是毫秒”的表格。

查询总时间覆盖其计时器实际存活区间。Profiling 的启动路径、`EXPLAIN ANALYZE` 和早期规划阶段有专门处理，不宜将它等同于客户端从发送请求到完全消费结果的全部延迟。

### 3.2 算子级

`OperatorProfiler::StartOperator` / `EndOperator` 用 [Profiler](../src/include/duckdb/common/profiler.hpp) 的 elapsed timer 计时，并通过 `OperatorMetrics::GatherMetrics` 累加输出 chunk 行数、`GetDataSize()` 和缓冲管理器用量样本。任务结束后测量合并到查询树。

- `operator.timing` 为多次调用及并行实例计时的累加，增加线程数不保证该值下降。
- `query.cpu_time` 来自整棵算子树测量的累加。虽然名称含 CPU，它不是操作系统进程 CPU 时钟；不能将其解释为“纯 CPU 指令执行时间”。
- 并行计时区间会重叠，`query.cpu_time` 可以大于 `query.total_time`；两者相减不能直接计算 I/O 等待。
- `AsyncTask::Execute` 不会仅因被调度到 ASYNC 池就自动新增算子计时节点，因此该累计值也不能解释为覆盖所有后台 I/O 线程的工作时间。异步执行边界见[协议内部实现](ASYNC_TABLE_SCAN_PROTOCOL_INTERNALS.md)。
- `OperatorProfiler::FinishSource` 对 `TABLE_SCAN` 调用 `PhysicalTableScan::GetMetrics`；扫描行数/row-group 数还依赖具体扫描函数提供的测量，不能统一当作操作系统或磁盘读取量。

### 3.3 汇总的含义

`FinalizeMetricsInternal` 在合并前处理 secure view 边界，再由 `MergeOperatorMeasurements` 形成查询总计。`total_intermediate_rows` 会累计执行树各节点的中间输出，同一条业务记录可被多个节点计数。它既不是最终结果行数，也不能独立验证结果正确性。

`total_intermediate_size_bytes` 是中间输出 chunk 数据大小的累计，不是结果集驻留内存或查询峰值 RSS。旧兼容 JSON 将它映射为 `result_set_size`，字段名称不能改变测量本身的含义。

## 四、关键指标的解释边界

| 指标 | 当前采集含义与限制 |
|---|---|
| `query.total_time` | 查询 Profiler 的 elapsed 时间；和客户端端到端计时分别分析 |
| `query.cpu_time` | 算子测量时间累加；存在并行重叠，不保证小于查询总时间 |
| `operator.timing` | 当前节点调用时间累加；不是该节点关键路径的墙钟区间 |
| `operator.intermediate_rows` | 该节点被采集到的 chunk 输出行数，不等于扫描原始行数 |
| `operator.rows_scanned` | 扫描函数提供的扫描行数，当前节点输出只在 TABLE_SCAN 路径使用 |
| `system.blocked_thread_time` | `Executor::WaitForTask` 等待获取执行锁及无可执行任务时等待通知的累计；不是全体 worker 的全部阻塞/I/O时间 |
| `system.peak_buffer_memory` | 算子采样观察到的 buffer pool 用量峰值；不能解释为查询独占的进程 RSS，其他并发查询可影响观察值 |
| `system.peak_temp_dir_size` | 采样时缓冲管理器使用的 swap 大小峰值；不能仅凭非零值认定某一算子或本次新增线程触发 spill |
| `system.peak_streaming_buffer_size` | 流式结果队列字节加被阻塞 worker 持有的结果单元；不包含仍在构造中的单元 |
| `system.total_memory_allocated` | 经对应 tracking 接口累计的 buffer-manager 分配量；不是当前内存占用或所有 malloc 总量 |
| `io.total_bytes_read` / `io.total_bytes_written` | 经 Profiler 的字节 tracking 接口累计；不是未经验证的物理磁盘流量或全部网络流量 |
| `storage.*` | 仅相应 attach、WAL、checkpoint、事务等路径被触发并记录时才有对应测量；描述符存在不代表每条 SELECT 都执行了这些操作 |

依据：[executor.cpp](../src/parallel/executor.cpp) 的 `WaitForTask` 与 `QueryProfiler::SetBlockedTime`、`OperatorMetrics::GatherMetrics/GetMetrics` 和 `QueryMetrics::FinalizeMetrics`。

字节计数的具体入口见 [file_system.cpp](../src/common/file_system.cpp)：带 QueryContext 的 FileHandle 操作仅在 `track_io` 开启且有 ClientContext 时跟踪；顺序读/写按实际返回量累计，定位读/写在调用前按请求量累计。因此它们也不是所有失败路径都能解释为“已成功传输的字节”。内存分配入口见 [client_data.cpp](../src/main/client_data.cpp) 的 BufferManager 包装器及 `TrackMemoryAllocation`，不能扩大为整个进程所有分配的统计。

## 五、结果树与旧格式

默认 `legacy_metrics_format = false`。`GatheredMetrics::MetricsToProfileResult` 把点分隔键转换为嵌套对象；算子树位于顶层 `operator` 列表中，节点后代仍使用 `children`。

以下仅示意字段结构，不是本轮查询输出：

```json
{
  "query": {"total_time": 0.0, "cpu_time": 0.0},
  "system": {"blocked_thread_time": 0.0},
  "operator": [{"type": "PROJECTION", "timing": 0.0, "children": []}]
}
```

`SET legacy_metrics_format = true` 启用已弃用的兼容输出路径 `ToLegacyResultTree`，映射出 `latency`、`cpu_time`、`cumulative_cardinality`、`operator_timing` 等旧字段及顶层 `children`。它不会恢复旧版 `custom_profiling_settings` 或三套 `profiling_mode` 语义。

| 旧格式字段示例 | 当前指标来源 |
|---|---|
| `latency` | `query.total_time` |
| `cpu_time` | `query.cpu_time` |
| `cumulative_cardinality` | `query.total_intermediate_rows` |
| `cumulative_rows_scanned` | `query.total_rows_scanned` |
| `result_set_size`（查询级） | `query.total_intermediate_size_bytes` |
| `rows_returned` | 根算子的 `intermediate_rows` |
| `operator_timing` | 算子节点 `timing` |
| `operator_cardinality` | 算子节点 `intermediate_rows` |

原始 JSON 的物理类型由 `ValueToJSON` 决定：计数为数值、时间为浮点数、额外信息 MAP 为对象，多行额外信息可转换为数组。字段缺失可能是指标未跟踪、路径未执行或该输出器未生成，不能一律按零处理。

## 六、多线程分析建议

用同一数据、查询、设置和冷热缓存条件比较多次运行的 `query.total_time`，再查看 `operator.timing`、扫描量、内存和 swap 变化。延迟收益、累计工作量和等待是不同维度。

`T1 / TN / N` 可作为固定工作负载的扩展效率计算式，但 `query.cpu_time / query.total_time` 不能直接证明 CPU 利用率或并行效率；`system.blocked_thread_time` 升高也不能单独证明调度锁竞争。定位这些问题需要额外的运行采样，本轮未做性能验证。

## 七、内置指标目录

下表从当前 `src/common/metrics.json` 静态核对。优化器明细由 `MetricsManager::GetAllMetrics` 遍历当前 `OptimizerType` 动态生成 `optimizer.<小写枚举名>`，类型为 double、单位为秒；扩展还可注册额外项，因此不固定“34个优化器指标”。

注意：目录表示注册的描述符。当前 `OperatorMetrics::GetMetrics` 输出 `timing` 等节点字段，但没有单独输出已注册的 `operator.cpu_time`；不能仅凭下表假定每个名称都在结果树中出现。

| 指标 | 类型 | 单位 | 源码描述 |
|---|---|---|---|
| `query.sql` | string | — | The SQL string of the query |
| `query.total_time` | double | seconds | Time spent executing the entire query |
| `query.cpu_time` | double | seconds | CPU time spent on the query |
| `query.total_intermediate_rows` | uint64 | rows | Cumulative number of intermediate rows produced by the query |
| `query.total_row_groups_scanned` | uint64 | row_groups | Cumulative number of row groups scanned by the query |
| `query.total_row_groups_to_scan` | uint64 | row_groups | Cumulative total number of row groups available to scan |
| `query.total_rows_scanned` | uint64 | rows | Cumulative number of rows scanned by the query |
| `query.total_intermediate_size_bytes` | uint64 | bytes | Cumulative size in bytes of all intermediate results produced by the query |
| `system.blocked_thread_time` | double | seconds | Time spent waiting for a thread to become available |
| `system.peak_buffer_memory` | uint64 | bytes | Peak memory usage of the buffer manager |
| `system.peak_streaming_buffer_size` | uint64 | bytes | Peak number of bytes a streaming query result held: queued bytes plus the units blocked workers hold, both exact. Units still under construction are not counted |
| `system.peak_temp_dir_size` | uint64 | bytes | Peak size of the temporary directory |
| `system.total_memory_allocated` | uint64 | bytes | The total memory allocated by the buffer manager |
| `io.total_bytes_read` | uint64 | bytes | The total amount of bytes read from storage |
| `io.total_bytes_written` | uint64 | bytes | The total amount of bytes written to storage |
| `storage.attach_load_storage_latency` | double | seconds | Time spent loading from storage |
| `storage.attach_replay_wal_latency` | double | seconds | Time spent replaying the WAL file |
| `storage.checkpoint_latency` | double | seconds | Time spent running checkpoints |
| `storage.commit_local_storage_latency` | double | seconds | Time spent committing the transaction-local storage |
| `storage.waiting_to_attach_latency` | double | seconds | Time spent waiting to ATTACH a file |
| `storage.wal_replay_entry_count` | uint64 | rows | The total number of entries to replay in the WAL |
| `storage.total_vacuum_time` | double | seconds | Total time spent running vacuum tasks during checkpointing |
| `storage.write_to_wal_latency` | double | seconds | Time spent writing to the WAL |
| `operator.cpu_time` | double | seconds | CPU time spent in the operator |
| `operator.extra_info` | map | — | Unique operator metrics |
| `operator.intermediate_rows` | uint64 | rows | Number of intermediate rows produced by the operator |
| `operator.intermediate_size_bytes` | uint64 | bytes | Intermediate size in bytes produced by the operator |
| `operator.row_groups_scanned` | uint64 | row_groups | Number of row groups scanned by the operator |
| `operator.rows_scanned` | uint64 | rows | Number of rows scanned by the operator |
| `operator.timing` | double | seconds | Time spent in the operator |
| `operator.total_row_groups_to_scan` | uint64 | row_groups | Total number of row groups available for the operator to scan |
| `operator.type` | string | — | Type of the operator |
| `optimizer.total_time` | double | seconds | Time spent in all optimizers combined |
| `parser.total_time` | double | seconds | Time spent parsing the SQL query |
| `planner.total_time` | double | seconds | Time spent generating the logical plan |
| `planner.binding_time` | double | seconds | Time spent binding the logical plan |
| `physical_planner.total_time` | double | seconds | Time spent generating the physical plan |
| `physical_planner.column_binding` | double | seconds | Time spent binding the columns in the logical plan to physical columns |
| `physical_planner.create_plan` | double | seconds | Time spent creating the physical plan |
| `physical_planner.resolve_types` | double | seconds | Time spent resolving the types in the logical plan to physical types |

## 八、核对边界

本文核对了指标定义、注册、采集、设置和输出的源码链路，没有运行 SQL、解析真实 profile 或测量采集开销。指标解释适用于上述冻结提交；与其他版本或旧格式消费者集成时，应重新核对字段及兼容设置。
