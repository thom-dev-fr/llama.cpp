// Minimal in-process consumer of the private server core (engine/server-context.h).
// It loads a local GGUF model, streams a chat reply, then tokenizes the prompt.
// No HTTP server, no listener, no download.

#include "server-common.h"
#include "server-context.h"
#include "server-task.h"

#include "base64.hpp"
#include "common.h"
#include "llama.h"
#include "log.h"

#include <cstdio>
#include <cstring>
#include <fstream>
#include <iterator>
#include <string>
#include <thread>

static void print_usage(const char * argv0) {
    fprintf(stderr, "usage: %s -m model.gguf [--mmproj mmproj.gguf --image image.png] [-p \"prompt\"] [-n n_predict] [-c n_ctx]\n", argv0);
}

// runs the decode loop on its own thread
// note: destroy every reader before this object, and this object before the server_context
struct loop_thread {
    server_context & ctx;
    std::thread th;

    explicit loop_thread(server_context & ctx) : ctx(ctx), th([&ctx]() { ctx.start_loop(); }) {}

    ~loop_thread() {
        // terminate() has no effect before start_loop() runs: wait for one answer from the loop first
        {
            server_response_reader rd = ctx.get_response_reader();
            server_task task(SERVER_TASK_TYPE_METRICS);
            task.id = rd.get_new_id();
            rd.post_task(std::move(task), true);
            rd.next([]() { return false; });
        }
        ctx.terminate();
        th.join();
    }
};

static bool read_file(const std::string & path, std::string & out) {
    std::ifstream f(path, std::ios::binary);
    if (!f) {
        return false;
    }
    out.assign(std::istreambuf_iterator<char>(f), std::istreambuf_iterator<char>());
    return true;
}

int main(int argc, char ** argv) {
    common_params params;
    std::string prompt = "Tell me a short story.";
    std::string image_path;
    int n_predict = 32;

    // the example sets these values itself, see README.md
    params.n_ctx      = 4096;
    params.n_parallel = 1;

    for (int i = 1; i < argc; i += 2) {
        if (i + 1 >= argc) {
            print_usage(argv[0]);
            return 1;
        }
        const std::string arg = argv[i];
        const std::string val = argv[i + 1];
        try {
            if (arg == "-m") {
                params.model.path = val;
            } else if (arg == "--mmproj") {
                params.mmproj.path = val;
            } else if (arg == "--image") {
                image_path = val;
            } else if (arg == "-p") {
                prompt = val;
            } else if (arg == "-n") {
                n_predict = std::stoi(val);
            } else if (arg == "-c") {
                params.n_ctx = std::stoi(val);
            } else {
                print_usage(argv[0]);
                return 1;
            }
        } catch (const std::exception &) {
            print_usage(argv[0]);
            return 1;
        }
    }
    if (params.model.path.empty() || (!image_path.empty() && params.mmproj.path.empty())) {
        print_usage(argv[0]);
        return 1;
    }

    json content = prompt;
    if (!image_path.empty()) {
        std::string image;
        if (!read_file(image_path, image)) {
            fprintf(stderr, "error: cannot read %s\n", image_path.c_str());
            return 1;
        }
        // the chat parser decodes data URLs into raw buffers, as for HTTP requests
        content = json::array({
            {{"type", "image_url"}, {"image_url", {{"url", "data:image/unknown;base64," + base64::encode(image)}}}},
            {{"type", "text"}, {"text", prompt}},
        });
    }

    common_init();
    llama_backend_init();

    // argv parsing normally resolves the thread counts
    postprocess_cpu_params(params.cpuparams, nullptr);
    postprocess_cpu_params(params.cpuparams_batch, &params.cpuparams);

    int ret = 0;
    {
        server_context ctx;
        if (!ctx.load_model(params)) {
            fprintf(stderr, "error: failed to load %s\n", params.model.path.c_str());
            ret = 1;
        } else {
            // read before the loop starts, get_meta() is not thread-safe
            const server_context_meta meta = ctx.get_meta();
            const auto never_stop = []() { return false; };

            loop_thread loop(ctx);

            try {
                json body = {
                    {"messages",   json::array({{{"role", "user"}, {"content", content}}})},
                    {"max_tokens", n_predict},
                    {"stream",     true},
                };
                std::vector<raw_buffer> files;
                json data = oaicompat_chat_params_parse(body, meta.chat_params, files);

                server_response_reader rd = ctx.get_response_reader();
                rd.post_tasks(ctx.prepare_completion(rd, params, SERVER_TASK_TYPE_COMPLETION, data, files, TASK_RESPONSE_TYPE_OAI_CHAT));

                // each result is an OpenAI chat chunk or an array of them, as in the HTTP stream
                while (rd.has_next()) {
                    server_task_result_ptr res = rd.next(never_stop);
                    if (res->is_error()) {
                        fprintf(stderr, "\nerror: %s\n", res->to_json().dump().c_str());
                        ret = 1;
                        break;
                    }
                    json chunks = res->to_json();
                    if (!chunks.is_array()) {
                        chunks = json::array({chunks});
                    }
                    for (const auto & chunk : chunks) {
                        if (!chunk.is_object() || !chunk.contains("choices")) {
                            continue;
                        }
                        for (const auto & choice : chunk.at("choices")) {
                            const json delta = choice.value("delta", json::object());
                            if (delta.contains("content") && delta.at("content").is_string()) {
                                printf("%s", delta.at("content").get<std::string>().c_str());
                                fflush(stdout);
                            }
                        }
                    }
                }
                printf("\n");

                if (ret == 0) {
                    // a direct call, it does not go through the loop
                    const json tokens = ctx.tokenize({{"content", prompt}});
                    printf("the prompt has %zu tokens\n", tokens.at("tokens").size());
                }
            } catch (const std::exception & e) {
                fprintf(stderr, "error: %s\n", e.what());
                ret = 1;
            }
        }
    }

    llama_backend_free();
    return ret;
}
