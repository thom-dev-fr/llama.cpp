// Command-line parsing for executables: argv, environment, system config files
// and model download. The option registry and preset translation are in arg.cpp
// and preset.cpp, which do not need the network.
#include "arg.h"

#include "chat.h"
#include "common.h"
#include "download.h"
#include "log.h"
#include "preset.h"

#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#ifndef NOMINMAX
#   define NOMINMAX
#endif
#include <windows.h>
#include <shellapi.h>
#endif

#include <algorithm>
#include <filesystem>
#include <set>
#include <string>
#include <unordered_map>
#include <vector>

using namespace common_arg_utils;

common_models_handler common_models_handler_init(const common_params & params, llama_example curr_ex) {
    return common_models_handler_init(params, curr_ex, &common_download_network());
}

void common_models_handler_apply(common_models_handler & handler, common_params & params, common_download_callback * callback) {
    common_models_handler_apply(handler, params, &common_download_network(), callback);
}

static bool parse_bool_value(const std::string & value) {
    if (is_truthy(value)) {
        return true;
    } else if (is_falsey(value)) {
        return false;
    } else {
        throw std::invalid_argument("invalid boolean value");
    }
}

//
// CLI argument parsing functions
//

// apply config files (if present), a later file overrides an earlier one
static void common_params_apply_system_config(common_params & params, llama_example ex) {
    const std::vector<std::filesystem::path> found = common_params_config_files();
    if (found.empty()) {
        return;
    }

    common_preset_context ctx(ex);
    ctx.ignore_unknown_keys = true; // the same config file is shared by all programs
    for (const auto & path : found) {
        LOG_INF("using config file: %s\n", fs_path_to_utf8(path).c_str());
        common_preset global;
        common_presets presets = ctx.load_from_ini(path, global);
        global.apply_to_params(params);
        auto it = presets.find(COMMON_PRESET_DEFAULT_NAME);
        if (it != presets.end()) {
            it->second.apply_to_params(params);
        }
    }
}

static bool common_params_parse_ex(int argc, char ** argv, common_params_context & ctx_arg) {
    common_params & params = ctx_arg.params;

    // setup log directly from params.verbosity: see tools/cli/cli.cpp
    common_log_set_verbosity_thold(params.verbosity);

    // config file applies first, so env variables and CLI arguments override it
    common_params_apply_system_config(params, ctx_arg.ex);

    std::unordered_map<std::string, std::pair<common_arg *, bool>> arg_to_options;
    for (auto & opt : ctx_arg.options) {
        for (const auto & arg : opt.args) {
            arg_to_options[arg] = {&opt, /* is_positive */ true};
        }
        for (const auto & arg : opt.args_neg) {
            arg_to_options[arg] = {&opt, /* is_positive */ false};
        }
    }

    // handle environment variables
    for (auto & opt : ctx_arg.options) {
        std::string value;
        if (opt.get_value_from_env(value)) {
            try {
                if (opt.handler_void && is_truthy(value)) {
                    opt.handler_void(params);
                }
                if (opt.handler_int) {
                    opt.handler_int(params, std::stoi(value));
                }
                if (opt.handler_bool) {
                    opt.handler_bool(params, parse_bool_value(value));
                }
                if (opt.handler_string) {
                    opt.handler_string(params, value);
                    continue;
                }
            } catch (std::exception & e) {
                throw std::invalid_argument(string_format(
                    "error while handling environment variable \"%s\": %s\n\n", opt.env, e.what()));
            }
        }
    }

    // handle command line arguments
    auto check_arg = [&](int i) {
        if (i+1 >= argc) {
            throw std::invalid_argument("expected value for argument");
        }
    };

    auto parse_cli_args = [&]() {
        std::set<std::string> seen_args;

        for (int i = 1; i < argc; i++) {
            const std::string arg_prefix = "--";

            std::string arg = argv[i];
            if (arg.compare(0, arg_prefix.size(), arg_prefix) == 0) {
                std::replace(arg.begin(), arg.end(), '_', '-');
            }
            if (arg_to_options.find(arg) == arg_to_options.end()) {
                throw std::invalid_argument(string_format("error: invalid argument: %s", arg.c_str()));
            }
            if (!seen_args.insert(arg).second) {
                const bool skip = (arg == "--spec-type");

                if (!skip) {
                    LOG_WRN("DEPRECATED: argument '%s' specified multiple times, use comma-separated values instead (only last value will be used)\n", arg.c_str());
                }
            }
            auto & tmp = arg_to_options[arg];
            auto opt = *tmp.first;
            bool is_positive = tmp.second;
            if (opt.has_value_from_env()) {
                fprintf(stderr, "warn: %s environment variable is set, but will be overwritten by command line argument %s\n", opt.env, arg.c_str());
            }
            try {
                if (opt.handler_void) {
                    opt.handler_void(params);
                    continue;
                }
                if (opt.handler_bool) {
                    opt.handler_bool(params, is_positive);
                    continue;
                }

                // arg with single value
                check_arg(i);
                std::string val = argv[++i];
                if (opt.handler_int) {
                    opt.handler_int(params, std::stoi(val));
                    continue;
                }
                if (opt.handler_string) {
                    opt.handler_string(params, val);
                    continue;
                }

                // arg with 2 values
                check_arg(i);
                std::string val2 = argv[++i];
                if (opt.handler_str_str) {
                    opt.handler_str_str(params, val, val2);
                    continue;
                }
            } catch (std::exception & e) {
                throw std::invalid_argument(string_format(
                    "error while handling argument \"%s\": %s\n\n"
                    "usage:\n%s\n\nto show complete usage, run with -h",
                    arg.c_str(), e.what(), opt.to_string().c_str()));
            }
        }
    };

    // parse all CLI args now, so that -hf is available below for remote preset resolution
    parse_cli_args();

    // shared with presets applied by other consumers (common_params_finalize)
    common_params_finalize(params);

    const bool skip_model_download =
        // server will call common_params_handle_models() later, so we skip it here
        ctx_arg.ex == LLAMA_EXAMPLE_SERVER ||
        // the CLI's engine resolves and downloads the model while loading it
        ctx_arg.ex == LLAMA_EXAMPLE_CLI ||
        // download calls common_params_handle_models() itself and prints the paths
        ctx_arg.ex == LLAMA_EXAMPLE_DOWNLOAD ||
        // export_graph_ops loads only metadata
        ctx_arg.ex == LLAMA_EXAMPLE_EXPORT_GRAPH_OPS;

    if (!skip_model_download) {
        // handle model and download
        common_models_handler handler = common_models_handler_init(params, ctx_arg.ex);
        common_models_handler_apply(handler, params);

        // model is required (except for server)
        // TODO @ngxson : maybe show a list of available models in CLI in this case
        bool can_skip_model = params.usage || params.completion || !params.server_base.empty();
        if (!can_skip_model && params.model.path.empty()) {
            throw std::invalid_argument("error: --model is required\n");
        }
    }

    return true;
}

static void common_params_print_usage(common_params_context & ctx_arg) {
    auto print_options = [](std::vector<common_arg *> & options) {
        for (common_arg * opt : options) {
            printf("%s", opt->to_string().c_str());
        }
    };

    std::vector<common_arg *> common_options;
    std::vector<common_arg *> sampling_options;
    std::vector<common_arg *> spec_options;
    std::vector<common_arg *> specific_options;
    for (auto & opt : ctx_arg.options) {
        // in case multiple LLAMA_EXAMPLE_* are set, we prioritize the LLAMA_EXAMPLE_* matching current example
        if (opt.is_sampling) {
            sampling_options.push_back(&opt);
        } else if (opt.is_spec) {
            spec_options.push_back(&opt);
        } else if (opt.in_example(ctx_arg.ex)) {
            specific_options.push_back(&opt);
        } else {
            common_options.push_back(&opt);
        }
    }
    bool first = true;
    auto print_section = [&](const char * header, std::vector<common_arg *> & options) {
        if (options.empty()) {
            return;
        }
        printf("%s----- %s -----\n\n", first ? "" : "\n\n", header);
        first = false;
        print_options(options);
    };
    print_section("common params",           common_options);
    print_section("sampling params",         sampling_options);
    print_section("speculative params",      spec_options);
    print_section("example-specific params", specific_options);
}

static void common_params_print_completion(common_params_context & ctx_arg) {
    std::vector<common_arg *> common_options;
    std::vector<common_arg *> sampling_options;
    std::vector<common_arg *> spec_options;
    std::vector<common_arg *> specific_options;

    for (auto & opt : ctx_arg.options) {
        if (opt.is_sampling) {
            sampling_options.push_back(&opt);
        } else if (opt.is_spec) {
            spec_options.push_back(&opt);
        } else if (opt.in_example(ctx_arg.ex)) {
            specific_options.push_back(&opt);
        } else {
            common_options.push_back(&opt);
        }
    }

    printf("_llama_completions() {\n");
    printf("    local cur prev opts\n");
    printf("    COMPREPLY=()\n");
    printf("    cur=\"${COMP_WORDS[COMP_CWORD]}\"\n");
    printf("    prev=\"${COMP_WORDS[COMP_CWORD-1]}\"\n\n");

    printf("    opts=\"");
    auto print_options = [](const std::vector<common_arg *> & options) {
        for (const common_arg * opt : options) {
            for (const char * arg : opt->args) {
                printf("%s ", arg);
            }
        }
    };

    print_options(common_options);
    print_options(sampling_options);
    print_options(spec_options);
    print_options(specific_options);
    printf("\"\n\n");

    printf("    case \"$prev\" in\n");
    printf("        --model|-m)\n");
    printf("            COMPREPLY=( $(compgen -f -X '!*.gguf' -- \"$cur\") $(compgen -d -- \"$cur\") )\n");
    printf("            return 0\n");
    printf("            ;;\n");
    printf("        --grammar-file)\n");
    printf("            COMPREPLY=( $(compgen -f -X '!*.gbnf' -- \"$cur\") $(compgen -d -- \"$cur\") )\n");
    printf("            return 0\n");
    printf("            ;;\n");
    printf("        --chat-template-file)\n");
    printf("            COMPREPLY=( $(compgen -f -X '!*.jinja' -- \"$cur\") $(compgen -d -- \"$cur\") )\n");
    printf("            return 0\n");
    printf("            ;;\n");
    printf("        *)\n");
    printf("            COMPREPLY=( $(compgen -W \"${opts}\" -- \"$cur\") )\n");
    printf("            return 0\n");
    printf("            ;;\n");
    printf("    esac\n");
    printf("}\n\n");

    std::set<std::string> executables = {
        "llama-batched",
        "llama-batched-bench",
        "llama-bench",
        "llama-cli",
        "llama-completion",
        "llama-convert-llama2c-to-ggml",
        "llama-cvector-generator",
        "llama-debug",
        "llama-diffusion-cli",
        "llama-embedding",
        "llama-eval-callback",
        "llama-export-lora",
        "llama-finetune",
        "llama-fit-params",
        "llama-gemma3-cli",
        "llama-gen-docs",
        "llama-gguf",
        "llama-gguf-hash",
        "llama-gguf-split",
        "llama-idle",
        "llama-imatrix",
        "llama-llava-cli",
        "llama-lookahead",
        "llama-lookup",
        "llama-lookup-create",
        "llama-lookup-merge",
        "llama-lookup-stats",
        "llama-minicpmv-cli",
        "llama-mtmd-cli",
        "llama-parallel",
        "llama-passkey",
        "llama-perplexity",
        "llama-q8dot",
        "llama-quantize",
        "llama-qwen2vl-cli",
        "llama-retrieval",
        "llama-save-load-state",
        "llama-server",
        "llama-simple",
        "llama-simple-chat",
        "llama-speculative",
        "llama-speculative-simple",
        "llama-tokenize",
        "llama-tts",
        "llama-vdot"
    };

    for (const auto& exe : executables) {
        printf("complete -F _llama_completions %s\n", exe.c_str());
    }
}

#ifdef _WIN32
struct utf8_argv {
    std::vector<std::string> buf;
    std::vector<char*> ptrs;
};

static utf8_argv make_utf8_argv() {
    utf8_argv out;
    int wargc = 0;
    LPWSTR* wargv = CommandLineToArgvW(GetCommandLineW(), &wargc);
    if (!wargv) return out;

    out.buf.reserve(wargc);
    for (int i = 0; i < wargc; ++i) {
        int n = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, wargv[i], -1, nullptr, 0, nullptr, nullptr);
        if (n <= 0) { out.buf.emplace_back(); continue; }
        auto& s = out.buf.emplace_back();
        s.resize(static_cast<size_t>(n - 1));
        (void)WideCharToMultiByte(CP_UTF8, 0, wargv[i], -1, s.data(), n, nullptr, nullptr);
    }
    LocalFree(wargv);

    out.ptrs.reserve(out.buf.size() + 1);
    for (auto& s : out.buf) out.ptrs.push_back(s.data());
    out.ptrs.push_back(nullptr);
    return out;
}
#endif

bool common_params_parse(int argc, char ** argv, common_params & params, llama_example ex, void(*print_usage)(int, char **)) {
#ifdef _WIN32
    auto utf8 = make_utf8_argv();
    // repair argv only when it matches the process command line
    if (static_cast<int>(utf8.buf.size()) == argc) {
        argv = utf8.ptrs.data();
    }
#endif

    auto ctx_arg = common_params_parser_init(params, ex, print_usage);
    const common_params params_org = ctx_arg.params; // the example can modify the default params

    try {
        if (!common_params_parse_ex(argc, argv, ctx_arg)) {
            ctx_arg.params = params_org;
            return false;
        }
        if (ctx_arg.params.usage) {
            common_params_print_usage(ctx_arg);
            if (ctx_arg.print_usage) {
                ctx_arg.print_usage(argc, argv);
            }
            common_log_flush(common_log_main());
            exit(0);
        }
        if (ctx_arg.params.completion) {
            common_params_print_completion(ctx_arg);
            exit(0);
        }
        params.lr.init();
    } catch (const std::invalid_argument & ex) {
        fprintf(stderr, "%s\n", ex.what());
        ctx_arg.params = params_org;
        return false;
    } catch (std::exception & ex) {
        fprintf(stderr, "%s\n", ex.what());
        exit(1); // for other exceptions, we exit with status code 1
    }

    return true;
}
