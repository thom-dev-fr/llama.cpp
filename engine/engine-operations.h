#pragma once
#include "engine-context.h"
#include <stdexcept>

namespace llama_engine { namespace detail {
struct operation_error : std::runtime_error {
    ::json data;
    explicit operation_error(::json data) : std::runtime_error(data.value("message", "")), data(std::move(data)) {}
};
struct prepared_operation {
    std::vector<server_task> tasks;
    ::json immediate;
    task_response_type format = TASK_RESPONSE_TYPE_NONE;
    bool priority = false;
    std::function<::json(::json)> assemble;
};
// Capability checks precede JSON parsing in HTTP for historical error priority.
void validate_operation_support(const server_context_meta & meta, const common_params & params, operation op);
prepared_operation prepare_operation(server_context & context, operation op, ::json body,
                                    const std::vector<attachment> & files, size_t max_tasks);
::json assemble_completions(::json results, task_response_type format);
::json engine_model_info(const server_context_meta & meta);
::json engine_models(const server_context_meta & meta);
::json engine_properties(const server_context_meta & meta, const common_params & params, bool sleeping);
} }
