#include "server-context.h"
#include "engine-runtime.h"
#include "engine-operations.h"
#include "server-common.h"
#include "server-http.h"
#include "server-task.h"
#include "server-queue.h"
#include "server-stream.h"
#include "server-wire.h"

#include <chrono>
#include <exception>
#include <memory>
#include <utility>

constexpr int HTTP_POLLING_SECONDS = 1;

// generator-like API for HTTP response generation
// may have bypass_sleep = true if the task does not use ctx_server
struct server_res_generator : server_res_spipe {
    std::shared_ptr<llama_engine::request> engine_request;
    server_res_generator(server_queue & queue_tasks, int sleep_idle_seconds, bool bypass_sleep = false) {
        // fast path in case sleeping is disabled
        bypass_sleep |= sleep_idle_seconds < 0;
        if (!bypass_sleep) {
            queue_tasks.wait_until_no_sleep();
        }
    }
    void ok(const json & response_data) {
        status = 200;
        data = safe_json_to_str(response_data);
    }
    void error(const json & error_data) {
        status = json_value(error_data, "code", 500);
        data = safe_json_to_str({{ "error", error_data }});
    }
};


//
// server_routes
//

std::unique_ptr<server_res_generator> server_routes::handle_operation(
        const server_http_req & req, llama_engine::operation op, const json & body,
        const std::vector<llama_engine::attachment> & files, bool model_in_query) {
    // with several models, sleeping is per model and handled by the engine
    auto res = create_response(routing.has_value() || op == llama_engine::operation::metrics ||
                               op == llama_engine::operation::properties || op == llama_engine::operation::models);
    std::string model;
    std::shared_ptr<llama_engine::detail::request_state> state;
    if (routing) {
        // the model's capabilities are checked by the engine once it is resident
        json input = body.is_null() ? json::parse(req.body) : body;
        if (model_in_query) {
            model = req.get_param("model");
            if (input.is_object() && !model.empty()) {
                input["model"] = model;
            }
        } else if (input.is_object()) {
            model = json_value(input, "model", std::string());
        }
        res->set_req(&req);
        state = routing->submit(req, op, model, std::move(input), files);
    } else {
        // Preserve support errors and sleep behavior before parsing the body. The
        // capability rules themselves belong to the engine and use owned metadata.
        try {
            llama_engine::detail::validate_operation_support(*meta, params, op);
        } catch (const llama_engine::detail::operation_error & error) {
            res->error(error.data);
            return res;
        }
        const json input = body.is_null() ? json::parse(req.body) : body;
        res->set_req(&req);
        state = std::make_shared<llama_engine::detail::request_state>();
        llama_engine::detail::submit_native(ctx_server.runtime, state, input, op, files);
    }
    res->engine_request = std::make_shared<llama_engine::request>(state); // cancels on destruction
    auto error_json = [model](const llama_engine::event & item) {
        if (item.data.is_object() && item.data.contains("code")) {
            return json::parse(item.data.dump());
        }
        // model selection errors keep the messages and statuses of the process router
        if (item.category == "model_downloading") {
            return format_error_response("model name=" + model + " is not running", ERROR_TYPE_INVALID_REQUEST);
        }
        if (item.category == "load_failed") {
            return format_error_response("model name=" + model + " failed to load", ERROR_TYPE_SERVER);
        }
        auto type = item.category == "invalid_request" || item.category == "model_not_found" ||
                    item.category == "model_not_loaded" ? ERROR_TYPE_INVALID_REQUEST
                  : item.category == "wake_failed" || item.category == "wait_timeout" ||
                    item.category == "capacity_exceeded" ? ERROR_TYPE_UNAVAILABLE : ERROR_TYPE_SERVER;
        return format_error_response(item.message, type);
    };
    auto next = [state](const std::function<bool()> & should_stop) {
        for (;;) {
            if (should_stop()) {
                return llama_engine::detail::native_item {{llama_engine::event_type::cancelled, nullptr, "closed", {}}, nullptr};
            }
            auto item = state->read_native(std::chrono::seconds(HTTP_POLLING_SECONDS));
            if (item.status.type != llama_engine::event_type::timeout) { return item; }
        }
    };
    // A request that waits for its model: a resumable session survives its client
    // until a stop (DELETE /v1/stream), like any other request of that session.
    auto first = routing ? next([&res] { return res->should_stop(); }) : next(req.should_stop);
    if (routing) {
        routing->started(req);
    }
    if (first.status.type == llama_engine::event_type::error) {
        res->error(error_json(first.status));
        return res;
    }
    if (!first.result && first.status.type != llama_engine::event_type::success) {
        res->engine_request->cancel();
        if (routing && first.status.category == "closed" && !server_stream_conv_id_from_headers(req.headers).empty()) {
            res->error(format_error_response("request cancelled by a stop while the model was loading", ERROR_TYPE_INVALID_REQUEST));
        } else if (routing && first.status.category != "closed" && first.status.category != "stopped") {
            // the model was unloaded or removed while the request waited for it
            res->error(format_error_response(first.status.message, ERROR_TYPE_SERVER));
        }
        return res; // connection closed, cancelled or stopped
    }

    if (!state->stream) {
        std::vector<json> results(state->complete.size());
        for (auto item = std::move(first);; item = next(req.should_stop)) {
            if (item.result) {
                results[item.result->index] = item.result->to_json();
                continue;
            }
            if (item.status.type == llama_engine::event_type::error) {
                res->error(error_json(item.status));
            } else if (item.status.type == llama_engine::event_type::success) {
                json arr = json::array();
                for (auto & result : results) {
                    arr.push_back(std::move(result));
                }
                // if single request, return single object instead of array
                if (op == llama_engine::operation::metrics) {
                    res->headers["Process-Start-Time-Unix"] = std::to_string(arr[0].at("t_start").get<int64_t>());
                    res->content_type = "text/plain; version=0.0.4";
                    res->status = 200;
                    res->data = format_metrics(arr[0]);
                } else {
                    res->ok(state->assemble ? state->assemble(std::move(arr)) : (arr.size() == 1 ? arr[0] : arr));
                }
            } else {
                res->engine_request->cancel(); // connection closed
                if (routing && item.status.category != "closed" && item.status.category != "stopped") {
                    // the model was unloaded or removed during the request
                    res->error(format_error_response(item.status.message, ERROR_TYPE_SERVER));
                }
            }
            return res;
        }
    }

    const int32_t sse_ping_interval = state->sse_ping_interval;
    auto format = [type = state->format](const json & value) {
        if (type == TASK_RESPONSE_TYPE_ANTHROPIC) { return format_anthropic_sse(value); }
        if (type == TASK_RESPONSE_TYPE_OAI_RESP) { return format_oai_resp_sse(value); }
        return format_oai_sse(value);
    };
    auto format_error = [type = state->format](const json & value) {
        return type == TASK_RESPONSE_TYPE_ANTHROPIC
            ? format_anthropic_sse({{"event", "error"}, {"data", value}})
            : format_oai_sse(json {{"error", value}});
    };
    json first_json = first.result ? first.result->to_json() : json();
    res->data = first_json == nullptr ? "" : format(first_json);
    res->status = 200;
    res->content_type = "text/event-stream";
    res->set_next([res_this = res.get(), state, error_json, sse_ping_interval, format, format_error](std::string & output) -> bool {
        try {
            if (res_this->should_stop()) {
                res_this->engine_request->cancel();
                return false;
            }
            if (!res_this->data.empty()) {
                output = std::move(res_this->data);
                res_this->data.clear();
                return true;
            }
            const int64_t start_time = ggml_time_ms();
            for (;;) {
                if (res_this->should_stop()) {
                    res_this->engine_request->cancel();
                    return false;
                }
                auto item = state->read_native(std::chrono::seconds(HTTP_POLLING_SECONDS));
                if (item.status.type == llama_engine::event_type::timeout) {
                    if (sse_ping_interval > 0 && ggml_time_ms() - start_time > (int64_t) sse_ping_interval * 1000) {
                        // keep clients with idle timeouts connected
                        output = ":\n\n";
                        return true;
                    }
                    continue;
                }
                if (item.result) {
                    output = format(item.result->to_json());
                    return true;
                }
                output = item.status.type == llama_engine::event_type::error
                    ? format_error(error_json(item.status)) : "";
                if (item.status.type == llama_engine::event_type::success &&
                    state->format != TASK_RESPONSE_TYPE_NONE && state->format != TASK_RESPONSE_TYPE_OAI_RESP &&
                    state->format != TASK_RESPONSE_TYPE_ANTHROPIC) { output = "data: [DONE]\n\n"; }
                return false;
            }
        } catch (const std::exception & e) {
            output = format_error(format_error_response(e.what(), ERROR_TYPE_SERVER));
            return false;
        }
    });
    return res;
}

std::unique_ptr<server_res_generator> server_routes::create_response(bool bypass_sleep) {
    return std::make_unique<server_res_generator>(queue_tasks, params.sleep_idle_seconds, bypass_sleep);
}

server_routes::server_routes(const common_params & params, server_context & ctx_server)
        : params(params),
          ctx_server(ctx_server),
          queue_tasks(ctx_server.tasks()) {
    init_routes();


}

json server_routes::get_model_info() const {
    return llama_engine::detail::engine_model_info(*meta);
}

void server_routes::init_routes() {
    // handle_operation pins model resources through preparation and admission.
    // Transport-only guards use create_response() with the historical sleep policy.

    this->get_health = [this](const server_http_req &) {
        // error and loading states are handled by middleware
        auto res = create_response(true);

        // this endpoint can be accessed during sleeping
        // the next LOC is to avoid someone accidentally use ctx_server
        bool ctx_server; // do NOT delete this line
        GGML_UNUSED(ctx_server);

        res->ok({{"status", "ok"}});
        return res;
    };

    this->get_metrics = [this](const server_http_req & req) {
        if (!(routing ? routing->host_params(req.get_param("model")) : params).endpoint_metrics) {
            auto res = create_response(true);
            res->error(format_error_response("This server does not support metrics endpoint. Start it with `--metrics`", ERROR_TYPE_NOT_SUPPORTED));
            return res;
        }
        return handle_operation(req, llama_engine::operation::metrics, json::object(), {}, true);
    };

    this->get_slots = [this](const server_http_req & req) {
        if (!(routing ? routing->host_params(req.get_param("model")) : params).endpoint_slots) {
            auto res = create_response();
            res->error(format_error_response("This server does not support slots endpoint. Start it with `--slots`", ERROR_TYPE_NOT_SUPPORTED));
            return res;
        }
        return handle_operation(req, llama_engine::operation::slots, {{"fail_on_no_slot", !req.get_param("fail_on_no_slot").empty()}}, {}, true);
    };

    this->post_slots = [this](const server_http_req & req) {
        auto res = create_response(routing.has_value());
        // with several models, each model's slot directory is checked by the engine
        if (!routing && params.slot_save_path.empty()) {
            res->error(format_error_response("This server does not support slots action. Start it with `--slot-save-path`", ERROR_TYPE_NOT_SUPPORTED));
            return res;
        }

        std::string id_slot_str = req.get_param("id_slot");

        int id_slot;
        try {
            id_slot = std::stoi(id_slot_str);
        } catch (const std::exception &) {
            res->error(format_error_response("Invalid slot ID", ERROR_TYPE_INVALID_REQUEST));
            return res;
        }

        std::string action = req.get_param("action");

        if (action == "save") {
            return handle_slots_save(req, id_slot);
        }
        if (action == "restore") {
            return handle_slots_restore(req, id_slot);
        }
        if (action == "erase") {
            return handle_slots_erase(req, id_slot);
        }

        res->error(format_error_response("Invalid action", ERROR_TYPE_INVALID_REQUEST));
        return res;
    };

    this->get_props = [this](const server_http_req & req) {
        return handle_operation(req, llama_engine::operation::properties, json::object(), {}, true);
    };

    this->post_props = [this](const server_http_req & req) {
        auto res = create_response(routing.has_value());
        const auto model = [&] {
            const json body = json::parse(req.body);
            return body.is_object() ? json_value(body, "model", std::string()) : std::string();
        };
        if (!(routing ? routing->host_params(model()) : params).endpoint_props) {
            res->error(format_error_response("This server does not support changing global properties. Start it with `--props`", ERROR_TYPE_NOT_SUPPORTED));
            return res;
        }
        return handle_operation(req, llama_engine::operation::properties_update, json::object());
    };

    this->post_infill = [this](const server_http_req & req) {
        return handle_operation(req, llama_engine::operation::infill);
    };

    this->post_completions = [this](const server_http_req & req) {
        return handle_operation(req, llama_engine::operation::completion);
    };

    this->post_completions_oai = [this](const server_http_req & req) {
        return handle_operation(req, llama_engine::operation::completions);
    };

    this->post_chat_completions = [this](const server_http_req & req) {
        return handle_operation(req, llama_engine::operation::chat);
    };

    this->post_chat_completions_tok = [this](const server_http_req & req) {
        return handle_operation(req, llama_engine::operation::chat_tokens);
    };

    this->post_control = [this](const server_http_req & req) {
        return handle_operation(req, llama_engine::operation::control);
    };

    this->post_responses_oai = [this](const server_http_req & req) {
        return handle_operation(req, llama_engine::operation::responses);
    };

    this->post_responses_tok_oai = [this](const server_http_req & req) {
        return handle_operation(req, llama_engine::operation::response_tokens);
    };

    this->post_transcriptions_oai = [this](const server_http_req & req) {
        std::vector<llama_engine::attachment> files;
        for (const auto & file : req.files) { files.push_back({file.first, file.second.data}); }
        return handle_operation(req, llama_engine::operation::transcription, nullptr, files);
    };

    this->post_anthropic_messages = [this](const server_http_req & req) {
        return handle_operation(req, llama_engine::operation::messages);
    };

    this->post_anthropic_count_tokens = [this](const server_http_req & req) {
        return handle_operation(req, llama_engine::operation::message_tokens);
    };

    // same with handle_chat_completions, but without inference part
    this->post_apply_template = [this](const server_http_req & req) {
        return handle_operation(req, llama_engine::operation::apply_template);
    };

    this->get_models = [this](const server_http_req & req) {
        return handle_operation(req, llama_engine::operation::models, json::object(), {}, true);
    };

    this->post_tokenize = [this](const server_http_req & req) {
        return handle_operation(req, llama_engine::operation::tokenize);
    };

    this->post_detokenize = [this](const server_http_req & req) {
        return handle_operation(req, llama_engine::operation::detokenize);
    };

    this->post_embeddings = [this](const server_http_req & req) {
        return handle_operation(req, llama_engine::operation::embeddings);
    };

    this->post_embeddings_oai = [this](const server_http_req & req) {
        return handle_operation(req, llama_engine::operation::embeddings_openai);
    };

    this->post_rerank = [this](const server_http_req & req) {
        return handle_operation(req, llama_engine::operation::rerank);
    };

    this->get_lora_adapters = [this](const server_http_req & req) {
        return handle_operation(req, llama_engine::operation::lora_list, json::object(), {}, true);
    };

    this->post_lora_adapters = [this](const server_http_req & req) {
        return handle_operation(req, llama_engine::operation::lora_apply);
    };
}

std::unique_ptr<server_res_generator> server_routes::handle_slots_save(const server_http_req & req, int id_slot) {
    json body = json::parse(req.body);
    body["id_slot"] = id_slot;
    return handle_operation(req, llama_engine::operation::slot_save, body);
}

std::unique_ptr<server_res_generator> server_routes::handle_slots_restore(const server_http_req & req, int id_slot) {
    json body = json::parse(req.body);
    body["id_slot"] = id_slot;
    return handle_operation(req, llama_engine::operation::slot_restore, body);
}

std::unique_ptr<server_res_generator> server_routes::handle_slots_erase(const server_http_req & req, int id_slot) {
    // the body names the model when there are several
    json body = routing ? json::parse(req.body) : json::object();
    body["id_slot"] = id_slot;
    return handle_operation(req, llama_engine::operation::slot_erase, body);
}
