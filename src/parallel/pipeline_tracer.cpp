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

void PipelineTracer::WriteOutput(const string &content, const string &output_path) {
	if (output_path.empty()) {
		Printer::Print(OutputStream::STREAM_STDERR, content);
		return;
	}
	std::ofstream f(output_path, std::ios::out | std::ios::trunc);
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
	WriteOutput(out, output_path);
}

void PipelineTracer::PrintChromeTrace(const vector<shared_ptr<Pipeline>> &pipelines, int64_t query_start_ns,
                                      const string &output_path) {
	string events;
	bool first = true;
	for (auto &p : pipelines) {
		if (p->start_time_ns < 0 || p->end_time_ns < 0) {
			continue;
		}
		int64_t start_us = (p->start_time_ns - query_start_ns) / 1000;
		int64_t dur_us = (p->end_time_ns - p->start_time_ns) / 1000;
		if (dur_us < 0) {
			dur_us = 0;
		}
		if (!first) {
			events += ",\n  ";
		} else {
			first = false;
		}
		string name = "#" + to_string(p->pipeline_id) + ": " + Describe(*p);
		// Escape quotes in name for JSON safety
		StringUtil::ReplaceAll(name, "\"", "\\\"");
		events += "{\"name\":\"" + name + "\",\"ph\":\"X\",\"pid\":0,\"tid\":" + to_string(p->pipeline_id) +
		          ",\"ts\":" + to_string(start_us) + ",\"dur\":" + to_string(dur_us) + "}";
	}
	string json = "{\"traceEvents\":[\n  " + events + "\n]}\n";
	WriteOutput(json, output_path);
}

} // namespace duckdb
