# DuckDB 日志系统开发者文档

> 适用源码：`v2.0-cyanoptera` @ `c1cd2470a455`；核对日期：2026-10-23。核对方式：静态源码审查，未执行本文示例或性能测试。

本文覆盖日志写入、配置、存储与查询。SQL 示例按当前注册接口核对；C++ 骨架仅说明接入位置，未独立编译。

## 一、总体架构与默认配置

```text
DatabaseInstance
  └─ LogManager：配置、已注册类型/存储、当前 storage、全局 logger
       ├─ LogConfig
       ├─ LogStorage
       │    ├─ InMemoryLogStorage
       │    ├─ CSVLogStorage → StdOutLogStorage / FileLogStorage
       │    └─ 扩展注册的实现
       └─ Logger：由具体上下文获取
            ├─ MutableLogger
            ├─ ThreadSafeLogger
            └─ NopLogger
```

依据：[log_manager.cpp](../src/logging/log_manager.cpp) 的 `Initialize`、`CreateLogger` 和 [logger.hpp](../src/include/duckdb/logging/logger.hpp)。`CreateLogger` 优先处理 `mutable_settings`；否则日志未启用时返回 `NopLogger`，其余当前返回 `ThreadSafeLogger`。`ThreadLocalLogger` 虽已声明，其 `ShouldLog` / `WriteLogInternal` 仍抛未实现异常，工厂没有启用它，不能将其当作可用的线程本地缓冲优化。

[logging.cpp](../src/logging/logging.cpp) 中 `LogConfig` 的构造默认值为关闭日志、`LEVEL_ONLY`、`INFO`、`memory`。但当前 [shell.cpp](../tools/shell/shell.cpp) 的 `RegisterShellLogger` 会启用日志、选择 `shell_log_storage` 并设置 `WARNING`。因此 CLI 会话不能直接套用库的原始默认值。

| 主要源码 | 核对入口 |
|---|---|
| [logging.hpp](../src/include/duckdb/logging/logging.hpp) | 级别、模式、配置、上下文 |
| [logger.hpp](../src/include/duckdb/logging/logger.hpp) / [logger.cpp](../src/logging/logger.cpp) | 宏、上下文选择与各类 logger |
| [log_type.hpp](../src/include/duckdb/logging/log_type.hpp) / [log_types.cpp](../src/logging/log_types.cpp) | 类型名、级别、结构化 schema、消息构造 |
| [log_manager.cpp](../src/logging/log_manager.cpp) | 注册、过滤配置与后端切换 |
| [log_storage.hpp](../src/include/duckdb/logging/log_storage.hpp) / [log_storage.cpp](../src/logging/log_storage.cpp) | 写入、缓冲、扫描及文件路径处理 |
| [logging_utils.cpp](../src/function/table/system/logging_utils.cpp) | enable/disable/truncate 表函数 |
| [duckdb_log.cpp](../src/function/table/system/duckdb_log.cpp) | 日志扫描及上下文 join 替换 |
| [write_log.cpp](../src/function/scalar/system/write_log.cpp) | SQL 日志写入、scope 与返回值 |

## 二、级别、过滤与写入语义

当前枚举依次为 `LOG_TRACE=10`、`LOG_DEBUG=20`、`LOG_INFO=30`、`LOG_WARNING=40`、`LOG_ERROR=50`、`LOG_FATAL=60`。SQL 字符串和输出使用 `TRACE / DEBUG / INFO / WARNING / ERROR / FATAL`；当前名称是 **WARNING**，不是旧文档的 WARN。对应宏也为 `DUCKDB_LOG_WARNING`。

`ShouldLog` 先检查是否启用和最低级别，再按 `LogMode` 决定类型过滤：

| 模式 | 类型条件 |
|---|---|
| `LEVEL_ONLY` | 不额外筛选类型 |
| `ENABLE_SELECTED` | 类型名必须在 `enabled_log_types` 中 |
| `DISABLE_SELECTED` | 类型名不能在 `disabled_log_types` 中 |

`ThreadSafeLogger` 保存配置快照；`MutableLogger` 用原子字段快速筛选，选择类型时还需要锁。不要假定所有既有 logger 都会实时接收每次配置修改。全局 logger 的更新路径见 `LogManager::SetConfigInternal` 等 setter。

宏把格式化和消息构造放在 `ShouldLog` 分支中，可避免未选中日志的这部分工作，但仍有获取 logger 和过滤检查的开销；本轮没有测量开销。

## 三、在 C++ 中写日志

### 3.1 通用宏

```cpp
#include "duckdb/logging/logger.hpp"

// 接入骨架：context 为已有 ClientContext，operation_name 为调用方提供的字符串。
DUCKDB_LOG_INFO(context, "Starting operation %s", operation_name);
DUCKDB_LOG_WARNING(context, "Deprecated option %s", option_name);
```

可用宏为 `DUCKDB_LOG_TRACE/DEBUG/INFO/WARNING/ERROR/FATAL`。格式化重载使用 `StringUtil::Format`；通用类型名 `DefaultLogType::NAME` 是空字符串。

`Logger::Get` 按头文件建议的优先顺序提供以下来源，优先采用调用点真实拥有的细粒度上下文：

| 来源 | 关联方式 |
|---|---|
| `ThreadContext` | 使用其 logger，保留线程执行上下文 |
| `ExecutionContext` | 取得 `execution_context.thread.logger` |
| `ClientContext` | 调用 `GetLogger()` |
| `FileOpener` | 调用 opener 的 `GetLogger()` |
| `DatabaseInstance` | 使用 LogManager 的全局 logger |
| `shared_ptr<Logger>` | 直接取得其对象 |

普通 table-function 的 `function(ClientContext &, TableFunctionInput &, DataChunk &)` 没有额外的 `ExecutionContext` 参数。不能假定任意 `LocalTableFunctionState` 都有 `.context` 字段；有 `ClientContext` 时可直接以它作为 SOURCE。

### 3.2 结构化日志

```cpp
#include "duckdb/logging/log_type.hpp"

// 接入骨架：变量由真实调用点提供。
DUCKDB_LOG(context, QueryLogType, query_string);
DUCKDB_LOG(opener, FileSystemLogType, file_handle, "READ", bytes_read, offset);
```

`DUCKDB_LOG` 采用类型的 `NAME`、`LEVEL` 和 `ConstructLogMessage`。`QueryLogType` 返回原 SQL 文本；FileSystem、HTTP 等类型有结构化 schema。不能将所有消息都称为 JSON。

当前 `LogManager::RegisterDefaultLogTypes` 注册的类型如下：

| 类型名 | 类 | 级别 |
|---|---|---|
| 空字符串 | `DefaultLogType` | INFO |
| `QueryLog` | `QueryLogType` | INFO |
| `FileSystem` | `FileSystemLogType` | TRACE |
| `HTTP` | `HTTPLogType` | DEBUG |
| `PhysicalOperator` | `PhysicalOperatorLogType` | DEBUG |
| `Metrics` | `MetricsLogType` | INFO |
| `AdaptiveFilter` | `AdaptiveFilterLogType` | DEBUG |
| `ParquetPrefetch` | `ParquetPrefetchLogType` | DEBUG |
| `AsyncTaskSchedule` | `AsyncTaskScheduleLogType` | DEBUG |
| `ExternalResource` | `ExternalResourceLogType` | INFO |
| `ProgressVerification` | `ProgressVerificationLogType` | INFO |

`CheckpointLogType` 和 `TransactionLogType` 也有声明/实现，但不在上述默认注册清单中。仅看到类定义不能保证 `CALL enable_logging('Checkpoint')` 或某个扩展类型在当前会话可用。`BindEnableLogging` 会尝试按类型自动加载对应扩展，再检查类型是否已注册。

### 3.3 直接接口与异常边界

```cpp
// 接入骨架：直接写入时由调用方负责 ShouldLog 检查。
auto &logger = Logger::Get(context);
if (logger.ShouldLog("my_type", LogLevel::LOG_INFO)) {
    logger.WriteLog("my_type", LogLevel::LOG_INFO, "message");
}
```

`Logger::WriteLog` 本身不补做上述筛选。`LogManager::WriteLogEntry` 在 `warnings_as_errors` 启用时将 WARNING 转为异常，因此写日志不是无条件无异常的操作。存储写入也可能失败；`FATAL` 是日志级别，日志宏本身不等于终止进程。

## 四、运行时配置

以下示例均未运行。日志设置通过数据库的 LogManager 生效，勿将其当作仅影响一个查询的局部调试开关。

### 4.1 使用 SET

```sql
SET logging_storage = 'memory';
SET enable_logging = true;
SET logging_level = 'DEBUG';
SET logging_mode = 'LEVEL_ONLY';

-- 手动选择类型时，还要配置模式与合适的最低级别
SET enabled_log_types = 'QueryLog,FileSystem';
SET logging_mode = 'ENABLE_SELECTED';
SET logging_level = 'TRACE';
```

`enabled_log_types` / `disabled_log_types` setter 按逗号拆分字符串并更新集合，不会自动选择模式或修改级别；类型名筛选是具体字符串集合查找。`CALL enable_logging` 额外提供注册检查与配置组合。

### 4.2 使用 CALL

```sql
-- 无类型参数：LEVEL_ONLY；显式选择可查询后端，避免沿用 CLI 的 shell 后端
CALL enable_logging(level := 'DEBUG', storage := 'memory');

-- 选择已注册结构化类型，自动采用所选类型最低的级别
CALL enable_logging(['QueryLog', 'FileSystem'], storage := 'memory');

-- .csv 路径默认使用非规范化单文件；目录路径默认使用规范化双文件
CALL enable_logging('FileSystem', storage_path := '/tmp/duckdb_logs.csv');

CALL disable_logging();
CALL truncate_duckdb_logs();
```

`BindEnableLogging` 接受0或1个位置参数（字符串或字符串列表），以及 `level`、`storage`、`storage_config`、`storage_path`、`storage_normalize`、`storage_buffer_size`。后三项会转入 storage config。

- 未指定 storage 时，提供 path 隐含选择 file；否则保留当前后端。因此无参数 `enable_logging()` 在 CLI 中不保证切换到 memory。
- 指定类型列表时，`SetEnableStructuredLoggers` 将模式设为 `ENABLE_SELECTED`，并用类型声明的最低级别覆盖最终 level；不要假定同时传入的 level 始终优先。
- 首次切换 file 必须有非 NULL、非空 path。`SET logging_storage='file'` 无法提供路径，首次切换会被拒绝，应使用 CALL。
- 执行阶段应用配置失败时尝试恢复先前 LogConfig；这不构成对外部文件写入及所有后端内部状态的事务性回滚保证。
- `disable_logging()` 只关闭 enable 标志，不自动清除已有日志；truncate 调用当前后端的 `Truncate`，自定义后端可能不支持。

## 五、存储与生命周期

| 后端 | 实现及查询能力 |
|---|---|
| `memory` | 规范化的 entry/context 列式集合；实现扫描接口 |
| `stdout` | CSV 输出到标准输出，当前不提供日志扫描接口 |
| `file` | CSV 文件；通过 `BindReplace` 转换为 `read_csv_auto` 查询 |
| `shell_log_storage` 等 | 调用方注册的实现，能力由该实现决定 |

`BufferingLogStorage` 管理 entry/context 或合并表的缓冲；CSV 子类处理转换、writer 与配置。线程安全不能由“日志在某线程发出”推导，应检查 LogManager/后端的锁和对象共享方式。

`FileLogStorage::SetPaths/UpdateConfigInternal` 的路径规则：

- 规范化模式在目录下写 `duckdb_log_entries.csv` 与 `duckdb_log_contexts.csv`。
- `.csv` 路径在未显式指定 normalize 时隐含 `false`；显式 `normalize=true` 配合 `.csv` 路径会报错。
- 非规范化示例使用显式 `.csv` 单文件路径。当前 `SetPaths` 对非 `.csv` 路径只设置 LOG_ENTRIES 路径，而非规范化 flush 使用 ALL_LOGS；后者路径仍为空，`Initialize` 对空路径有异常检查。这是静态发现的分支不一致，未运行复现，本文不把“目录路径 + normalize=false”作为可用用法，也未修改源码。

```sql
CALL enable_logging('FileSystem', storage := 'file',
    storage_config := {'path': '/tmp/duckdb_logs', 'normalize': true});
```

`SetLogStorageInternal` 对相同名称直接返回；真正切换时先 flush 旧后端，再替换当前对象。旧日志不会自动迁移到新后端，新的默认 memory 对象也不包含旧对象的数据；不能把这概括成“任何切换都清空所有已记录日志”。查询后端能力与数据保留应分别判断。

## 六、查询与解析日志

### 6.1 原始函数和默认视图

[duckdb_log.cpp](../src/function/table/system/duckdb_log.cpp) 的 `DuckDBLogBind` 定义基础函数 `duckdb_logs()` 的五列：`context_id`、`timestamp`、`type`、`log_level`、`message`。

[default_views.cpp](../src/catalog/default/default_views.cpp) 定义同名视图 `duckdb_logs`，实际调用 `duckdb_logs(denormalized_table=true)`。这时通过后端替换或 entry/context join 增加 `scope`、`connection_id`、`transaction_id`、`query_id`、`thread_id`。这些 ID 使用可选上下文，不能根据 scope 假定全部有值。

```sql
-- 使用当前可查询后端，带上下文
SELECT timestamp, scope, query_id, type, log_level, message
FROM duckdb_logs ORDER BY timestamp;

-- 原始 entry 表与上下文表是不同接口
SELECT * FROM duckdb_logs();
SELECT * FROM duckdb_log_contexts();
```

memory 使用扫描接口；file 可通过 `BindReplace` 读取 CSV。stdout 等不可查询后端会报能力错误，不会自动回读终端输出。

### 6.2 结构化解析

[default_table_functions.cpp](../src/catalog/default/default_table_functions.cpp) 中 `duckdb_logs_parsed(log_type)` 是 SQL table macro：按类型筛选，调用 `parse_duckdb_log_message`，排除原 message 后展开解析结果。

```sql
SELECT type, log_level, fs, path, op, bytes, pos
FROM duckdb_logs_parsed('FileSystem') ORDER BY timestamp;

SELECT request.type, request.url, response.status
FROM duckdb_logs_parsed('HTTP');

-- QueryLog 保存原 SQL 文本，直接读取 message
SELECT message FROM duckdb_logs WHERE type = 'QueryLog';
```

FileSystem 的 `bytes/pos` 只在相应消息形态中提供。HTTP schema 还包含请求起始时间、duration_ms、请求长度与请求/响应 headers；具体字段能否取得取决于消息构造时的信息。日志存在不代表某次 I/O 必须走过特定协议。

HTTP 消息构造还受 `redact_http_logs` 控制，当前设置默认 true。`CreateHTTPHeadersValue` 只保留请求/响应各自允许列表中的 header 值；`BuildLogURL` 替换 URL 的用户信息及 query/fragment 内容。关闭该设置会走保留原始值的分支。依据：[log_types.cpp](../src/logging/log_types.cpp) 和 [settings.json](../src/common/settings.json)。这描述的是该消息构造路径的处理范围，不是任意日志类型的通用脱敏保证。

### 6.3 从 SQL 写日志

```sql
CALL enable_logging(level := 'INFO', storage := 'memory');
SELECT write_log('hello world', level := 'WARNING', log_type := 'my_type');
SELECT write_log('message ' || i::VARCHAR, log_type := 'bulk_test')
FROM range(10) t(i);
```

`write_log` 默认 INFO、connection scope；支持 connection、database、file_opener 三种 scope，未知 scope 在执行写入时抛错。配置参数由 bind 阶段读取常量。

默认返回 NULL（默认返回类型 VARCHAR）；指定 `return_value` 时引用对应参数作为结果。`disable_logging` 只控制该调用的写入。普通自定义 `log_type` 字符串写入和注册一个具有解析 schema 的 `LogType` 是两件事。

## 七、自定义存储接入

`LogStorage` 的必要写入接口包括 `GetStorageName`、`WriteLogEntry`、`WriteLogEntries`、`FlushAll`、`Flush`、`IsEnabled`。读取接口是可选的：实现 `CanScan/CreateScanState/InitializeScan/Scan`，或提供 `BindReplace`。只实现写入并不自动支持 `duckdb_logs` 查询。

注册接入骨架（存储实现省略，未编译）：

```cpp
// db 为 DatabaseInstance&，my_storage 为实现了必要虚接口的对象。
shared_ptr<LogStorage> storage = my_storage;
bool registered = db.GetLogManager().RegisterLogStorage("my_log_storage", storage);
// 注册成功后再由调用方选择该后端；实现自行处理共享、缓冲和 flush。
```

`RegisterLogStorage` 对已存在名称返回 false，并把成功注册的 shared_ptr 移入注册表；`RegisterLogType` 对重复名称抛异常。二者都不能按“同名注册自动覆盖”理解。查询与 truncate 能力、配置验证及外部系统失败策略需要由实现明确提供。

## 八、核对边界

本轮未执行 SQL、写日志文件或验证并发/崩溃行为。日志采集的性能、外部存储持久性和日志丢失边界需要单独运行验证；本文只陈述冻结源码的调用和分支行为。
