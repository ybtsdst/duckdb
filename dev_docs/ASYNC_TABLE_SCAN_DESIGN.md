# Async Table Scan 执行模式分析

## 概述

DuckDB 的 `TableScanFunc`（[table_scan.cpp](../src/function/table/table_scan.cpp)）在扫描 row group 时支持两种执行模式：**同步模式**（SYNCHRONOUS）和**任务调度模式**（TASK_EXECUTOR）。理解这两种模式的差异，对实现自定义 table function 至关重要。

---

## 核心类型定义

### `AsyncResultsExecutionMode`（[async_result.hpp](../src/include/duckdb/parallel/async_result.hpp)）

```cpp
enum class AsyncResultsExecutionMode : uint8_t {
    SYNCHRONOUS,  // BLOCKED 不会上浮，同步等待执行
    TASK_EXECUTOR // BLOCKED 允许上浮，由调度器驱动
};
```

### `AsyncResultType`（[operator_result_type.hpp](../src/include/duckdb/common/enums/operator_result_type.hpp)）

| 值 | 含义 |
|----|------|
| `INVALID` | 未初始化状态 |
| `IMPLICIT` | 依赖外部上下文（框架根据 output chunk size 自动判断） |
| `HAVE_MORE_OUTPUT` | 当前批次未完成，调度器应再次调用 |
| `FINISHED` | 数据已全部产出，调度器不应再调用 |
| `BLOCKED` | 当前被异步 I/O 阻塞，附带 AsyncTask 列表等待调度 |

---

## 关键代码解析

### `TableScanFunc` 中的模式分支（table_scan.cpp:324-332）

```cpp
// 处理完当前 row group，调用 NextParallelScan 推进到下一个
l_state.rows_in_current_row_group = storage.NextParallelScan(context, state, l_state.scan_state);

if (data_p.results_execution_mode == AsyncResultsExecutionMode::TASK_EXECUTOR) {
    // TASK_EXECUTOR 模式：不循环，立即 return，告知调度器下一步
    if (l_state.rows_in_current_row_group == 0) {
        data_p.async_result = AsyncResultType::FINISHED;
    } else {
        data_p.async_result = AsyncResultType::HAVE_MORE_OUTPUT;
    }
    return;
}
// SYNCHRONOUS 模式：rows 为 0 则自然退出循环，否则继续 do-while
if (l_state.rows_in_current_row_group == 0) {
    return;
}
// 检查中断信号
if (context.interrupted) {
    throw InterruptException();
}
```

### 执行流程对比

```
SYNCHRONOUS 模式：
  do {
    Scan row group → 有数据 → return
    Scan row group → 无数据 → NextParallelScan
      → 有更多 row group → 继续循环
      → 没有更多     → return
  } while (true)
  （整个过程阻塞调用线程）

TASK_EXECUTOR 模式：
  Scan row group → 有数据 → return（async_result = IMPLICIT）
  Scan row group → 无数据 → NextParallelScan
    → 有更多 row group → async_result = HAVE_MORE_OUTPUT, return
    → 没有更多     → async_result = FINISHED, return
  （每个 row group 是一个调度单元，不阻塞）
```

---

## 对功能和性能的影响

### 功能

- **SYNCHRONOUS**：函数内部自旋直到产出数据或耗尽所有 row group，适合简单/单线程场景。
- **TASK_EXECUTOR**：每处理一个 row group 就归还控制权，框架可以将剩余 row group 重新调度，支持真正的 pipeline 并行。
- 可中断性：SYNCHRONOUS 模式通过 `context.interrupted` 检查实现中断；TASK_EXECUTOR 天然可调度，不存在长时间占用问题。

### 性能

| 维度 | SYNCHRONOUS | TASK_EXECUTOR |
|------|-------------|---------------|
| 延迟 | 低（无调度开销） | 稍高（每 row group 一次调度） |
| 吞吐 | 适合单 worker | 多 worker 并行时吞吐更好 |
| CPU 利用 | 可能忙等空 row group | 协作让出，利用率更均匀 |
| 异步 I/O 支持 | 不支持 BLOCKED | 支持，配合 AsyncTask 调度 |

---

## 自定义 Table Function 参考

### 最简实现（无异步需求）

```cpp
void MyTableScan(ClientContext &context, TableFunctionInput &data_p, DataChunk &output) {
    auto &lstate = data_p.local_state->Cast<MyLocalState>();

    if (lstate.done) {
        data_p.async_result = SourceResultType::FINISHED;
        return;
    }

    FillOutputChunk(output, lstate);
    lstate.Advance();

    data_p.async_result = lstate.done
        ? SourceResultType::FINISHED
        : SourceResultType::HAVE_MORE_OUTPUT;
}
```

### 支持 TASK_EXECUTOR 的分批实现

```cpp
void MyTableScan(ClientContext &context, TableFunctionInput &data_p, DataChunk &output) {
    auto &lstate = data_p.local_state->Cast<MyLocalState>();

    do {
        FillOutputChunk(output, lstate);
        if (output.size() > 0) return;  // async_result 保持 IMPLICIT，框架自动处理

        bool has_more = lstate.AdvanceToNextBatch();

        // 关键：TASK_EXECUTOR 模式下不循环
        if (data_p.results_execution_mode == AsyncResultsExecutionMode::TASK_EXECUTOR) {
            data_p.async_result = has_more
                ? AsyncResultType::HAVE_MORE_OUTPUT
                : AsyncResultType::FINISHED;
            return;
        }

        if (!has_more) return;

        // SYNCHRONOUS 模式继续循环
        if (context.interrupted) {
            throw InterruptException();
        }
    } while (true);
}
```

### 支持异步 I/O（BLOCKED）的完整实现

参考 [multi_file_function.hpp:599-673](../src/include/duckdb/common/multi_file/multi_file_function.hpp)，核心模式：

```cpp
auto res = data.reader->Scan(...);

if (res.GetResultType() == AsyncResultType::BLOCKED) {
    switch (data_p.results_execution_mode) {
    case AsyncResultsExecutionMode::TASK_EXECUTOR:
        data_p.async_result = std::move(res);  // 把 AsyncTask 上浮给调度器
        return;
    case AsyncResultsExecutionMode::SYNCHRONOUS:
        res.ExecuteTasksSynchronously();        // 就地同步执行异步任务
        continue;
    }
}
```

---

## 关键参考文件

| 文件 | 说明 |
|------|------|
| [src/function/table/table_scan.cpp](../src/function/table/table_scan.cpp) | 本文分析的主体，TableScanFunc 实现 |
| [src/include/duckdb/parallel/async_result.hpp](../src/include/duckdb/parallel/async_result.hpp) | AsyncResult / AsyncResultsExecutionMode 完整接口 |
| [src/include/duckdb/common/enums/operator_result_type.hpp](../src/include/duckdb/common/enums/operator_result_type.hpp) | AsyncResultType / SourceResultType 枚举定义 |
| [src/include/duckdb/common/multi_file/multi_file_function.hpp](../src/include/duckdb/common/multi_file/multi_file_function.hpp) | 处理 BLOCKED 的最完整参考实现 |
| [src/include/duckdb/function/table_function.hpp](../src/include/duckdb/function/table_function.hpp) | TableFunctionInput 结构体，含 async_result 和 results_execution_mode 字段 |
