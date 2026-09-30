#pragma once
#include "../../engine/engine-context.h"
#include "engine-runtime.h"
#include "server-http.h"

#include <optional>

// forward declarations
struct server_res_generator;

// Multi-model mode: every request names its model, served by the engine's
// catalog in this process (see server-models.h). Unset with one model.
struct server_model_routing {
    // Admits the request for the named model (it may wait for the model to load).
    std::function<std::shared_ptr<llama_engine::detail::request_state>(const server_http_req & req,
            llama_engine::operation op, const std::string & model, json data,
            std::vector<llama_engine::attachment> files)> submit;
    // Called once the request stopped waiting: first result, error or cancellation.
    std::function<void(const server_http_req & req)> started;
    // Server parameters with the host options of that model (endpoint guards).
    std::function<common_params(const std::string & model)> host_params;
};

struct server_routes {
    server_routes(const common_params & params, server_context & ctx_server);

    void init_routes();

    // note: this is not thread-safe and can only when ctx_http.is_ready is false
    void update_meta(const server_context & ctx_server) {
        this->meta = std::make_unique<server_context_meta>(ctx_server.get_meta());
    }

    // handlers using lambda function, so that they can capture `this` without `std::bind`
    // they won't be called until ctx_http.is_ready is set to true
    server_http_context::handler_t get_health;
    server_http_context::handler_t get_metrics;
    server_http_context::handler_t get_slots;
    server_http_context::handler_t post_slots;
    server_http_context::handler_t get_props;
    server_http_context::handler_t post_props;
    server_http_context::handler_t post_infill;
    server_http_context::handler_t post_completions;
    server_http_context::handler_t post_completions_oai;
    server_http_context::handler_t post_chat_completions;
    server_http_context::handler_t post_chat_completions_tok;
    server_http_context::handler_t post_control;
    server_http_context::handler_t post_responses_oai;
    server_http_context::handler_t post_responses_tok_oai;
    server_http_context::handler_t post_transcriptions_oai;
    server_http_context::handler_t post_anthropic_messages;
    server_http_context::handler_t post_anthropic_count_tokens;
    server_http_context::handler_t post_apply_template;
    server_http_context::handler_t get_models;
    server_http_context::handler_t post_tokenize;
    server_http_context::handler_t post_detokenize;
    server_http_context::handler_t post_embeddings;
    server_http_context::handler_t post_embeddings_oai;
    server_http_context::handler_t post_rerank;
    server_http_context::handler_t get_lora_adapters;
    server_http_context::handler_t post_lora_adapters;

    // to be used in router mode
    json get_model_info() const;

    // multi-model mode, set before the routes are used
    std::optional<server_model_routing> routing;

private:
    // With routing, the model is the "model" field of the body, or the "model"
    // query parameter when model_in_query (GET routes).
    std::unique_ptr<server_res_generator> handle_operation(const server_http_req & req,
            llama_engine::operation op, const json & body = nullptr,
            const std::vector<llama_engine::attachment> & files = {}, bool model_in_query = false);
    std::unique_ptr<server_res_generator> handle_slots_save(const server_http_req & req, int id_slot);
    std::unique_ptr<server_res_generator> handle_slots_restore(const server_http_req & req, int id_slot);
    std::unique_ptr<server_res_generator> handle_slots_erase(const server_http_req &, int id_slot);

    // using unique_ptr to allow late initialization of const
    std::unique_ptr<const server_context_meta> meta;

    const common_params & params;
    server_context & ctx_server;

    server_queue & queue_tasks;
    std::unique_ptr<server_res_generator> create_response(bool bypass_sleep = false);

};
