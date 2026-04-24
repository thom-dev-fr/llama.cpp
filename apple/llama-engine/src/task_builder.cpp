#include "task_builder.hpp"

#include <stdexcept>
#include <utility>

namespace llama_engine {

using json = nlohmann::ordered_json;

task_builder::parsed_request task_builder::parse_oai_chat_request(
    const std::string        & request_json,
    const server_chat_params & chat_params)
{
    parsed_request out;

    json body;
    try {
        body = json::parse(request_json);
    } catch (const json::parse_error & e) {
        throw std::invalid_argument(std::string("invalid JSON: ") + e.what());
    }

    if (!body.is_object()) {
        throw std::invalid_argument("request must be a JSON object");
    }

    out.stream  = json_value(body, "stream", false);
    out.cmpl_id = gen_chatcmplid();

    // oaicompat_chat_params_parse mutates `body` (e.g., stripping media and
    // replacing with media_marker placeholders) and returns the llama-params
    // payload that downstream code (params_from_json_cmpl) consumes.
    out.data = oaicompat_chat_params_parse(body, chat_params, out.files);

    return out;
}

std::vector<server_task> task_builder::build_tasks(
    const parsed_request                  & parsed,
    const llama_vocab                     * vocab,
    const common_params                   & params_base,
    int                                     n_ctx_slot,
    const std::vector<llama_logit_bias>   & logit_bias_eog,
    const std::string                     & model_name,
    std::function<int()>                    next_id)
{
    if (!parsed.data.contains("prompt") || !parsed.data.at("prompt").is_string()) {
        throw std::invalid_argument("internal error: parsed request missing string 'prompt'");
    }

    const std::string prompt_str = parsed.data.at("prompt").get<std::string>();

    server_task task(SERVER_TASK_TYPE_COMPLETION);
    task.id         = next_id();
    task.cli        = true;
    task.cli_prompt = prompt_str;
    task.cli_files  = parsed.files;
    task.params = server_task::params_from_json_cmpl(
        vocab,
        params_base,
        n_ctx_slot,
        logit_bias_eog,
        parsed.data);
    task.id_slot = json_value(parsed.data, "id_slot", -1);

    task.params.res_type          = TASK_RESPONSE_TYPE_OAI_CHAT;
    task.params.oaicompat_cmpl_id = parsed.cmpl_id;
    task.params.oaicompat_model   = model_name;

    if (task.params.n_cmpl > 1) {
        // CLI path carries the prompt in cli_prompt/cli_files which server_task::add_child
        // does not copy. Parallel sampling would silently drop the prompt on children.
        throw std::invalid_argument("n > 1 (parallel sampling) is not supported in v1");
    }

    std::vector<server_task> tasks;
    tasks.push_back(std::move(task));
    return tasks;
}

} // namespace llama_engine
