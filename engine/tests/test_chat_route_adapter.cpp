#include "test_util.hpp"

#include "chat_route_adapter.hpp"
#include "json.h"

#include <memory>
#include <string>
#include <vector>

using namespace llama_engine;

static std::unique_ptr<stream_handle> make_stream(std::vector<std::string> frames) {
    auto stream = std::make_unique<stream_handle>();
    auto response = std::make_unique<server_http_res>();
    response->next = [frames = std::move(frames), index = size_t{0}](std::string & out) mutable {
        if (index >= frames.size()) {
            out.clear();
            return false;
        }
        out = frames[index++];
        return index < frames.size();
    };
    stream->response = std::move(response);
    return stream;
}

void run_chat_route_adapter_tests() {
    std::fprintf(stderr, "ChatRouteAdapter:\n");

    CASE("SSE ping comments are ignored before data payloads");
    {
        auto stream = make_stream({":\n\n", "data: {\"delta\":\"ok\"}\n\n", "data: [DONE]\n\n"});
        std::string chunk;
        bool done = false;
        std::string error;

        EXPECT_EQ(chat_route_adapter::stream_next(stream.get(), chunk, done, [&](std::string e) { error = std::move(e); }), LLAMA_ENGINE_OK);
        EXPECT_EQ(chunk, std::string("{\"delta\":\"ok\"}"));
        EXPECT(!done);
        EXPECT(error.empty());

        EXPECT_EQ(chat_route_adapter::stream_next(stream.get(), chunk, done, [&](std::string e) { error = std::move(e); }), LLAMA_ENGINE_OK);
        EXPECT(done);
        EXPECT(chunk.empty());
    }

    CASE("SSE ping-only final frame completes without yielding a chunk");
    {
        auto stream = make_stream({":\n\n"});
        std::string chunk;
        bool done = false;
        std::string error;

        EXPECT_EQ(chat_route_adapter::stream_next(stream.get(), chunk, done, [&](std::string e) { error = std::move(e); }), LLAMA_ENGINE_OK);
        EXPECT(done);
        EXPECT(chunk.empty());
        EXPECT(error.empty());
    }

    CASE("SSE data payloads in the same frame are queued separately");
    {
        auto stream = make_stream({"data: one\n\ndata: two\n\ndata: [DONE]\n\n"});
        std::string chunk;
        bool done = false;
        std::string error;

        EXPECT_EQ(chat_route_adapter::stream_next(stream.get(), chunk, done, [&](std::string e) { error = std::move(e); }), LLAMA_ENGINE_OK);
        EXPECT_EQ(chunk, std::string("one"));
        EXPECT(!done);

        EXPECT_EQ(chat_route_adapter::stream_next(stream.get(), chunk, done, [&](std::string e) { error = std::move(e); }), LLAMA_ENGINE_OK);
        EXPECT_EQ(chunk, std::string("two"));
        EXPECT(done);
        EXPECT(error.empty());
    }

    CASE("SSE event fields are ignored");
    {
        auto stream = make_stream({"event: message\ndata: {\"delta\":\"ok\"}\n\n"});
        std::string chunk;
        bool done = false;
        std::string error;

        EXPECT_EQ(chat_route_adapter::stream_next(stream.get(), chunk, done, [&](std::string e) { error = std::move(e); }), LLAMA_ENGINE_OK);
        EXPECT_EQ(chunk, std::string("{\"delta\":\"ok\"}"));
        EXPECT(done);
        EXPECT(error.empty());
    }

    CASE("SSE error payload returns its message");
    {
        auto stream = make_stream({"data: {\"error\":{\"message\":\"boom\"}}\n\n"});
        std::string chunk;
        bool done = false;
        std::string error;

        EXPECT_EQ(chat_route_adapter::stream_next(stream.get(), chunk, done, [&](std::string e) { error = std::move(e); }), LLAMA_ENGINE_ERR_INFERENCE);
        EXPECT_EQ(chunk, std::string("{\"error\":{\"message\":\"boom\"}}"));
        EXPECT(done);
        EXPECT_EQ(error, std::string("boom"));
    }

    CASE("non-JSON SSE payload remains normal data");
    {
        auto stream = make_stream({"data: not json\n\n"});
        std::string chunk;
        bool done = false;
        std::string error;

        EXPECT_EQ(chat_route_adapter::stream_next(stream.get(), chunk, done, [&](std::string e) { error = std::move(e); }), LLAMA_ENGINE_OK);
        EXPECT_EQ(chunk, std::string("not json"));
        EXPECT(done);
        EXPECT(error.empty());
    }

    CASE("preempt during stream open preserves the route request");
    {
        auto stream = chat_route_adapter::make_stream_handle("{}");
        EXPECT(stream->opening);
        EXPECT(stream->request != nullptr);

        chat_route_adapter::stream_preempt(stream.get());
        EXPECT(stream->cancelled.load());
        EXPECT(stream->opening);
        EXPECT(stream->request != nullptr);
    }

    CASE("speech stream frames are raw bytes, never SSE or JSON errors");
    {
        const std::string bin("\x00\x00\x80\x3f", 4);
        auto stream = make_stream({bin, "data: {\"error\":{\"message\":\"x\"}}\n\n", ""});
        stream->audio = true;
        std::string chunk;
        bool done = false;
        std::string error;

        EXPECT_EQ(chat_route_adapter::stream_next(stream.get(), chunk, done, [&](std::string e) { error = std::move(e); }), LLAMA_ENGINE_OK);
        EXPECT_EQ(chunk, bin);
        EXPECT(!done);

        EXPECT_EQ(chat_route_adapter::stream_next(stream.get(), chunk, done, [&](std::string e) { error = std::move(e); }), LLAMA_ENGINE_OK);
        EXPECT_EQ(chunk, std::string("data: {\"error\":{\"message\":\"x\"}}\n\n"));
        EXPECT(!done);
        EXPECT(error.empty());

        EXPECT_EQ(chat_route_adapter::stream_next(stream.get(), chunk, done, [&](std::string e) { error = std::move(e); }), LLAMA_ENGINE_OK);
        EXPECT(done);
        EXPECT(chunk.empty());
    }

    CASE("speech stream handle posts to /tts with PCM output and stream on");
    {
        std::string error;
        auto stream = chat_route_adapter::make_speech_stream_handle(R"({"input":"hi","response_format":"wav","stream":false})", error);
        EXPECT(stream != nullptr);
        EXPECT(stream->audio);
        EXPECT_EQ(stream->request->path, std::string("/tts"));
        const auto body = common_json::parse(stream->request->body);
        EXPECT_EQ(body.at("response_format").get<std::string>(), std::string("pcm"));
        EXPECT(body.at("stream").get<bool>());
        EXPECT_EQ(body.at("input").get<std::string>(), std::string("hi"));

        EXPECT(chat_route_adapter::make_speech_stream_handle("[1]", error) == nullptr);
        EXPECT(!error.empty());
        EXPECT(chat_route_adapter::make_speech_stream_handle("not json", error) == nullptr);
    }

    CASE("PCM sample rate comes from the content type");
    {
        EXPECT_EQ(chat_route_adapter::pcm_sample_rate("audio/pcm;rate=24000;encoding=float;bits=32"), 24000);
        EXPECT_EQ(chat_route_adapter::pcm_sample_rate("audio/pcm;rate=16000"), 16000);
        EXPECT_EQ(chat_route_adapter::pcm_sample_rate("audio/wav"), 0);
        EXPECT_EQ(chat_route_adapter::pcm_sample_rate("audio/pcm;rate=-5"), 0);
        EXPECT_EQ(chat_route_adapter::pcm_sample_rate(""), 0);
    }
}
