#include "llama_bridge.h"

#include "llama-engine.h"

#include <algorithm>
#include <chrono>
#include <functional>
#include <map>
#include <memory>
#include <new>
#include <optional>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

using llama_engine::json;

struct llama_bridge_event {
    llama_engine::event_type type = llama_engine::event_type::error;
    std::string data = "null";
    std::string category;
    std::string message;
};

struct llama_bridge_engine {
    std::unique_ptr<llama_engine::engine> engine;
};

struct llama_bridge_request {
    std::unique_ptr<llama_engine::request> request;
};

struct llama_bridge_subscription {
    std::unique_ptr<llama_engine::subscription> subscription;
};

namespace {

// Invalid UTF-8 from a partial generation never makes serialization throw.
std::string dump(const json & value) {
    return value.dump(-1, ' ', false, json::error_handler_t::replace);
}

llama_bridge_event * make_event(const llama_engine::event & source) {
    auto * event = new llama_bridge_event();
    event->type = source.type;
    event->data = dump(source.data);
    event->category = source.category;
    event->message = source.message;
    return event;
}

llama_bridge_event * make_error(const std::string & category, const std::string & message) {
    auto * event = new (std::nothrow) llama_bridge_event();
    if (event) {
        event->type = llama_engine::event_type::error;
        event->category = category;
        event->message = message;
    }
    return event;
}

void set_error(llama_bridge_event ** error, llama_bridge_event * event) {
    if (error) {
        *error = event;
    } else {
        delete event;
    }
}

// Runs body; a C++ exception becomes an owned error event (never propagated).
template <typename T, typename Body>
T guarded(llama_bridge_event ** error, T failure, Body && body) {
    try {
        return body();
    } catch (const std::bad_alloc &) {
        set_error(error, make_error("out_of_memory", "out of memory"));
    } catch (const std::invalid_argument & e) {
        set_error(error, make_error("invalid_request", e.what()));
    } catch (const json::exception & e) {
        set_error(error, make_error("invalid_request", e.what()));
    } catch (const std::exception & e) {
        set_error(error, make_error("bridge_error", e.what()));
    } catch (...) {
        set_error(error, make_error("bridge_error", "unknown native exception"));
    }
    return failure;
}

// Same, for calls that report their outcome as an event.
template <typename Body>
llama_bridge_event * guarded_event(Body && body) {
    llama_bridge_event * error = nullptr;
    auto * event = guarded<llama_bridge_event *>(&error, nullptr, std::forward<Body>(body));
    return event ? event : error;
}

json parse(const char * text, const char * what) {
    if (!text) {
        throw std::invalid_argument(std::string(what) + " is NULL");
    }
    return json::parse(text);
}

std::optional<int> optional_int(const json & settings, const char * key, std::optional<int> fallback) {
    if (!settings.contains(key)) {
        return fallback;
    }
    const auto & value = settings.at(key);
    if (value.is_null()) {
        return std::nullopt; // llama.cpp's default
    }
    return value.get<int>();
}

std::string option_value(const json & value) {
    if (value.is_string()) {
        return value.get<std::string>();
    }
    if (value.is_boolean()) {
        return value.get<bool>() ? "true" : "false";
    }
    if (value.is_number()) {
        return value.dump();
    }
    throw std::invalid_argument("option values are strings, numbers or booleans");
}

llama_engine::config to_config(const json & settings) {
    llama_engine::config config;
    if (!settings.is_object()) {
        throw std::invalid_argument("model settings must be an object");
    }
    config.model_path       = settings.value("model_path", config.model_path);
    config.mmproj_path      = settings.value("mmproj_path", config.mmproj_path);
    config.chat_template    = settings.value("chat_template", config.chat_template);
    config.context_size     = optional_int(settings, "context_size", config.context_size);
    config.parallel         = optional_int(settings, "parallel", config.parallel);
    config.threads          = optional_int(settings, "threads", config.threads);
    config.gpu_layers       = optional_int(settings, "gpu_layers", config.gpu_layers);
    config.batch_size       = optional_int(settings, "batch_size", config.batch_size);
    config.micro_batch_size = optional_int(settings, "micro_batch_size", config.micro_batch_size);
    if (settings.contains("fit")) {
        config.fit = settings.at("fit").is_null() ? std::nullopt : std::optional<bool>(settings.at("fit").get<bool>());
    }
    if (settings.contains("warmup")) {
        config.warmup = settings.at("warmup").is_null() ? std::nullopt : std::optional<bool>(settings.at("warmup").get<bool>());
    }
    config.max_tasks         = settings.value("max_tasks", config.max_tasks);
    config.max_events        = settings.value("max_events", config.max_events);
    config.max_request_bytes = settings.value("max_request_bytes", config.max_request_bytes);
    if (settings.contains("options")) {
        for (const auto & [key, value] : settings.at("options").items()) {
            config.options[key] = option_value(value);
        }
    }
    if (settings.contains("generation_defaults")) {
        config.generation_defaults = settings.at("generation_defaults");
    }
    return config;
}

std::vector<llama_engine::model_entry> to_models(const json & models) {
    if (!models.is_array()) {
        throw std::invalid_argument("models must be an array");
    }
    std::vector<llama_engine::model_entry> entries;
    for (const auto & model : models) {
        entries.emplace_back(model.at("id").get<std::string>(),
                             model.value("aliases", std::vector<std::string>{}),
                             model.value("tags", std::vector<std::string>{}),
                             to_config(model.value("settings", json::object())));
    }
    return entries;
}

llama_engine::operation to_operation(const std::string & name) {
    using op = llama_engine::operation;
    static const std::map<std::string, op> operations = {
        {"completion", op::completion},     {"completions", op::completions},   {"chat", op::chat},
        {"responses", op::responses},       {"messages", op::messages},         {"infill", op::infill},
        {"transcription", op::transcription}, {"embeddings", op::embeddings},   {"embeddings_openai", op::embeddings_openai},
        {"rerank", op::rerank},             {"tokenize", op::tokenize},         {"detokenize", op::detokenize},
        {"apply_template", op::apply_template}, {"chat_tokens", op::chat_tokens}, {"response_tokens", op::response_tokens},
        {"message_tokens", op::message_tokens}, {"control", op::control},       {"slots", op::slots},
        {"properties", op::properties},     {"models", op::models},             {"metrics", op::metrics},
    };
    auto it = operations.find(name);
    if (it == operations.end()) {
        throw std::invalid_argument("unsupported operation: " + name);
    }
    return it->second;
}

llama_bridge_event * next_event(const std::function<llama_engine::event()> & read) {
    return guarded_event([&] { return make_event(read()); });
}

} // namespace

extern "C" {

llama_bridge_event_type llama_bridge_event_get_type(const llama_bridge_event * event) {
    switch (event->type) {
        case llama_engine::event_type::payload:   return LLAMA_BRIDGE_EVENT_PAYLOAD;
        case llama_engine::event_type::success:   return LLAMA_BRIDGE_EVENT_SUCCESS;
        case llama_engine::event_type::error:     return LLAMA_BRIDGE_EVENT_ERROR;
        case llama_engine::event_type::cancelled: return LLAMA_BRIDGE_EVENT_CANCELLED;
        case llama_engine::event_type::timeout:   return LLAMA_BRIDGE_EVENT_TIMEOUT;
    }
    return LLAMA_BRIDGE_EVENT_ERROR;
}

bool llama_bridge_event_is_terminal(const llama_bridge_event * event) {
    const auto type = event->type;
    return type == llama_engine::event_type::success || type == llama_engine::event_type::error ||
           type == llama_engine::event_type::cancelled;
}

const char * llama_bridge_event_get_data(const llama_bridge_event * event) { return event->data.c_str(); }
const char * llama_bridge_event_get_category(const llama_bridge_event * event) { return event->category.c_str(); }
const char * llama_bridge_event_get_message(const llama_bridge_event * event) { return event->message.c_str(); }
void llama_bridge_event_free(llama_bridge_event * event) { delete event; }

void llama_bridge_string_free(char * string) { delete[] string; }

llama_bridge_engine * llama_bridge_engine_create(const char * catalog_json, llama_bridge_event ** error) {
    return guarded<llama_bridge_engine *>(error, nullptr, [&]() -> llama_bridge_engine * {
        const json input = parse(catalog_json, "catalog configuration");
        llama_engine::catalog_config catalog;
        catalog.models                = to_models(input.value("models", json::array()));
        catalog.max_loaded            = input.value("max_loaded", catalog.max_loaded);
        catalog.autoload              = input.value("autoload", catalog.autoload);
        catalog.max_waiting           = input.value("max_waiting", catalog.max_waiting);
        catalog.max_subscriber_events = input.value("max_subscriber_events", catalog.max_subscriber_events);
        if (input.contains("wait_timeout_ms")) {
            catalog.wait_timeout = std::chrono::milliseconds(input.at("wait_timeout_ms").get<int64_t>());
        }
        llama_engine::event failure;
        auto engine = llama_engine::engine::create_catalog(catalog, failure);
        if (!engine) {
            set_error(error, make_event(failure));
            return nullptr;
        }
        auto * handle = new llama_bridge_engine();
        handle->engine = std::move(engine);
        return handle;
    });
}

void llama_bridge_engine_stop(llama_bridge_engine * engine) {
    guarded<int>(nullptr, 0, [&] { engine->engine->stop(); return 0; });
}

void llama_bridge_engine_destroy(llama_bridge_engine * engine) {
    if (!engine) {
        return;
    }
    guarded<int>(nullptr, 0, [&] { engine->engine->stop(); return 0; });
    delete engine;
}

llama_bridge_request * llama_bridge_engine_submit(llama_bridge_engine * engine, const char * operation,
                                                  const char * request_json,
                                                  const llama_bridge_attachment * attachments, size_t n_attachments,
                                                  llama_bridge_event ** error) {
    return guarded<llama_bridge_request *>(error, nullptr, [&] {
        if (!operation) {
            throw std::invalid_argument("operation is NULL");
        }
        const auto op = to_operation(operation);
        json input = request_json ? parse(request_json, "request") : json::object();
        std::vector<llama_engine::attachment> files;
        files.reserve(n_attachments);
        for (size_t i = 0; i < n_attachments; ++i) {
            const auto & source = attachments[i];
            if (!source.name || (!source.bytes && source.size > 0)) {
                throw std::invalid_argument("attachment without name or bytes");
            }
            files.push_back({source.name, std::vector<uint8_t>(source.bytes, source.bytes + source.size)});
        }
        auto * handle = new llama_bridge_request();
        handle->request = engine->engine->submit(op, std::move(input), std::move(files));
        return handle;
    });
}

char * llama_bridge_engine_catalog(const llama_bridge_engine * engine, llama_bridge_event ** error) {
    return guarded<char *>(error, nullptr, [&] {
        const std::string text = dump(engine->engine->catalog());
        auto * copy = new char[text.size() + 1];
        std::copy(text.c_str(), text.c_str() + text.size() + 1, copy);
        return copy;
    });
}

llama_bridge_request * llama_bridge_engine_load(llama_bridge_engine * engine, const char * model,
                                                llama_bridge_event ** error) {
    return guarded<llama_bridge_request *>(error, nullptr, [&] {
        if (!model) {
            throw std::invalid_argument("model is NULL");
        }
        auto * handle = new llama_bridge_request();
        handle->request = engine->engine->load(model);
        return handle;
    });
}

llama_bridge_event * llama_bridge_engine_unload(llama_bridge_engine * engine, const char * model) {
    return guarded_event([&] {
        if (!model) {
            throw std::invalid_argument("model is NULL");
        }
        return make_event(engine->engine->unload(model));
    });
}

llama_bridge_event * llama_bridge_engine_update_catalog(llama_bridge_engine * engine, const char * models_json) {
    return guarded_event([&] {
        return make_event(engine->engine->update_catalog(to_models(parse(models_json, "models"))));
    });
}

llama_bridge_subscription * llama_bridge_engine_subscribe(llama_bridge_engine * engine, llama_bridge_event ** error) {
    return guarded<llama_bridge_subscription *>(error, nullptr, [&] {
        auto * handle = new llama_bridge_subscription();
        handle->subscription = engine->engine->subscribe();
        return handle;
    });
}

llama_bridge_event * llama_bridge_request_next(llama_bridge_request * request, int64_t timeout_ms) {
    return next_event([&] {
        return timeout_ms < 0 ? request->request->next()
                              : request->request->next_for(std::chrono::milliseconds(timeout_ms));
    });
}

void llama_bridge_request_cancel(llama_bridge_request * request) {
    guarded<int>(nullptr, 0, [&] { request->request->cancel(); return 0; });
}

void llama_bridge_request_destroy(llama_bridge_request * request) {
    if (!request) {
        return;
    }
    guarded<int>(nullptr, 0, [&] { delete request; return 0; });
}

llama_bridge_event * llama_bridge_subscription_next(llama_bridge_subscription * subscription, int64_t timeout_ms) {
    return next_event([&] {
        return timeout_ms < 0 ? subscription->subscription->next()
                              : subscription->subscription->next_for(std::chrono::milliseconds(timeout_ms));
    });
}

void llama_bridge_subscription_destroy(llama_bridge_subscription * subscription) {
    if (!subscription) {
        return;
    }
    guarded<int>(nullptr, 0, [&] { delete subscription; return 0; });
}

} // extern "C"
