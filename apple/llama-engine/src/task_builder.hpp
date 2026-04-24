#pragma once

#include "server-common.h"
#include "server-task.h"

#include <functional>
#include <string>
#include <vector>

namespace llama_engine {

// Build server_task vectors from OpenAI-compatible chat/completions JSON requests.
//
// Split intentionally in two layers:
//   - parse_oai_chat_request: pure-ish, depends on server_chat_params only,
//     does template application and input validation. Unit-testable without a
//     loaded model as long as a minimal server_chat_params with synthetic
//     templates is provided.
//   - build_tasks: depends on vocab and server metadata, constructs server_task
//     instances using the CLI path (cli = true), which lets server_context
//     perform tokenization including multimodal chunking with its own
//     mtmd_context when present.
struct task_builder {
    struct parsed_request {
        nlohmann::ordered_json  data;       // payload returned by oaicompat_chat_params_parse
        std::vector<raw_buffer> files;      // media buffers extracted from multi-part content
        std::string             cmpl_id;    // OAI-compatible completion ID
        bool                    stream = false;
    };

    static parsed_request parse_oai_chat_request(
        const std::string        & request_json,
        const server_chat_params & chat_params);

    static std::vector<server_task> build_tasks(
        const parsed_request                  & parsed,
        const llama_vocab                     * vocab,
        const common_params                   & params_base,
        int                                     n_ctx_slot,
        const std::vector<llama_logit_bias>   & logit_bias_eog,
        const std::string                     & model_name,
        std::function<int()>                    next_id);
};

} // namespace llama_engine
