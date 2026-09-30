#include "server-models.h"
#include "server-stream.h"

#include "engine-options.h"

#include "arg.h"
#include "build-info.h"
#include "preset.h"

#include <chrono>
#include <ctime>
#include <limits>
#include <set>
#include <thread>
#include <tuple>

using llama_engine::detail::model_manager;
using llama_engine::detail::option_scope;

namespace {

// options of the server's command line that belong to the server or name a model
const char * const reserved_envs[] = {
    "LLAMA_ARG_SSL_KEY_FILE", "LLAMA_ARG_SSL_CERT_FILE", "LLAMA_API_KEY", "LLAMA_ARG_API_KEY_FILE",
    "LLAMA_ARG_MODELS_DIR", "LLAMA_ARG_MODELS_MAX", "LLAMA_ARG_MODELS_PRESET", "LLAMA_ARG_MODELS_AUTOLOAD",
    "LLAMA_ARG_LOG_FILE", "LLAMA_ARG_MODEL", "LLAMA_ARG_MMPROJ", "LLAMA_ARG_ALIAS", "LLAMA_ARG_HF_REPO",
};

const common_preset_context & preset_context() {
    static const common_preset_context ctx(LLAMA_EXAMPLE_SERVER);
    return ctx;
}

// options that describe one model's files, never shared by every model
bool names_a_model(const std::string & key) {
    static const std::set<std::string> keys = {
        "model", "model-url", "hf-repo", "hf-file", "docker-repo", "mmproj", "mmproj-url",
    };
    return keys.count(key) > 0;
}

// The server's command line, applied over every model like the former router
// passed it to each child process.
std::map<std::string, std::string> command_line_options(int argc, char ** argv) {
    std::map<std::string, std::string> out;
    if (argv == nullptr) {
        return out;
    }
    common_preset base = preset_context().load_from_args(argc, argv);
    for (const char * env : reserved_envs) {
        base.unset_option(env);
    }
    for (const auto & [opt, value] : base.options) {
        const std::string key = llama_engine::detail::option_key(opt);
        const option_scope * scope = llama_engine::detail::find_option_scope(key);
        if (!scope || *scope == option_scope::catalog) {
            SRV_WRN("option '%s' of the command line is not applied to each model\n", key.c_str());
            continue;
        }
        out[key] = value;
    }
    return out;
}

// The configuration files and LLAMA_ARG_* variables that each child process
// read before its command line: explicit defaults under every model.
std::map<std::string, std::string> environment_options() {
    std::map<std::string, std::string> out;
    for (const auto & [opt, value] : preset_context().load_from_env().options) {
        const std::string key = llama_engine::detail::option_key(opt);
        const option_scope * scope = llama_engine::detail::find_option_scope(key);
        if (scope && *scope == option_scope::engine && !names_a_model(key)) {
            out[key] = value;
        }
    }
    return out;
}

// Fields of the host's parameters that a model's requests and properties read.
template <typename params_t>
auto host_fields(params_t & p) {
    return std::tie(p.sse_ping_interval, p.verbosity, p.ui, p.ui_config_json, p.ui_mcp_proxy,
                    p.endpoint_slots, p.endpoint_props, p.endpoint_metrics);
}

void copy_host_fields(common_params & dst, const common_params & src) {
    host_fields(dst) = host_fields(src);
}

// Status of the former process router: an instance being freed was still running.
std::string http_status(const std::string & status) {
    return status == "unloading" ? "loaded" : status;
}

bool is_running(const std::string & status) {
    return status == "loading" || status == "loaded" || status == "sleeping" || status == "unloading";
}

void res_ok(std::unique_ptr<server_http_res> & res, const json & data) {
    res->status = 200;
    res->data = safe_json_to_str(data);
}

void res_err(std::unique_ptr<server_http_res> & res, const json & error) {
    res->status = json_value(error, "code", 500);
    res->data = safe_json_to_str({{"error", error}});
}

json to_server_json(const llama_engine::json & value) {
    return json::parse(value.dump());
}

// LLAMA_SERVER_DEBUG_FAKE_TIMING: the delays of the former router, which let
// tests observe queued, loading and busy models.
struct delayed_backend : llama_engine::detail::model_backend {
    std::shared_ptr<model_backend> inner;
    explicit delayed_backend(std::shared_ptr<model_backend> inner) : inner(std::move(inner)) {}
    bool load(std::string & error) override {
        std::this_thread::sleep_for(std::chrono::seconds(2));
        return inner->load(error);
    }
    void cancel_load() override { inner->cancel_load(); }
    void submit(const std::shared_ptr<llama_engine::detail::request_state> & state, const json & data,
                llama_engine::operation op, const std::vector<llama_engine::attachment> & files) override {
        std::this_thread::sleep_for(std::chrono::seconds(2)); // the model is busy meanwhile
        inner->submit(state, data, op, files);
    }
    void stop(const llama_engine::event & reason) override { inner->stop(reason); }
    llama_engine::json info() override { return inner->info(); }
};

// Catalog events of one SSE client, as the events of the former router.
struct sse_translator {
    std::map<std::string, std::string> last; // status per model already reported
    std::map<std::string, json> downloads;   // progress per model and URL

    void reset(const llama_engine::json & models) {
        last.clear();
        for (const auto & m : models) {
            last[m.at("id").get<std::string>()] = m.at("status").get<std::string>();
        }
    }

    static json make(const std::string & event, const std::string & model, const json & data = nullptr) {
        json out = {{"model", model}, {"event", event}};
        if (!data.is_null()) {
            out["data"] = data;
        }
        return out;
    }

    std::vector<json> translate(const llama_engine::json & ev) {
        std::vector<json> out;
        const std::string type = ev.value("type", "");
        if (type == "snapshot") {
            reset(ev.at("models"));
        } else if (type == "reload" || type == "resync") {
            reset(ev.at("models"));
            out.push_back(make("models_reload", "*"));
        } else if (type == "remove") {
            out.push_back(make("model_remove", ev.at("model").get<std::string>(), json::object()));
        } else if (type == "download") {
            const std::string model = ev.at("model").get<std::string>();
            downloads.erase(model);
            last.erase(model);
            const bool ok = ev.value("result", "") == "finished";
            out.push_back(make(ok ? "download_finished" : "download_failed", model, json::object()));
        } else if (type == "progress") {
            const std::string model = ev.at("model").get<std::string>();
            const auto & progress = ev.at("progress");
            if (progress.value("stage", "") == "download") {
                if (last[model] != "downloading") {
                    return out; // a resource fetched while loading: the router did not report it
                }
                json & info = downloads[model];
                info["progress"][progress.value("url", "")] = {
                    {"done",  progress.value("downloaded", (int64_t) 0)},
                    {"total", progress.value("total", (int64_t) 0)},
                };
                out.push_back(make("download_progress", model, info));
            } else {
                out.push_back(make("status_change", model, {{"status", "loading"}, {"progress", to_server_json(progress)}}));
            }
        } else if (type == "status") {
            const std::string model  = ev.at("model").get<std::string>();
            const std::string status = ev.at("status").get<std::string>();
            std::string & previous = last[model];
            if (status == "unloading" || status == previous) {
                return out; // still resident, or only the number of waiting requests changed
            }
            if (status == "loading" || status == "downloading") {
                out.push_back(make("model_status", model, {{"status", status}}));
            } else {
                json data = {{"status", status}};
                if (status == "loaded" && previous != "sleeping" && ev.contains("info")) {
                    data["info"] = to_server_json(ev.at("info"));
                }
                if (status == "failed") {
                    data["error"] = ev.value("error", "");
                }
                out.push_back(make("status_change", model, data));
            }
            previous = status;
        }
        return out;
    }
};

} // namespace

server_models_routes::server_models_routes(const common_params & params_, int argc, char ** argv)
        : params(params_) {
    const std::string & cfg = params.ui_config_json;
    if (!cfg.empty()) {
        try {
            ui_settings = json::parse(cfg);
        } catch (const std::exception & e) {
            LOG_ERR("%s: failed to parse UI config: %s\n", __func__, e.what());
            throw;
        }
    }
    debug_fake_timing = !common_get_env("LLAMA_SERVER_DEBUG_FAKE_TIMING").empty();
    base_options = command_line_options(argc, argv);

    llama_engine::catalog_sources sources;
    sources.cache      = true;
    sources.models_dir = params.models_dir;
    sources.presets    = params.models_preset;
    sources.options    = base_options;
    sources.defaults   = environment_options();

    llama_engine::catalog_config catalog;
    catalog.max_loaded   = params.models_max;
    catalog.autoload     = params.models_autoload;
    catalog.wait_timeout = std::chrono::hours(24 * 365 * 100); // requests wait for their model as long as it takes
    catalog.max_waiting  = std::numeric_limits<size_t>::max();
    catalog.max_subscriber_events = 4096; // a slower SSE client receives models_reload
    catalog.sources      = sources;

    // like the single-model server: no admission, event or size limit per model
    const auto adjust = [](llama_engine::model_entry & entry) {
        entry.settings.max_tasks         = std::numeric_limits<size_t>::max();
        entry.settings.max_events        = std::numeric_limits<size_t>::max();
        entry.settings.max_request_bytes = std::numeric_limits<size_t>::max();
    };
    const auto factory = [this](const llama_engine::model_entry & entry, llama_engine::detail::backend_hooks hooks) {
        const common_params host = host_params(entry);
        hooks.host_params = [host, id = entry.id, tags = entry.tags](common_params & p) {
            copy_host_fields(p, host);
            p.model_alias = {id}; // requests and responses name the model as the catalog does
            p.model_tags  = std::set<std::string>(tags.begin(), tags.end());
        };
        auto backend = llama_engine::detail::make_context_backend(entry, std::move(hooks));
        if (debug_fake_timing) {
            backend = std::make_shared<delayed_backend>(std::move(backend));
        }
        return backend;
    };
    llama_engine::event error;
    models = llama_engine::detail::make_catalog_manager(catalog, factory, adjust, error);
    if (!models) {
        throw std::runtime_error(error.message);
    }

    const auto entries = models->entries();
    log_models(entries);
    warn_host_options(entries);
    size_t n_startup = 0;
    for (const auto & entry : entries) {
        n_startup += entry.load_on_startup ? 1 : 0;
    }
    if (params.models_max > 0 && (int) n_startup > params.models_max) {
        models->stop();
        throw std::runtime_error(string_format("number of models to load on startup (%zu) exceeds models_max (%d)",
                                               n_startup, params.models_max));
    }
    init_routes();
}

server_models_routes::~server_models_routes() {
    stop();
}

void server_models_routes::stop() {
    stopping.store(true);
    if (models) {
        models->stop();
    }
}

void server_models_routes::load_startup_models() {
    for (const auto & entry : models->entries()) {
        if (entry.load_on_startup) {
            SRV_INF("(startup) loading model %s\n", entry.id.c_str());
            models->load(entry.id); // loads in the background; the handle is not needed
        }
    }
}

common_params server_models_routes::host_params(const llama_engine::model_entry & entry) const {
    common_params out = params;
    if (!entry.host_options.empty()) {
        try {
            preset_context().load_from_map(entry.id, entry.host_options).apply_to_params(out);
        } catch (const std::exception & e) {
            SRV_WRN("host options of model '%s' are ignored: %s\n", entry.id.c_str(), e.what());
            out = params;
        }
    }
    return out;
}

common_params server_models_routes::host_params(const std::string & model) const {
    auto entry = models->entry(model);
    return entry ? host_params(*entry) : params;
}

void server_models_routes::log_models(const std::vector<llama_engine::model_entry> & entries) const {
    auto join = [](const std::vector<std::string> & values) {
        std::string out;
        for (const auto & v : values) {
            out += (out.empty() ? "" : ", ") + v;
        }
        return out;
    };
    SRV_INF("Available models (%zu):\n", entries.size());
    if (entries.empty()) {
        SRV_INF("%s", "  no models found on the system (visit https://llama.app/models for suggestions)\n");
    }
    for (const auto & entry : entries) {
        std::string info;
        if (!entry.aliases.empty()) info += " (aliases: " + join(entry.aliases) + ")";
        if (!entry.tags.empty())    info += " [tags: "    + join(entry.tags)    + "]";
        SRV_INF("  [%10s] %s%s\n", entry.source.c_str(), entry.id.c_str(), info.c_str());
    }
}

void server_models_routes::warn_host_options(const std::vector<llama_engine::model_entry> & entries) const {
    // A child process applied its own server, process and logging options; in
    // one process, only the options that its requests and properties read apply.
    for (const auto & entry : entries) {
        for (const auto & [key, value] : entry.host_options) {
            auto base = base_options.find(key);
            if ((base != base_options.end() && base->second == value) || key == "stop-timeout") {
                continue; // the server's own option, or an unload delay without a process to kill
            }
            common_params p = params;
            try {
                preset_context().load_from_map(entry.id, {{key, value}}).apply_to_params(p);
            } catch (const std::exception &) {
                // reported when the model is used
            }
            if (host_fields(p) == host_fields(params)) {
                SRV_WRN("model '%s': option '%s' has no effect per model, models run in the server process\n",
                        entry.id.c_str(), key.c_str());
            }
        }
    }
}

void server_models_routes::remember_conv(const std::string & conv_id, const std::string & model) {
    std::lock_guard<std::mutex> lock(conv_mutex);
    auto & entry = pending_convs[conv_id];
    entry.model = model;
    entry.count++;
}

void server_models_routes::forget_conv(const std::string & conv_id, bool all) {
    std::lock_guard<std::mutex> lock(conv_mutex);
    auto it = pending_convs.find(conv_id);
    if (it != pending_convs.end() && (all || --it->second.count <= 0)) {
        pending_convs.erase(it);
    }
}

std::string server_models_routes::pending_conv(const std::string & conv_id) {
    std::lock_guard<std::mutex> lock(conv_mutex);
    auto it = pending_convs.find(conv_id);
    return it == pending_convs.end() ? std::string() : it->second.model;
}

server_model_routing server_models_routes::routing() {
    server_model_routing out;
    out.submit = [this](const server_http_req & req, llama_engine::operation op, const std::string & model,
                        json data, std::vector<llama_engine::attachment> files) {
        const std::string conv_id = server_stream_conv_id_from_headers(req.headers);
        if (!conv_id.empty()) {
            remember_conv(conv_id, model);
        }
        std::optional<bool> autoload;
        const std::string value = req.get_param("autoload");
        if (!value.empty()) {
            autoload = value == "true" || value == "1";
        }
        return models->submit_native(op, std::move(data), std::move(files), autoload);
    };
    out.started = [this](const server_http_req & req) {
        const std::string conv_id = server_stream_conv_id_from_headers(req.headers);
        if (!conv_id.empty()) {
            forget_conv(conv_id, false);
        }
    };
    out.host_params = [this](const std::string & model) {
        return host_params(model);
    };
    return out;
}

void server_models_routes::init_routes() {
    this->get_router_props = [this](const server_http_req &) {
        auto res = std::make_unique<server_http_res>();
        res_ok(res, {
            // TODO: add support for this on web UI
            {"role",                 "router"},
            {"max_instances",        params.models_max},
            {"models_autoload",      params.models_autoload},
            // this is a dummy response to make sure the UI doesn't break
            {"model_alias", "llama-server"},
            {"model_path",  "none"},
            {"default_generation_settings", {
                {"params", json{}},
                {"n_ctx",  0},
            }},
            // New key
            {"ui_settings",          ui_settings},
            {"build_info",           std::string(llama_build_info())},
            {"cors_proxy_enabled",   params.ui_mcp_proxy},
        });
        return res;
    };

    this->get_router_models = [this](const server_http_req & req) {
        if (!req.get_param("reload", "").empty()) {
            const auto reloaded = models->reload();
            if (reloaded.type != llama_engine::event_type::success) {
                throw std::runtime_error(reloaded.message);
            }
            const auto entries = models->entries();
            log_models(entries);
            warn_host_options(entries);
        }
        std::map<std::string, llama_engine::model_entry> entries;
        for (auto & entry : models->entries()) {
            entries.emplace(entry.id, std::move(entry));
        }
        const auto catalog = models->catalog();
        const std::time_t t = std::time(0);
        json data = json::array();
        for (const auto & item : catalog) {
            if (item.value("hidden", false)) {
                continue; // cache model deduplicated by a preset
            }
            const std::string id     = item.at("id").get<std::string>();
            const std::string status = item.at("status").get<std::string>();
            // the model's configuration as an INI section and as the equivalent
            // arguments; nothing is launched, so no binary, host or port
            json status_json {
                {"value", http_status(status)},
                {"args",  json::array()},
            };
            auto entry = entries.find(id);
            if (entry != entries.end() && !(entry->second.settings.options.empty() && entry->second.host_options.empty())) {
                try {
                    std::map<std::string, std::string> options = entry->second.settings.options;
                    options.insert(entry->second.host_options.begin(), entry->second.host_options.end());
                    common_preset preset = preset_context().load_from_map(id, options);
                    for (const char * env : reserved_envs) {
                        preset.unset_option(env);
                    }
                    preset.unset_option("LLAMA_ARG_HOST");
                    preset.unset_option("LLAMA_ARG_PORT");
                    preset.unset_option("LLAMA_ARG_TAGS");
                    status_json["args"]   = preset.to_args();
                    status_json["preset"] = preset.to_ini();
                } catch (const std::exception & e) {
                    SRV_WRN("cannot render the configuration of model '%s': %s\n", id.c_str(), e.what());
                }
            }
            if (status == "failed") {
                // no process, hence no exit code: the error of the load instead
                status_json["failed"] = true;
                status_json["error"]  = item.value("error", "");
            }

            // pi coding agent multimodal compatibility
            json input_modalities = json::array({"text"});
            if (item.contains("input_modalities")) {
                input_modalities = to_server_json(item.at("input_modalities"));
            }
            json model_info = {
                {"id",           id},
                {"aliases",      to_server_json(item.at("aliases"))},
                {"tags",         to_server_json(item.at("tags"))},
                {"object",       "model"},    // for OAI-compat
                {"owned_by",     "llamacpp"}, // for OAI-compat
                {"created",      t},          // for OAI-compat
                {"status",       status_json},
                {"architecture", {
                    {"input_modalities",  input_modalities},
                    {"output_modalities", json::array({"text"})},
                }},
                {"source",       item.value("source", "cache")},
                {"can_remove",   item.value("source", "cache") == "cache"},
            };
            // metadata of the resident model
            if (item.contains("info")) {
                const json info = to_server_json(item.at("info"));
                for (auto it = info.begin(); it != info.end(); ++it) {
                    if (!model_info.contains(it.key())) {
                        model_info[it.key()] = it.value();
                    }
                }
            }
            data.push_back(model_info);
        }
        auto res = std::make_unique<server_http_res>();
        res_ok(res, {
            {"data",   data},
            {"object", "list"},
        });
        return res;
    };

    this->post_router_models_load = [this](const server_http_req & req) {
        auto res = std::make_unique<server_http_res>();
        const json body = json::parse(req.body);
        const std::string name = json_value(body, "model", std::string());
        const auto entry = models->entry(name);
        if (!entry) {
            res_err(res, format_error_response("model is not found", ERROR_TYPE_NOT_FOUND));
            return res;
        }
        if (is_running(models->status_of(entry->id))) {
            res_err(res, format_error_response("model is already running", ERROR_TYPE_INVALID_REQUEST));
            return res;
        }
        // waits for a slot and loads in the background; progress goes to /models/sse
        SRV_INF("loading model name=%s\n", entry->id.c_str());
        models->load(entry->id);
        res_ok(res, {{"success", true}});
        return res;
    };

    this->post_router_models_unload = [this](const server_http_req & req) {
        auto res = std::make_unique<server_http_res>();
        const json body = json::parse(req.body);
        const std::string name = json_value(body, "model", std::string());
        const auto entry = models->entry(name);
        if (!entry) {
            res_err(res, format_error_response("model is not found", ERROR_TYPE_INVALID_REQUEST));
            return res;
        }
        const std::string status = models->status_of(entry->id);
        if (!is_running(status) && status != "downloading") {
            res_err(res, format_error_response("model is not running", ERROR_TYPE_INVALID_REQUEST));
            return res;
        }
        SRV_INF("stopping model instance name=%s\n", entry->id.c_str());
        // ends its requests and waiters, then frees it before answering
        const auto unloaded = models->unload(entry->id);
        if (unloaded.type == llama_engine::event_type::error && unloaded.category != "model_not_loaded") {
            throw std::runtime_error(unloaded.message);
        }
        res_ok(res, {{"success", true}});
        return res;
    };

    this->get_router_models_sse = [this](const server_http_req & req) {
        auto res = std::make_unique<server_http_res>();
        res->status = 200;
        res->content_type = "text/event-stream";
        auto sub = std::make_shared<llama_engine::subscription>(models->subscribe());
        auto translator = std::make_shared<sse_translator>();
        res->next = [this, sub, translator, &req](std::string & output) -> bool {
            while (true) {
                const auto ev = sub->next_for(std::chrono::seconds(1)); // check should_stop every second
                if (ev.type == llama_engine::event_type::timeout) {
                    if (stopping.load(std::memory_order_relaxed) || req.should_stop()) {
                        return false; // client disconnected or server stopping
                    }
                    continue;
                }
                if (ev.terminal()) {
                    return false; // engine stopped
                }
                for (const auto & item : translator->translate(ev.data)) {
                    SRV_DBG("notifying SSE client: %s\n", safe_json_to_str(item).c_str());
                    output += "data: " + safe_json_to_str(item) + "\n\n";
                }
                if (!output.empty()) {
                    return true; // listen for the next event
                }
            }
        };
        return res;
    };

    this->post_router_models = [this](const server_http_req & req) {
        auto res = std::make_unique<server_http_res>();
        const json body = json::parse(req.body);
        const std::string name = json_value(body, "model", std::string());
        if (name.empty()) {
            throw std::invalid_argument("model must be a non-empty string");
        }
        std::map<std::string, std::string> options;
        if (!params.hf_token.empty()) {
            options["hf-token"] = params.hf_token;
        }
        SRV_INF("starting download for model '%s'\n", name.c_str());
        // metadata is validated before returning; the download continues in the background
        auto state = models->download(name, options);
        const auto early = state->read(std::chrono::milliseconds(0));
        if (early.type == llama_engine::event_type::error) {
            if (early.category == "invalid_request") {
                throw std::invalid_argument(early.message);
            }
            throw std::runtime_error(early.message);
        }
        res_ok(res, {{"success", true}});
        return res;
    };

    this->del_router_models = [this](const server_http_req & req) {
        auto res = std::make_unique<server_http_res>();
        const std::string name = req.get_param("model");
        if (name.empty()) {
            throw std::invalid_argument("model must be a non-empty string");
        }
        const auto removed = models->remove(name);
        if (removed.type == llama_engine::event_type::error) {
            if (removed.category == "model_not_found") {
                throw std::runtime_error("model name=" + name + " is not found");
            }
            if (removed.category == "invalid_request") {
                throw std::runtime_error("model name=" + name + " is not removable (not from cache)");
            }
            throw std::runtime_error(removed.message);
        }
        res_ok(res, {{"success", true}});
        return res;
    };

    // The sessions are the server's own; a request that waits for its model has
    // no stream yet: clients are asked to retry, as the former router did.
    auto local_get    = server_stream_make_get_handler();
    auto local_lookup = server_stream_make_lookup_handler();
    auto local_delete = server_stream_make_delete_handler();

    this->stream_get = [this, local_get](const server_http_req & req) {
        const std::string model = pending_conv(req.get_param("conv_id"));
        if (!model.empty()) {
            const std::string status = models->status_of(model);
            if (status != "loaded" && status != "sleeping") {
                auto res = std::make_unique<server_http_res>();
                res_err(res, format_error_response("Stream owner model is loading, retry later", ERROR_TYPE_UNAVAILABLE));
                return res;
            }
        }
        return local_get(req);
    };

    this->streams_lookup = [this, local_lookup](const server_http_req & req) {
        auto res = local_lookup(req);
        if (res->status != 200) {
            return res;
        }
        json found = json::parse(res->data);
        json out = json::array();
        for (const auto & session : found) {
            if (pending_conv(json_value(session, "conversation_id", std::string())).empty()) {
                out.push_back(session);
            }
        }
        res->data = safe_json_to_str(out);
        return res;
    };

    this->stream_delete = [this, local_delete](const server_http_req & req) {
        // cancels the session, including a request still waiting for its model
        forget_conv(req.get_param("conv_id"), true);
        return local_delete(req);
    };
}
