#include "pipeline_info_extension.hpp"
#include "duckdb/common/enums/physical_operator_type.hpp"
#include "duckdb/common/string_util.hpp"
#include "duckdb/execution/executor.hpp"
#include "duckdb/execution/physical_plan_generator.hpp"
#include "duckdb/function/table_function.hpp"
#include "duckdb/main/client_context.hpp"
#include "duckdb/main/extension/extension_loader.hpp"
#include "duckdb/optimizer/optimizer.hpp"
#include "duckdb/parallel/meta_pipeline.hpp"
#include "duckdb/parallel/pipeline.hpp"
#include "duckdb/parallel/task_scheduler.hpp"
#include "duckdb/parser/parser.hpp"
#include "duckdb/planner/binder.hpp"

namespace duckdb {

static bool HasRecursiveCTE(const PhysicalOperator &op) {
	if (op.type == PhysicalOperatorType::RECURSIVE_CTE) {
		return true;
	}
	for (auto &child : op.GetChildren()) {
		if (HasRecursiveCTE(child.get())) {
			return true;
		}
	}
	return false;
}

static string FormatOperator(const PhysicalOperator &op) {
	string s = op.GetName();
	auto params = op.ParamsToString();
	if (!params.empty()) {
		vector<string> kv;
		for (auto &entry : params) {
			kv.push_back(entry.first + "=" + entry.second);
		}
		s += " [" + StringUtil::Join(kv, ", ") + "]";
	}
	return s;
}

static string BuildPipelineInfoText(ClientContext &context, const string &sql) {
	Parser parser(context.GetParserOptions());
	parser.ParseQuery(sql);
	if (parser.statements.empty()) {
		throw InvalidInputException("explain_pipeline: empty SQL");
	}
	if (parser.statements.size() > 1) {
		throw InvalidInputException("explain_pipeline: only one statement allowed");
	}

	auto binder = Binder::CreateBinder(context);
	auto bound = binder->Bind(*parser.statements[0]);

	Optimizer optimizer(*binder, context);
	auto optimized = optimizer.Optimize(std::move(bound.plan));

	PhysicalPlanGenerator generator(context);
	auto physical_plan = generator.Plan(std::move(optimized));

	if (HasRecursiveCTE(physical_plan->Root())) {
		return "explain_pipeline: recursive CTEs are not yet supported\n";
	}

	// Create a local executor for pipeline building — Executor::Get() requires
	// active_query->executor which doesn't exist during the Bind phase.
	Executor local_executor(context);
	PipelineBuildState build_state;
	auto root_meta = make_shared_ptr<MetaPipeline>(local_executor, build_state, nullptr);
	root_meta->Build(physical_plan->Root());

	vector<shared_ptr<Pipeline>> all_pipelines;
	root_meta->GetPipelines(all_pipelines, true);

	reference_map_t<Pipeline, idx_t> pipeline_idx;
	for (idx_t i = 0; i < all_pipelines.size(); i++) {
		pipeline_idx[*all_pipelines[i]] = i + 1;
	}

	auto &scheduler = TaskScheduler::GetScheduler(context);
	auto scheduler_threads = NumericCast<idx_t>(scheduler.NumberOfThreads());

	string result = StringUtil::Format("Total Pipelines: %llu\n", all_pipelines.size());

	for (idx_t i = 0; i < all_pipelines.size(); i++) {
		auto &p = *all_pipelines[i];
		result += "\n";
		result += StringUtil::Format("Pipeline %llu", i + 1);

		// Static parallelism check (no state initialization needed)
		bool can_parallel = true;
		if (p.GetSource() && !p.GetSource()->ParallelSource()) {
			can_parallel = false;
		}
		if (p.GetSink() && !p.GetSink()->ParallelSink()) {
			can_parallel = false;
		}
		if (p.IsOrderDependent()) {
			can_parallel = false;
		}
		if (can_parallel) {
			for (auto &op_ref : p.GetIntermediateOperators()) {
				if (!op_ref.get().ParallelOperator()) {
					can_parallel = false;
					break;
				}
			}
		}

		// Dependencies
		auto deps = p.GetDependencies();
		vector<string> dep_strs;
		for (auto &weak_dep : deps) {
			auto dep = weak_dep.lock();
			if (!dep) {
				continue;
			}
			auto it = pipeline_idx.find(*dep);
			if (it != pipeline_idx.end()) {
				dep_strs.push_back(StringUtil::Format("Pipeline %llu", it->second));
			}
		}
		if (!dep_strs.empty()) {
			result += " [depends on: " + StringUtil::Join(dep_strs, ", ") + "]";
		}

		if (can_parallel) {
			result += StringUtil::Format(" [parallel, max_threads=%llu]", scheduler_threads);
		} else {
			result += " [sequential, threads=1]";
		}
		result += ":\n";

		if (p.GetSource()) {
			result += "   Source: " + FormatOperator(*p.GetSource()) + "\n";
		}
		for (auto &op_ref : p.GetIntermediateOperators()) {
			result += "   " + FormatOperator(op_ref.get()) + "\n";
		}
		if (p.GetSink()) {
			result += "   Sink: " + FormatOperator(*p.GetSink()) + "\n";
		}
	}

	return result;
}

struct PipelineInfoBindData : public TableFunctionData {
	string pipeline_info;
};

struct PipelineInfoGlobalState : public GlobalTableFunctionState {
	bool returned = false;
};

static unique_ptr<FunctionData> ExplainPipelineBind(ClientContext &context, TableFunctionBindInput &input,
                                                    vector<LogicalType> &return_types, vector<string> &names) {
	if (input.inputs.empty() || input.inputs[0].IsNull()) {
		throw InvalidInputException("explain_pipeline: SQL argument cannot be NULL");
	}
	auto sql = input.inputs[0].GetValue<string>();

	auto bind_data = make_uniq<PipelineInfoBindData>();
	bind_data->pipeline_info = BuildPipelineInfoText(context, sql);

	names = {"pipeline_info"};
	return_types = {LogicalType::VARCHAR};
	return bind_data;
}

static unique_ptr<GlobalTableFunctionState> ExplainPipelineInitGlobal(ClientContext &context,
                                                                      TableFunctionInitInput &input) {
	return make_uniq<PipelineInfoGlobalState>();
}

static void ExplainPipelineFunction(ClientContext &context, TableFunctionInput &data_p, DataChunk &output) {
	auto &state = data_p.global_state->Cast<PipelineInfoGlobalState>();
	if (state.returned) {
		output.SetCardinality(0);
		return;
	}
	auto &bind_data = data_p.bind_data->Cast<PipelineInfoBindData>();
	output.SetValue(0, 0, Value(bind_data.pipeline_info));
	output.SetCardinality(1);
	state.returned = true;
}

static void LoadInternal(ExtensionLoader &loader) {
	TableFunction func("explain_pipeline", {LogicalType::VARCHAR}, ExplainPipelineFunction, ExplainPipelineBind,
	                   ExplainPipelineInitGlobal);
	loader.RegisterFunction(func);
}

void PipelineInfoExtension::Load(ExtensionLoader &loader) {
	LoadInternal(loader);
}

std::string PipelineInfoExtension::Name() {
	return "pipeline_info";
}

std::string PipelineInfoExtension::Version() const {
	return "";
}

} // namespace duckdb

extern "C" {

DUCKDB_CPP_EXTENSION_ENTRY(pipeline_info, loader) {
	duckdb::LoadInternal(loader);
}
}
