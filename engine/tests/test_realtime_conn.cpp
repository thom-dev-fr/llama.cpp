#include "test_util.hpp"

#include "realtime_conn.hpp"

#include "json.h"

#include <string>
#include <thread>

using llama_engine::realtime_conn;
using push_status = realtime_conn::push_status;

static std::string error_code(const std::string & ev) {
    auto j = common_json::parse_no_throw(ev);
    if (j.is_null() || j.value("type", std::string()) != "error") {
        return "";
    }
    return j.at("error").value("code", std::string());
}

static void test_ordered_both_ways() {
    CASE("events keep their order in both directions");
    realtime_conn conn;
    EXPECT(conn.push("a") == push_status::ok);
    EXPECT(conn.push("b") == push_status::ok);
    std::string msg;
    EXPECT_EQ(conn.read(msg), 1);
    EXPECT_EQ(msg, std::string("a"));
    EXPECT_EQ(conn.read(msg), 1);
    EXPECT_EQ(msg, std::string("b"));

    EXPECT(conn.send("x"));
    EXPECT(conn.send("y"));
    EXPECT(conn.next(msg));
    EXPECT_EQ(msg, std::string("x"));
    EXPECT(conn.next(msg));
    EXPECT_EQ(msg, std::string("y"));
}

static void test_close_wakes_reader() {
    CASE("close() wakes a handler blocked in read()");
    realtime_conn conn;
    int got = -1;
    std::thread t([&]() {
        std::string msg;
        got = conn.read(msg);
    });
    conn.close();
    t.join();
    EXPECT_EQ(got, 0);
}

static void test_close_wakes_app_reader() {
    CASE("close() wakes the app blocked in next()");
    realtime_conn conn;
    bool got = true;
    std::thread t([&]() {
        std::string msg;
        got = conn.next(msg);
    });
    conn.close();
    t.join();
    EXPECT(!got);
}

static void test_close_is_idempotent() {
    CASE("close() is idempotent, the closed connection refuses events");
    realtime_conn conn;
    EXPECT(conn.is_open());
    conn.close();
    conn.close();
    EXPECT(!conn.is_open());
    EXPECT(conn.push("a") == push_status::closed);
    EXPECT(!conn.send("x"));
    std::string msg;
    EXPECT_EQ(conn.read(msg), 0);
    EXPECT(!conn.next(msg));
}

static void test_events_after_close() {
    CASE("the app reads the events sent before close(), the handler gets no more input");
    realtime_conn conn;
    EXPECT(conn.push("a") == push_status::ok);
    EXPECT(conn.send("x"));
    conn.close();
    std::string msg;
    EXPECT_EQ(conn.read(msg), 0);
    EXPECT(conn.next(msg));
    EXPECT_EQ(msg, std::string("x"));
    EXPECT(!conn.next(msg));
}

static void test_too_large_keeps_open() {
    CASE("an event over max_message is refused, the connection stays open");
    realtime_conn::limits lim;
    lim.max_message = 4;
    realtime_conn conn(lim);
    EXPECT(conn.push("12345") == push_status::too_large);
    EXPECT(conn.is_open());
    EXPECT(conn.push("1234") == push_status::ok);
}

static void test_input_overflow() {
    CASE("max_in reached: closed with one input_queue_full error");
    realtime_conn::limits lim;
    lim.max_in = 4;
    realtime_conn conn(lim);
    EXPECT(conn.push("123") == push_status::ok);
    EXPECT(conn.push("45") == push_status::overflow);
    EXPECT(!conn.is_open());
    std::string msg;
    EXPECT_EQ(conn.read(msg), 0);
    EXPECT(conn.next(msg));
    EXPECT_EQ(error_code(msg), std::string("input_queue_full"));
    EXPECT(!conn.next(msg));
}

static void test_input_budget_freed_by_read() {
    CASE("read() gives the bytes back to max_in");
    realtime_conn::limits lim;
    lim.max_in = 4;
    realtime_conn conn(lim);
    std::string msg;
    for (int i = 0; i < 8; i++) {
        EXPECT(conn.push("123") == push_status::ok);
        EXPECT_EQ(conn.read(msg), 1);
    }
    EXPECT(conn.is_open());
}

static void test_output_overflow() {
    CASE("max_out reached: the queued events, then one output_queue_full error");
    realtime_conn::limits lim;
    lim.max_out = 4;
    realtime_conn conn(lim);
    EXPECT(conn.send("123"));
    EXPECT(!conn.send("45"));
    EXPECT(!conn.is_open());
    std::string msg;
    EXPECT(conn.next(msg));
    EXPECT_EQ(msg, std::string("123"));
    EXPECT(conn.next(msg));
    EXPECT_EQ(error_code(msg), std::string("output_queue_full"));
    EXPECT(!conn.next(msg));
}

static void test_single_terminal_error() {
    CASE("only the first failure queues an error, none after close()");
    realtime_conn conn;
    conn.fail("first", "first");
    conn.fail("second", "second");
    std::string msg;
    EXPECT(conn.next(msg));
    EXPECT_EQ(error_code(msg), std::string("first"));
    EXPECT(!conn.next(msg));

    realtime_conn closed;
    closed.close();
    closed.fail("late", "late");
    EXPECT(!closed.next(msg));
}

static void test_binary_fails() {
    CASE("send_binary() closes with an error instead of losing the event");
    realtime_conn conn;
    EXPECT(!conn.send_binary("x"));
    EXPECT(!conn.is_open());
    std::string msg;
    EXPECT(conn.next(msg));
    EXPECT_EQ(error_code(msg), std::string("binary_not_supported"));
}

static void test_echo_handler() {
    CASE("a handler thread echoes every event until the app closes");
    realtime_conn conn;
    std::thread handler([&]() {
        std::string msg;
        while (conn.read(msg) != 0) {
            conn.send("echo:" + msg);
        }
    });
    std::string msg;
    for (int i = 0; i < 100; i++) {
        EXPECT(conn.push(std::to_string(i)) == push_status::ok);
        EXPECT(conn.next(msg));
        EXPECT_EQ(msg, "echo:" + std::to_string(i));
    }
    conn.close();
    handler.join();
    EXPECT(!conn.next(msg));
}

void run_realtime_conn_tests() {
    test_ordered_both_ways();
    test_close_wakes_reader();
    test_close_wakes_app_reader();
    test_close_is_idempotent();
    test_events_after_close();
    test_too_large_keeps_open();
    test_input_overflow();
    test_input_budget_freed_by_read();
    test_output_overflow();
    test_single_terminal_error();
    test_binary_fails();
    test_echo_handler();
}
