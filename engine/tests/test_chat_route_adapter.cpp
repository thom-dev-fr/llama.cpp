#include "test_util.hpp"

#include "chat_route_adapter.hpp"

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
}
