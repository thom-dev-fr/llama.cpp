#pragma once

#include "server-task.h"
#include "server-queue.h"

#include "json.h"
#include "mtmd-helper.h"

#include <cstddef>
#include <memory>
#include <mutex>
#include <set>

struct server_context_impl; // private implementation
struct server_decision_context;
struct server_decision_question;

constexpr int HTTP_POLLING_SECONDS = 1;

struct server_context_meta {
    std::string build_info;
    std::string model_name;
    std::set<std::string> model_aliases;
    std::set<std::string> model_tags;
    std::string model_path;
    std::vector<std::string> model_output_modalities; // output modalities for GET /models
    bool has_mtmd;
    bool has_inp_image;
    bool has_inp_audio;
    bool has_inp_video;
    json json_ui_settings;
    int slot_n_ctx;
    enum llama_pooling_type pooling_type;

    // chat params
    server_chat_params & chat_params;
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

    server_context();
    ~server_context();

    // load the model and initialize llama_context
    // returns true on success
    bool load_model(common_params & params);

    // this function will block main thread until termination
    void start_loop();

    // terminate main loop (will unblock start_loop)
    // note: no effect before start_loop() runs; it does not wake readers, their should_stop does
    void terminate();

    // get the underlaying llama_context, can return nullptr if sleeping
    // not thread-safe, should only be used from the main thread
    llama_context * get_llama_context() const;

    // get a new response reader, used by CLI application
    // note: a reader uses the task queues, destroy it before server_context
    server_response_reader get_response_reader();

    // get server metadata (read-only), can only be called after load_model()
    // not thread-safe, should only be used from the main thread
    server_context_meta get_meta() const;

    // note: must be set before load_model() is called
    void set_state_callback(server_state_callback_t callback);

    // used for http(s) media URLs in chat requests, they are rejected if not set
    // note: must be set before load_model() is called
    void set_media_fetcher(server_media_fetcher_t fetcher);

    // used by the HTTP routes; the pointers change when the model is reloaded after sleep
    server_queue    & get_queue_tasks();
    server_response & get_queue_results();
    const llama_vocab * get_vocab() const;
    const server_decision_context & get_decision() const;
    server_metrics get_metrics() const;
    void reset_metrics_bucket();

    // operation preparation, shared by all consumers
    // params are the caller params (not the ones modified by load_model), task ids come from rd
    // invalid input throws, the caller formats the error
    // must not be called while sleeping (the model is unloaded), see server_queue::wait_until_no_sleep()
    std::vector<server_task> prepare_completion(
            server_response_reader & rd,
            const common_params & params,
            server_task_type type,
            const json & data,
            const std::vector<raw_buffer> & files,
            task_response_type res_type);
    json format_infill_prompt(const common_params & params, const json & data);
    std::vector<server_tokens> tokenize_embeddings(const json & prompt);
    std::vector<server_task> prepare_embeddings(
            server_response_reader & rd,
            std::vector<server_tokens> && tokenized_prompts,
            task_response_type res_type,
            int embd_normalize);
    std::vector<server_task> prepare_rerank(server_response_reader & rd, const json & query, const std::vector<std::string> & documents);
    std::vector<server_task> prepare_decision(
            server_response_reader & rd,
            const common_params & params,
            const std::vector<server_decision_question> & questions,
            const json & state,
            const std::vector<raw_buffer> & files);
    size_t count_tokens(const json & prompt, const std::vector<raw_buffer> & files);
    json tokenize(const json & body);
    json detokenize(const json & body);
};
