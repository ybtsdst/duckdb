# DuckDB Filter Execution 设计文档（扫描期执行）

> 适用源码：`v2.0-cyanoptera` @ `c1cd2470a455`；核对日期：2026-10-23。核对方式：静态源码审查，未执行本文示例或性能测试。

## 范围

本文是 [Filter 系列](./FILTER_DESIGN.md) 的扫描期部分。讨论 DuckDB 内置存储从 `ExpressionFilter` 集合到统计剪枝、SelectionVector 和列读取的路径。外部 Table Function 的过滤由各自实现负责，`PhysicalTableScan` 不会对任意数据源输出自动补过滤。

## 一、扫描初始化与过滤器寿命

[physical_table_scan.cpp](../src/execution/operator/scan/physical_table_scan.cpp) 的 `TableScanGlobalSourceState` 在初始化时调用 `DynamicTableFilterSet::GetFinalTableFilters`，将生产者发布的运行期集合和静态 `op.table_filters` 合并，通过 `TableFunctionInitInput::filters` 交给 `init_global`；`TableScanLocalSourceState` 把同一个最终集合交给 `init_local`。

合并集合保存在 global source state，字段析构顺序使其寿命覆盖引用它的 table-function global state。集合合并是初始化时的动作，不是每个输出 chunk 重新合并；但表达式 bind data 中的共享 `DynamicFilterData` 后续仍可更新，这是 TopN 的路径。

[scan_state.cpp](../src/storage/table/scan_state.cpp) 的 `ScanFilterInfo::Initialize` 为每个单列 filter 构造 `ScanFilter`、`TableFilterState` 和可重排列表，保存 `ProjectionIndex → StorageIndex` 对应关系。多列 filters 单独保存用于 row-group 统计，不进入单列 hot loop。

## 二、Row group 统计剪枝

依据：[row_group.cpp](../src/storage/table/row_group.cpp) 的 `RowGroup::CheckZonemap`。

1. 对多列 `ExpressionFilter` 按 `column_indexes` 收集该行组各列统计，调用 `CheckExpressionStatistics`。统计不支持或缺失时继续保守扫描；FALSE / FALSE_OR_NULL 则跳过行组。
2. `CheckAllFilters()` 重置上一个行组留下的 always-true 状态。
3. 对单列过滤调用该列的 `CheckZonemap`；rowid 没有持久 zone-map，由 `CheckRowIdFilter` 构造 `[row_start, row_start + count - 1]` 的数值统计。
4. FALSE / FALSE_OR_NULL 跳过行组；root non-selectivity optional 在未排除行组时标记为 always-true；精确 ALWAYS_TRUE 也省略行级判断。
5. TRUE_OR_NULL / NO_PRUNING 不能直接放行所有行。

这里跳过的是后续行数据扫描工作。统计/元数据读取、缓存命中和已提交的预取都可能已发生，不能概括为“绝对零 I/O”。

`SetFilterAlwaysTrue` 同时清该列的 active-filter 标记，所以只用于统计的列若仍在扫描请求内，会在普通列读取阶段被正确填充，不会产生未初始化输出。

## 三、Segment 统计与扫描准备

`RowGroup::CheckZonemapSegments` 使用列当前 segment 的统计，能排除时推进完整 vector 的扫描位置；不足一个 vector 的可跳区间仍有保守处理。段边界由压缩和存储布局决定，不能假设每段大小固定为 vector 大小的整数倍。

当前实现将准备和消费拆开：`PrepareScan` 选择可扫描的 vector，`ProcessPreparedScan` 消费准备好的状态，`Scan` 串接二者。内置表函数还使用 `PrepareScanIO` / `ProcessPreparedScan`、`ScanReadAhead` 调度读取，见 [table_scan.cpp](../src/function/table/table_scan.cpp)。因此实际调用可能跨异步任务，旧“GetData 内立即同步读完一批”的图不能覆盖全部路径。

MVCC 可见性、删除、采样选择和过滤选择共同决定最终行集合；不能只依据 WHERE 命中率解释输出行数。

## 四、向量内先过滤再读取其余列

下面是对 `RowGroup::ProcessPreparedScan` 的简化伪代码，省略事务、采样、错误及异步控制：

```text
sel = 当前可见/采样行
if 无 active filter 且不需部分可见性处理:
    扫描请求中的所有列
else:
    按 AdaptiveFilter 顺序处理 active filter 列:
        若已无存活行，仅推进该列 scan state
        否则 ColumnData::Filter(..., sel, approved_count)
    对已读取 filter 列按最终 sel Slice
    若 approved_count == 0:
        其余列 Skip，完成本 vector
    否则:
        对其余列 ColumnData::Select(..., sel, approved_count)
```

关键收益是选择集合可流式收窄；已经排除整个 vector 时，无需再扫描其余列的数据。`Slice` 经常是引用/选择映射操作，不能将其描述成“一次拷贝全部物理数据”。

### Select 不保证只解码存活行

必须区分两个实现，依据 [column_data.cpp](../src/storage/table/column_data.cpp) 与 [standard_column_data.cpp](../src/storage/table/standard_column_data.cpp)：

- `ColumnData::Select` 的基础实现是 `Scan` 然后 `Slice`，可能仍扫描整个 vector。
- `StandardColumnData::Select` 仅当数据与 validity 压缩函数都提供 `select`、且二者没有 updates 时走 `SelectVector`；否则回退基础实现。
- `ColumnData::SelectVector` 按 segment 分配所选行，调用 [ColumnSegment::Select](../src/storage/table/column_segment.cpp) 的压缩回调。没有选中行的段可以跳过，但具体解码粒度由压缩实现决定。

所以“1% 命中率意味着只读取/解压 1% 投影数据”不是通用结论。这种扫描内延后读取也不同于 [LateMaterialization 优化器](./LATE_MATERIALIZATION_DESIGN.md) 的行 ID 半连接改写。

## 五、ExpressionFilter 行级执行

入口为 [ColumnSegment::FilterSelection](../src/storage/table/column_segment.cpp)，当前不再按一组活动 `TableFilterType` 子类 switch。它取 `ExpressionFilterState`：

```text
存在 fast_executor 且 scan_count <= STANDARD_VECTOR_SIZE
  → fast_executor->FilterSelection
否则
  → ExecuteExpressionFilterSelection
  → ExpressionExecutor::SelectExpression
```

[table_filter_state.cpp](../src/planner/table_filter_state.cpp) 的 `TryCreateFastExecutor` 按表达式形状构建快速执行器，包括简单列常量比较、可完整识别的 AND、optional、Bloom、prefix-range 等。AND 的子树只要有一部分不支持，整体会回退通用 executor。NULL 检查或复杂 CAST 不应仅因旧版存在专门枚举就假定能命中快速路径。

`ComparisonFilterExecutor::TemplatedSelect<T, OP, CAN_HAVE_NULL>` 保留类型/比较/NULL 特化；`ExpressionFilterExecutor` 本身仍有虚接口，外围还有表达式分析和分派，不能声称全链路“零动态 dispatch”。是否机器级 SIMD 未在本次静态审查中验证。

通用执行把单列向量作为输入，传入已有选择向量，只判断仍存活的行；超过标准 vector 大小则分块处理并转换选择偏移。不要把单列表达式的 `BoundReference(0)` 和原表列0混淆。

## 六、AdaptiveFilter：基于耗时试探顺序

依据：[adaptive_filter.cpp](../src/execution/adaptive_filter.cpp) 的构造、`BeginFilter`、`EndFilter`、`AdaptRuntimeStatistics`。

扫描的初始 permutation 由 `ExpressionHeuristics::GetInitialOrder` 给出；后续比较整个过滤阶段的运行耗时，随机试探相邻交换。当前常量是 warmup 5 次、执行间隔20次、观察间隔10次。交换后的平均耗时未下降则撤销，并降低该位置再交换的概率。

这是耗时驱动的启发式，不是直接按单列观测选择率排序，也没有保证收敛到全局最优顺序。只有至少两个 filter 且允许重排时才执行学习；`CanThrow()` 或表达式 barrier 会禁用 permutation，以免改变抛错和求值顺序语义。

`AdaptiveFilter::Remap` 可按稳定 filter identity 重映射已有顺序；本次未穷尽多文件调用方的所有重映射和日志分支。

## 七、执行检查要点

排查过滤效果时，先区分：过滤是否下推、统计是否能证明排除、行级是否 active、是否命中 fast executor、其余列是否能走选择性解码。这些层次不能通过一个 `Filters:` 展示字段统一推断。

运行期集合发布和 TopN 边界更新见 [RUNTIME_FILTER_DESIGN.md](./RUNTIME_FILTER_DESIGN.md)；收益条件见 [FILTER_PERFORMANCE_DESIGN.md](./FILTER_PERFORMANCE_DESIGN.md)。本文没有执行 SQL、测量 I/O/CPU，也未验证每个压缩 codec。
