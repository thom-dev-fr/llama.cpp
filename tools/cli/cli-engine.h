#pragma once

#include "cli-backend.h"

#include "common.h"
#include "llama-engine.h"

#include <cstddef>
#include <functional>
#include <memory>
#include <string>

// local backend: the model of the command line, loaded in this process by the
// engine; no server, no port
struct cli_engine : cli_backend {
    // files of the model being downloaded, summed
    struct download_progress {
        size_t files      = 0;
        size_t downloaded = 0;
        size_t total      = 0;
    };

    // loads the model configured by the command line: params is its parsed form,
    // argc/argv give the options it names. Remote resources (-hf, -mu, -dr) are
    // downloaded meanwhile, reported to on_download.
    // returns false with the error, or with an empty error when should_stop()
    // interrupted the loading
    bool load(const common_params & params, int argc, char ** argv,
              const std::function<bool()> & should_stop,
              const std::function<void(const download_progress &)> & on_download,
              std::string & error);

    // ends the requests and frees the model; idempotent
    void stop();

    std::string models() override;
    std::string properties(const std::string & model) override;
    std::string chat(const std::string & body,
                     const std::function<bool()> & should_stop,
                     const std::function<void(const std::string &)> & on_chunk) override;

private:
    std::unique_ptr<llama_engine::engine> engine;
    std::string model; // catalog id of the loaded model
};
