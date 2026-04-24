#pragma once

#include "server-task.h"

#include <string>
#include <vector>

namespace llama_engine {

// Turn server_task_result instances into plain JSON strings for the public API.
//
// The upstream server_task_result::to_json() already routes to
// to_json_oaicompat_chat_stream() / to_json_oaicompat_chat() based on the task
// response type set at build time, so this module is mostly a thin layer that
// guarantees a single JSON object per stream chunk (no SSE framing, no [DONE]
// sentinel) and aggregates multiple non-stream results from parallel sampling
// into a single OAI-compatible response when applicable.
struct result_formatter {
    // Serialise a single streaming chunk to a JSON object string.
    // Precondition: res.res_type was set to TASK_RESPONSE_TYPE_OAI_CHAT at task build time.
    static std::string format_stream_chunk(server_task_result & res);

    // Aggregate the non-stream results of a single or parallel-sampled request
    // into a single OAI-compatible chat completion JSON object.
    // Precondition: all results are TASK_RESPONSE_TYPE_OAI_CHAT completion finals.
    static std::string format_non_stream(std::vector<server_task_result_ptr> & results);

    // Serialise an error result to a JSON object string wrapped in {"error": ...}.
    static std::string format_error(server_task_result & res);
};

} // namespace llama_engine
