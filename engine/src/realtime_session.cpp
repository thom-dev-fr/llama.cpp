#include "realtime_session.hpp"

#include <utility>

namespace llama_engine {

std::shared_ptr<realtime_session> realtime_session::start(handler_t handler, const std::string & intent) {
    std::shared_ptr<realtime_session> s(new realtime_session());
    if (!intent.empty()) {
        s->req.params["intent"] = intent;
    }
    realtime_session * self = s.get();
    // the worker never outlives the session: the destructor joins it
    s->worker = std::thread([self, handler = std::move(handler)]() mutable {
        handler(self->req, self->conn_);
        handler = nullptr;
        // the handler may return without closing, e.g. on a server error
        self->conn_.close();
    });
    return s;
}

realtime_session::~realtime_session() {
    conn_.close();
    join();
}

void realtime_session::terminate(const std::string & reason) {
    conn_.fail("session_terminated", reason);
    join();
}

void realtime_session::join() {
    std::lock_guard<std::mutex> lock(join_mtx);
    if (worker.joinable()) {
        worker.join();
    }
}

} // namespace llama_engine
