#ifdef NDEBUG
#undef NDEBUG
#endif
#include "engine-runtime.h"
#include "chat.h"
#include <cassert>
#include <fstream>
#include <iterator>

using namespace llama_engine::detail;
using llama_engine::event_type;

// Controlled decoder output exercises the actual public reader and incremental
// converters, without depending on a model's ability to produce tool calls.
int main(int argc, char ** argv) {
    assert(argc == 2);
    std::ifstream input(argv[1]);
    assert(input);
    std::string source(std::istreambuf_iterator<char>(input), {});
    auto tmpls = common_chat_templates_init(nullptr, source);
    common_chat_templates_inputs inputs;
    common_chat_msg msg;
    msg.role = "user";
    msg.content = "Weather in Paris?";
    inputs.messages.push_back(msg);
    inputs.tools.push_back({"weather", "Weather", R"({"type":"object","properties":{"city":{"type":"string"}},"required":["city"]})"});
    inputs.reasoning_format = COMMON_REASONING_FORMAT_DEEPSEEK;
    auto params = common_chat_templates_apply(tmpls.get(), inputs);
    common_chat_parser_params parser(params);
    parser.parser.load(params.parser);
    parser.reasoning_format = COMMON_REASONING_FORMAT_DEEPSEEK;

    for (auto format : {TASK_RESPONSE_TYPE_OAI_CHAT, TASK_RESPONSE_TYPE_OAI_RESP, TASK_RESPONSE_TYPE_ANTHROPIC}) {
        auto state = std::make_shared<request_state>();
        state->stream = true;
        state->remaining = 1;
        state->conversion.emplace_back(parser);
        llama_engine::request req(state);
        // Feed reasoning and a tool call one byte at a time, including delimiters.
        const std::string text = "<think>Let me check.</think>\n<tool_call>\n{\"name\":\"weather\",\"arguments\":{\"city\":\"Paris\"}}\n</tool_call>";
        std::string arguments, reasoning;
        int fragments = 0;
        auto collect = [&](const llama_engine::json & chunks) {
            for (const auto & chunk : chunks) {
                if (format == TASK_RESPONSE_TYPE_OAI_CHAT) {
                    for (const auto & choice : chunk.at("choices")) {
                        const auto & delta = choice.at("delta");
                        reasoning += delta.value("reasoning_content", std::string());
                        if (delta.contains("tool_calls")) {
                            for (const auto & call : delta.at("tool_calls")) {
                                if (!call.contains("function")) { continue; }
                                auto fragment = call.at("function").value("arguments", std::string());
                                arguments += fragment;
                                fragments += !fragment.empty();
                            }
                        }
                    }
                } else {
                    const auto name = chunk.at("event").get<std::string>();
                    const auto & data = chunk.at("data");
                    if (name == "response.function_call_arguments.delta") {
                        arguments += data.at("delta").get<std::string>(); ++fragments;
                    } else if (name == "response.reasoning_text.delta") {
                        reasoning += data.at("delta").get<std::string>();
                    } else if (name == "content_block_delta") {
                        auto delta = data.at("delta");
                        if (delta.at("type") == "input_json_delta") {
                            arguments += delta.at("partial_json").get<std::string>(); ++fragments;
                        } else if (delta.at("type") == "thinking_delta") {
                            reasoning += delta.at("thinking").get<std::string>();
                        }
                    }
                }
            }
        };
        for (char c : text) {
            auto partial = std::make_unique<server_task_result_cmpl_partial>();
            partial->content = std::string(1, c);
            partial->res_type = format;
            partial->oaicompat_cmpl_id = "chatcmpl-test";
            state->push(std::move(partial));
            auto event = req.next();
            assert(event.type == event_type::payload);
            collect(event.data);
        }
        auto final = std::make_unique<server_task_result_cmpl_final>();
        final->res_type = format;
        final->stream = true;
        final->stop = STOP_TYPE_EOS;
        final->oaicompat_cmpl_id = "chatcmpl-test";
        state->push(std::move(final));
        auto last = req.next();
        assert(last.type == event_type::payload);
        collect(last.data);
        assert(req.next().type == event_type::success);
        assert(fragments > 1);
        assert(llama_engine::json::parse(arguments).at("city") == "Paris");
        assert(reasoning.find("Let me check.") != std::string::npos);
    }

    // The final payload precedes success; an error after start is observable and
    // cannot be replaced by later decoder output, cancellation or shutdown.
    for (bool started : {false, true}) {
        auto state = std::make_shared<request_state>();
        state->stream = true;
        state->remaining = 1;
        llama_engine::request req(state);
        if (started) {
            state->conversion.emplace_back(common_chat_parser_params{});
            auto begin = std::make_unique<server_task_result_cmpl_partial>();
            begin->is_begin = true;
            state->push(std::move(begin));
            assert(req.next().type == event_type::payload);
        }
        auto error = std::make_unique<server_task_result_error>();
        error->err_msg = "controlled failure";
        state->push(std::move(error));
        req.cancel();
        state->finish({event_type::success, nullptr, {}, {}});
        auto end = req.next();
        assert(end.type == event_type::error && end.message == "controlled failure");
        assert(req.next().type == event_type::error);
    }
}
