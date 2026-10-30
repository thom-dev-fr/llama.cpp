#pragma once

#include "realtime_conn.hpp"

#include "server-http.h"

#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <thread>

namespace llama_engine {

// One realtime session: the in-memory connection and the worker that runs the
// websocket handler on it. Shared by the app handle and Engine Core, so the
// handle stays usable (and closable) after the engine is gone. Only Engine
// Core may let the server context go, and only after join().
class realtime_session {
public:
    using handler_t = std::function<void(const server_http_req &, server_http_context::ws_conn &)>;

    // starts the worker; the handler and what it captures are released when the worker ends
    static std::shared_ptr<realtime_session> start(handler_t handler, const std::string & intent);

    ~realtime_session(); // close() + join()

    realtime_session(const realtime_session &)             = delete;
    realtime_session & operator=(const realtime_session &) = delete;

    realtime_conn & conn() { return conn_; }

    // false once closed, the worker may still run: join() waits for it
    bool is_open() const { return conn_.is_open(); }

    // ends the session with one session_terminated error, then waits for the worker
    void terminate(const std::string & reason);

    // waits for the worker; idempotent, never called from the worker
    void join();

private:
    realtime_session() = default;

    realtime_conn         conn_;
    std::function<bool()> should_stop = [this]() { return !conn_.is_open(); };
    server_http_req       req{{}, {}, "/v1/realtime", "", "", {}, should_stop};
    std::mutex            join_mtx;
    std::thread           worker;
};

} // namespace llama_engine
