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
//!
//! Output destinations (empty string = stderr):
//!   SET pipeline_graph_output  = '/path/graph.txt'   -- pipeline dependency graph
//!   SET pipeline_trace_output  = '/path/trace.json'  -- Chrome Trace JSON (Perfetto)
class PipelineTracer {
public:
	//! Assign sequential IDs (0, 1, 2, ...) to all pipelines.
	//! Must be called before PrintGraph or PrintChromeTrace.
	static void AssignIds(vector<shared_ptr<Pipeline>> &pipelines);

	//! Print the static pipeline structure and dependency graph.
	//! output_path: file path to write to, or empty string for stderr.
	static void PrintGraph(const vector<shared_ptr<Pipeline>> &pipelines, const string &output_path);

	//! Print Chrome Trace JSON (loadable in https://ui.perfetto.dev/).
	//! query_start_ns: steady_clock nanoseconds since epoch at query start.
	//! output_path: file path to write to, or empty string for stderr.
	static void PrintChromeTrace(const vector<shared_ptr<Pipeline>> &pipelines, int64_t query_start_ns,
	                             const string &output_path);

private:
	//! Build a short human-readable description: "TableScan→HashJoinBuild→..."
	static string Describe(const Pipeline &pipeline);

	//! Write content to output_path if non-empty, otherwise to stderr.
	static void WriteOutput(const string &content, const string &output_path);
};

} // namespace duckdb
