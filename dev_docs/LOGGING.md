# DuckDB 日志系统开发者文档

本文档面向 DuckDB 内部开发者，介绍如何在代码中添加日志输出，以及如何在运行时配置并查询日志。

---

## 一、总体架构

DuckDB 日志系统的核心层次结构如下：

```
DatabaseInstance
  └── LogManager                  ← 全局日志管理器，持有配置和存储
        ├── LogConfig             ← 日志配置（级别、模式、存储等）
        ├── LogStorage            ← 日志存储后端（内存/文件/stdout）
        └── Logger                ← 各上下文的日志写入接口
              ├── MutableLogger        ← 数据库/连接级别，支持动态配置更新
              ├── ThreadSafeLogger     ← 线程安全的固定配置日志器
              ├── ThreadLocalLogger    ← 线程级别缓存（暂未完全实现）
              └── NopLogger            ← 日志关闭时使用的空操作日志器
```

**关键源码位置：**

| 文件 | 说明 |
|------|------|
| `src/include/duckdb/logging/logger.hpp` | Logger 基类及所有 `DUCKDB_LOG_*` 宏 |
| `src/include/duckdb/logging/logging.hpp` | `LogLevel`、`LogConfig`、`LoggingContext` 等基础配置类型定义 |
| `src/include/duckdb/logging/log_type.hpp` | 结构化日志类型定义 |
| `src/include/duckdb/logging/log_manager.hpp` | `LogManager` 全局日志管理器 |
| `src/include/duckdb/logging/log_storage.hpp` | `LogStorage` 抽象接口及 `InMemoryLogStorage`、`FileLogStorage`、`StdOutLogStorage` 等实现 |
| `src/include/duckdb/logging/file_system_logger.hpp` | 文件系统操作专用日志宏 |
| `src/logging/logger.cpp` | Logger 各子类实现 |
| `src/logging/log_manager.cpp` | LogManager 实现 |
| `src/logging/log_storage.cpp` | LogStorage 各后端实现 |
| `src/logging/log_types.cpp` | 内置结构化日志类型实现 |
| `src/function/table/system/duckdb_log.cpp` | `duckdb_logs` 表函数 |
| `src/function/scalar/system/write_log.cpp` | `write_log()` 标量函数 |
| `src/function/table/system/logging_utils.cpp` | `enable_logging()`、`disable_logging()` 等 |

---

## 二、日志级别

```cpp
enum class LogLevel : uint8_t {
    LOG_TRACE = 10,  // 最详细，用于追踪底层操作（如文件读写）
    LOG_DEBUG = 20,  // 调试信息
    LOG_INFO  = 30,  // 一般性信息（默认最低级别）
    LOG_WARN  = 40,  // 警告
    LOG_ERROR = 50,  // 错误
    LOG_FATAL = 60   // 致命错误
};
```

默认最低日志级别为 `INFO`，级别低于该值的日志不会被记录。

---

## 三、在 C++ 代码中写日志

### 3.1 引入头文件

```cpp
#include "duckdb/logging/logger.hpp"
```

### 3.2 使用日志宏

推荐使用以下宏写入日志，宏会自动检查是否需要记录（避免不必要的字符串格式化）：

```cpp
// SOURCE 是日志上下文来源，见 3.3 节
// 支持 printf 风格的格式化字符串

DUCKDB_LOG_TRACE(SOURCE, format, ...)
DUCKDB_LOG_DEBUG(SOURCE, format, ...)
DUCKDB_LOG_INFO(SOURCE, format, ...)
DUCKDB_LOG_WARN(SOURCE, format, ...)
DUCKDB_LOG_ERROR(SOURCE, format, ...)
DUCKDB_LOG_FATAL(SOURCE, format, ...)
```

**示例：**

```cpp
// 在有 ClientContext 的地方（推荐）
DUCKDB_LOG_INFO(*client_context, "Loaded extension '%s'", extension_name);

// 带格式化参数
DUCKDB_LOG_INFO(db, "ColumnDataCheckpointer result for %s.%s: score=%d",
                schema_name, table_name, best_score);

// 记录警告
DUCKDB_LOG_WARN(*client_context, "Deprecated option '%s' used", option_name);
```

### 3.3 选择合适的日志上下文来源（SOURCE）

`SOURCE` 决定日志记录在哪个上下文下，**优先使用更细粒度的上下文**，这样日志中会包含更丰富的关联信息（connection_id、query_id 等）。

| 优先级（高→低） | 类型 | 说明 |
|---|---|---|
| 1（最优） | `ThreadContext &` | 在表函数或执行上下文中获取，关联线程、连接、查询信息 |
| 2 | `ExecutionContext &` | 在算子执行期间可用 |
| 3 | `ClientContext &` | 连接级别，覆盖大多数查询相关代码 |
| 4 | `FileOpener &` | 文件系统操作相关代码 |
| 5（最后手段） | `DatabaseInstance &` | 全局日志，缺少连接/查询上下文 |

```cpp
// 在有 ClientContext 的代码中（最常见）
void MyFunction(ClientContext &context) {
    DUCKDB_LOG_INFO(context, "Starting operation");
    // ...
}

// 在表函数的执行函数中（使用 ExecutionContext）
static void MyTableFunction(ClientContext &context, TableFunctionInput &data_p, DataChunk &output) {
    auto &exec_context = data_p.local_state->Cast<MyState>().context;
    DUCKDB_LOG_DEBUG(exec_context, "Processing chunk");
}

// 在只有 DatabaseInstance 的地方（如初始化代码）
void DatabaseInit(DatabaseInstance &db) {
    DUCKDB_LOG_INFO(db, "Database initialized");
}
```

### 3.4 使用结构化日志类型

DuckDB 支持通过 `LogType` 子类进行结构化日志记录，SQL 查询时可以按类型解析结构化字段。
使用 `DUCKDB_LOG` 宏配合内置或自定义的 `LogType` 类：

```cpp
#include "duckdb/logging/log_type.hpp"

// 使用内置的 QueryLogType（记录 SQL 查询字符串）
DUCKDB_LOG(context, QueryLogType, query_string);

// 使用内置的 FileSystemLogType
DUCKDB_LOG(opener, FileSystemLogType, file_handle, "READ", bytes_read, offset);
```

内置 `LogType` 类及其默认级别：

| LogType 类 | 类型名称（NAME） | 默认级别 | 说明 |
|---|---|---|---|
| `DefaultLogType` | `""` (空) | `INFO` | 通用日志，使用 `DUCKDB_LOG_*` 宏时默认类型 |
| `QueryLogType` | `"QueryLog"` | `INFO` | 记录执行的 SQL 查询 |
| `FileSystemLogType` | `"FileSystem"` | `TRACE` | 文件系统读写、打开、关闭操作 |
| `HTTPLogType` | `"HTTP"` | `DEBUG` | HTTP 请求和响应 |
| `PhysicalOperatorLogType` | `"PhysicalOperator"` | `DEBUG` | 物理算子执行事件 |
| `MetricsLogType` | `"Metrics"` | `INFO` | 性能指标 |
| `CheckpointLogType` | `"Checkpoint"` | `DEBUG` | Checkpoint/Vacuum 操作 |

### 3.5 底层接口（不推荐直接使用）

如需绕过宏直接使用 Logger：

```cpp
auto &logger = Logger::Get(context);
if (logger.ShouldLog("my_type", LogLevel::LOG_INFO)) {
    logger.WriteLog("my_type", LogLevel::LOG_INFO, "My message");
    // 或格式化版本：
    logger.WriteLog("my_type", LogLevel::LOG_INFO, "Value: %d", my_value);
}
```

---

## 四、运行时配置

### 4.1 通过 SQL SET 配置

```sql
-- 开启日志（默认关闭）
SET enable_logging = true;

-- 设置日志最低级别（TRACE/DEBUG/INFO/WARN/ERROR/FATAL，默认 INFO）
SET logging_level = 'debug';

-- 设置日志模式
-- LEVEL_ONLY（默认）：只按级别过滤
-- ENABLE_SELECTED：只记录指定类型
-- DISABLE_SELECTED：记录除指定类型外的所有日志
SET logging_mode = 'enable_selected';

-- 设置要启用的日志类型（logging_mode=ENABLE_SELECTED 时生效）
SET enabled_log_types = 'QueryLog,FileSystem';

-- 设置要禁用的日志类型（logging_mode=DISABLE_SELECTED 时生效）
SET disabled_log_types = 'FileSystem';

-- 设置日志存储后端（memory/stdout/file，默认 memory）
SET logging_storage = 'memory';
```

### 4.2 通过 CALL 函数配置（推荐）

`enable_logging()` 函数会一步完成配置并启用日志：

```sql
-- 最简单：使用默认配置开启日志（INFO 级别，内存存储）
CALL enable_logging();

-- 开启指定日志类型（自动选择合适的最低级别）
CALL enable_logging('QueryLog');

-- 开启多个日志类型
CALL enable_logging(['QueryLog', 'FileSystem']);

-- 指定日志级别
CALL enable_logging(level := 'DEBUG');

-- 使用文件存储
CALL enable_logging('FileSystem', storage := 'file', storage_config := {'path': '/tmp/duckdb_logs'});

-- 关闭日志（不清除已记录的日志）
CALL disable_logging();

-- 清空日志内容
CALL truncate_duckdb_logs();
```

### 4.3 典型场景

**场景1：开发调试，查看所有 DEBUG 及以上日志**

```sql
CALL enable_logging(level := 'DEBUG');
-- 执行你的操作 ...
SELECT * FROM duckdb_logs ORDER BY timestamp;
```

**场景2：只追踪文件系统 I/O**

```sql
CALL enable_logging('FileSystem');
COPY (SELECT 1) TO '/tmp/test.csv';
SELECT fs, path, op, bytes FROM duckdb_logs_parsed('FileSystem') ORDER BY timestamp;
```

**场景3：追踪执行的 SQL 查询**

```sql
CALL enable_logging('QueryLog');
SELECT 42;
SELECT message FROM duckdb_logs WHERE type = 'QueryLog';
```

---

## 五、查询日志

### 5.1 `duckdb_logs` 表

主日志表，包含所有已记录的日志条目：

```sql
SELECT * FROM duckdb_logs;
```

字段说明：

| 字段 | 类型 | 说明 |
|------|------|------|
| `context_id` | `UBIGINT` | 日志上下文 ID，关联 `duckdb_log_contexts` |
| `scope` | `VARCHAR` | 上下文范围：`DATABASE`/`CONNECTION`/`THREAD` |
| `connection_id` | `UBIGINT` | 连接 ID（CONNECTION 或 THREAD scope 时有值） |
| `transaction_id` | `UBIGINT` | 事务 ID |
| `query_id` | `UBIGINT` | 查询 ID |
| `thread_id` | `UBIGINT` | 线程 ID（THREAD scope 时有值） |
| `timestamp` | `TIMESTAMPTZ` | 日志记录时间 |
| `type` | `VARCHAR` | 日志类型名称（如 `QueryLog`、`FileSystem`，空字符串为默认类型） |
| `log_level` | `VARCHAR` | 日志级别（`TRACE`/`DEBUG`/`INFO`/`WARN`/`ERROR`/`FATAL`） |
| `message` | `VARCHAR` | 日志消息内容（结构化类型为 JSON 字符串） |

### 5.2 `duckdb_log_contexts` 表

```sql
SELECT * FROM duckdb_log_contexts;
```

包含各日志上下文的元数据（scope、connection_id、thread_id 等），通过 `context_id` 与 `duckdb_logs` 关联。

### 5.3 `duckdb_logs_parsed()` 函数

对于结构化日志类型，`duckdb_logs_parsed()` 会将 JSON 消息自动解析为各字段列：

```sql
-- 解析 FileSystem 日志
SELECT type, log_level, scope, fs, path, op, bytes, pos
FROM duckdb_logs_parsed('FileSystem')
ORDER BY timestamp;

-- 解析 QueryLog 日志
SELECT type, log_level, scope, message
FROM duckdb_logs_parsed('QueryLog')
ORDER BY timestamp;

-- 解析 HTTP 日志
SELECT request.type, request.url, response.status
FROM duckdb_logs_parsed('HTTP')
WHERE request.type = 'GET';
```

### 5.4 常用查询示例

```sql
-- 查看所有错误及以上级别的日志
SELECT timestamp, type, log_level, message
FROM duckdb_logs
WHERE log_level IN ('ERROR', 'FATAL')
ORDER BY timestamp;

-- 按类型统计日志数量
SELECT type, log_level, count(*) AS cnt
FROM duckdb_logs
GROUP BY type, log_level
ORDER BY cnt DESC;

-- 查看最近 10 条日志
SELECT * FROM duckdb_logs ORDER BY timestamp DESC LIMIT 10;

-- 从 SQL 写入自定义日志（用于测试或调试）
SELECT write_log('hello world', level := 'info', log_type := 'my_type');
```

---

## 六、日志存储后端

### 6.1 内置后端

| 名称 | `storage` 值 | 说明 |
|------|---|---|
| 内存存储（默认） | `'memory'` | 日志保存在内存的列式存储中，可通过 `duckdb_logs` 查询 |
| 标准输出 | `'stdout'` | 以 CSV 格式输出到 stdout，不支持 `duckdb_logs` 查询 |
| 文件存储 | `'file'` | 写入本地文件，支持规范化（normalized）和非规范化两种模式 |

**切换存储后端会清空已有日志内容。**

文件存储配置示例：

```sql
CALL enable_logging('FileSystem',
    storage := 'file',
    storage_config := {
        'path': '/tmp/duckdb_logs',   -- 存储目录
        'normalize': 'true'           -- 是否规范化（分两个文件存储条目和上下文）
    }
);
```

### 6.2 自定义插件式存储

可以实现 `LogStorage` 接口，注册自定义存储后端（例如用于扩展或测试）：

```cpp
#include "duckdb/logging/log_storage.hpp"

class MyLogStorage : public LogStorage {
public:
    void WriteLogEntry(timestamp_t timestamp, LogLevel level,
                       const string &log_type, const string &log_message,
                       const RegisteredLoggingContext &context) override {
        // 自定义存储逻辑，例如写入外部系统
        my_store.push_back(log_message);
    }

    void WriteLogEntries(DataChunk &chunk, const RegisteredLoggingContext &context) override {}
    void Flush(LoggingTargetTable table) override {}
    void FlushAll() override {}

    bool IsEnabled(LoggingTargetTable table) override {
        return table == LoggingTargetTable::ALL_LOGS;
    }

    const string GetStorageName() override {
        return "my_log_storage";
    }

    vector<string> my_store;
};

// 注册自定义存储
auto my_storage = make_shared_ptr<MyLogStorage>();
duckdb::shared_ptr<LogStorage> base_ptr = my_storage;
db.instance->GetLogManager().RegisterLogStorage("my_log_storage", base_ptr);

// 通过 SQL 切换到自定义存储
// SET logging_storage = 'my_log_storage';
```

---

## 七、从 SQL 写入日志

`write_log()` 标量函数可以直接从 SQL 写入日志，适合测试和调试：

```sql
-- 基本用法（默认级别 INFO，scope 为 connection）
SELECT write_log('my message');

-- 指定级别、scope 和日志类型
SELECT write_log('hello',
    level    := 'warn',
    scope    := 'connection',
    log_type := 'my_type'
);

-- 批量写入（利用向量化执行）
SELECT write_log('message ' || i::VARCHAR, log_type := 'bulk_test')
FROM range(0, 1000) t(i);
```

---

## 八、注意事项

1. **日志默认关闭**：生产环境中日志默认不启用（`enable_logging = false`）。在代码中调用宏是安全的——`ShouldLog()` 会快速返回 false，几乎没有性能开销。

2. **优先使用细粒度上下文**：`ThreadContext > ExecutionContext > ClientContext > FileOpener > DatabaseInstance`，细粒度上下文能提供更多关联信息。

3. **默认日志级别为 INFO**：`DUCKDB_LOG_TRACE` 和 `DUCKDB_LOG_DEBUG` 在默认配置下不会被记录，除非显式将 `logging_level` 设置为更低级别。

4. **切换存储后端会清空日志**：切换 `logging_storage` 会丢失已有的内存中日志。

5. **`FileSystem` 类型默认级别为 TRACE**：如需记录文件系统操作，需将 `logging_level` 设置为 `TRACE` 或使用 `CALL enable_logging('FileSystem')` 自动设置。
