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
static std::string base64(const std::vector<uint8_t> & bytes) {
    static const char * chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    std::string out;
    for (size_t i = 0; i < bytes.size(); i += 3) {
        uint32_t n = bytes[i] << 16;
        if (i + 1 < bytes.size()) { n |= bytes[i + 1] << 8; }
        if (i + 2 < bytes.size()) { n |= bytes[i + 2]; }
        out += chars[(n >> 18) & 63];
        out += chars[(n >> 12) & 63];
        out += i + 1 < bytes.size() ? chars[(n >> 6) & 63] : '=';
        out += i + 2 < bytes.size() ? chars[n & 63] : '=';
    }
    return out;
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
    } else if (mode == "vision" || mode == "vision-embeddings") {
        assert(argc == 5);
        settings.mmproj_path = argv[3];
        if (mode == "vision-embeddings") {
            settings.embeddings = true;
            settings.pooling_type = 1; // mean
        }
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
    } else if (mode == "vision-embeddings") {
        std::ifstream input(argv[4], std::ios::binary);
        assert(input);
        attachment image {"image", std::vector<uint8_t>(std::istreambuf_iterator<char>(input), {})};
        auto content = [](const std::string & url) {
            return json{{"content", {
                {{"type", "text"}, {"text", "What is this: "}},
                {{"type", "image_url"}, {"image_url", {{"url", url}}}},
                {{"type", "text"}, {"text", "\n"}}
            }}};
        };
        json body = {{"input", {content("attachment:image"), content("data:image/png;base64," + base64(image.bytes)), "What is this: \n"}}};
        auto req = owner->submit(operation::embeddings_openai, body, {image});
        image.bytes.clear(); // the request must not retain the caller's buffer
        auto data = result(std::move(req))["data"];
        assert(data.size() == 3);
        assert(data[0]["embedding"] == data[1]["embedding"]); // same image, owned buffer or base64
        assert(data[0]["embedding"] != data[2]["embedding"]);
        assert(owner->submit(operation::embeddings_openai, body)->result().type == event_type::error); // unknown attachment
        assert(owner->submit(operation::embeddings_openai, {{"input", "text"}}, {{"", {1}}})->result().type == event_type::error);
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
