#include "test_util.hpp"

#include "realtime_session.hpp"

#include "json.h"

#include <atomic>
#include <condition_variable>
#include <memory>
#include <mutex>
#include <string>
#include <thread>

using llama_engine::realtime_conn;
using llama_engine::realtime_session;

static std::string error_code(const std::string & ev) {
    auto j = common_json::parse_no_throw(ev);
    if (j.is_null() || j.value("type", std::string()) != "error") {
        return "";
    }
    return j.at("error").value("code", std::string());
}

// echoes every event until the connection closes, like a handler that waits on read()
static void echo(const server_http_req &, server_http_context::ws_conn & conn) {
    std::string msg;
    while (conn.read(msg) != 0) {
        conn.send("echo:" + msg);
    }
}

static void test_intent_param() {
    CASE("the intent goes in the request params of the handler");
    std::string seen = "unset";
    auto s = realtime_session::start([&](const server_http_req & req, server_http_context::ws_conn &) {
        seen = req.get_param("intent", "none");
    }, "transcription");
    s->join();
    EXPECT_EQ(seen, std::string("transcription"));
    EXPECT(!s->is_open()); // a returned handler closes the session
}

static void test_terminate_wakes_reader() {
    CASE("terminate() wakes the app in next(), the last event is session_terminated");
    auto s = realtime_session::start(echo, "");
    std::string last;
    std::thread reader([&]() {
        std::string msg;
        while (s->conn().next(msg)) {
            last = msg;
        }
    });
    EXPECT(s->conn().push("a") == realtime_conn::push_status::ok);
    s->terminate("engine paused");
    EXPECT(!s->is_open());
    reader.join();
    EXPECT_EQ(error_code(last), std::string("session_terminated"));
    EXPECT(s->conn().push("b") == realtime_conn::push_status::closed);
}

static void test_close_then_join() {
    CASE("close() does not wait, join() waits for the worker and is idempotent");
    std::mutex              mtx;
    std::condition_variable cv;
    bool                    in_handler = false;
    auto s = realtime_session::start([&](const server_http_req & req, server_http_context::ws_conn & conn) {
        {
            std::lock_guard<std::mutex> lock(mtx);
            in_handler = true;
        }
        cv.notify_all();
        echo(req, conn);
    }, "");
    {
        std::unique_lock<std::mutex> lock(mtx);
        cv.wait(lock, [&]() { return in_handler; });
    }
    s->conn().close();
    s->join();
    s->join();
    std::string msg;
    EXPECT(!s->conn().next(msg));
}

static void test_handle_outlives_owner() {
    CASE("the app handle stays usable after the engine side terminated and dropped its reference");
    auto engine_ref = realtime_session::start(echo, "");
    std::shared_ptr<realtime_session> app_ref = engine_ref;
    EXPECT(app_ref->conn().push("a") == realtime_conn::push_status::ok);
    engine_ref->terminate("engine destroyed");
    engine_ref.reset();

    std::string msg;
    std::string last;
    while (app_ref->conn().next(msg)) {
        last = msg;
    }
    EXPECT_EQ(error_code(last), std::string("session_terminated"));
    EXPECT(app_ref->conn().push("b") == realtime_conn::push_status::closed);
    app_ref->conn().close();
    app_ref.reset(); // the destructor joins nothing, the worker is gone
}

static void test_destructor_ends_worker() {
    CASE("dropping the last reference closes the session and joins the worker");
    std::atomic<bool> returned{false};
    {
        auto s = realtime_session::start([&](const server_http_req & req, server_http_context::ws_conn & conn) {
            echo(req, conn);
            returned = true;
        }, "");
        EXPECT(s->conn().push("a") == realtime_conn::push_status::ok);
    }
    EXPECT(returned.load());
}

static void test_handler_releases_captures() {
    CASE("the handler and its captures are released when the worker ends");
    auto token = std::make_shared<int>(1);
    std::weak_ptr<int> weak = token;
    auto s = realtime_session::start([token](const server_http_req & req, server_http_context::ws_conn & conn) {
        echo(req, conn);
    }, "");
    token.reset();
    EXPECT(!weak.expired());
    s->conn().close();
    s->join();
    EXPECT(weak.expired());
}

void run_realtime_session_tests() {
    test_intent_param();
    test_terminate_wakes_reader();
    test_close_then_join();
    test_handle_outlives_owner();
    test_destructor_ends_worker();
    test_handler_releases_captures();
}
