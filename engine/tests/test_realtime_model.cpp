// Runs server_routes::ws_realtime over realtime_conn, without HTTP, against a
// real realtime conversation model (LFM3-Omni-2B) and a short PCM16 fixture,
// then the same sessions through the public C API and the engine lifecycle.
//
// usage: test-llama-engine-realtime <model.gguf> <mmproj.gguf> <audio.pcm> [gpu_layers]
// exit code 77 means "skipped" (no model given).

#include "llama_engine.h"
#include "params_translator.hpp"
#include "realtime_conn.hpp"

#include "base64.hpp"
#include "json.h"
#include "server-context.h"

#include <algorithm>
#include <condition_variable>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <functional>
#include <iterator>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

using llama_engine::realtime_conn;
using json = common_json;

static int g_total    = 0;
static int g_failures = 0;

#define EXPECT(cond)                                                                \
    do {                                                                            \
        g_total++;                                                                  \
        if (!(cond)) {                                                              \
            g_failures++;                                                           \
            std::fprintf(stderr, "FAIL: %s:%d: %s\n", __FILE__, __LINE__, #cond);   \
        }                                                                           \
    } while (0)

// one session: the handler runs on its own worker, like on its HTTP thread
struct session {
    realtime_conn                      conn;
    std::function<bool()>              should_stop = [this]() { return !conn.is_open(); };
    server_http_req                    req{{}, {}, "/v1/realtime", "", "", {}, should_stop};
    std::thread                        worker;
    std::vector<std::string>           types; // every event type, in order

    session(server_routes & routes, const std::string & intent) {
        if (!intent.empty()) {
            req.params["intent"] = intent;
        }
        worker = std::thread([this, &routes]() { routes.ws_realtime(req, conn); });
    }

    ~session() {
        conn.close();
        worker.join();
    }

    void send(const json & ev) {
        EXPECT(conn.push(ev.dump()) == realtime_conn::push_status::ok);
    }

    // reads events until one of `type`; false if the session ends first
    bool until(const std::string & type, json & ev, const std::function<void(const json &)> & on_event = nullptr) {
        std::string msg;
        while (conn.next(msg)) {
            ev = json::parse(msg);
            const std::string t = ev.value("type", std::string());
            types.push_back(t);
            if (std::getenv("LLAMA_ENGINE_TEST_TRACE")) {
                std::printf("    < %s\n", msg.substr(0, 200).c_str());
            }
            if (t == "error") {
                std::fprintf(stderr, "  error event: %s\n", msg.c_str());
            }
            if (on_event) {
                on_event(ev);
            }
            if (t == type) {
                return true;
            }
        }
        return false;
    }

    void append_audio(const std::string & pcm) {
        const size_t chunk = 3200; // 100 ms at 16 kHz
        for (size_t i = 0; i < pcm.size(); i += chunk) {
            const std::string part = pcm.substr(i, chunk);
            send({{"type", "input_audio_buffer.append"}, {"audio", base64::encode(part)}});
        }
    }
};

static std::string read_file(const char * path) {
    std::ifstream f(path, std::ios::binary);
    return std::string(std::istreambuf_iterator<char>(f), std::istreambuf_iterator<char>());
}

static void print_types(const char * name, const session & s) {
    std::printf("  %s events:", name);
    for (const auto & t : s.types) {
        std::printf(" %s", t.c_str());
    }
    std::printf("\n");
}

static void test_conversation(server_routes & routes, const std::string & pcm) {
    std::printf("conversation: audio turn, text response, cancel, close\n");
    session s(routes, "");
    json ev;
    EXPECT(s.until("session.created", ev));
    EXPECT(ev.at("session").value("type", std::string()) == "realtime");
    std::printf("  session: %s\n", ev.at("session").dump().c_str());

    s.send({{"type", "session.update"}, {"session", {
        {"instructions",      "You are a helpful assistant. Answer in one short sentence."},
        {"output_modalities", json::array({"text"})},
    }}});
    EXPECT(s.until("session.updated", ev));

    s.append_audio(pcm);
    s.send({{"type", "input_audio_buffer.commit"}});
    EXPECT(s.until("input_audio_buffer.committed", ev));
    EXPECT(s.until("conversation.item.done", ev));

    std::string text;
    s.send({{"type", "response.create"}});
    EXPECT(s.until("response.done", ev, [&](const json & e) {
        if (e.value("type", std::string()) == "response.output_text.delta") {
            text += e.value("delta", std::string());
        }
    }));
    EXPECT(ev.at("response").value("status", std::string()) == "completed");
    EXPECT(!text.empty());
    std::printf("  answer: %s\n", text.c_str());

    // cancel after the first delta: the response ends as cancelled, the session goes on
    s.send({{"type", "conversation.item.create"}, {"item", {
        {"type", "message"}, {"role", "user"},
        {"content", json::array({json {{"type", "input_text"}, {"text", "Count from 1 to 500, one number per line."}}})},
    }}});
    s.send({{"type", "response.create"}});
    EXPECT(s.until("response.output_text.delta", ev));
    s.send({{"type", "response.cancel"}});
    EXPECT(s.until("response.done", ev));
    EXPECT(ev.at("response").value("status", std::string()) == "cancelled");

    s.send({{"type", "conversation.item.create"}, {"item", {
        {"type", "message"}, {"role", "user"},
        {"content", json::array({json {{"type", "input_text"}, {"text", "Say OK."}}})},
    }}});
    s.send({{"type", "response.create"}});
    EXPECT(s.until("response.done", ev));
    EXPECT(ev.at("response").value("status", std::string()) == "completed");

    print_types("conversation", s);
}

static void test_fast_barge_in(server_routes & routes) {
    std::printf("cancel a queued response and start the next turn\n");
    session s(routes, "");
    json ev;
    EXPECT(s.until("session.created", ev));
    auto message = [&s](const char * text) {
        s.send({{"type", "conversation.item.create"}, {"item", {
            {"type", "message"}, {"role", "user"},
            {"content", json::array({json{{"type", "input_text"}, {"text", text}}})},
        }}});
    };
    message("Count from 1 to 500, one number per line.");
    s.send({{"type", "response.create"}, {"response", {{"output_modalities", json::array({"text"})}}}});
    s.send({{"type", "response.cancel"}});
    message("Say OK.");
    s.send({{"type", "response.create"}, {"response", {{"output_modalities", json::array({"text"})}, {"max_output_tokens", 8}}}});
    EXPECT(s.until("response.created", ev));
    const auto first = ev.at("response").at("id");
    EXPECT(s.until("response.done", ev));
    EXPECT(ev.at("response").at("id") == first);
    EXPECT(ev.at("response").at("status") == "cancelled");
    EXPECT(s.until("response.created", ev));
    const auto second = ev.at("response").at("id");
    EXPECT(first != second);
    EXPECT(s.until("response.done", ev));
    EXPECT(ev.at("response").at("id") == second);
    EXPECT(ev.at("response").at("status") == "completed");
}

static void test_response_in_progress(server_routes & routes) {
    std::printf("a second response.create without a cancel is refused\n");
    session s(routes, "");
    json ev;
    EXPECT(s.until("session.created", ev));
    s.send({{"type", "conversation.item.create"}, {"item", {
        {"type", "message"}, {"role", "user"},
        {"content", json::array({json{{"type", "input_text"}, {"text", "Count from 1 to 20."}}})},
    }}});
    s.send({{"type", "response.create"}, {"response", {{"output_modalities", json::array({"text"})}, {"max_output_tokens", 32}}}});
    s.send({{"type", "response.create"}, {"event_id", "evt_second"}});
    EXPECT(s.until("error", ev));
    EXPECT(ev.at("error").value("type", std::string()) == "conversation_already_has_active_response");
    EXPECT(ev.at("error").value("event_id", std::string()) == "evt_second");
    EXPECT(s.until("response.done", ev));
    EXPECT(ev.at("response").value("status", std::string()) == "completed");
}

static void test_clear_audio(server_routes & routes, const std::string & pcm) {
    std::printf("clear uncommitted audio, then capture a fresh turn\n");
    session s(routes, "");
    json ev;
    EXPECT(s.until("session.created", ev));
    s.append_audio(pcm);
    s.send({{"type", "input_audio_buffer.clear"}});
    EXPECT(s.until("input_audio_buffer.cleared", ev));
    s.send({{"type", "input_audio_buffer.commit"}});
    EXPECT(s.until("error", ev));
    EXPECT(ev.at("error").value("type", std::string()) == "input_audio_buffer_commit_empty");
    s.send({{"type", "response.create"}, {"event_id", "evt_empty"}});
    EXPECT(s.until("error", ev));
    EXPECT(ev.at("error").value("type", std::string()) == "conversation_empty");
    EXPECT(ev.at("error").value("event_id", std::string()) == "evt_empty");
    s.append_audio(pcm);
    s.send({{"type", "input_audio_buffer.commit"}});
    EXPECT(s.until("input_audio_buffer.committed", ev));
    s.send({{"type", "response.create"}, {"response", {{"output_modalities", json::array({"text"})}, {"max_output_tokens", 8}}}});
    EXPECT(s.until("response.done", ev));
    EXPECT(ev.at("response").value("status", std::string()) == "completed");
}

static void test_spoken_response(server_routes & routes, const std::string & pcm) {
    std::printf("spoken response: text and audio, then a cancel during the voice\n");
    session s(routes, "");
    json ev;
    EXPECT(s.until("session.created", ev));
    EXPECT(ev.at("session").at("audio").contains("output"));
    s.send({{"type", "session.update"}, {"session", {{"instructions", "Answer in one short sentence."}}}});
    EXPECT(s.until("session.updated", ev));
    s.append_audio(pcm);
    s.send({{"type", "input_audio_buffer.commit"}});
    EXPECT(s.until("conversation.item.done", ev));

    const json mixed = {{"type", "response.create"}, {"response", {{"output_modalities", json::array({"text", "audio"})}}}};
    s.send(mixed);
    EXPECT(s.until("response.created", ev));
    EXPECT(ev.at("response").at("output_modalities") == json::array({"text", "audio"}));
    const auto response_id = ev.at("response").at("id");

    // the parts open on their first delta; the deltas stay inside the response
    std::string text;
    std::vector<std::string> parts;
    size_t samples    = 0;
    bool   bad_delta  = false;
    bool   any_done   = false;
    EXPECT(s.until("response.done", ev, [&](const json & e) {
        const std::string t = e.value("type", std::string());
        if (t == "response.content_part.added") {
            parts.push_back(e.at("part").value("type", std::string()));
        } else if (t == "response.output_text.delta") {
            text += e.value("delta", std::string());
            bad_delta |= any_done;
        } else if (t == "response.output_audio.delta") {
            const size_t n = base64::decode(e.value("delta", std::string())).size();
            // 2 bytes per sample, at most a second per delta
            bad_delta |= n == 0 || n % 2 != 0 || n > 2 * 24000 || any_done || e.at("response_id") != response_id;
            samples += n / 2;
        } else if (t == "response.output_text.done" || t == "response.output_audio.done") {
            any_done = true;
        }
    }));
    EXPECT(ev.at("response").value("status", std::string()) == "completed");
    EXPECT(ev.at("response").at("id") == response_id);
    EXPECT(parts == std::vector<std::string>({"output_text", "output_audio"}));
    EXPECT(!bad_delta);
    EXPECT(!text.empty());
    EXPECT(samples >= 12000); // half a second at 24 kHz; the voice itself is checked by ear
    std::printf("  answer: %s, %.2f s of voice\n", text.c_str(), samples / 24000.0);

    // cancel once the voice has started: no delta after response.done
    s.send({{"type", "conversation.item.create"}, {"item", {
        {"type", "message"}, {"role", "user"},
        {"content", json::array({json {{"type", "input_text"}, {"text", "Tell me a long story about a lighthouse."}}})},
    }}});
    s.send(mixed);
    EXPECT(s.until("response.output_audio.delta", ev));
    s.send({{"type", "response.cancel"}});
    EXPECT(s.until("response.done", ev));
    EXPECT(ev.at("response").value("status", std::string()) == "cancelled");

    // the next response comes without a stray delta of the cancelled one
    s.send({{"type", "conversation.item.create"}, {"item", {
        {"type", "message"}, {"role", "user"},
        {"content", json::array({json {{"type", "input_text"}, {"text", "Say OK."}}})},
    }}});
    s.send({{"type", "response.create"}, {"response", {{"output_modalities", json::array({"text"})}, {"max_output_tokens", 8}}}});
    bool stray = false;
    EXPECT(s.until("response.created", ev, [&](const json & e) {
        const std::string t = e.value("type", std::string());
        stray |= t == "response.output_audio.delta" || t == "response.output_text.delta";
    }));
    EXPECT(!stray);
    EXPECT(s.until("response.done", ev));
    EXPECT(ev.at("response").value("status", std::string()) == "completed");
}

// a spoken response with tools: the model calls in text or speaks, the answer to the call result is spoken
struct tool_response {
    std::string text;
    size_t      samples = 0;
    json        calls   = json::array();
    std::string status;
};

static tool_response run_tool_response(session & s, const json & response = json::object()) {
    tool_response r;
    json ev;
    s.send({{"type", "response.create"}, {"response", response}});
    EXPECT(s.until("response.done", ev, [&](const json & e) {
        const std::string t = e.value("type", std::string());
        if (t == "response.output_text.delta") {
            r.text += e.value("delta", std::string());
        } else if (t == "response.output_audio.delta") {
            r.samples += base64::decode(e.value("delta", std::string())).size() / 2;
        } else if (t == "response.output_item.done" && e.at("item").value("type", std::string()) == "function_call") {
            r.calls.push_back(e.at("item"));
        }
    }));
    r.status = ev.at("response").value("status", std::string());
    return r;
}

static void test_spoken_tool_call(server_routes & routes) {
    std::printf("spoken response with tools: a call in text, then the spoken answer to its result\n");
    const json tools = json::array({{
        {"type", "function"}, {"name", "get_weather"}, {"description", "Get the current weather for a city."},
        {"parameters", {{"type", "object"}, {"properties", {{"city", {{"type", "string"}}}}}, {"required", json::array({"city"})}}},
    }});
    // the system prompt of the LFM3-Omni model card for tools
    const std::string instructions = "You are a friendly home assistant. Answer in one short sentence.\n"
                                     "Respond with function calls, and interleaved text and audio.";
    auto user_text = [](session & s, const std::string & text) {
        json ev;
        s.send({{"type", "conversation.item.create"}, {"item", {{"type", "message"}, {"role", "user"},
            {"content", json::array({json {{"type", "input_text"}, {"text", text}}})}}}});
        EXPECT(s.until("conversation.item.done", ev));
    };

    session s(routes, "");
    json ev;
    EXPECT(s.until("session.created", ev));
    s.send({{"type", "session.update"}, {"session", {
        {"instructions", instructions}, {"tools", tools}, {"output_modalities", json::array({"text", "audio"})},
    }}});
    EXPECT(s.until("session.updated", ev));

    user_text(s, "What is the weather in Paris right now?");
    const tool_response call = run_tool_response(s);
    EXPECT(call.status == "completed");
    EXPECT(call.calls.size() == 1);
    EXPECT(call.samples == 0);
    EXPECT(call.text.find("<tool_call>") == std::string::npos);
    std::printf("  call: %s\n", call.calls.dump().c_str());
    if (call.calls.size() != 1) {
        return;
    }
    EXPECT(call.calls[0].value("name", std::string()) == "get_weather");
    EXPECT(json::parse(call.calls[0].value("arguments", std::string("{}"))).value("city", std::string()) == "Paris");

    s.send({{"type", "conversation.item.create"}, {"item", {{"type", "function_call_output"},
        {"call_id", call.calls[0].at("call_id")}, {"output", R"({"temperature_c": 14, "condition": "light rain"})"}}}});
    EXPECT(s.until("conversation.item.done", ev));
    const tool_response answer = run_tool_response(s);
    EXPECT(answer.status == "completed");
    EXPECT(answer.calls.empty());
    EXPECT(answer.samples >= 12000);
    EXPECT(answer.text.find("14") != std::string::npos || answer.text.find("fourteen") != std::string::npos);
    std::printf("  answer: %s, %.2f s of voice\n", answer.text.c_str(), answer.samples / 24000.0);

    // nothing to call: the response is spoken right away
    user_text(s, "Tell me a short joke about cats.");
    const tool_response joke = run_tool_response(s);
    EXPECT(joke.calls.empty());
    EXPECT(joke.samples >= 12000);
    std::printf("  joke: %s, %.2f s of voice\n", joke.text.c_str(), joke.samples / 24000.0);

    // a required call opens the response in text
    user_text(s, "And in Lyon?");
    const tool_response required = run_tool_response(s, {{"tool_choice", "required"}});
    EXPECT(required.calls.size() == 1);
    EXPECT(required.samples == 0);
}

static void test_transcription_session(server_routes & routes, const std::string & pcm) {
    std::printf("conversation handler, session.type transcription\n");
    session s(routes, "");
    json ev;
    EXPECT(s.until("session.created", ev));
    s.send({{"type", "session.update"}, {"session", {{"type", "transcription"}}}});
    EXPECT(s.until("session.updated", ev));
    EXPECT(ev.at("session").value("type", std::string()) == "transcription");

    s.append_audio(pcm);
    s.send({{"type", "input_audio_buffer.commit"}});
    EXPECT(s.until("conversation.item.input_audio_transcription.completed", ev));
    const std::string transcript = ev.value("transcript", std::string());
    EXPECT(!transcript.empty());
    std::printf("  transcript: %s\n", transcript.c_str());

    // a conversation event is a protocol error, not the end of the session
    s.send({{"type", "response.create"}});
    EXPECT(s.until("error", ev));
    EXPECT(s.conn.is_open());

    print_types("transcription", s);
}

static void test_live_asr(server_routes & routes, const std::string & pcm) {
    std::printf("live transcription, ?intent=transcription\n");
    session s(routes, "transcription");
    json ev;
    EXPECT(s.until("session.created", ev));
    // without an "asr" chat template the intent is ignored: a realtime conversation opens
    if (ev.at("session").value("type", std::string()) != "transcription") {
        std::printf("  no live transcription for this model\n");
        return;
    }
    std::printf("  session: %s\n", ev.at("session").dump().c_str());
    s.append_audio(pcm);
    s.send({{"type", "input_audio_buffer.commit"}, {"final", true}});
    EXPECT(s.until("conversation.item.input_audio_transcription.completed", ev));
    std::printf("  transcript: %s\n", ev.value("transcript", std::string()).c_str());
    print_types("live", s);
}

static void test_close_during_response(server_routes & routes) {
    std::printf("close during a response: the worker ends, the slot is free again\n");
    {
        session s(routes, "");
        json ev;
        EXPECT(s.until("session.created", ev));
        s.send({{"type", "conversation.item.create"}, {"item", {
            {"type", "message"}, {"role", "user"},
            {"content", json::array({json {{"type", "input_text"}, {"text", "Write a long story."}}})},
        }}});
        s.send({{"type", "response.create"}});
        EXPECT(s.until("response.output_text.delta", ev));
        // ~session closes and joins the worker
    }
    // with one slot, a new session only starts once the previous one released it
    session s(routes, "");
    json ev;
    EXPECT(s.until("session.created", ev));
}

//
// public C API
//

// one reader thread per C session, like the Swift facade will run it
struct capi_reader {
    llama_engine_realtime_t * rt;
    std::mutex                mtx;
    std::condition_variable   cv;
    std::vector<std::string>  types;
    std::string               last;
    bool                      done   = false;
    bool                      failed = false; // next() returned an error
    std::thread               thread;

    explicit capi_reader(llama_engine_realtime_t * rt) : rt(rt) {
        thread = std::thread([this]() {
            while (true) {
                char * ev   = nullptr;
                bool   end  = false;
                const auto st = llama_engine_realtime_next(this->rt, &ev, &end);
                std::lock_guard<std::mutex> lock(mtx);
                if (st != LLAMA_ENGINE_OK || end) {
                    failed = st != LLAMA_ENGINE_OK;
                    done   = true;
                    cv.notify_all();
                    return;
                }
                last = ev;
                llama_engine_free_string(ev);
                types.push_back(json::parse(last).value("type", std::string()));
                cv.notify_all();
            }
        });
    }

    ~capi_reader() {
        thread.join();
        EXPECT(!failed);
    }

    // waits until an event of `type` was read, or the end of the session
    bool wait_for(const std::string & type) {
        std::unique_lock<std::mutex> lock(mtx);
        cv.wait(lock, [&]() { return done || std::find(types.begin(), types.end(), type) != types.end(); });
        return std::find(types.begin(), types.end(), type) != types.end();
    }

    void wait_done() {
        std::unique_lock<std::mutex> lock(mtx);
        cv.wait(lock, [&]() { return done; });
    }

    // the session ended without finishing its response: the close was seen during the generation
    bool response_done() {
        std::lock_guard<std::mutex> lock(mtx);
        return std::find(types.begin(), types.end(), "response.done") != types.end();
    }

    std::string last_error_code() {
        std::lock_guard<std::mutex> lock(mtx);
        auto j = json::parse_no_throw(last);
        if (j.is_null() || j.value("type", std::string()) != "error") {
            return "";
        }
        return j.at("error").value("code", std::string());
    }
};

static const char * k_user_text =
    "{\"type\": \"conversation.item.create\", \"item\": {\"type\": \"message\", \"role\": \"user\", "
    "\"content\": [{\"type\": \"input_text\", \"text\": \"Write a long story about a lighthouse.\"}]}}";
static const char * k_response_create = "{\"type\": \"response.create\"}";
static const char * k_chat_request    = "{\"messages\": [{\"role\": \"user\", \"content\": \"Say OK.\"}], \"max_tokens\": 4}";

static bool caps_contain(llama_engine_t * engine, const char * needle) {
    char * caps = nullptr;
    if (llama_engine_get_capabilities(engine, &caps) != LLAMA_ENGINE_OK || !caps) {
        return false;
    }
    const bool found = std::strstr(caps, needle) != nullptr;
    llama_engine_free_string(caps);
    return found;
}

static void test_capi_exclusive(llama_engine_t * engine) {
    std::printf("C API: one session at a time, chat refused while it is open\n");
    EXPECT(caps_contain(engine, "\"realtime\":true"));

    llama_engine_realtime_t * rt = nullptr;
    EXPECT(llama_engine_realtime_open(engine, nullptr, &rt) == LLAMA_ENGINE_OK);
    {
        capi_reader reader(rt);
        EXPECT(reader.wait_for("session.created"));

        llama_engine_realtime_t * other = nullptr;
        EXPECT(llama_engine_realtime_open(engine, nullptr, &other) == LLAMA_ENGINE_ERR_BUSY);
        EXPECT(other == nullptr);
        char * out = nullptr;
        EXPECT(llama_engine_chat_completion(engine, k_chat_request, &out) == LLAMA_ENGINE_ERR_BUSY);
        llama_engine_stream_t * stream = nullptr;
        EXPECT(llama_engine_chat_completion_stream(engine, k_chat_request, &stream) == LLAMA_ENGINE_ERR_BUSY);
        EXPECT(llama_engine_count_chat_tokens(engine, k_chat_request, &out) == LLAMA_ENGINE_OK);
        llama_engine_free_string(out);

        EXPECT(llama_engine_realtime_send(rt, "{\"type\": \"conversation.item.create\", \"item\": {\"type\": \"message\", "
            "\"role\": \"user\", \"content\": [{\"type\": \"input_text\", \"text\": \"Say OK.\"}]}}") == LLAMA_ENGINE_OK);
        EXPECT(llama_engine_realtime_send(rt, k_response_create) == LLAMA_ENGINE_OK);
        EXPECT(reader.wait_for("response.done"));

        // a bad event is an error event, the session goes on
        EXPECT(llama_engine_realtime_send(rt, "{not json") == LLAMA_ENGINE_OK);
        EXPECT(reader.wait_for("error"));
        EXPECT(llama_engine_realtime_send(rt, std::string(3u << 20, ' ').c_str()) == LLAMA_ENGINE_ERR_INVALID_ARG);

        llama_engine_realtime_close(rt);
        llama_engine_realtime_close(rt);
        reader.wait_done();
        EXPECT(llama_engine_realtime_send(rt, k_response_create) == LLAMA_ENGINE_ERR_CANCELLED);

        // right after the close: the open waits for the worker, the new session gets the slot
        llama_engine_realtime_t * next = nullptr;
        EXPECT(llama_engine_realtime_open(engine, nullptr, &next) == LLAMA_ENGINE_OK);
        if (next) {
            capi_reader next_reader(next);
            EXPECT(next_reader.wait_for("session.created"));
            llama_engine_realtime_close(next);
            next_reader.wait_done();
        }
        llama_engine_realtime_free(next);
    }
    llama_engine_realtime_free(rt);

    // the slot is given back: chat works again
    char * out = nullptr;
    EXPECT(llama_engine_chat_completion(engine, k_chat_request, &out) == LLAMA_ENGINE_OK);
    llama_engine_free_string(out);
}

// starts a long response and waits for its first delta
static void start_long_response(llama_engine_realtime_t * rt, capi_reader & reader) {
    EXPECT(reader.wait_for("session.created"));
    EXPECT(llama_engine_realtime_send(rt, k_user_text) == LLAMA_ENGINE_OK);
    EXPECT(llama_engine_realtime_send(rt, k_response_create) == LLAMA_ENGINE_OK);
    EXPECT(reader.wait_for("response.output_text.delta"));
}

static void test_capi_pause(llama_engine_t * engine) {
    std::printf("C API: pause during a response ends the session, open resumes the engine\n");
    llama_engine_realtime_t * rt = nullptr;
    EXPECT(llama_engine_realtime_open(engine, nullptr, &rt) == LLAMA_ENGINE_OK);
    {
        capi_reader reader(rt);
        start_long_response(rt, reader);
        EXPECT(llama_engine_pause(engine) == LLAMA_ENGINE_OK);
        reader.wait_done();
        EXPECT(reader.last_error_code() == "session_terminated");
        EXPECT(!reader.response_done());
        EXPECT(llama_engine_realtime_send(rt, k_response_create) == LLAMA_ENGINE_ERR_CANCELLED);
    }
    llama_engine_realtime_free(rt);

    EXPECT(llama_engine_get_state(engine) == LLAMA_ENGINE_STATE_PAUSED);
    rt = nullptr;
    EXPECT(llama_engine_realtime_open(engine, nullptr, &rt) == LLAMA_ENGINE_OK);
    EXPECT(llama_engine_get_state(engine) == LLAMA_ENGINE_STATE_READY);
    {
        capi_reader reader(rt);
        EXPECT(reader.wait_for("session.created"));
        // unload with a session open but idle
        EXPECT(llama_engine_unload(engine) == LLAMA_ENGINE_OK);
        reader.wait_done();
        EXPECT(reader.last_error_code() == "session_terminated");
    }
    llama_engine_realtime_free(rt);
}

static void test_capi_destroy(const llama_engine_config & cfg) {
    std::printf("C API: destroy during a response, the handle is freed after the engine\n");
    llama_engine_t * engine = llama_engine_create();
    EXPECT(llama_engine_load(engine, &cfg) == LLAMA_ENGINE_OK);
    llama_engine_realtime_t * rt = nullptr;
    EXPECT(llama_engine_realtime_open(engine, nullptr, &rt) == LLAMA_ENGINE_OK);
    {
        capi_reader reader(rt);
        start_long_response(rt, reader);
        llama_engine_destroy(engine);
        reader.wait_done();
        EXPECT(reader.last_error_code() == "session_terminated");
        EXPECT(!reader.response_done());
        EXPECT(llama_engine_realtime_send(rt, k_response_create) == LLAMA_ENGINE_ERR_CANCELLED);
        llama_engine_realtime_close(rt);
    }
    llama_engine_realtime_free(rt);
}

static void test_capi_idle_sleep(llama_engine_config cfg) {
    std::printf("C API: no realtime with the idle sleep on\n");
    cfg.idle_pause_seconds = 600;
    llama_engine_t * engine = llama_engine_create();
    EXPECT(llama_engine_load(engine, &cfg) == LLAMA_ENGINE_OK);
    EXPECT(caps_contain(engine, "\"realtime\":false"));
    EXPECT(caps_contain(engine, "\"realtime_conversation\":true"));
    llama_engine_realtime_t * rt = nullptr;
    EXPECT(llama_engine_realtime_open(engine, nullptr, &rt) == LLAMA_ENGINE_ERR_INVALID_REQUEST);
    EXPECT(rt == nullptr);
    llama_engine_destroy(engine);
}

static void run_routes_tests(const llama_engine_config & cfg, const std::string & pcm) {
    common_params params = llama_engine::params_translator::translate(cfg);

    server_context ctx;
    server_routes  routes(params, ctx);
    if (!ctx.load_model(params)) {
        std::fprintf(stderr, "failed to load the model\n");
        g_failures++;
        return;
    }
    routes.update_meta(ctx);
    std::thread loop([&ctx]() { ctx.start_loop(); });

    test_conversation(routes, pcm);
    test_clear_audio(routes, pcm);
    test_fast_barge_in(routes);
    test_response_in_progress(routes);
    test_spoken_response(routes, pcm);
    test_spoken_tool_call(routes);
    test_transcription_session(routes, pcm);
    test_live_asr(routes, pcm);
    test_close_during_response(routes);

    ctx.terminate();
    loop.join();
}

int main(int argc, char ** argv) {
    if (argc < 4 || argv[1][0] == '\0') {
        std::fprintf(stderr, "SKIP: no model given\n");
        return 77;
    }
    const std::string pcm = read_file(argv[3]);
    if (pcm.empty() || pcm.size() % 2 != 0) {
        std::fprintf(stderr, "bad PCM16 file: %s\n", argv[3]);
        return 1;
    }

    std::setvbuf(stdout, nullptr, _IOLBF, 0);
    llama_engine_set_log_level(LLAMA_ENGINE_LOG_ERROR);
    ggml_backend_load_all();
    llama_backend_init();

    llama_engine_config cfg;
    std::memset(&cfg, 0, sizeof(cfg));
    cfg.model_path          = argv[1];
    cfg.mtmd_projector_path = argv[2];
    cfg.context_size        = 4096;
    cfg.gpu_layers          = argc > 4 ? std::atoi(argv[4]) : -1;
    cfg.parallel_slots      = 1;
    cfg.kv_cache_type       = LLAMA_ENGINE_KV_F16;
    cfg.use_mmap            = true;
    cfg.idle_pause_seconds  = -1;
    run_routes_tests(cfg, pcm);

    llama_engine_t * engine = llama_engine_create();
    EXPECT(llama_engine_load(engine, &cfg) == LLAMA_ENGINE_OK);
    test_capi_exclusive(engine);
    test_capi_pause(engine);
    llama_engine_destroy(engine);
    test_capi_destroy(cfg);
    test_capi_idle_sleep(cfg);

    std::printf("\n===== %d / %d passed =====\n", g_total - g_failures, g_total);
    return g_failures == 0 ? 0 : 1;
}
