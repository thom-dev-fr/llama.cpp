// Direct tests of the server inference core (engine/), without HTTP.
//
// usage: test-server-core <case> [-m model.gguf] [--mmproj mmproj.gguf] [--media file] [-ngl n]
//
// load        no fixture; with -m, also a missing projector
// lifecycle   small completion model (stories15M)
// chat, reasoning, tools, schema   chat model with a jinja template (reasoning: a thinking model)
// vision, audio                    model + projector + image or audio file
// embeddings  embedding model (bert-bge-small)
// rerank      reranker model (jina-reranker-v1-tiny-en)

#include "server-common.h"
#include "server-context.h"
#include "server-task.h"

#include "base64.hpp"
#include "common.h"
#include "llama.h"
#include "log.h"

#include <atomic>
#include <cmath>
#include <condition_variable>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <functional>
#include <iterator>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

static int g_failures = 0;

#define CHECK(cond) do { if (!(cond)) { fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); g_failures++; } } while (0)

static const auto never_stop = []() { return false; };

// a missing or null string field gives ""
static std::string str(const json & j, const std::string & key) {
    return j.contains(key) && j.at(key).is_string() ? j.at(key).get<std::string>() : "";
}

struct test_args {
    std::string model;
    std::string mmproj;
    std::string media;
    int n_gpu_layers = 0;
};

static common_params make_params(const test_args & args, int n_parallel = 1) {
    common_params params;
    params.model.path   = args.model;
    params.mmproj.path  = args.mmproj;
    params.n_gpu_layers = args.n_gpu_layers;
    params.mmproj_use_gpu = args.n_gpu_layers != 0;
    params.n_parallel   = n_parallel;
    params.n_ctx        = 2048 * n_parallel;
    params.warmup       = false;
    postprocess_cpu_params(params.cpuparams, nullptr);
    postprocess_cpu_params(params.cpuparams_batch, &params.cpuparams);
    return params;
}

// a loaded core with its decode loop on a thread
struct core_instance {
    common_params params;
    server_context ctx;
    std::unique_ptr<server_context_meta> meta;
    std::thread loop;

    explicit core_instance(const common_params & p) : params(p) {
        if (!ctx.load_model(params)) {
            return;
        }
        meta = std::make_unique<server_context_meta>(ctx.get_meta());
        loop = std::thread([this]() { ctx.start_loop(); });
    }

    ~core_instance() {
        stop();
    }

    bool loaded() const {
        return meta != nullptr;
    }

    void stop() {
        if (!loop.joinable()) {
            return;
        }
        // terminate() has no effect before start_loop() runs: wait for one answer from the loop first
        {
            server_response_reader rd = ctx.get_response_reader();
            server_task task(SERVER_TASK_TYPE_METRICS);
            task.id = rd.get_new_id();
            rd.post_task(std::move(task), true);
            CHECK(rd.next(never_stop) != nullptr);
        }
        ctx.terminate();
        loop.join();
    }

    // task ids of the busy slots
    std::vector<int> busy_tasks() {
        server_response_reader rd = ctx.get_response_reader();
        server_task task(SERVER_TASK_TYPE_SLOT_GET);
        task.id = rd.get_new_id();
        rd.post_task(std::move(task));
        auto res = rd.next(never_stop);
        auto * slots = dynamic_cast<server_task_result_slots *>(res.get());
        CHECK(slots != nullptr);
        std::vector<int> ids;
        if (slots) {
            for (const auto & sd : slots->slots_data) {
                if (sd.value("is_processing", false)) {
                    ids.push_back(sd.value("id_task", -1));
                }
            }
        }
        return ids;
    }

    // a cancel is applied by the loop after the current decode, so poll the slots; the bound only stops a hung run
    bool wait_idle(int never_seen_task = -1) {
        for (int i = 0; i < 100000; i++) {
            auto ids = busy_tasks();
            for (int id : ids) {
                CHECK(id != never_seen_task);
            }
            if (ids.empty()) {
                return true;
            }
        }
        return false;
    }
};

// the response of one request, as the HTTP API would return it
struct response {
    json error;        // null on success
    json body;         // non-stream: the response object; stream: the array of chunks
    json message;      // chat: the assistant message, rebuilt from the chunks when streamed
    std::string finish_reason;
    json usage;
};

static response collect(server_response_reader & rd, bool stream) {
    response out;
    if (!stream) {
        auto all = rd.wait_for_all(never_stop);
        if (all.error) {
            out.error = all.error->to_json();
            return out;
        }
        CHECK(all.results.size() == 1);
        out.body = all.results[0]->to_json();
        return out;
    }
    out.body = json::array();
    while (rd.has_next()) {
        auto res = rd.next(never_stop);
        if (res->is_error()) {
            out.error = res->to_json();
            return out;
        }
        json chunks = res->to_json();
        if (chunks.is_array()) {
            for (auto & c : chunks) {
                out.body.push_back(std::move(c));
            }
        } else if (!chunks.is_null()) {
            out.body.push_back(std::move(chunks));
        }
    }
    return out;
}

// rebuild the assistant message from the OAI chat chunks, as a client of the SSE stream does
static void rebuild_message(response & res) {
    json msg = {{"role", "assistant"}};
    std::string content;
    std::string reasoning;
    std::map<int, json> calls;
    for (const auto & chunk : res.body) {
        if (chunk.contains("usage")) {
            res.usage = chunk.at("usage");
        }
        for (const auto & choice : chunk.at("choices")) {
            const json & delta = choice.at("delta");
            content   += str(delta, "content");
            reasoning += str(delta, "reasoning_content");
            for (const auto & tc : delta.value("tool_calls", json::array())) {
                json & call = calls[tc.at("index").get<int>()];
                if (tc.contains("id")) {
                    CHECK(!call.contains("id")); // the id is sent once per call
                    call["id"] = tc.at("id");
                }
                const json fn = tc.value("function", json::object());
                if (fn.contains("name")) {
                    call["name"] = call.value("name", "") + fn.at("name").get<std::string>();
                }
                if (fn.contains("arguments")) {
                    call["arguments"] = call.value("arguments", "") + fn.at("arguments").get<std::string>();
                }
            }
            if (!choice.at("finish_reason").is_null()) {
                CHECK(res.finish_reason.empty()); // a single terminal chunk
                res.finish_reason = choice.at("finish_reason");
            }
        }
    }
    if (!content.empty()) {
        msg["content"] = content;
    }
    if (!reasoning.empty()) {
        msg["reasoning_content"] = reasoning;
    }
    if (!calls.empty()) {
        msg["tool_calls"] = json::array();
        for (auto & [idx, call] : calls) {
            msg["tool_calls"].push_back({
                {"id", call.value("id", "")},
                {"type", "function"},
                {"function", {{"name", call.value("name", "")}, {"arguments", call.value("arguments", "")}}},
            });
        }
    }
    res.message = msg;
}

// same steps as POST /v1/chat/completions, without the HTTP envelope
static response chat(core_instance & core, json body, bool stream, std::vector<raw_buffer> * files_out = nullptr) {
    body["stream"] = stream;
    // greedy and no prompt reuse, so stream and non-stream can be compared
    if (!body.contains("temperature")) {
        body["temperature"] = 0.0;
    }
    if (!body.contains("cache_prompt")) {
        body["cache_prompt"] = false;
    }
    if (stream) {
        body["stream_options"] = {{"include_usage", true}};
    }
    response out;
    server_response_reader rd = core.ctx.get_response_reader();
    try {
        std::vector<raw_buffer> files;
        json data = oaicompat_chat_params_parse(body, core.meta->chat_params, files);
        auto tasks = core.ctx.prepare_completion(rd, core.params, SERVER_TASK_TYPE_COMPLETION, data, files, TASK_RESPONSE_TYPE_OAI_CHAT);
        if (files_out) {
            // the caller buffers can go away once the tasks are prepared
            for (auto & f : files) {
                std::fill(f.begin(), f.end(), 0);
            }
            *files_out = std::move(files);
        }
        rd.post_tasks(std::move(tasks));
    } catch (const std::exception & e) {
        // HTTP gives 400 or 500 depending on the exception type, the parity check covers it
        out.error = format_error_response(e.what(), ERROR_TYPE_INVALID_REQUEST);
        return out;
    }
    out = collect(rd, stream);
    if (!out.error.is_null()) {
        return out;
    }
    if (stream) {
        rebuild_message(out);
    } else {
        const json & choice = out.body.at("choices").at(0);
        out.message       = choice.at("message");
        out.finish_reason = choice.at("finish_reason");
        out.usage         = out.body.at("usage");
    }
    return out;
}

static bool same_message(const json & a, const json & b) {
    // non-stream sends "content": "" with tool calls, the stream sends no content
    if (str(a, "content") != str(b, "content") || str(a, "reasoning_content") != str(b, "reasoning_content")) {
        return false;
    }
    const json ca = a.value("tool_calls", json::array());
    const json cb = b.value("tool_calls", json::array());
    if (ca.size() != cb.size()) {
        return false;
    }
    for (size_t i = 0; i < ca.size(); i++) {
        // ids are generated per request
        if (ca[i].at("function") != cb[i].at("function") || ca[i].value("id", "").empty() || cb[i].value("id", "").empty()) {
            return false;
        }
    }
    return true;
}

// non-stream and stream must give the same message, finish reason and token counts
static response chat_both(core_instance & core, const json & body) {
    response full = chat(core, body, false);
    response part = chat(core, body, true);
    CHECK(full.error.is_null() && part.error.is_null());
    if (!full.error.is_null() || !part.error.is_null()) {
        fprintf(stderr, "errors: %s | %s\n", full.error.dump().c_str(), part.error.dump().c_str());
        return full;
    }
    CHECK(same_message(full.message, part.message));
    CHECK(full.finish_reason == part.finish_reason);
    CHECK(full.usage.at("completion_tokens") == part.usage.at("completion_tokens"));
    CHECK(full.usage.at("prompt_tokens") == part.usage.at("prompt_tokens"));
    CHECK(full.usage.at("prompt_tokens").get<int>() > 0);
    if (!same_message(full.message, part.message)) {
        fprintf(stderr, "non-stream: %s\nstream:     %s\n", full.message.dump().c_str(), part.message.dump().c_str());
    }
    return full;
}

static bool read_file(const std::string & path, std::string & out) {
    std::ifstream f(path, std::ios::binary);
    if (!f) {
        return false;
    }
    out.assign(std::istreambuf_iterator<char>(f), std::istreambuf_iterator<char>());
    return true;
}

static json user(const json & content) {
    return json::array({{{"role", "user"}, {"content", content}}});
}

//
// load
//

static void test_load(const test_args & args, const char * self) {
    {
        common_params p = make_params(args);
        p.model.path = "/nonexistent/model.gguf";
        p.mmproj.path = "";
        core_instance core(p);
        CHECK(!core.loaded());
    }
    {
        // not a GGUF file
        common_params p = make_params(args);
        p.model.path = self;
        p.mmproj.path = "";
        core_instance core(p);
        CHECK(!core.loaded());
    }
    if (!args.model.empty()) {
        common_params p = make_params(args);
        p.mmproj.path = "/nonexistent/mmproj.gguf";
        core_instance core(p);
        CHECK(!core.loaded());
    }
    if (!args.model.empty()) {
        // a failed load leaves nothing behind that prevents a new load
        core_instance core(make_params(args));
        CHECK(core.loaded());
    }
}

//
// lifecycle (completion model)
//

static json cmpl(const std::string & prompt, int n_predict, bool stream) {
    return json {
        {"prompt", prompt},
        {"n_predict", n_predict},
        {"ignore_eos", true},
        {"stream", stream},
        {"temperature", 0.0},
    };
}

static void post_completion(core_instance & core, server_response_reader & rd, const json & data) {
    rd.post_tasks(core.ctx.prepare_completion(rd, core.params, SERVER_TASK_TYPE_COMPLETION, data, {}, TASK_RESPONSE_TYPE_NONE));
}

// returns the generated text, or the error message
static std::string complete(core_instance & core, const std::string & prompt, int n_predict, int * n_decoded = nullptr) {
    server_response_reader rd = core.ctx.get_response_reader();
    post_completion(core, rd, cmpl(prompt, n_predict, false));
    auto all = rd.wait_for_all(never_stop);
    if (all.error) {
        return "error: " + all.error->to_json().dump();
    }
    auto * fin = dynamic_cast<server_task_result_cmpl_final *>(all.results.at(0).get());
    CHECK(fin != nullptr);
    if (n_decoded) {
        *n_decoded = fin ? fin->n_decoded : -1;
    }
    return fin ? fin->content : "";
}

static void test_lifecycle(const test_args & args) {
    const std::string p1 = "Once upon a time";
    const std::string p2 = "The little dog";

    std::string ref1;
    std::string ref2;
    {
        core_instance core(make_params(args));
        CHECK(core.loaded());
        if (!core.loaded()) {
            return;
        }

        // completed, and the stream gives the same text
        int n_decoded = 0;
        ref1 = complete(core, p1, 16, &n_decoded);
        ref2 = complete(core, p2, 16);
        CHECK(n_decoded == 16);
        {
            server_response_reader rd = core.ctx.get_response_reader();
            post_completion(core, rd, cmpl(p1, 16, true));
            response res = collect(rd, true);
            std::string text;
            int n_stop = 0;
            for (const auto & c : res.body) {
                text += str(c, "content");
                n_stop += c.value("stop", false) ? 1 : 0;
            }
            CHECK(res.error.is_null());
            CHECK(text == ref1);
            CHECK(n_stop == 1);
        }

        // invalid input is reported, and the core still serves the next request
        {
            server_response_reader rd = core.ctx.get_response_reader();
            bool thrown = false;
            try {
                post_completion(core, rd, json {{"n_predict", 4}});
            } catch (const std::exception &) {
                thrown = true;
            }
            CHECK(thrown);
        }
        {
            json tok = core.ctx.tokenize({{"content", p1}});
            json detok = core.ctx.detokenize({{"tokens", tok.at("tokens")}});
            CHECK(!tok.at("tokens").empty());
            CHECK(detok.at("content").get<std::string>().find(p1) != std::string::npos);
        }

        // active then cancelled: the slot is released and the next request gives the same text
        {
            server_response_reader rd = core.ctx.get_response_reader();
            post_completion(core, rd, cmpl(p1, 400, true));
            auto first = rd.next(never_stop);
            CHECK(first != nullptr && !first->is_error());
        }
        CHECK(core.wait_idle());
        CHECK(complete(core, p1, 16) == ref1);

        // queued then cancelled while another one is active: it never runs, the active one is not affected
        {
            server_response_reader rd_a = core.ctx.get_response_reader();
            post_completion(core, rd_a, cmpl(p1, 32, true));
            auto first = rd_a.next(never_stop);
            CHECK(first != nullptr && !first->is_error());

            int id_b = -1;
            {
                server_response_reader rd_b = core.ctx.get_response_reader();
                auto tasks = core.ctx.prepare_completion(rd_b, core.params, SERVER_TASK_TYPE_COMPLETION, cmpl(p2, 400, false), {}, TASK_RESPONSE_TYPE_NONE);
                id_b = tasks[0].id;
                rd_b.post_tasks(std::move(tasks));
                rd_b.stop();
            }
            int n_final = -1;
            while (rd_a.has_next()) {
                auto res = rd_a.next(never_stop);
                CHECK(res != nullptr && !res->is_error());
                if (auto * fin = dynamic_cast<server_task_result_cmpl_final *>(res.get())) {
                    n_final = fin->n_decoded;
                }
            }
            CHECK(n_final == 32);
            CHECK(core.wait_idle(id_b));
        }
    }

    // simultaneous requests on one model: no cross-request contamination
    {
        core_instance core(make_params(args, 2));
        CHECK(core.loaded());
        std::string out1;
        std::string out2;
        std::thread t1([&]() { out1 = complete(core, p1, 16); });
        std::thread t2([&]() { out2 = complete(core, p2, 16); });
        t1.join();
        t2.join();
        CHECK(out1 == ref1);
        CHECK(out2 == ref2);
    }

    // two independently owned instances at the same time
    {
        core_instance a(make_params(args));
        core_instance b(make_params(args));
        CHECK(a.loaded() && b.loaded());
        std::string out_a;
        std::string out_b;
        std::thread ta([&]() { out_a = complete(a, p1, 16); });
        std::thread tb([&]() { out_b = complete(b, p2, 16); });
        ta.join();
        tb.join();
        CHECK(out_a == ref1);
        CHECK(out_b == ref2);
        a.stop();
        CHECK(complete(b, p1, 16) == ref1); // stopping one does not affect the other
    }

    // termination while a reader waits: terminate() does not wake it, its should_stop does
    {
        core_instance core(make_params(args));
        std::atomic<bool> stop_reader { false };
        std::mutex mtx;
        std::condition_variable cv;
        bool first_seen = false;
        bool returned_null = false;

        server_response_reader rd = core.ctx.get_response_reader();
        post_completion(core, rd, cmpl(p1, 100000, true));

        std::thread reader([&]() {
            while (true) {
                auto res = rd.next([&]() { return stop_reader.load(); });
                if (res == nullptr) {
                    returned_null = true;
                    break;
                }
                std::lock_guard<std::mutex> lock(mtx);
                if (!first_seen) {
                    first_seen = true;
                    cv.notify_all();
                }
            }
        });
        {
            std::unique_lock<std::mutex> lock(mtx);
            cv.wait(lock, [&]() { return first_seen; });
        }
        core.stop();
        stop_reader = true;
        reader.join();
        CHECK(returned_null);
        // rd is destroyed before core (declaration order)
    }

    // repeated load, request, stop
    for (int i = 0; i < 3; i++) {
        core_instance core(make_params(args, 2));
        CHECK(core.loaded());
        CHECK(complete(core, p1, 16) == ref1);
    }
}

//
// chat model
//

static const json no_thinking = {{"enable_thinking", false}};

static void test_chat(const test_args & args) {
    core_instance core(make_params(args));
    CHECK(core.loaded());
    if (!core.loaded()) {
        return;
    }

    // stopped by the token limit
    response r = chat_both(core, {
        {"messages", user("Write a long story about a cat.")},
        {"max_tokens", 8},
        {"chat_template_kwargs", no_thinking},
    });
    CHECK(r.finish_reason == "length");
    CHECK(r.usage.value("completion_tokens", 0) == 8);
    CHECK(!str(r.message, "content").empty());

    // stopped by the model
    r = chat_both(core, {
        {"messages", user("Say hello in one word.")},
        {"max_tokens", 64},
        {"chat_template_kwargs", no_thinking},
    });
    CHECK(r.finish_reason == "stop");
    CHECK(r.usage.value("completion_tokens", 0) < 64);
    CHECK(!str(r.message, "content").empty());

    // invalid requests
    for (const json & body : {
            json {{"messages", "hello"}},
            json {{"messages", json::array()}},
            json {{"messages", user("hi")}, {"response_format", {{"type", "unknown"}}}},
            json {{"messages", user("hi")}, {"n_probs", "x"}},
        }) {
        for (bool stream : {false, true}) {
            response e = chat(core, body, stream);
            CHECK(!e.error.is_null() && !str(e.error, "message").empty());
        }
    }

    // the core still serves requests after the errors
    r = chat(core, {{"messages", user("Say hello in one word.")}, {"max_tokens", 4}, {"chat_template_kwargs", no_thinking}}, true);
    CHECK(r.error.is_null() && !r.finish_reason.empty());
}

static void test_reasoning(const test_args & args) {
    core_instance core(make_params(args));
    CHECK(core.loaded());
    if (!core.loaded()) {
        return;
    }
    const json q = user("What is 17 + 25? Answer with the number only.");

    response on = chat_both(core, {{"messages", q}, {"max_tokens", 2048}, {"chat_template_kwargs", {{"enable_thinking", true}}}});
    CHECK(!str(on.message, "reasoning_content").empty());
    CHECK(str(on.message, "content").find("42") != std::string::npos);
    CHECK(str(on.message, "content").find("<think>") == std::string::npos);
    CHECK(on.finish_reason == "stop");

    response off = chat_both(core, {{"messages", q}, {"max_tokens", 2048}, {"chat_template_kwargs", no_thinking}});
    CHECK(!off.message.contains("reasoning_content"));
    CHECK(str(off.message, "content").find("42") != std::string::npos);
    CHECK(off.usage.value("completion_tokens", 0) < on.usage.value("completion_tokens", 0));

    // reasoning_format none keeps the reasoning in the content
    response raw = chat(core, {{"messages", q}, {"max_tokens", 2048}, {"reasoning_format", "none"}, {"chat_template_kwargs", {{"enable_thinking", true}}}}, false);
    CHECK(raw.error.is_null());
    CHECK(!raw.message.contains("reasoning_content"));
    CHECK(str(raw.message, "content").find("</think>") != std::string::npos);
}

static void test_tools(const test_args & args) {
    core_instance core(make_params(args));
    CHECK(core.loaded());
    if (!core.loaded()) {
        return;
    }
    const json tools = json::array({{
        {"type", "function"},
        {"function", {
            {"name", "get_weather"},
            {"description", "Get the current weather in a city"},
            {"parameters", {
                {"type", "object"},
                {"properties", {{"city", {{"type", "string"}}}}},
                {"required", json::array({"city"})},
            }},
        }},
    }});
    const json q = user("What is the weather in Paris?");

    for (const std::string choice : {"required", "auto"}) {
        response r = chat_both(core, {{"messages", q}, {"tools", tools}, {"tool_choice", choice}, {"max_tokens", 256}, {"chat_template_kwargs", no_thinking}});
        const json calls = r.message.value("tool_calls", json::array());
        CHECK(calls.size() == 1);
        CHECK(r.finish_reason == "tool_calls");
        if (calls.size() == 1) {
            CHECK(calls[0].at("function").at("name") == "get_weather");
            json arguments = json::parse_no_throw(calls[0].at("function").at("arguments").get<std::string>());
            CHECK(arguments.is_object() && arguments.value("city", "").find("Paris") != std::string::npos);
        }
    }

    response none = chat_both(core, {{"messages", q}, {"tools", tools}, {"tool_choice", "none"}, {"max_tokens", 64}, {"chat_template_kwargs", no_thinking}});
    CHECK(!none.message.contains("tool_calls"));
    CHECK(none.finish_reason != "tool_calls");

    // the host runs the tool and sends its result back
    json messages = q;
    messages.push_back({
        {"role", "assistant"},
        {"content", ""},
        {"tool_calls", json::array({{{"id", "call_1"}, {"type", "function"}, {"function", {{"name", "get_weather"}, {"arguments", "{\"city\":\"Paris\"}"}}}}})},
    });
    messages.push_back({{"role", "tool"}, {"tool_call_id", "call_1"}, {"content", "{\"temperature_c\": 22, \"sky\": \"sunny\"}"}});
    response after = chat_both(core, {{"messages", messages}, {"tools", tools}, {"max_tokens", 128}, {"chat_template_kwargs", no_thinking}});
    CHECK(!after.message.contains("tool_calls"));
    CHECK(str(after.message, "content").find("22") != std::string::npos);

    // unknown tool_choice value
    response e = chat(core, {{"messages", q}, {"tools", tools}, {"tool_choice", "sometimes"}}, false);
    CHECK(!e.error.is_null());
}

static void test_schema(const test_args & args) {
    core_instance core(make_params(args));
    CHECK(core.loaded());
    if (!core.loaded()) {
        return;
    }
    const json schema = {
        {"type", "object"},
        {"properties", {
            {"name", {{"type", "string"}}},
            {"age", {{"type", "integer"}, {"minimum", 0}}},
        }},
        {"required", json::array({"name", "age"})},
        {"additionalProperties", false},
    };
    const json q = user("Invent a person. Give a name and an age.");

    for (const json & format : {
            json {{"type", "json_schema"}, {"json_schema", {{"name", "person"}, {"schema", schema}}}},
            json {{"type", "json_object"}, {"schema", schema}},
        }) {
        response r = chat_both(core, {{"messages", q}, {"response_format", format}, {"max_tokens", 128}, {"chat_template_kwargs", no_thinking}});
        json out = json::parse_no_throw(str(r.message, "content"));
        CHECK(out.is_object());
        if (out.is_object()) {
            CHECK(out.size() == 2);
            CHECK(out.contains("name") && out.at("name").is_string());
            CHECK(out.contains("age") && out.at("age").is_number_integer() && out.at("age").get<int>() >= 0);
        }
    }

    // a GBNF grammar
    response g = chat_both(core, {{"messages", user("Is the sky blue?")}, {"grammar", "root ::= \"yes\" | \"no\""}, {"max_tokens", 8}, {"chat_template_kwargs", no_thinking}});
    const std::string answer = str(g.message, "content");
    CHECK(answer == "yes" || answer == "no");

    // invalid combinations, as for HTTP
    for (const json & body : {
            json {{"messages", q}, {"json_schema", schema}, {"grammar", "root ::= \"a\""}},
            json {{"messages", q}, {"grammar", "root ::= ("}},
        }) {
        response e = chat(core, body, false);
        CHECK(!e.error.is_null());
    }
}

//
// multimodal
//

static json media_part(const std::string & kind, const std::string & bytes) {
    if (kind == "audio") {
        return {{"type", "input_audio"}, {"input_audio", {{"data", base64::encode(bytes)}, {"format", "mp3"}}}};
    }
    return {{"type", "image_url"}, {"image_url", {{"url", "data:image/jpeg;base64," + base64::encode(bytes)}}}};
}

static void test_media(const test_args & args, const std::string & kind) {
    std::string bytes;
    CHECK(read_file(args.media, bytes));
    if (bytes.empty()) {
        return;
    }
    const std::string ask = kind == "audio" ? "What is said in this audio?" : "What is in this image?";

    response text_only;
    {
        core_instance core(make_params(args));
        CHECK(core.loaded());
        if (!core.loaded()) {
            return;
        }
        CHECK(kind == "audio" ? core.meta->has_inp_audio : core.meta->has_inp_image);

        const json body = {
            {"messages", user(json::array({media_part(kind, bytes), {{"type", "text"}, {"text", ask}}}))},
            {"max_tokens", 48},
            {"chat_template_kwargs", no_thinking},
        };
        response r = chat_both(core, body);
        CHECK(!str(r.message, "content").empty());
        text_only = chat(core, {{"messages", user(ask)}, {"max_tokens", 4}, {"chat_template_kwargs", no_thinking}}, false);
        CHECK(r.usage.value("prompt_tokens", 0) > text_only.usage.value("prompt_tokens", 0) + 16);

        // the request does not depend on the caller buffers after preparation
        std::vector<raw_buffer> files;
        json b = body;
        response cleared = chat(core, b, false, &files);
        CHECK(files.size() == 1);
        CHECK(cleared.error.is_null() && cleared.message == r.message);

        // invalid media bytes
        response bad = chat(core, {{"messages", user(json::array({media_part(kind, std::string(256, 'x')), {{"type", "text"}, {"text", ask}}}))}, {"max_tokens", 4}}, false);
        CHECK(!bad.error.is_null());
        // remote URLs need a host fetcher
        response remote = chat(core, {{"messages", user(json::array({{{"type", "image_url"}, {"image_url", {{"url", "https://example.invalid/a.jpg"}}}}}))}, {"max_tokens", 4}}, false);
        CHECK(!remote.error.is_null());
    }

    // the same model without the projector
    {
        test_args no_proj = args;
        no_proj.mmproj.clear();
        core_instance core(make_params(no_proj));
        CHECK(core.loaded());
        response e = chat(core, {{"messages", user(json::array({media_part(kind, bytes), {{"type", "text"}, {"text", ask}}}))}, {"max_tokens", 4}}, false);
        CHECK(!e.error.is_null());
    }
}

//
// embeddings and rerank
//

static void test_embeddings(const test_args & args) {
    common_params p = make_params(args);
    p.embedding = true;
    p.n_batch = p.n_ubatch; // as llama-server does for embeddings
    core_instance core(p);
    CHECK(core.loaded());
    if (!core.loaded()) {
        return;
    }
    CHECK(core.meta->pooling_type != LLAMA_POOLING_TYPE_NONE);

    const json input = json::array({"I like cats.", "I like dogs.", "The stock market fell today."});
    for (bool use_base64 : {false, true}) {
        const json body = {{"input", input}, {"encoding_format", use_base64 ? "base64" : "float"}};
        auto prompts = core.ctx.tokenize_embeddings(input);
        CHECK(prompts.size() == 3);
        server_response_reader rd = core.ctx.get_response_reader();
        rd.post_tasks(core.ctx.prepare_embeddings(rd, std::move(prompts), TASK_RESPONSE_TYPE_OAI_EMBD, p.embd_normalize));
        auto all = rd.wait_for_all(never_stop);
        CHECK(!all.error && all.results.size() == 3);
        json responses = json::array();
        for (auto & r : all.results) {
            responses.push_back(r->to_json());
        }
        json root = format_embeddings_response_oaicompat(body, core.meta->model_name, responses, use_base64);
        const json & data = root.at("data");
        CHECK(data.size() == 3);

        std::vector<std::vector<float>> vecs;
        for (size_t i = 0; i < data.size(); i++) {
            CHECK(data[i].at("index") == (int) i);
            std::vector<float> v;
            if (use_base64) {
                const std::string raw = base64::decode(data[i].at("embedding").get<std::string>());
                v.resize(raw.size() / sizeof(float));
                memcpy(v.data(), raw.data(), v.size() * sizeof(float));
            } else {
                v = data[i].at("embedding").get<std::vector<float>>();
            }
            CHECK((int) v.size() == core.meta->model_n_embd_inp);
            double norm = 0.0;
            bool finite = true;
            for (float x : v) {
                finite = finite && std::isfinite(x);
                norm += (double) x * x;
            }
            CHECK(finite);
            CHECK(std::fabs(std::sqrt(norm) - 1.0) < 1e-3);
            vecs.push_back(std::move(v));
        }
        if (vecs.size() == 3) {
            auto dot = [](const std::vector<float> & a, const std::vector<float> & b) {
                double s = 0.0;
                for (size_t i = 0; i < a.size(); i++) {
                    s += (double) a[i] * b[i];
                }
                return s;
            };
            CHECK(dot(vecs[0], vecs[1]) > dot(vecs[0], vecs[2]));
        }
        CHECK(root.at("usage").at("prompt_tokens").get<int>() > 0);
    }

    // empty input gives no prompt, the caller reports it
    CHECK(core.ctx.tokenize_embeddings(json::array()).empty());
}

static void test_rerank(const test_args & args) {
    common_params p = make_params(args);
    p.embedding = true;
    p.pooling_type = LLAMA_POOLING_TYPE_RANK;
    p.n_batch = p.n_ubatch;
    core_instance core(p);
    CHECK(core.loaded());
    if (!core.loaded()) {
        return;
    }

    std::vector<std::string> documents = {
        "A machine is a physical system that uses power to apply forces.",
        "Learning is the process of acquiring new understanding.",
        "The giant panda is a bear species endemic to China.",
        "Paris is the capital of France.",
    };
    const json query = "What is a panda?";
    for (int top_n : {4, 2}) {
        const json body = {{"query", query}, {"documents", documents}, {"top_n", top_n}};
        server_response_reader rd = core.ctx.get_response_reader();
        rd.post_tasks(core.ctx.prepare_rerank(rd, query, documents));
        auto all = rd.wait_for_all(never_stop);
        CHECK(!all.error && all.results.size() == documents.size());
        json ranks = json::array();
        for (auto & r : all.results) {
            ranks.push_back(r->to_json());
        }
        json root = format_response_rerank(body, core.meta->model_name, ranks, false, documents, top_n);
        const json & results = root.at("results");
        CHECK((int) results.size() == top_n);
        double prev = INFINITY;
        std::vector<bool> seen(documents.size(), false);
        for (const auto & r : results) {
            const int idx = r.at("index").get<int>();
            const double score = r.at("relevance_score").get<double>();
            CHECK(idx >= 0 && idx < (int) documents.size() && !seen[idx]);
            if (idx >= 0 && idx < (int) documents.size()) {
                seen[idx] = true;
            }
            CHECK(std::isfinite(score) && score <= prev);
            prev = score;
        }
        CHECK(results.at(0).at("index") == 2);
    }
}

int main(int argc, char ** argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: %s <case> [-m model.gguf] [--mmproj mmproj.gguf] [--media file] [-ngl n]\n", argv[0]);
        return 2;
    }
    const std::string name = argv[1];
    test_args args;
    for (int i = 2; i + 1 < argc; i += 2) {
        const std::string arg = argv[i];
        if (arg == "-m") {
            args.model = argv[i + 1];
        } else if (arg == "--mmproj") {
            args.mmproj = argv[i + 1];
        } else if (arg == "--media") {
            args.media = argv[i + 1];
        } else if (arg == "-ngl") {
            args.n_gpu_layers = std::stoi(argv[i + 1]);
        } else {
            fprintf(stderr, "unknown argument: %s\n", arg.c_str());
            return 2;
        }
    }

    const std::map<std::string, std::function<void()>> cases = {
        {"load",       [&]() { test_load(args, argv[0]); }},
        {"lifecycle",  [&]() { test_lifecycle(args); }},
        {"chat",       [&]() { test_chat(args); }},
        {"reasoning",  [&]() { test_reasoning(args); }},
        {"tools",      [&]() { test_tools(args); }},
        {"schema",     [&]() { test_schema(args); }},
        {"vision",     [&]() { test_media(args, "image"); }},
        {"audio",      [&]() { test_media(args, "audio"); }},
        {"embeddings", [&]() { test_embeddings(args); }},
        {"rerank",     [&]() { test_rerank(args); }},
    };
    auto it = cases.find(name);
    if (it == cases.end()) {
        fprintf(stderr, "unknown case: %s\n", name.c_str());
        return 2;
    }
    if (name != "load" && args.model.empty()) {
        fprintf(stderr, "case %s needs -m\n", name.c_str());
        return 2;
    }
    if ((name == "vision" || name == "audio") && (args.mmproj.empty() || args.media.empty())) {
        fprintf(stderr, "case %s needs --mmproj and --media\n", name.c_str());
        return 2;
    }

    common_init();
    llama_backend_init();
    it->second();
    llama_backend_free();

    printf("%s: %s (%d failures)\n", name.c_str(), g_failures ? "FAILED" : "OK", g_failures);
    return g_failures ? 1 : 0;
}
