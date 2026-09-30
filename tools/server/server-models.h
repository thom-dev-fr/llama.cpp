#pragma once

#include "common.h"
#include "server-common.h"
#include "server-context.h"
#include "server-http.h"
#include "engine-models.h"

#include <atomic>
#include <map>
#include <memory>
#include <mutex>
#include <string>

// Multi-model mode ("router mode"). The models run in this process, in the
// engine's catalog (engine/engine-models.h): no child process and no port per
// model. This adapter reads the catalog sources from the command line, the
// environment and the configuration files, serves the /models routes and
// translates the catalog events into the /models/sse events of the former
// process router. Fields that described a child process are adapted as
// documented in README-dev.md ("Multi-model mode").
struct server_models_routes {
    // Throws when the catalog cannot be read (conflicting aliases, invalid
    // shared options) or when load-on-startup models exceed --models-max.
    server_models_routes(const common_params & params, int argc, char ** argv);
    ~server_models_routes();

    // Model selection for the inference routes (server_routes::routing).
    server_model_routing routing();

    // Starts loading the models marked load-on-startup (in the background).
    void load_startup_models();

    // Ends the requests, the waiting requests and the SSE clients, then frees
    // every model. Idempotent.
    void stop();

    std::atomic<bool> stopping = false; // disconnects SSE clients during shutdown

    server_http_context::handler_t get_router_props;
    server_http_context::handler_t get_router_models;
    server_http_context::handler_t post_router_models_load;
    server_http_context::handler_t post_router_models_unload;
    server_http_context::handler_t get_router_models_sse;
    server_http_context::handler_t post_router_models;
    server_http_context::handler_t del_router_models;

    // the server's resumable stream routes, aware of requests waiting for their model
    server_http_context::handler_t stream_get;
    server_http_context::handler_t streams_lookup;
    server_http_context::handler_t stream_delete;

private:
    // server parameters with the host options of one model (endpoint guards,
    // HTTP-facing defaults of its requests and properties)
    common_params host_params(const llama_engine::model_entry & entry) const;
    common_params host_params(const std::string & model) const;
    void log_models(const std::vector<llama_engine::model_entry> & entries) const;
    void warn_host_options(const std::vector<llama_engine::model_entry> & entries) const;
    void init_routes();

    // conversations whose request waits for its model, see stream_get
    void remember_conv(const std::string & conv_id, const std::string & model);
    void forget_conv(const std::string & conv_id, bool all);
    std::string pending_conv(const std::string & conv_id);

    common_params params;
    json ui_settings = json::object();
    std::map<std::string, std::string> base_options; // the server's command line, over every model
    bool debug_fake_timing = false;
    std::shared_ptr<llama_engine::detail::model_manager> models;

    struct conv_entry {
        std::string model;
        int count = 0;
    };
    std::mutex conv_mutex;
    std::map<std::string, conv_entry> pending_convs;
};
