// Minimal consumer of the embeddable inference engine (include/llama-engine.h):
// loads a GGUF model in this process, streams a chat reply, then counts the
// tokens of the prompt with a non-streaming request. No server, no port, no
// llama.cpp internals: this file only sees the public header.
//
//   llama-engine-simple -m model.gguf [-p "prompt"] [-n n_predict]

#include "llama-engine.h"

#include <cstdio>
#include <cstring>
#include <string>

static void print_usage(const char * argv0) {
    fprintf(stderr, "usage: %s -m model.gguf [-p \"prompt\"] [-n n_predict]\n", argv0);
}

static int fail(const llama_engine::event & ev) {
    fprintf(stderr, "error: %s: %s\n", ev.category.c_str(), ev.message.c_str());
    return 1;
}

int main(int argc, char ** argv) {
    std::string model;
    std::string prompt = "Tell me a short story.";
    int n_predict = 32;
    for (int i = 1; i < argc; i += 2) {
        if (i + 1 >= argc) {
            print_usage(argv[0]);
            return 1;
        }
        if (strcmp(argv[i], "-m") == 0) {
            model = argv[i + 1];
        } else if (strcmp(argv[i], "-p") == 0) {
            prompt = argv[i + 1];
        } else if (strcmp(argv[i], "-n") == 0) {
            n_predict = std::stoi(argv[i + 1]);
        } else {
            print_usage(argv[0]);
            return 1;
        }
    }
    if (model.empty()) {
        print_usage(argv[0]);
        return 1;
    }

    // Typed fields have conservative defaults (CPU, small context); any other
    // llama-server setting is an option named as in preset files.
    llama_engine::config config;
    config.model_path   = model;
    config.context_size = 2048;
    config.options      = {{"temp", "0"}};

    llama_engine::event error;
    auto engine = llama_engine::engine::create(config, error); // loads the model
    if (!engine) {
        return fail(error);
    }

    // Streaming: each payload is an OpenAI chat chunk, or an array of them.
    auto request = engine->submit(llama_engine::operation::chat, {
        {"messages",   {{{"role", "user"}, {"content", prompt}}}},
        {"max_tokens", n_predict},
        {"stream",     true},
    });
    for (;;) {
        llama_engine::event ev = request->next(); // blocks until the next event
        if (ev.terminal()) {
            if (ev.type != llama_engine::event_type::success) {
                return fail(ev); // error or cancelled: the only terminal event
            }
            break;
        }
        const auto chunks = ev.data.is_array() ? ev.data : llama_engine::json::array({ev.data});
        for (const auto & chunk : chunks) {
            if (!chunk.is_object() || !chunk.contains("choices")) {
                continue; // null payload: generation started
            }
            for (const auto & choice : chunk.at("choices")) {
                const auto & delta = choice.value("delta", llama_engine::json::object());
                if (delta.contains("content") && delta.at("content").is_string()) {
                    printf("%s", delta.at("content").get<std::string>().c_str());
                    fflush(stdout);
                }
            }
        }
    }
    printf("\n");

    // Without streaming, result() returns the complete JSON document.
    auto count = engine->submit(llama_engine::operation::tokenize, {{"content", prompt}})->result();
    if (count.type != llama_engine::event_type::success) {
        return fail(count);
    }
    printf("the prompt has %zu tokens\n", count.data.at("tokens").size());

    engine->stop(); // also done by the destructor
    return 0;
}
