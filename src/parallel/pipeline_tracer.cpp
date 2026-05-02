#include "duckdb/parallel/pipeline_tracer.hpp"

#include "duckdb/common/printer.hpp"
#include "duckdb/common/string_util.hpp"
#include "duckdb/execution/physical_operator.hpp"
#include "duckdb/parallel/pipeline.hpp"

#include <fstream>

namespace duckdb {

void PipelineTracer::AssignIds(vector<shared_ptr<Pipeline>> &pipelines) {
	for (idx_t i = 0; i < pipelines.size(); i++) {
		pipelines[i]->pipeline_id = i;
	}
}

string PipelineTracer::Describe(const Pipeline &pipeline) {
	auto ops = pipeline.GetOperators();
	string result;
	for (idx_t i = 0; i < ops.size(); i++) {
		if (i > 0) {
			result += "→";
		}
		result += ops[i].get().GetName();
	}
	return result;
}

void PipelineTracer::WriteOutput(const string &content, const string &output_path, bool append) {
	if (output_path.empty()) {
		Printer::Print(OutputStream::STREAM_STDERR, content);
		return;
	}
	auto mode = std::ios::out | (append ? std::ios::app : std::ios::trunc);
	std::ofstream f(output_path, mode);
	if (!f.is_open()) {
		// Fall back to stderr if the file cannot be opened
		Printer::Print(OutputStream::STREAM_STDERR,
		               "pipeline_tracer: could not open '" + output_path + "', falling back to stderr\n" + content);
		return;
	}
	f << content;
}

void PipelineTracer::PrintGraph(const vector<shared_ptr<Pipeline>> &pipelines, const string &output_path) {
	string out = "\n=== Pipeline Graph ===\n";
	for (auto &p : pipelines) {
		out += "Pipeline #" + to_string(p->pipeline_id) + ": " + Describe(*p) + "\n";
		auto deps = p->GetDependencies();
		if (!deps.empty()) {
			out += "  depends on:";
			for (auto &dep : deps) {
				auto locked = dep.lock();
				if (locked) {
					out += " #" + to_string(locked->pipeline_id);
				}
			}
			out += "\n";
		}
	}
	out += "======================\n";
	// Append: the graph is plain text and the per-query "=== Pipeline Graph ===" header
	// already separates entries, so multiple queries in the same session accumulate cleanly.
	WriteOutput(out, output_path, /*append=*/true);
}

void PipelineTracer::PrintChromeTrace(const vector<shared_ptr<Pipeline>> &pipelines, int64_t query_start_ns,
                                      const string &output_path) {
	string events;
	bool first = true;
	for (auto &p : pipelines) {
		string desc = Describe(*p);
		// Escape quotes for JSON safety; do it once per pipeline, not per task.
		desc = StringUtil::Replace(desc, "\"", "\\\"");
		// One Chrome Trace event per PipelineTask: each parallel slice of the pipeline gets
		// its own bar. tid = thread hash so each worker thread occupies its own row in
		// Perfetto, making real parallelism visible.
		idx_t task_idx = 0;
		for (auto &t : p->task_timings) {
			int64_t start_us = (t.start_ns - query_start_ns) / 1000;
			int64_t dur_us = (t.end_ns - t.start_ns) / 1000;
			if (dur_us < 0) {
				dur_us = 0;
			}
			// Mask to a 31-bit non-negative value for tools that treat tid as signed int32.
			uint64_t tid = t.thread_hash & 0x7fffffffULL;
			if (!first) {
				events += ",\n  ";
			} else {
				first = false;
			}
			events += "{\"name\":\"#" + to_string(p->pipeline_id) + "[" + to_string(task_idx) + "]: " + desc +
			          "\",\"ph\":\"X\",\"pid\":0,\"tid\":" + to_string(tid) +
			          ",\"ts\":" + to_string(start_us) + ",\"dur\":" + to_string(dur_us) + "}";
			task_idx++;
		}
	}
	string json = "{\"traceEvents\":[\n  " + events + "\n]}\n";
	// Truncate: Chrome Trace JSON must be a single valid JSON object; concatenating
	// per-query traces would produce invalid JSON. Each query overwrites the file.
	WriteOutput(json, output_path, /*append=*/false);
}

} // namespace duckdb
