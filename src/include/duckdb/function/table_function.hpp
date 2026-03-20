//===----------------------------------------------------------------------===//
//                         DuckDB
//
// duckdb/function/table_function.hpp
//
//
//===----------------------------------------------------------------------===//

// TableFunction Interface Overview
// =================================
// A TableFunction is a function that produces a set of rows (a relation) and can be
// used in the FROM clause of a query.  Examples include read_csv(), read_parquet(),
// range(), and user-defined table functions (UDTFs).
//
// Execution Lifecycle
// -------------------
// 1. BIND phase  (planning time, single-threaded)
//    bind / bind_replace / bind_operator
//    - Inspects the user-supplied arguments, validates them, and decides the
//      output schema (column names + types).
//    - Returns a FunctionData object ("bind data") that is immutable for the
//      rest of query execution and shared across all threads.
//
// 2. GLOBAL INIT phase  (just before execution starts, single-threaded)
//    init_global
//    - Allocates a GlobalTableFunctionState that is shared by every thread
//      participating in the scan.
//    - MaxThreads() on the returned state controls the degree of parallelism.
//      Return GlobalTableFunctionState::MAX_THREADS to use all available threads.
//
// 3. LOCAL INIT phase  (once per worker thread)
//    init_local
//    - Allocates a LocalTableFunctionState for each thread.
//    - Typical use: assign a chunk of work (e.g., a file or row-group range)
//      from the global state to this local state.
//
// 4. SCAN phase  (hot loop, called repeatedly per thread until exhausted)
//    function  (for source-only table functions)
//    in_out_function / in_out_function_final  (for in-out table functions)
//    - Fills the provided DataChunk with up to STANDARD_VECTOR_SIZE rows.
//    - Return an empty chunk (output.SetCardinality(0)) to signal EOF on the
//      local thread.
//
// Extension Guidelines
// --------------------
// * bind data (FunctionData) MUST be treated as read-only after bind returns.
//   Use GlobalTableFunctionState for mutable, shared runtime data.
// * GlobalTableFunctionState access MUST be synchronized (use a mutex) whenever
//   threads compete for work items.
// * LocalTableFunctionState is thread-local – no locking needed there.
// * Enable projection_pushdown / filter_pushdown / filter_prune flags only when
//   the implementation actually honours the pushed-down column list / filters;
//   incorrect flags produce wrong results or unnecessary data movement.
// * Implement cardinality() whenever possible – the optimizer uses it for join
//   ordering and memory budget decisions.
// * serialize / deserialize must be provided together if you want prepared
//   statements or query caching to work correctly across process restarts.

#pragma once

#include "duckdb/common/enums/operator_result_type.hpp"
#include "duckdb/common/optional_ptr.hpp"
#include "duckdb/execution/execution_context.hpp"
#include "duckdb/function/function.hpp"
#include "duckdb/planner/logical_operator.hpp"
#include "duckdb/storage/statistics/node_statistics.hpp"
#include "duckdb/common/column_index.hpp"
#include "duckdb/common/table_column.hpp"
#include "duckdb/function/partition_stats.hpp"
#include "duckdb/common/exception/binder_exception.hpp"

#include <functional>

namespace duckdb {

class BaseStatistics;
class LogicalDependencyList;
class LogicalGet;
class TableFunction;
class TableFilterSet;
class TableFunctionRef;
class TableCatalogEntry;
class SampleOptions;
struct MultiFileReader;
struct OperatorPartitionData;
struct OperatorPartitionInfo;

// ---------------------------------------------------------------------------
// TableFunctionInfo
// ---------------------------------------------------------------------------
// Optional static metadata that is attached to a TableFunction at registration
// time and passed through to the bind callback via TableFunctionBindInput::info.
// Use this to carry configuration that is fixed for the lifetime of the
// function registration (e.g., a schema hint, a file-format flavor, or a
// plugin-specific context).
//
// Extension note: Subclass this and store it in TableFunction::function_info.
// The object is shared across all bind invocations, so it must be immutable
// (or internally synchronized) once the function is registered.
struct TableFunctionInfo {
	DUCKDB_API virtual ~TableFunctionInfo();

	template <class TARGET>
	TARGET &Cast() {
		DynamicCastCheck<TARGET>(this);
		return reinterpret_cast<TARGET &>(*this);
	}
	template <class TARGET>
	const TARGET &Cast() const {
		DynamicCastCheck<TARGET>(this);
		return reinterpret_cast<const TARGET &>(*this);
	}
};

// ---------------------------------------------------------------------------
// GlobalTableFunctionState
// ---------------------------------------------------------------------------
// Shared state allocated once per query execution of the table function.
// Created by init_global (single-threaded) and then read/modified by all
// worker threads during the scan phase.
//
// Key responsibilities:
//  - Track which "work units" (files, row-groups, partitions, …) still need
//    to be scanned.
//  - Report how many threads should participate via MaxThreads().
//
// Extension note:
//  - Protect any mutable fields with a mutex; they are accessed concurrently.
//  - MaxThreads() is queried once, so it must reflect the total parallelism
//    available at init time.  Return MAX_THREADS to use all executor threads.
struct GlobalTableFunctionState {
public:
	// value returned from MaxThreads when as many threads as possible should be used
	constexpr static const int64_t MAX_THREADS = 999999999;

public:
	DUCKDB_API virtual ~GlobalTableFunctionState();

	virtual idx_t MaxThreads() const {
		return 1;
	}

	template <class TARGET>
	TARGET &Cast() {
		DynamicCastCheck<TARGET>(this);
		return reinterpret_cast<TARGET &>(*this);
	}
	template <class TARGET>
	const TARGET &Cast() const {
		DynamicCastCheck<TARGET>(this);
		return reinterpret_cast<const TARGET &>(*this);
	}
};

// ---------------------------------------------------------------------------
// LocalTableFunctionState
// ---------------------------------------------------------------------------
// Per-thread state allocated by init_local for each worker thread.
// Holds the cursor/buffer/state for the slice of work assigned to this thread
// (e.g., the current file handle, row-group iterator, etc.).
//
// Extension note:
//  - This state is never accessed from another thread, so no locking is needed.
//  - init_local should "claim" work from GlobalTableFunctionState (under a lock)
//    and record it here.
struct LocalTableFunctionState {
	DUCKDB_API virtual ~LocalTableFunctionState();

	template <class TARGET>
	TARGET &Cast() {
		DynamicCastCheck<TARGET>(this);
		return reinterpret_cast<TARGET &>(*this);
	}
	template <class TARGET>
	const TARGET &Cast() const {
		DynamicCastCheck<TARGET>(this);
		return reinterpret_cast<const TARGET &>(*this);
	}
};

// ---------------------------------------------------------------------------
// TableFunctionBindInput
// ---------------------------------------------------------------------------
// Passed to the bind / bind_replace / bind_operator callbacks.
// Carries everything needed to validate arguments and decide the output schema.
//
// Fields:
//  inputs              - positional argument values (may contain NULLs for
//                        optional arguments the user omitted).
//  named_parameters    - keyword arguments supplied by the caller.
//  input_table_types   - column types of the input relation (in-out functions).
//  input_table_names   - column names of the input relation (in-out functions).
//  info                - optional static metadata registered with the function.
//  binder              - the active Binder, available for resolving catalog
//                        entries or running sub-binds.
//  table_function      - the TableFunction object being bound (read-only).
//  ref                 - the original TableFunctionRef from the parser.
struct TableFunctionBindInput {
	TableFunctionBindInput(vector<Value> &inputs, named_parameter_map_t &named_parameters,
	                       vector<LogicalType> &input_table_types, vector<string> &input_table_names,
	                       optional_ptr<TableFunctionInfo> info, optional_ptr<Binder> binder,
	                       TableFunction &table_function, const TableFunctionRef &ref)
	    : inputs(inputs), named_parameters(named_parameters), input_table_types(input_table_types),
	      input_table_names(input_table_names), info(info), binder(binder), table_function(table_function), ref(ref) {
	}

	vector<Value> &inputs;
	named_parameter_map_t &named_parameters;
	vector<LogicalType> &input_table_types;
	vector<string> &input_table_names;
	optional_ptr<TableFunctionInfo> info;
	optional_ptr<Binder> binder;
	TableFunction &table_function;
	const TableFunctionRef &ref;
};

// ---------------------------------------------------------------------------
// TableFunctionInitInput
// ---------------------------------------------------------------------------
// Passed to init_global and init_local.
// Conveys which columns and filters the rest of the plan actually requires so
// the function can avoid reading unnecessary data.
//
// Fields:
//  bind_data       - the immutable object returned by bind.
//  column_ids      - flat list of column indices to materialise (primary index
//                    of each ColumnIndex, for backward compatibility).
//  column_indexes  - richer per-column descriptor including sub-column paths
//                    (used by nested formats such as Parquet).
//  projection_ids  - subset of column_ids that must actually *leave* the scan
//                    operator; the remainder are only needed for filter evaluation
//                    and can be dropped with filter_prune = true.
//  filters         - pushed-down filter predicates (only set when
//                    filter_pushdown = true on the TableFunction).
//  sample_options  - requested sampling parameters (only set when
//                    sampling_pushdown = true).
//  op              - the physical operator node, available for advanced
//                    introspection (rarely needed).
//
// Extension note:
//  - Call CanRemoveFilterColumns() to test whether filter columns can be
//    dropped before emitting results (requires filter_prune = true).
struct TableFunctionInitInput {
	TableFunctionInitInput(optional_ptr<const FunctionData> bind_data_p, vector<column_t> column_ids_p,
	                       const vector<idx_t> &projection_ids_p, optional_ptr<TableFilterSet> filters_p,
	                       optional_ptr<SampleOptions> sample_options_p = nullptr,
	                       optional_ptr<const PhysicalOperator> op_p = nullptr)
	    : bind_data(bind_data_p), column_ids(std::move(column_ids_p)), projection_ids(projection_ids_p),
	      filters(filters_p), sample_options(sample_options_p), op(op_p) {
		for (auto &col_id : column_ids) {
			column_indexes.emplace_back(col_id);
		}
	}

	TableFunctionInitInput(optional_ptr<const FunctionData> bind_data_p, vector<ColumnIndex> column_indexes_p,
	                       const vector<idx_t> &projection_ids_p, optional_ptr<TableFilterSet> filters_p,
	                       optional_ptr<SampleOptions> sample_options_p = nullptr,
	                       optional_ptr<const PhysicalOperator> op_p = nullptr)
	    : bind_data(bind_data_p), column_indexes(std::move(column_indexes_p)), projection_ids(projection_ids_p),
	      filters(filters_p), sample_options(sample_options_p), op(op_p) {
		for (auto &col_id : column_indexes) {
			column_ids.emplace_back(col_id.GetPrimaryIndex());
		}
	}

	optional_ptr<const FunctionData> bind_data;
	vector<column_t> column_ids;
	vector<ColumnIndex> column_indexes;
	const vector<idx_t> projection_ids;
	optional_ptr<TableFilterSet> filters;
	optional_ptr<SampleOptions> sample_options;
	optional_ptr<const PhysicalOperator> op;

	bool CanRemoveFilterColumns() const {
		if (projection_ids.empty()) {
			// No filter columns to remove.
			return false;
		}
		if (projection_ids.size() == column_ids.size()) {
			// Filter column is used in remainder of plan, so we cannot remove it.
			return false;
		}
		// Fewer columns need to be projected out than that we scan.
		return true;
	}
};

// ---------------------------------------------------------------------------
// TableFunctionInput
// ---------------------------------------------------------------------------
// Passed to the main scan callback (function / in_out_function).
// Provides read-only access to bind data and mutable access to local and
// global states so the scan loop can advance its cursor.
struct TableFunctionInput {
public:
	TableFunctionInput(optional_ptr<const FunctionData> bind_data_p,
	                   optional_ptr<LocalTableFunctionState> local_state_p,
	                   optional_ptr<GlobalTableFunctionState> global_state_p)
	    : bind_data(bind_data_p), local_state(local_state_p), global_state(global_state_p) {
	}

public:
	optional_ptr<const FunctionData> bind_data;
	optional_ptr<LocalTableFunctionState> local_state;
	optional_ptr<GlobalTableFunctionState> global_state;
};

struct TableFunctionPartitionInput {
	TableFunctionPartitionInput(optional_ptr<const FunctionData> bind_data_p, const vector<column_t> &partition_ids)
	    : bind_data(bind_data_p), partition_ids(partition_ids) {
	}

	optional_ptr<const FunctionData> bind_data;
	const vector<column_t> &partition_ids;
};

struct TableFunctionToStringInput {
	TableFunctionToStringInput(const TableFunction &table_function_p, optional_ptr<const FunctionData> bind_data_p)
	    : table_function(table_function_p), bind_data(bind_data_p) {
	}
	const TableFunction &table_function;
	optional_ptr<const FunctionData> bind_data;
};

struct TableFunctionDynamicToStringInput {
	TableFunctionDynamicToStringInput(const TableFunction &table_function_p,
	                                  optional_ptr<const FunctionData> bind_data_p,
	                                  optional_ptr<LocalTableFunctionState> local_state_p,
	                                  optional_ptr<GlobalTableFunctionState> global_state_p)
	    : table_function(table_function_p), bind_data(bind_data_p), local_state(local_state_p),
	      global_state(global_state_p) {
	}
	const TableFunction &table_function;
	optional_ptr<const FunctionData> bind_data;
	optional_ptr<LocalTableFunctionState> local_state;
	optional_ptr<GlobalTableFunctionState> global_state;
};

struct TableFunctionGetPartitionInput {
public:
	TableFunctionGetPartitionInput(optional_ptr<const FunctionData> bind_data_p,
	                               optional_ptr<LocalTableFunctionState> local_state_p,
	                               optional_ptr<GlobalTableFunctionState> global_state_p,
	                               const OperatorPartitionInfo &partition_info_p)
	    : bind_data(bind_data_p), local_state(local_state_p), global_state(global_state_p),
	      partition_info(partition_info_p) {
	}

public:
	optional_ptr<const FunctionData> bind_data;
	optional_ptr<LocalTableFunctionState> local_state;
	optional_ptr<GlobalTableFunctionState> global_state;
	const OperatorPartitionInfo &partition_info;
};

struct GetPartitionStatsInput {
	GetPartitionStatsInput(const TableFunction &table_function_p, optional_ptr<const FunctionData> bind_data_p)
	    : table_function(table_function_p), bind_data(bind_data_p) {
	}

	const TableFunction &table_function;
	optional_ptr<const FunctionData> bind_data;
};

enum class ScanType : uint8_t { TABLE, PARQUET, EXTERNAL };

struct BindInfo {
public:
	explicit BindInfo(ScanType type_p) : type(type_p) {};
	explicit BindInfo(TableCatalogEntry &table) : type(ScanType::TABLE), table(&table) {};

	unordered_map<string, Value> options;
	ScanType type;
	optional_ptr<TableCatalogEntry> table;

	void InsertOption(const string &name, Value value) { // NOLINT: work-around bug in clang-tidy
		if (options.find(name) != options.end()) {
			throw InternalException("This option already exists");
		}
		options.emplace(name, std::move(value));
	}
	template <class T>
	T GetOption(const string &name) {
		if (options.find(name) == options.end()) {
			throw InternalException("This option does not exist");
		}
		return options[name].GetValue<T>();
	}
	template <class T>
	vector<T> GetOptionList(const string &name) {
		if (options.find(name) == options.end()) {
			throw InternalException("This option does not exist");
		}
		auto option = options[name];
		if (option.type().id() != LogicalTypeId::LIST) {
			throw InternalException("This option is not a list");
		}
		vector<T> result;
		auto list_children = ListValue::GetChildren(option);
		for (auto &child : list_children) {
			result.emplace_back(child.GetValue<T>());
		}
		return result;
	}
};

// ---------------------------------------------------------------------------
// Function pointer type aliases
// ---------------------------------------------------------------------------

//! bind: validate arguments, populate return_types / names, return bind data.
//! Called once per query at planning time on a single thread.
//! The returned FunctionData MUST be treated as immutable during execution.
typedef unique_ptr<FunctionData> (*table_function_bind_t)(ClientContext &context, TableFunctionBindInput &input,
                                                          vector<LogicalType> &return_types, vector<string> &names);

//! bind_replace: higher-priority alternative to bind.
//! Return a TableRef (e.g. a SubqueryRef) to replace the entire LogicalGet,
//! or return nullptr to fall back to the regular bind path.
//! Use this when the function can be completely rewritten to a sub-query.
typedef unique_ptr<TableRef> (*table_function_bind_replace_t)(ClientContext &context, TableFunctionBindInput &input);

//! bind_operator: like bind_replace, but returns a raw LogicalOperator.
//! Gives full control over the logical plan node that replaces the LogicalGet.
typedef unique_ptr<LogicalOperator> (*table_function_bind_operator_t)(ClientContext &context,
                                                                      TableFunctionBindInput &input, idx_t bind_index,
                                                                      vector<string> &return_names);

//! init_global: allocate shared, query-wide state before scan threads start.
//! Called once, single-threaded.  The returned object must be safe to read
//! from multiple threads; protect mutable fields with a mutex.
typedef unique_ptr<GlobalTableFunctionState> (*table_function_init_global_t)(ClientContext &context,
                                                                             TableFunctionInitInput &input);

//! init_local: allocate per-thread state for each worker.
//! Called once per thread.  Should claim a work unit from global_state under
//! a lock and store it in the returned LocalTableFunctionState.
typedef unique_ptr<LocalTableFunctionState> (*table_function_init_local_t)(ExecutionContext &context,
                                                                           TableFunctionInitInput &input,
                                                                           GlobalTableFunctionState *global_state);

//! statistics: return column statistics derived from the bind data.
//! Used by the optimizer for better cardinality / filter selectivity estimates.
typedef unique_ptr<BaseStatistics> (*table_statistics_t)(ClientContext &context, const FunctionData *bind_data,
                                                         column_t column_index);

//! function: the core scan callback; fill output with up to STANDARD_VECTOR_SIZE rows.
//! Called repeatedly per thread until EOF.  Signal EOF by leaving output empty
//! (output.SetCardinality(0)).  Must be thread-safe with respect to global state.
typedef void (*table_function_t)(ClientContext &context, TableFunctionInput &data, DataChunk &output);

//! in_out_function: scan callback for in-out (pipeline-breaker) table functions.
//! Receives an input chunk and should produce rows into output.
//! Return HAVE_MORE_OUTPUT if more output can be produced for the same input,
//! NEED_MORE_INPUT otherwise.
typedef OperatorResultType (*table_in_out_function_t)(ExecutionContext &context, TableFunctionInput &data,
                                                      DataChunk &input, DataChunk &output);

//! in_out_function_final: called after all input has been consumed.
//! Flush any buffered state into output.  Return FINISHED when done.
typedef OperatorFinalizeResultType (*table_in_out_function_final_t)(ExecutionContext &context, TableFunctionInput &data,
                                                                    DataChunk &output);

//! get_partition_data: return the partition data (e.g. sort key column values)
//! for the current position of a local scan thread.  Used by the partitioned
//! pipeline infrastructure to route rows to the correct partition.
typedef OperatorPartitionData (*table_function_get_partition_data_t)(ClientContext &context,
                                                                     TableFunctionGetPartitionInput &input);

//! get_bind_info: return a BindInfo descriptor summarising the scan options.
//! Used by EXPLAIN and optimizer rules that need to inspect scan metadata.
typedef BindInfo (*table_function_get_bind_info_t)(const optional_ptr<FunctionData> bind_data);

//! get_multi_file_reader: inject a custom MultiFileReader implementation.
//! If set, DuckDB calls this instead of constructing its default MultiFileReader.
typedef unique_ptr<MultiFileReader> (*table_function_get_multi_file_reader_t)(const TableFunction &);

//! supports_pushdown_type: fine-grained control over which column types
//! accept filter pushdown.  Return true iff the scanner can apply a filter
//! on the column at col_idx without a post-scan filter operator.
//! Only consulted when filter_pushdown = true.
typedef bool (*table_function_supports_pushdown_type_t)(const FunctionData &bind_data, idx_t col_idx);

//! table_scan_progress: return a value in [0, 100] indicating how far the
//! scan has progressed.  Used by progress bars and the system table
//! duckdb_progress().  Return -1 if progress cannot be determined.
typedef double (*table_function_progress_t)(ClientContext &context, const FunctionData *bind_data,
                                            const GlobalTableFunctionState *global_state);

//! dependency: populate the LogicalDependencyList with all catalog objects
//! this function depends on (e.g., base tables, sequences).
//! Called at bind time to ensure those objects are not dropped while a query
//! using this function is still running.
typedef void (*table_function_dependency_t)(LogicalDependencyList &dependencies, const FunctionData *bind_data);

//! cardinality: estimate the output row count and whether it is exact.
//! The optimizer uses this for join ordering and hash-table sizing.
//! Return nullptr if you cannot provide an estimate.
typedef unique_ptr<NodeStatistics> (*table_function_cardinality_t)(ClientContext &context,
                                                                   const FunctionData *bind_data);

//! pushdown_complex_filter: consume / transform arbitrary filter expressions.
//! Filters that the function can handle natively should be removed from the
//! vector; the remaining ones are applied as a post-scan filter operator.
//! Must set filter_pushdown = true to be invoked.
//! Extension note: only remove an expression if the scan *guarantees* it,
//! otherwise wrong results will be produced (the fallback filter is removed).
typedef void (*table_function_pushdown_complex_filter_t)(ClientContext &context, LogicalGet &get,
                                                         FunctionData *bind_data,
                                                         vector<unique_ptr<Expression>> &filters);

//! pushdown_expression: per-expression gate for filter pushdown.
//! Return true if the single expression `expr` can be pushed down as a
//! TableFilter.  Called for each candidate filter expression before the
//! planner decides to push it down.
typedef bool (*table_function_pushdown_expression_t)(ClientContext &context, const LogicalGet &get, Expression &expr);

//! to_string: return a key→value map rendered in EXPLAIN / query profiles
//! before execution starts.  Only bind_data is available here.
typedef InsertionOrderPreservingMap<string> (*table_function_to_string_t)(TableFunctionToStringInput &input);

//! dynamic_to_string: like to_string but invoked *after* execution, so both
//! the local and global states are also accessible.  Use this to include
//! runtime statistics (rows read, bytes scanned, …).
typedef InsertionOrderPreservingMap<string> (*table_function_dynamic_to_string_t)(
    TableFunctionDynamicToStringInput &input);

//! serialize: persist bind data into a Serializer stream.
//! Required for prepared statement caching and query serialization.
//! Must be implemented together with deserialize.
typedef void (*table_function_serialize_t)(Serializer &serializer, const optional_ptr<FunctionData> bind_data,
                                           const TableFunction &function);

//! deserialize: reconstruct bind data from a Deserializer stream.
//! The result must be semantically equivalent to what the original bind would
//! have returned for the same arguments.
typedef unique_ptr<FunctionData> (*table_function_deserialize_t)(Deserializer &deserializer, TableFunction &function);

//! type_pushdown: notify the scanner that DuckDB has determined tighter types
//! for some output columns (e.g., after a CAST is folded in).  The scanner
//! may update its internal state so it reads data with the narrower types.
typedef void (*table_function_type_pushdown_t)(ClientContext &context, optional_ptr<FunctionData> bind_data,
                                               const unordered_map<idx_t, LogicalType> &new_column_types);

//! get_partition_info: describe how the scan output is partitioned.
//! The planner uses this to avoid redundant re-partitioning above the scan.
typedef TablePartitionInfo (*table_function_get_partition_info_t)(ClientContext &context,
                                                                  TableFunctionPartitionInput &input);

//! get_partition_stats: return per-partition statistics (row offset + count).
//! Used to implement zone-map / min-max filtering at the partition level and
//! for parallel partition assignment during adaptive parallel execution.
typedef vector<PartitionStatistics> (*table_function_get_partition_stats_t)(ClientContext &context,
                                                                            GetPartitionStatsInput &input);

//! get_virtual_columns: enumerate columns that the scanner can synthesise on
//! demand (e.g., row_id, filename, file_row_number).  These are not part of
//! the declared schema but can appear in SELECT lists or WHERE clauses.
typedef virtual_column_map_t (*table_function_get_virtual_columns_t)(ClientContext &context,
                                                                     optional_ptr<FunctionData> bind_data);

//! get_row_id_columns: return the column indices that together form the
//! logical row identifier for this scan (used for UPDATE / DELETE rewrites).
typedef vector<column_t> (*table_function_get_row_id_columns)(ClientContext &context,
                                                              optional_ptr<FunctionData> bind_data);

//! When to call init_global to initialize the table function.
//! INITIALIZE_ON_EXECUTE (default): init_global is called when the pipeline
//!   becomes ready for execution.  This is appropriate for most table functions.
//! INITIALIZE_ON_SCHEDULE: init_global is called when the query is first
//!   scheduled, *before* any pipeline begins executing.  Use this when
//!   initialization has significant latency (e.g., opening a remote connection)
//!   and you want to hide that latency behind query planning.
enum class TableFunctionInitialization { INITIALIZE_ON_EXECUTE, INITIALIZE_ON_SCHEDULE };

// ---------------------------------------------------------------------------
// TableFunction
// ---------------------------------------------------------------------------
// The primary class that describes a table-producing function.  Register it
// via DuckDB's catalog (CatalogEntry::CreateTableFunction) or through an
// extension loader.
//
// Minimal required fields
// -----------------------
//   name        - unique name the SQL parser recognises.
//   arguments   - ordered list of positional argument types.
//   function    - the scan callback (OR set in_out_function for in-out mode).
//   bind        - resolves argument values → output schema + bind data.
//
// All other fields are optional and default to nullptr / false.
//
// Thread-safety contract
// ----------------------
//   * bind / bind_replace / bind_operator – called single-threaded.
//   * init_global                          – called single-threaded.
//   * init_local / function                – called concurrently per thread.
//   * serialize / deserialize              – called single-threaded.
//   * All optional callbacks               – see individual docstrings above.
class TableFunction : public SimpleNamedParameterFunction { // NOLINT: work-around bug in clang-tidy
public:
	DUCKDB_API
	TableFunction(string name, vector<LogicalType> arguments, table_function_t function,
	              table_function_bind_t bind = nullptr, table_function_init_global_t init_global = nullptr,
	              table_function_init_local_t init_local = nullptr);
	DUCKDB_API
	TableFunction(const vector<LogicalType> &arguments, table_function_t function, table_function_bind_t bind = nullptr,
	              table_function_init_global_t init_global = nullptr, table_function_init_local_t init_local = nullptr);
	DUCKDB_API TableFunction();

	//! Bind function
	//! This function is used for determining the return type of a table producing function and returning bind data
	//! The returned FunctionData object should be constant and should not be changed during execution.
	//! Extension note: throw a BinderException for invalid arguments; never return nullptr (use bind_replace for that).
	table_function_bind_t bind;
	//! (Optional) Bind replace function
	//! This function is called before the regular bind function. It allows returning a TableRef that will be used to
	//! to generate a logical plan that replaces the LogicalGet of a regularly bound TableFunction. The BindReplace can
	//! also return a nullptr to indicate a regular bind needs to be performed instead.
	//! Extension note: return nullptr to fall through to the normal bind path.  Only one of bind_replace /
	//! bind_operator should be set.
	table_function_bind_replace_t bind_replace;
	//! (Optional) Bind operator function
	//! This function is called before the regular bind function - similar to bind_replace - but allows returning a
	//! custom LogicalOperator instead.
	//! Extension note: only use this when you need a fully custom logical plan node; prefer bind_replace otherwise.
	table_function_bind_operator_t bind_operator;
	//! (Optional) global init function
	//! Initialize the global operator state of the function.
	//! The global operator state is used to keep track of the progress in the table function and is shared between
	//! all threads working on the table function.
	//! Extension note: set MaxThreads() on the returned state to control parallelism.  If omitted, DuckDB supplies a
	//! trivial single-threaded state.
	table_function_init_global_t init_global;
	//! (Optional) local init function
	//! Initialize the local operator state of the function.
	//! The local operator state is used to keep track of the progress in the table function and is thread-local.
	//! Extension note: claim a work unit from the global state under a lock; if no work remains, mark the local state
	//! as exhausted so function() can immediately return an empty chunk.
	table_function_init_local_t init_local;
	//! The main function
	//! Fill output with up to STANDARD_VECTOR_SIZE rows; leave it empty (cardinality 0) to signal EOF.
	//! Extension note: only one of `function` and `in_out_function` should be set.
	table_function_t function;
	//! The table in-out function (if this is an in-out function)
	//! Extension note: set exactly one of `function` and `in_out_function`.
	table_in_out_function_t in_out_function;
	//! The table in-out final function (if this is an in-out function)
	//! Called after all input has been consumed; flush any buffered state.
	table_in_out_function_final_t in_out_function_final;
	//! (Optional) statistics function
	//! Returns the statistics of a specified column
	//! Extension note: accurate stats improve join ordering; return nullptr if statistics are unavailable.
	table_statistics_t statistics;
	//! (Optional) dependency function
	//! Sets up which catalog entries this table function depend on
	//! Extension note: failing to declare a dependency may allow DROP TABLE to succeed while a query is running.
	table_function_dependency_t dependency;
	//! (Optional) cardinality function
	//! Returns the expected cardinality of this scan
	//! Extension note: even a rough estimate helps the optimizer; return nullptr only if completely unknown.
	table_function_cardinality_t cardinality;
	//! (Optional) pushdown a set of arbitrary filter expressions, rather than only simple comparisons with a constant
	//! Any functions remaining in the expression list will be pushed as a regular filter after the scan
	//! Extension note: ONLY remove expressions your scanner will fully enforce; if unsure, leave the expression in the
	//! vector so DuckDB applies it as a post-scan filter (safe but slower).
	table_function_pushdown_complex_filter_t pushdown_complex_filter;
	//! (Optional) whether or not this table function supports pushing down an expression into a TableFilter
	table_function_pushdown_expression_t pushdown_expression;
	//! (Optional) function for rendering the operator to a string in explain/profiling output (invoked pre-execution)
	table_function_to_string_t to_string;
	//! (Optional) function for rendering the operator to a string in profiling output (invoked post-execution)
	table_function_dynamic_to_string_t dynamic_to_string;
	//! (Optional) return how much of the table we have scanned up to this point (% of the data)
	//! Extension note: return -1 if progress cannot be determined; do not block.
	table_function_progress_t table_scan_progress;
	//! (Optional) returns the partition info of the current scan operator
	table_function_get_partition_data_t get_partition_data;
	//! (Optional) returns extra bind info
	table_function_get_bind_info_t get_bind_info;
	//! (Optional) pushes down type information to scanner, returns true if pushdown was successful
	table_function_type_pushdown_t type_pushdown;
	//! (Optional) allows injecting a custom MultiFileReader implementation
	table_function_get_multi_file_reader_t get_multi_file_reader;
	//! (Optional) If this scanner supports filter pushdown, but not to all data types
	table_function_supports_pushdown_type_t supports_pushdown_type;
	//! Get partition info of the table
	table_function_get_partition_info_t get_partition_info;
	//! (Optional) get a list of all the partition stats of the table
	table_function_get_partition_stats_t get_partition_stats;
	//! (Optional) returns a list of virtual columns emitted by the table function
	table_function_get_virtual_columns_t get_virtual_columns;
	//! (Optional) returns a list of row id columns
	table_function_get_row_id_columns get_row_id_columns;

	//! (Optional) serialize / deserialize bind data for prepared-statement caching and query serialization.
	//! Both must be set together; if either is nullptr the function is considered non-serializable.
	//! Extension note: the deserialized bind data must be semantically identical to a fresh bind invocation.
	table_function_serialize_t serialize;
	table_function_deserialize_t deserialize;
	bool verify_serialization = true;

	//! Whether or not the table function supports projection pushdown. If not supported a projection will be added
	//! that filters out unused columns.
	//! Extension note: set to true and honour column_ids in init_global/init_local to avoid reading unused columns.
	bool projection_pushdown;
	//! Whether or not the table function supports filter pushdown. If not supported a filter will be added
	//! that applies the table filter directly.
	//! Extension note: set to true only when the scan genuinely applies the filters; combined with
	//! pushdown_complex_filter / pushdown_expression / supports_pushdown_type for finer control.
	bool filter_pushdown;
	//! Whether or not the table function can immediately prune out filter columns that are unused in the remainder of
	//! the query plan, e.g., "SELECT i FROM tbl WHERE j = 42;" - j does not need to leave the table function at all
	//! Extension note: requires filter_pushdown = true; check CanRemoveFilterColumns() in init_global/init_local.
	bool filter_prune;
	//! Whether or not the table function supports sampling pushdown. If not supported a sample will be taken after the
	//! table function.
	bool sampling_pushdown;
	//! Whether or not the table function supports late materialization
	bool late_materialization;
	//! Additional function info, passed to the bind
	//! Extension note: share read-only configuration here (e.g., a registered plugin context).
	shared_ptr<TableFunctionInfo> function_info;

	//! When to call init_global
	//! By default init_global is called when the pipeline is ready for execution
	//! If this is set to `INITIALIZE_ON_SCHEDULE` the table function is initialized when the query is scheduled
	TableFunctionInitialization global_initialization = TableFunctionInitialization::INITIALIZE_ON_EXECUTE;

	DUCKDB_API bool Equal(const TableFunction &rhs) const;
	DUCKDB_API bool operator==(const TableFunction &rhs) const;
	DUCKDB_API bool operator!=(const TableFunction &rhs) const;
};

} // namespace duckdb
