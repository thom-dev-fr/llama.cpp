#ifdef NDEBUG
#undef NDEBUG
#endif
#include "llama-engine.h"
#include <cassert>
#include <fstream>
#include <iostream>
#include <iterator>

using namespace llama_engine;
using namespace std::chrono_literals;

static json result(std::unique_ptr<request> req) {
    auto end = req->result();
    if (end.type != event_type::success) { std::cerr << end.category << ": " << end.message << '\n'; }
    assert(end.type == event_type::success);
    return end.data;
}
int main(int argc, char ** argv) {
    assert(argc >= 3);
    std::string mode = argv[1];
    config settings;
    settings.model_path = argv[2];
    settings.context_size = 2048;
    settings.batch_size = settings.micro_batch_size = 512;
    if (mode == "rerank") {
        settings.embeddings = true;
        settings.pooling_type = 4; // rank
    } else if (mode == "vision") {
        assert(argc == 5);
        settings.mmproj_path = argv[3];
    } else {
        assert(mode == "infill");
    }
    event error;
    auto owner = engine::create(settings, error);
    if (!owner) { std::cerr << error.message << '\n'; }
    assert(owner);
    if (mode == "rerank") {
        const auto documents = json::array({"Paris is the capital of France.", "Machine learning uses statistical algorithms."});
        auto body = json{{"query", "Machine learning"}, {"documents", documents}, {"top_n", 1}};
        auto ranks = result(owner->submit(operation::rerank, body));
        assert(ranks["results"].size() == 1 && ranks["results"][0]["index"] == 1);
        body.erase("documents"); body.erase("top_n"); body["texts"] = documents;
        assert(result(owner->submit(operation::rerank, body)).size() == 2);
    } else if (mode == "infill") {
        auto body = json{{"input_prefix", "One"}, {"input_suffix", "time"}, {"n_predict", 8}, {"temperature", 0}};
        assert(result(owner->submit(operation::infill, body)).contains("content"));
        body["stream"] = true;
        auto req = owner->submit(operation::infill, body);
        bool final_payload = false;
        for (;;) {
            auto event = req->next_for(10s);
            assert(event.type != event_type::timeout);
            if (event.terminal()) { assert(event.type == event_type::success); break; }
            final_payload |= event.data.is_object() && event.data.value("stop", false);
        }
        assert(final_payload);
        body["input_extra"] = json::array({{{"filename", 123}}});
        assert(owner->submit(operation::infill, body)->result().type == event_type::error);
    } else {
        std::ifstream input(argv[4], std::ios::binary);
        assert(input);
        attachment image {"image", std::vector<uint8_t>(std::istreambuf_iterator<char>(input), {})};
        json body = {{"messages", {{{"role", "user"}, {"content", {
            {{"type", "text"}, {"text", "What is this?"}},
            {{"type", "image_url"}, {"image_url", {{"url", "attachment:image"}}}}
        }}}}}, {"max_tokens", 4}, {"temperature", 0}};
        auto count = result(owner->submit(operation::chat_tokens, body, {image}));
        assert(count["input_tokens"].get<int>() > 0);
        auto req = owner->submit(operation::chat, body, {image});
        image.bytes.clear(); // the request must not retain the caller's buffer
        assert(result(std::move(req))["choices"].size() == 1);
        assert(owner->submit(operation::chat, body)->result().type == event_type::error);
        assert(owner->submit(operation::chat, body, {{"image", {1,2,3}}})->result().type == event_type::error);
    }
    std::cout << "PASS direct " << mode << '\n';
}
