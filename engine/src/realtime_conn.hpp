#pragma once

#include "server-http.h"

#include <condition_variable>
#include <cstddef>
#include <deque>
#include <mutex>
#include <string>
#include <string_view>

namespace llama_engine {

// In-memory websocket connection between the app and server_routes::ws_realtime.
// The handler calls read/send on the session worker, the app calls push/next
// from its own threads. Both queues are bounded in bytes: an overflow closes
// the connection with one terminal error event instead of losing or blocking.
class realtime_conn final : public server_http_context::ws_conn {
public:
    struct limits {
        size_t max_message = 2u << 20; // one client event
        size_t max_in      = 4u << 20; // client events not read by the handler yet
        size_t max_out     = 8u << 20; // handler events not read by the app yet
    };

    enum class push_status {
        ok,
        closed,    // the connection is closed, the event is dropped
        too_large, // the event is over max_message, the connection stays open
        overflow,  // max_in is reached, the connection is now closed with an error
    };

    realtime_conn() = default;
    explicit realtime_conn(limits lim) : lim(lim) {}

    // app side; the event is copied once, after the size check
    push_status push(std::string_view msg);
    // blocks until the next handler event; false once closed and all events are read
    bool next(std::string & out);

    // handler side
    int  read(std::string & msg) override;
    bool send(const std::string & msg) override;
    bool send_binary(const std::string & msg) override;
    bool is_open() const override;
    void close() override;

    // closes and queues one error event; it always fits, max_out is only checked in send()
    void fail(const std::string & code, const std::string & message);

private:
    void fail_locked(const std::string & code, const std::string & message);
    void close_locked();

    limits lim;

    mutable std::mutex      mtx;
    std::condition_variable cv_in;
    std::condition_variable cv_out;
    std::deque<std::string> in;
    std::deque<std::string> out;
    size_t n_in   = 0;
    size_t n_out  = 0;
    bool   closed = false;
};

} // namespace llama_engine
