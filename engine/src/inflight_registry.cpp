#include "inflight_registry.hpp"

#include <utility>
#include <vector>

namespace llama_engine {

void inflight_registry::add_stream(stream_handle * s) {
    if (s == nullptr) return;
    std::lock_guard<std::mutex> lock(mtx_);
    streams_.insert(s);
}

void inflight_registry::remove_stream(stream_handle * s) {
    if (s == nullptr) return;
    {
        std::lock_guard<std::mutex> lock(mtx_);
        streams_.erase(s);
    }
    cv_drain_.notify_all();
}

inflight_registry::request_guard
inflight_registry::track_request(active_request * r) {
    if (r == nullptr) return request_guard{};
    {
        std::lock_guard<std::mutex> lock(mtx_);
        requests_.insert(r);
    }
    return request_guard{this, r};
}

void inflight_registry::erase_request_(active_request * r) {
    if (r == nullptr) return;
    {
        std::lock_guard<std::mutex> lock(mtx_);
        requests_.erase(r);
    }
    cv_drain_.notify_all();
}

inflight_registry::request_guard::~request_guard() {
    if (registry_ && req_) {
        registry_->erase_request_(req_);
    }
}

inflight_registry::request_guard::request_guard(request_guard && other) noexcept
    : registry_(other.registry_), req_(other.req_) {
    other.registry_ = nullptr;
    other.req_      = nullptr;
}

inflight_registry::request_guard &
inflight_registry::request_guard::operator=(request_guard && other) noexcept {
    if (this != &other) {
        if (registry_ && req_) {
            registry_->erase_request_(req_);
        }
        registry_ = other.registry_;
        req_      = other.req_;
        other.registry_ = nullptr;
        other.req_      = nullptr;
    }
    return *this;
}

void inflight_registry::preempt_all_and_drain(
    const std::function<void(stream_handle *)> & preempt_stream)
{
    // Snapshot the streams under the lock, then preempt each outside the
    // lock so the preempt callback can take its own locks (notably the
    // stream_handle's mtx) without nesting registry mutex underneath.
    std::vector<stream_handle *> streams_snapshot;
    {
        std::lock_guard<std::mutex> lock(mtx_);
        streams_snapshot.assign(streams_.begin(), streams_.end());
        for (auto * r : requests_) {
            r->cancelled.store(true);
        }
    }

    if (preempt_stream) {
        for (auto * s : streams_snapshot) {
            preempt_stream(s);
        }
    }

    std::unique_lock<std::mutex> lock(mtx_);
    cv_drain_.wait_for(lock, kDrainDeadline, [&]() {
        return streams_.empty() && requests_.empty();
    });
    // After the deadline, forget any leftover handles. Callers still own
    // them; subsequent calls will observe the cancelled flag and unwind.
    streams_.clear();
    requests_.clear();
}

size_t inflight_registry::stream_count() const {
    std::lock_guard<std::mutex> lock(mtx_);
    return streams_.size();
}

size_t inflight_registry::request_count() const {
    std::lock_guard<std::mutex> lock(mtx_);
    return requests_.size();
}

} // namespace llama_engine
