#pragma once

#include <functional>
#include <string>

// operations of the chat loop, served by the local engine (cli_engine) or by a
// running llama-server (cli_client); documents are the JSON of the server API
struct cli_backend {
    virtual ~cli_backend() = default;

    // OpenAI-like model list, with "data" entries carrying "id" and "aliases"
    // throws std::runtime_error on failure
    virtual std::string models() = 0;

    // properties of the model (same fields as /props); an empty model names the only one
    // throws std::runtime_error on failure
    virtual std::string properties(const std::string & model) = 0;

    // streamed OpenAI chat completion: on_chunk receives each chunk, should_stop interrupts it
    // returns the error (raw body or message), empty on success or interruption
    virtual std::string chat(const std::string & body,
                             const std::function<bool()> & should_stop,
                             const std::function<void(const std::string &)> & on_chunk) = 0;
};
