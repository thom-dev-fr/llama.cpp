#ifdef NDEBUG
#undef NDEBUG
#endif
#include "llama-engine.h"
#include <cassert>
#include <chrono>
#include <filesystem>
#include <future>
#include <iostream>

using namespace llama_engine;
using namespace std::chrono_literals;

static event success(std::unique_ptr<request> req) {
    auto result = req->result();
    if (result.type != event_type::success) { std::cerr << result.category << ": " << result.message << '\n'; }
    assert(result.type == event_type::success);
    return result;
}
static json chat() {
    return {{"messages", {{{"role", "user"}, {"content", "Hello"}}}},
            {"max_tokens", 8}, {"temperature", 0}, {"ignore_eos", true}};
}
static void stream(engine & owner, operation op, json body) {
    body["stream"] = true;
    auto req = owner.submit(op, body);
    int payloads = 0;
    bool final = false;
    for (;;) {
        auto item = req->next_for(10s);
        assert(item.type != event_type::timeout);
        if (item.terminal()) {
            if (item.type != event_type::success) { std::cerr << item.message << '\n'; }
            assert(item.type == event_type::success);
            assert(req->next().type == event_type::success);
            break;
        }
        ++payloads;
        if (op == operation::responses || op == operation::messages) {
            if (item.data.is_null()) { continue; }
            assert(item.data.is_array());
            for (const auto & event : item.data) {
                assert(event.contains("event") && event.contains("data"));
                const auto name = event["event"].get<std::string>();
                final |= name == "response.completed" || name == "message_stop";
            }
        } else {
            const auto chunks = item.data.is_array() ? item.data : json::array({item.data});
            for (const auto & chunk : chunks) {
                if (!chunk.is_object() || !chunk.contains("choices")) { continue; }
                for (const auto & choice : chunk["choices"]) {
                    final |= choice.contains("finish_reason") && !choice["finish_reason"].is_null();
                }
            }
        }
    }
    assert(payloads > 1 && final);
}
int main(int argc, char ** argv) {
    assert(argc == 2);
    config settings;
    settings.model_path = argv[1];
    settings.context_size = 1024;
    settings.parallel = 2;
    settings.chat_template = "chatml";
    const auto dir = std::filesystem::temp_directory_path() /
        ("engine-operations-" + std::to_string(std::chrono::steady_clock::now().time_since_epoch().count()));
    std::filesystem::create_directory(dir);
    settings.slot_save_path = dir.string();
    event error;
    auto owner = engine::create(settings, error);
    assert(owner);
    auto tokens = success(owner->submit(operation::tokenize, {{"content", "Hello"}})).data["tokens"];
    assert(!tokens.empty());
    assert(success(owner->submit(operation::detokenize, {{"tokens", tokens}})).data["content"].is_string());
    assert(success(owner->submit(operation::tokenize, {{"content", "Hello"}, {"with_pieces", true}})).data["tokens"][0].contains("piece"));
    auto props = success(owner->submit(operation::properties)).data;
    assert(props.contains("chat_template") && props["is_sleeping"] == false);
    assert(success(owner->submit(operation::properties_update)).data["success"] == true);
    assert(success(owner->submit(operation::models)).data["data"].size() == 1);
    auto cmpl = json{{"prompt", "Once upon a time"}, {"n_predict", 8}, {"temperature", 0}, {"ignore_eos", true}};
    assert(success(owner->submit(operation::completions, cmpl)).data["choices"].size() == 1);
    cmpl["n"] = 2;
    assert(success(owner->submit(operation::completions, cmpl)).data["choices"].size() == 2);
    stream(*owner, operation::completions, cmpl);
    auto body = chat();
    assert(success(owner->submit(operation::apply_template, body)).data["prompt"].is_string());
    assert(success(owner->submit(operation::chat_tokens, body)).data["input_tokens"].get<int>() > 0);
    assert(success(owner->submit(operation::chat, body)).data["choices"][0]["message"].contains("content"));
    stream(*owner, operation::chat, body);
    // Force a small supported structured output, independently of model quality.
    body["response_format"] = {{"type", "json_schema"}, {"json_schema", {{"schema", {{"type", "boolean"}}}}}};
    body["max_tokens"] = 32;
    body["ignore_eos"] = false;
    auto structured = success(owner->submit(operation::chat, body)).data["choices"][0]["message"]["content"].get<std::string>();
    assert(json::parse(structured).is_boolean());
    auto responses = json{{"input", "Hello"}, {"max_output_tokens", 8}, {"temperature", 0}, {"ignore_eos", true}};
    assert(success(owner->submit(operation::responses, responses)).data.contains("output"));
    assert(success(owner->submit(operation::response_tokens, responses)).data["object"] == "response.input_tokens");
    stream(*owner, operation::responses, responses);
    body = chat();
    assert(success(owner->submit(operation::messages, body)).data.contains("content"));
    assert(success(owner->submit(operation::message_tokens, body)).data.contains("input_tokens"));
    stream(*owner, operation::messages, body);
    assert(success(owner->submit(operation::lora_list)).data.empty());
    assert(success(owner->submit(operation::lora_apply, json::array())).data["success"] == true);
    assert(owner->submit(operation::lora_apply, json::object())->result().type == event_type::error);
    assert(owner->submit(operation::control, {{"id", "absent"}, {"action", "wrong"}})->result().type == event_type::error);
    assert(success(owner->submit(operation::control, {{"id", "absent"}, {"action", "reasoning_end"}})).data.contains("success"));
    assert(success(owner->submit(operation::slots)).data.size() == 2);
    auto saved = success(owner->submit(operation::slot_save, {{"id_slot", 0}, {"filename", "slot.bin"}}));
    assert(saved.data.contains("n_saved"));
    assert(success(owner->submit(operation::slot_erase, {{"id_slot", 0}})).data.contains("n_erased"));
    assert(success(owner->submit(operation::slot_restore, {{"id_slot", 0}, {"filename", "slot.bin"}})).data.contains("n_restored"));
    assert(owner->submit(operation::slot_save, {{"id_slot", 0}, {"filename", "../bad"}})->result().type == event_type::error);
    auto metrics = success(owner->submit(operation::metrics)).data;
    assert(metrics.contains("counters") && metrics.contains("gauges") && metrics.contains("t_start"));
    assert(owner->submit(operation::transcription, {}, {{"file", {1,2,3}}})->result().type == event_type::error);
    assert(owner->submit(operation::rerank, {{"query", "x"}, {"documents", {"y"}}})->result().type == event_type::error);
    owner->stop();
    assert(props.contains("chat_template")); // owned snapshot survives stop
    assert(owner->submit(operation::tokenize, {})->result().type == event_type::cancelled);
    std::filesystem::remove_all(dir);

    // The same bounded sink protects chat deltas; a stalled reader must not
    // block an unrelated request or lose its terminal overflow error.
    config bounded_settings = settings;
    bounded_settings.slot_save_path.clear();
    bounded_settings.max_events = 1;
    auto bounded = engine::create(bounded_settings, error);
    assert(bounded);
    body = chat(); body["stream"] = true; body["max_tokens"] = 64;
    auto stalled = bounded->submit(operation::chat, body);
    success(bounded->submit(operation::chat, chat()));
    event end;
    do { end = stalled->next_for(10s); assert(end.type != event_type::timeout); } while (!end.terminal());
    assert(end.category == "queue_full");
    bounded.reset();

    // Stop races with immediate snapshots and queued administrative operations.
    auto concurrent = engine::create(settings, error);
    assert(concurrent);
    std::promise<void> go;
    auto gate = go.get_future().share();
    std::vector<std::future<void>> workers;
    for (auto op : {operation::properties, operation::tokenize, operation::metrics, operation::slots}) {
        workers.push_back(std::async(std::launch::async, [&, op] {
            gate.wait();
            for (int i = 0; i < 24; ++i) {
                auto end = concurrent->submit(op, {{"content", "Once"}})->result();
                assert(end.type == event_type::success || end.type == event_type::cancelled);
            }
        }));
    }
    go.set_value();
    workers.front().wait();
    concurrent->stop();
    for (auto & worker : workers) { worker.get(); }

    settings.embeddings = true;
    settings.pooling_type = 1; // mean pooling
    settings.slot_save_path.clear();
    auto embedding = engine::create(settings, error);
    assert(embedding);
    auto vector = success(embedding->submit(operation::embeddings, {{"input", "Hello"}})).data;
    assert(vector.is_array() && vector.size() == 1);
    auto vectors = success(embedding->submit(operation::embeddings_openai, {{"input", {"Hello", "World"}}, {"encoding_format", "base64"}})).data;
    assert(vectors["data"].size() == 2 && vectors["data"][0]["embedding"].is_string());
    std::cout << "PASS direct operation families, semantic streaming, structured output and slots\n";
}
