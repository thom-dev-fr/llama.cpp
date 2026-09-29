#pragma once

#include "llama-engine.h"
#include "mtmd-helper.h"
#include "server-task.h"
#include "server-queue.h"

#include "json.h"

#include <cstddef>
#include <memory>
#include <mutex>
#include <set>

namespace llama_engine { namespace detail { struct runtime; } }
struct server_context_impl; // private implementation

struct server_context_meta {
    std::string build_info;
    std::string model_name;
    std::set<std::string> model_aliases;
    std::set<std::string> model_tags;
    std::string model_path;
    bool has_mtmd;
    bool has_inp_image;
    bool has_inp_audio;
    bool has_inp_video;
    json json_ui_settings;
    int slot_n_ctx;
    enum llama_pooling_type pooling_type;

    // chat params
    server_chat_params chat_params;
    std::map<std::string, bool> chat_template_caps;

    // tokens
    std::string bos_token_str;
    std::string eos_token_str;
    llama_token fim_pre_token;
    llama_token fim_sub_token;
    llama_token fim_mid_token;
    llama_token fim_pad_token;
    llama_token fim_rep_token;
    llama_token fim_sep_token;

    // sampling
    std::vector<llama_logit_bias> logit_bias_eog;

    // model meta
    enum llama_vocab_type model_vocab_type;
    int32_t model_vocab_n_tokens;
    int32_t model_n_ctx_train;
    int32_t model_n_embd_inp;
    uint64_t model_n_params;
    uint64_t model_size;
    std::string model_ftype;
};

enum server_state {
    SERVER_STATE_DOWNLOADING,
    SERVER_STATE_LOADING,
    SERVER_STATE_READY,
    SERVER_STATE_SLEEPING,
};

static std::string server_state_to_str(server_state state) {
    switch (state) {
        case SERVER_STATE_DOWNLOADING: return "downloading";
        case SERVER_STATE_LOADING:     return "loading";
        case SERVER_STATE_READY:       return "ready";
        case SERVER_STATE_SLEEPING:    return "sleeping";
        default: GGML_ASSERT(false && "invalid server_state");
    }
}

static server_state server_state_from_str(const std::string & str) {
    if (str == "downloading") return SERVER_STATE_DOWNLOADING;
    if (str == "loading")     return SERVER_STATE_LOADING;
    if (str == "ready")       return SERVER_STATE_READY;
    if (str == "sleeping")    return SERVER_STATE_SLEEPING;
    GGML_ASSERT(false && "invalid server_state string");
}

using server_state_callback_t = std::function<void(server_state, json /* payload */)>;

struct server_context {
    std::unique_ptr<server_context_impl> impl;
    std::shared_ptr<llama_engine::detail::runtime> runtime;
    std::unique_ptr<const server_context_meta> metadata;

    server_queue & tasks();
    server_response & responses();
    const llama_vocab * vocabulary() const;
    llama_model * model() const;
    mtmd_context * multimodal() const;
    mtmd_helper_init_opt media_options() const;
    const common_params & parameters() const;
    server_metrics get_metrics() const;
    void reset_metrics_bucket();
    std::vector<server_task> prepare_completion(const json & data, server_task_type type,
            task_response_type format, const std::vector<raw_buffer> & files, size_t max_tasks = SIZE_MAX);

    server_context();
    ~server_context();

    // load the model and initialize llama_context
    // returns true on success
    bool load_model(common_params & params);

    // Start the owned decoder after initial metadata consumers are ready.
    void start();

    // Legacy consumer wait; starts and joins the engine-owned decoder.
    void start_loop();

    // Request termination (unblocks start_loop); destructor joins.
    void terminate();

    // get the underlaying llama_context, can return nullptr if sleeping
    // not thread-safe, should only be used from the main thread
    llama_context * get_llama_context() const;

    // get a new response reader, used by CLI application
    server_response_reader get_response_reader();

    // get server metadata (read-only), can only be called after load_model()
    // not thread-safe, should only be used from the main thread
    server_context_meta get_meta() const;

    // note: must be set before load_model() is called
    void set_state_callback(server_state_callback_t callback);

    // Makes a load_model() in progress on another thread fail at its next
    // progress report. Thread-safe; there is no strict interruption delay.
    void cancel_load();
};


