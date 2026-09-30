// Qualification of the public engine API with a representative chat model on
// the configured backend: tool calls, structured output, reasoning, streaming
// formats, media attachments, cancellation, shutdown, multi-model eviction and
// coexisting engines. Not part of the default test runs: it needs local models
// (see LLAMA_ENGINE_QUALIFY_* in tests/CMakeLists.txt).
//
// test-engine-qualification --model M [--gpu-layers N] [--second-model S]
//                           [--mmproj P --image I] [--audio-model A --audio-mmproj P --audio F]
#ifdef NDEBUG
#undef NDEBUG
#endif
#include "llama-engine.h"

#include <atomic>
#include <cassert>
#include <chrono>
#include <cstdio>
#include <fstream>
#include <iostream>
#include <iterator>
#include <map>
#include <string>
#include <thread>

using namespace llama_engine;
using namespace std::chrono_literals;
using clock_type = std::chrono::steady_clock;

static std::map<std::string, std::string> args;

static std::string arg(const std::string & name, const std::string & fallback = {}) {
    auto it = args.find(name);
    return it == args.end() ? fallback : it->second;
}

static std::vector<uint8_t> read_file(const std::string & path) {
    std::ifstream input(path, std::ios::binary);
    assert(input);
    return std::vector<uint8_t>(std::istreambuf_iterator<char>(input), {});
}

static config model_config(const std::string & path) {
    config settings;
    settings.model_path = path;
    settings.context_size = 4096;
    settings.parallel = 2;
    settings.threads = 4;
    settings.gpu_layers = std::stoi(arg("gpu-layers", "0"));
    settings.batch_size = settings.micro_batch_size = 512;
    return settings;
}

static json success(std::unique_ptr<request> req) {
    auto end = req->result();
    if (end.type != event_type::success) {
        std::cerr << "unexpected " << end.category << ": " << end.message << '\n';
    }
    assert(end.type == event_type::success);
    return end.data;
}

// Streams a chat request; returns the concatenated content, reasoning and
// tool-call argument fragments of choice 0.
struct chat_stream {
    std::string content, reasoning, tool_name, tool_arguments;
    int tool_fragments = 0;
    std::string finish_reason;
    double first_event_ms = -1;
};

static chat_stream stream_chat(engine & owner, json body, std::vector<attachment> files = {}) {
    body["stream"] = true;
    const auto start = clock_type::now();
    auto req = owner.submit(operation::chat, body, std::move(files));
    chat_stream out;
    for (;;) {
        auto ev = req->next_for(120s);
        assert(ev.type != event_type::timeout);
        if (out.first_event_ms < 0) {
            out.first_event_ms = std::chrono::duration<double, std::milli>(clock_type::now() - start).count();
        }
        if (ev.terminal()) {
            if (ev.type != event_type::success) { std::cerr << ev.category << ": " << ev.message << '\n'; }
            assert(ev.type == event_type::success);
            break;
        }
        const auto chunks = ev.data.is_array() ? ev.data : json::array({ev.data});
        for (const auto & chunk : chunks) {
            if (!chunk.is_object() || !chunk.contains("choices")) { continue; }
            for (const auto & choice : chunk["choices"]) {
                if (choice.contains("finish_reason") && choice["finish_reason"].is_string()) {
                    out.finish_reason = choice["finish_reason"];
                }
                const auto & delta = choice.value("delta", json::object());
                if (delta.contains("content") && delta["content"].is_string()) { out.content += delta["content"].get<std::string>(); }
                if (delta.contains("reasoning_content") && delta["reasoning_content"].is_string()) {
                    out.reasoning += delta["reasoning_content"].get<std::string>();
                }
                for (const auto & call : delta.value("tool_calls", json::array())) {
                    const auto & fn = call.value("function", json::object());
                    if (fn.contains("name") && fn["name"].is_string()) { out.tool_name += fn["name"].get<std::string>(); }
                    if (fn.contains("arguments") && fn["arguments"].is_string()) {
                        out.tool_arguments += fn["arguments"].get<std::string>();
                        out.tool_fragments++;
                    }
                }
            }
        }
    }
    return out;
}

static const json no_thinking = {{"enable_thinking", false}};

static void check_chat_formats(engine & owner) {
    // complete and streamed chat
    json body = {{"messages", {{{"role", "user"}, {"content", "Name three primary colors."}}}},
                 {"max_tokens", 48}, {"temperature", 0}, {"chat_template_kwargs", no_thinking}};
    auto full = success(owner.submit(operation::chat, body));
    assert(!full["choices"][0]["message"]["content"].get<std::string>().empty());
    assert(full["usage"]["completion_tokens"].get<int>() > 0);
    auto streamed = stream_chat(owner, body);
    assert(!streamed.content.empty() && !streamed.finish_reason.empty());
    std::cout << "PASS chat complete/stream (first event " << streamed.first_event_ms << " ms)\n";

    // tool calls, complete then streamed with argument fragments; the engine
    // produces them and never executes a tool
    json tools = json::array({{{"type", "function"}, {"function", {
        {"name", "get_weather"}, {"description", "Current weather for a city"},
        {"parameters", {{"type", "object"}, {"properties", {{"city", {{"type", "string"}}}}}, {"required", {"city"}}}}}}}});
    json tool_body = {{"messages", {{{"role", "user"}, {"content", "What is the weather in Paris?"}}}},
                      {"tools", tools}, {"tool_choice", "required"}, {"max_tokens", 128}, {"temperature", 0},
                      {"chat_template_kwargs", no_thinking}};
    auto called = success(owner.submit(operation::chat, tool_body));
    const auto & choice = called["choices"][0];
    assert(choice["finish_reason"] == "tool_calls");
    const auto & call = choice["message"]["tool_calls"][0]["function"];
    assert(call["name"] == "get_weather");
    assert(json::parse(call["arguments"].get<std::string>()).contains("city"));
    auto tool_stream = stream_chat(owner, tool_body);
    assert(tool_stream.tool_name == "get_weather" && tool_stream.finish_reason == "tool_calls");
    assert(json::parse(tool_stream.tool_arguments).contains("city"));
    std::cout << "PASS tool calls (" << tool_stream.tool_fragments << " streamed argument fragments: "
              << tool_stream.tool_arguments << ")\n";

    // tool result turn: the host executed the tool, the model answers
    json turn = tool_body;
    turn.erase("tool_choice");
    turn["messages"].push_back(choice["message"]);
    turn["messages"].push_back({{"role", "tool"}, {"tool_call_id", choice["message"]["tool_calls"][0].value("id", "")},
                                {"content", "{\"temperature\": 21, \"sky\": \"clear\"}"}});
    auto answered = success(owner.submit(operation::chat, turn));
    assert(!answered["choices"][0]["message"]["content"].get<std::string>().empty());
    std::cout << "PASS tool result turn\n";

    // structured output conforming to a JSON schema
    json schema = {{"type", "object"}, {"properties", {{"name", {{"type", "string"}}}, {"age", {{"type", "integer"}}},
                  {"skills", {{"type", "array"}, {"items", {{"type", "string"}}}, {"minItems", 1}}}}},
                  {"required", {"name", "age", "skills"}}, {"additionalProperties", false}};
    json structured = {{"messages", {{{"role", "user"}, {"content", "Invent a software engineer profile."}}}},
                       {"response_format", {{"type", "json_schema"}, {"json_schema", {{"name", "profile"}, {"schema", schema}}}}},
                       {"max_tokens", 160}, {"temperature", 0}, {"chat_template_kwargs", no_thinking}};
    auto profile = json::parse(success(owner.submit(operation::chat, structured))["choices"][0]["message"]["content"].get<std::string>());
    assert(profile["name"].is_string() && profile["age"].is_number_integer() && !profile["skills"].empty());
    assert(profile.size() == 3);
    std::cout << "PASS structured output " << profile.dump() << '\n';

    // reasoning deltas are separated from content
    json think = {{"messages", {{{"role", "user"}, {"content", "Is 17 prime? Answer yes or no."}}}},
                  {"max_tokens", 512}, {"temperature", 0}};
    auto reasoning = stream_chat(owner, think);
    assert(!reasoning.reasoning.empty());
    assert(reasoning.content.find("<think>") == std::string::npos);
    std::cout << "PASS reasoning (" << reasoning.reasoning.size() << " reasoning bytes)\n";

    // Responses and Anthropic semantic events, without SSE framing
    for (auto op : {operation::responses, operation::messages}) {
        json input = op == operation::responses
            ? json{{"input", "Say hello."}, {"max_output_tokens", 16}}
            : json{{"messages", {{{"role", "user"}, {"content", "Say hello."}}}}, {"max_tokens", 16}};
        input["temperature"] = 0;
        input["stream"] = true;
        input["chat_template_kwargs"] = no_thinking;
        auto req = owner.submit(op, input);
        std::string last;
        for (;;) {
            auto ev = req->next_for(60s);
            assert(ev.type != event_type::timeout);
            if (ev.terminal()) { assert(ev.type == event_type::success); break; }
            for (const auto & item : ev.data) { last = item["event"]; }
        }
        assert(last == (op == operation::responses ? "response.completed" : "message_stop"));
    }
    std::cout << "PASS responses/messages events\n";
}

static void check_cancellation(engine & owner) {
    // two concurrent generations: cancelling one leaves the other intact
    json body = {{"messages", {{{"role", "user"}, {"content", "Write a long story about a lighthouse."}}}},
                 {"max_tokens", 256}, {"temperature", 0}, {"stream", true}, {"chat_template_kwargs", no_thinking}};
    auto keep = owner.submit(operation::chat, body);
    auto drop = owner.submit(operation::chat, body);
    for (int i = 0; i < 4; ++i) { assert(!drop->next_for(60s).terminal()); }
    drop->cancel();
    event end;
    do { end = drop->next_for(60s); } while (!end.terminal());
    assert(end.type == event_type::cancelled);
    do { end = keep->next_for(60s); } while (!end.terminal());
    assert(end.type == event_type::success);
    std::cout << "PASS cancellation during generation\n";
}

static void check_stop_with_blocked_reader(const config & settings) {
    event error;
    auto owner = engine::create(settings, error);
    assert(owner);
    auto req = owner->submit(operation::chat, {{"messages", {{{"role", "user"}, {"content", "Count to one thousand."}}}},
                                               {"max_tokens", 2048}, {"stream", true}, {"chat_template_kwargs", no_thinking}});
    assert(!req->next_for(60s).terminal());
    std::atomic<bool> done {false};
    event end;
    std::thread reader([&] {
        do { end = req->next(); } while (!end.terminal());
        done = true;
    });
    owner->stop();
    reader.join();
    assert(done && end.type == event_type::cancelled);
    owner.reset();
    assert(req->next().type == event_type::cancelled); // handle outlives the engine
    std::cout << "PASS stop with a blocked reader (" << end.category << ")\n";
}

static void check_media(const std::string & model, const std::string & mmproj, const std::string & image) {
    auto settings = model_config(model);
    settings.mmproj_path = mmproj;
    event error;
    auto owner = engine::create(settings, error);
    if (!owner) { std::cerr << error.message << '\n'; }
    assert(owner);
    json body = {{"messages", {{{"role", "user"}, {"content", {
        {{"type", "text"}, {"text", "Describe this image in one sentence."}},
        {{"type", "image_url"}, {"image_url", {{"url", "attachment:image"}}}}}}}}},
        {"max_tokens", 48}, {"temperature", 0}, {"chat_template_kwargs", no_thinking}};
    auto text = success(owner->submit(operation::chat, body, {{"image", read_file(image)}}))["choices"][0]["message"]["content"];
    assert(!text.get<std::string>().empty());
    std::cout << "PASS vision: " << text.get<std::string>() << '\n';
}

static void check_audio(const std::string & model, const std::string & mmproj, const std::string & audio) {
    auto settings = model_config(model);
    settings.mmproj_path = mmproj;
    event error;
    auto owner = engine::create(settings, error);
    if (!owner) { std::cerr << error.message << '\n'; }
    assert(owner);
    // multipart contract: form fields are strings; the budget leaves room for the
    // model's thinking before the transcript (96 tokens yield an empty text upstream too)
    auto text = success(owner->submit(operation::transcription, {{"max_tokens", "512"}, {"temperature", "0"}},
                                      {{"file", read_file(audio)}}));
    assert(text.contains("text") && !text["text"].get<std::string>().empty());
    std::cout << "PASS transcription: " << text["text"].get<std::string>() << '\n';
    json body = {{"messages", {{{"role", "user"}, {"content", {
        {{"type", "text"}, {"text", "What language is spoken in this audio?"}},
        {{"type", "input_audio"}, {"input_audio", {{"data", "attachment:clip"}, {"format", "mp3"}}}}}}}}},
        {"max_tokens", 512}, {"temperature", 0}, {"chat_template_kwargs", no_thinking}};
    auto reply = success(owner->submit(operation::chat, body, {{"clip", read_file(audio)}}));
    assert(!reply["choices"][0]["message"]["content"].get<std::string>().empty());
    std::cout << "PASS audio chat: " << reply["choices"][0]["message"]["content"].get<std::string>() << '\n';
}

static void check_catalog(const std::string & first, const std::string & second) {
    catalog_config catalog;
    catalog.max_loaded = 1;
    catalog.models = {{"main", {"m"}, {}, model_config(first)}, {"second", {}, {}, model_config(second)}};
    event error;
    auto owner = engine::create_catalog(catalog, error);
    assert(owner);
    auto sub = owner->subscribe();
    assert(sub->next().data["type"] == "snapshot");
    json body = {{"messages", {{{"role", "user"}, {"content", "Hi"}}}}, {"max_tokens", 4}, {"chat_template_kwargs", no_thinking}};
    for (const char * model : {"m", "second", "main"}) {
        body["model"] = model;
        assert(success(owner->submit(operation::chat, body))["choices"].size() == 1);
    }
    std::vector<std::string> transitions;
    for (;;) {
        auto ev = sub->next_for(100ms);
        if (ev.type == event_type::timeout) { break; }
        if (ev.data["type"] == "status") { transitions.push_back(ev.data["model"].get<std::string>() + ":" + ev.data["status"].get<std::string>()); }
    }
    int unloads = 0;
    for (const auto & t : transitions) { unloads += t.find(":unloaded") != std::string::npos; }
    assert(unloads >= 2); // each switch evicted the idle model, limit 1
    auto snapshot = owner->catalog();
    int resident = 0;
    for (const auto & entry : snapshot) { resident += entry["status"] == "loaded"; }
    assert(resident == 1);
    assert(owner->unload("main").type == event_type::success);
    owner->stop();
    std::cout << "PASS multi-model eviction (" << transitions.size() << " status events)\n";
}

static void check_coexistence(const config & settings) {
    event error;
    auto a = engine::create(settings, error);
    auto b = engine::create(settings, error);
    assert(a && b);
    json body = {{"prompt", "Once upon a time"}, {"n_predict", 8}};
    a->stop();
    a.reset();
    assert(success(b->completion(body)).contains("content"));
    for (int i = 0; i < 3; ++i) {
        auto c = engine::create(settings, error);
        assert(c && success(c->completion(body)).contains("content"));
    }
    std::cout << "PASS coexisting engines and repeated create/stop\n";
}

int main(int argc, char ** argv) {
    for (int i = 1; i + 1 < argc; i += 2) {
        std::string name = argv[i];
        assert(name.rfind("--", 0) == 0);
        args[name.substr(2)] = argv[i + 1];
    }
    const auto model = arg("model");
    assert(!model.empty());
    const auto settings = model_config(model);
    {
        event error;
        auto owner = engine::create(settings, error);
        if (!owner) { std::cerr << error.category << ": " << error.message << '\n'; }
        assert(owner);
        check_chat_formats(*owner);
        check_cancellation(*owner);
    }
    check_stop_with_blocked_reader(settings);
    check_coexistence(settings);
    if (!arg("second-model").empty()) {
        check_catalog(model, arg("second-model"));
    }
    if (!arg("mmproj").empty()) {
        check_media(model, arg("mmproj"), arg("image"));
    }
    if (!arg("audio").empty()) {
        check_audio(arg("audio-model"), arg("audio-mmproj"), arg("audio"));
    }
    std::cout << "PASS qualification\n";
    return 0;
}
