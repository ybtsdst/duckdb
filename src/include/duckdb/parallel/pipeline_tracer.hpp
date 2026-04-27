//===----------------------------------------------------------------------===//
//                         DuckDB
//
// duckdb/parallel/pipeline_tracer.hpp
//
//
//===----------------------------------------------------------------------===//

#pragma once

#include "duckdb/common/common.hpp"

namespace duckdb {

class Pipeline;

//! PipelineTracer collects and outputs pipeline structure and execution timing.
//! Enabled by SET enable_pipeline_trace = true.
//! Outputs:
//!   1. A pipeline dependency graph to stderr after initialization.
//!   2. A Chrome Trace JSON timing report to stderr after query completion
//!      (loadable in https://ui.perfetto.dev/ or chrome://tracing).
class PipelineTracer {
public:
	//! Assign sequential IDs (0, 1, 2, ...) to all pipelines.
	//! Must be called before PrintGraph or PrintChromeTrace.
	static void AssignIds(vector<shared_ptr<Pipeline>> &pipelines);

	//! Print the static pipeline structure and dependency graph to stderr.
	static void PrintGraph(const vector<shared_ptr<Pipeline>> &pipelines);

	//! Print Chrome Trace JSON to stderr.
	//! query_start_ns: steady_clock nanoseconds since epoch at query start.
	static void PrintChromeTrace(const vector<shared_ptr<Pipeline>> &pipelines, int64_t query_start_ns);

private:
	//! Build a short human-readable description: "TableScan→HashJoinBuild→..."
	static string Describe(const Pipeline &pipeline);
};

} // namespace duckdb
