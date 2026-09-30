#pragma once

#include "common.h"

#include "cli-backend.h"

#include <atomic>
#include <memory>
#include <optional>
#include <string>
#include <fstream>

struct cli_timings {
    double prompt_per_second    = 0.0;
    double predicted_per_second = 0.0;
};

struct cli_context_impl;

struct cli_context {
    common_params params;

    // the local engine, or the server given by --server-base; set by init()
    std::unique_ptr<cli_backend> backend;

    // model named in requests, when the server has multiple models (router mode)
    std::string model;

    // properties of the model
    // will be populated by fetch_server_props()
    std::string model_name;
    std::string model_ftype;
    std::string build_info;
    bool has_vision = false;
    bool has_audio  = false;
    bool has_video  = false;

    std::optional<std::ofstream> output_file;

    // argc/argv are the command line that params was parsed from
    cli_context(const common_params & params, int argc, char ** argv);
    ~cli_context();

    // connect to --server-base or load the model in this process;
    // the command line configures the local model
    bool init();

    // run the interactive chat loop, returns the process exit code
    int run();

    // free the local model (if any)
    void shutdown();

    // set by the SIGINT handler; cleared once the interrupt has been handled
    static std::atomic<bool> & interrupted();

private:
    struct generated_content {
        std::string reasoning;
        std::string content;
    };
    bool generate_completion(generated_content & content_out, cli_timings & timings);
    void fetch_server_props();
    void add_system_prompt();
    void push_user_message(const std::string & text);

    // check if server have multiple models (router mode)
    // if yes, list them then ask; do nothing otherwise
    bool list_and_ask_models();

    // read a file and stage it as a multimodal content part; type is one of
    // "image", "audio", "video"; returns false if the file cannot be read
    bool stage_media_file(const std::string & fname, const std::string & type);

    // no-op if output file is not set
    void write_output_file(const std::string & content);

    int argc;
    char ** argv;

    std::unique_ptr<cli_context_impl> impl;
};
