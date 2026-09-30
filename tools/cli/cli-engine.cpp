#include "cli-engine.h"

#include "engine-options.h" // option scopes: which options configure the model
#include "preset.h"

#include <chrono>
#include <limits>
#include <map>
#include <stdexcept>
#include <utility>

using llama_engine::event;
using llama_engine::event_type;
using llama_engine::json;
using llama_engine::operation;

// how often an interruption by the user is checked while waiting for the engine
static constexpr std::chrono::milliseconds CLI_ENGINE_POLL_INTERVAL(100);

static std::string error_message(const event & ev) {
    return ev.message.empty() ? ev.category : ev.message;
}

// The model configuration of the command line, with the priorities of
// common_params_parse: configuration files and LLAMA_ARG_* variables, then the
// arguments. Options of the terminal (prompt, colors, output file, ...) stay here.
static std::map<std::string, std::string> model_options(const common_params & params, int argc, char ** argv) {
    const common_preset_context ctx(LLAMA_EXAMPLE_CLI);
    common_preset preset = ctx.load_from_env();
    preset.merge(ctx.load_from_args(argc, argv));

    std::map<std::string, std::string> out;
    for (const auto & [opt, value] : preset.options) {
        const std::string key = llama_engine::detail::option_key(opt);
        const auto * scope = llama_engine::detail::find_option_scope(key);
        if (scope && *scope == llama_engine::detail::option_scope::engine) {
            out[key] = value;
        }
    }
    // the engine starts from llama-server's defaults, whose number of slots is automatic
    out.emplace("parallel", std::to_string(params.n_parallel));
    return out;
}

bool cli_engine::load(const common_params & params, int argc, char ** argv,
                      const std::function<bool()> & should_stop,
                      const std::function<void(const download_progress &)> & on_download,
                      std::string & error) {
    llama_engine::catalog_config catalog;
    try {
        auto settings = llama_engine::config::from_options(model_options(params, argc, argv));
        // as llama-server: no limit on buffered events or request size (the history holds media)
        settings.max_events        = std::numeric_limits<size_t>::max();
        settings.max_request_bytes = std::numeric_limits<size_t>::max();
        model = llama_engine::detail::model_name(settings);
        catalog.models.emplace_back(model, std::vector<std::string>{}, std::vector<std::string>{}, settings);
    } catch (const std::exception & e) {
        error = e.what();
        return false;
    }
    catalog.max_loaded   = 1;
    catalog.wait_timeout = std::chrono::hours(24 * 365 * 100); // downloading and loading take as long as they take

    // a catalog of one model, rather than engine::create(), so that the loading
    // reports its downloads and can be interrupted
    event status;
    engine = llama_engine::engine::create_catalog(catalog, status);
    if (!engine) {
        error = error_message(status);
        return false;
    }

    auto events  = engine->subscribe();
    auto loading = engine->load(model);
    std::map<std::string, std::pair<size_t, size_t>> downloads; // url -> downloaded, total
    const auto report_downloads = [&]() {
        for (auto ev = events->next_for(std::chrono::milliseconds(0)); ev.type == event_type::payload;
                  ev = events->next_for(std::chrono::milliseconds(0))) {
            if (ev.data.value("type", "") != "progress" || !on_download) {
                continue;
            }
            const auto & progress = ev.data.at("progress");
            if (progress.value("stage", "") != "download") {
                continue;
            }
            downloads[progress.value("url", "")] = {progress.value("downloaded", size_t(0)), progress.value("total", size_t(0))};
            download_progress sum;
            for (const auto & [url, bytes] : downloads) {
                sum.files++;
                sum.downloaded += bytes.first;
                sum.total      += bytes.second;
            }
            on_download(sum);
        }
    };
    for (;;) {
        if (should_stop()) {
            stop(); // interrupts the download or the loading
            error.clear();
            return false;
        }
        report_downloads();
        event loaded = loading->next_for(CLI_ENGINE_POLL_INTERVAL);
        if (loaded.type == event_type::timeout) {
            continue;
        }
        report_downloads(); // the last progress, published before the end of the loading
        if (loaded.type == event_type::success) {
            return true;
        }
        error = error_message(loaded);
        return false;
    }
}

void cli_engine::stop() {
    if (engine) {
        engine->stop();
    }
}

std::string cli_engine::models() {
    json data = json::array();
    for (const auto & entry : engine->catalog()) {
        data.push_back({{"id", entry.at("id")}, {"aliases", entry.value("aliases", json::array())}});
    }
    return json({{"object", "list"}, {"data", data}}).dump();
}

std::string cli_engine::properties(const std::string &) {
    event result = engine->submit(operation::properties, {{"model", model}})->result();
    if (result.type != event_type::success) {
        throw std::runtime_error(error_message(result));
    }
    return result.data.dump();
}

std::string cli_engine::chat(const std::string & body,
                             const std::function<bool()> & should_stop,
                             const std::function<void(const std::string &)> & on_chunk) {
    json input = json::parse(body);
    input["model"] = model;
    auto request = engine->submit(operation::chat, std::move(input));
    bool cancelled = false;
    for (;;) {
        if (!cancelled && should_stop()) {
            request->cancel(); // chunks already produced are still delivered
            cancelled = true;
        }
        event ev = request->next_for(CLI_ENGINE_POLL_INTERVAL);
        switch (ev.type) {
            case event_type::timeout:
                break;
            case event_type::payload:
                // a payload is one chunk or an ordered array of chunks; null marks the start
                if (ev.data.is_array()) {
                    for (const auto & chunk : ev.data) {
                        on_chunk(chunk.dump());
                    }
                } else if (ev.data.is_object()) {
                    on_chunk(ev.data.dump());
                }
                break;
            case event_type::success:
            case event_type::cancelled:
                return "";
            case event_type::error:
                return cancelled ? "" : error_message(ev);
        }
    }
}
