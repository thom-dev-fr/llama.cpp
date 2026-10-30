#include "realtime_conn.hpp"

#include "json.h"
#include "server-common.h"

namespace llama_engine {

realtime_conn::push_status realtime_conn::push(std::string_view msg) {
    if (msg.size() > lim.max_message) {
        return push_status::too_large;
    }
    std::lock_guard<std::mutex> lock(mtx);
    if (closed) {
        return push_status::closed;
    }
    if (n_in + msg.size() > lim.max_in) {
        fail_locked("input_queue_full", "the client sends events faster than the session reads them");
        return push_status::overflow;
    }
    in.emplace_back(msg);
    n_in += msg.size();
    cv_in.notify_one();
    return push_status::ok;
}

bool realtime_conn::next(std::string & msg) {
    std::unique_lock<std::mutex> lock(mtx);
    cv_out.wait(lock, [this]() { return !out.empty() || closed; });
    if (out.empty()) {
        return false;
    }
    msg = std::move(out.front());
    out.pop_front();
    n_out -= msg.size();
    return true;
}

int realtime_conn::read(std::string & msg) {
    std::unique_lock<std::mutex> lock(mtx);
    cv_in.wait(lock, [this]() { return !in.empty() || closed; });
    if (closed) {
        return 0;
    }
    msg = std::move(in.front());
    in.pop_front();
    n_in -= msg.size();
    return 1;
}

bool realtime_conn::send(const std::string & msg) {
    std::lock_guard<std::mutex> lock(mtx);
    if (closed) {
        return false;
    }
    if (n_out + msg.size() > lim.max_out) {
        fail_locked("output_queue_full", "the client reads events slower than the session sends them");
        return false;
    }
    out.push_back(msg);
    n_out += msg.size();
    cv_out.notify_one();
    return true;
}

bool realtime_conn::send_binary(const std::string &) {
    // the realtime handlers only send text, a binary event would be lost
    fail("binary_not_supported", "binary events are not supported");
    return false;
}

bool realtime_conn::is_open() const {
    std::lock_guard<std::mutex> lock(mtx);
    return !closed;
}

void realtime_conn::close() {
    std::lock_guard<std::mutex> lock(mtx);
    close_locked();
}

void realtime_conn::fail(const std::string & code, const std::string & message) {
    std::lock_guard<std::mutex> lock(mtx);
    fail_locked(code, message);
}

void realtime_conn::fail_locked(const std::string & code, const std::string & message) {
    if (closed) {
        return;
    }
    const common_json ev = {
        {"type",     "error"},
        {"event_id", "event_" + random_string()},
        {"error",    {
            {"type",    "server_error"},
            {"code",    code},
            {"message", message},
            {"param",   nullptr},
        }},
    };
    out.push_back(ev.dump());
    n_out += out.back().size();
    close_locked();
}

void realtime_conn::close_locked() {
    if (closed) {
        return;
    }
    closed = true;
    in.clear();
    n_in = 0;
    cv_in.notify_all();
    cv_out.notify_all();
}

} // namespace llama_engine
