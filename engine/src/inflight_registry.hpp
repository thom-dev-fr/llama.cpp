#pragma once

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <functional>
#include <mutex>
#include <set>

namespace llama_engine {

// Cancellation flag observed by an in-flight non-stream chat completion.
// Lives in the **Inflight Registry** module because that's the module that
// tracks its presence; the **Chat Route Adapter** wires the flag into the
// synthetic `server_http_req::should_stop` callback but does not own it.
struct active_request {
    std::atomic<bool> cancelled{false};
};

// Forward declaration. The full type lives in chat_route_adapter.hpp because
// only the adapter peers inside its fields; the registry treats it as opaque.
struct stream_handle;

// **Inflight Registry** — the set of chat completions and streams currently
// in flight against `server_routes`. Owns its own mutex + drain CV; never
// nested with **Engine Core**'s mutex. Survives `server_context` teardown so
// in-flight work can drain before the context is destroyed.
//
// Tracks two kinds of work:
//   - active_request: scope-bounded (a single `chat_completion` call). Use
//     `track_request()` to obtain an RAII guard that unregisters on scope
//     exit.
//   - stream_handle:  long-lived (open / next* / close). Use
//     `add_stream()` and `remove_stream()` to bracket the handle's lifetime
//     manually.
class inflight_registry {
public:
    inflight_registry()  = default;
    ~inflight_registry() = default;

    inflight_registry(const inflight_registry &)             = delete;
    inflight_registry & operator=(const inflight_registry &) = delete;

    // Stream tracking — manual lifecycle. Both calls are idempotent against
    // an already-(un)tracked handle. `remove_stream` notifies the drain CV so
    // a concurrent `preempt_all_and_drain` can observe the count drop.
    void add_stream(stream_handle * s);
    void remove_stream(stream_handle * s);

    // Request tracking — RAII. The returned guard removes `r` from the
    // registry and notifies the drain CV on destruction.
    class request_guard {
    public:
        request_guard() noexcept = default;
        ~request_guard();
        request_guard(request_guard && other) noexcept;
        request_guard & operator=(request_guard && other) noexcept;
        request_guard(const request_guard &)             = delete;
        request_guard & operator=(const request_guard &) = delete;

    private:
        friend class inflight_registry;
        request_guard(inflight_registry * registry, active_request * req) noexcept
            : registry_(registry), req_(req) {}

        inflight_registry * registry_ = nullptr;
        active_request    * req_      = nullptr;
    };
    request_guard track_request(active_request * r);

    // Drain protocol. Called by **Engine Core** during pause / unload before
    // `ctx` and `routes` are destroyed.
    //
    // For each tracked `stream_handle`, invokes `preempt_stream(s)` (which is
    // expected to release the upstream response so any in-flight
    // `stream_next` blocked on it can unwind). Sets `cancelled = true` on
    // every tracked `active_request`. Then waits up to `kDrainDeadline` for
    // both sets to empty. After the deadline, leftover handles are forgotten:
    // the registry no longer references them, callers retain ownership and
    // their next interaction will observe a cancelled state.
    void preempt_all_and_drain(
        const std::function<void(stream_handle *)> & preempt_stream);

    // Snapshot accessors for tests / diagnostics.
    size_t stream_count()  const;
    size_t request_count() const;

    static constexpr auto kDrainDeadline = std::chrono::seconds(2);

private:
    void erase_request_(active_request * r);

    mutable std::mutex         mtx_;
    std::condition_variable    cv_drain_;
    std::set<stream_handle *>  streams_;
    std::set<active_request *> requests_;
};

} // namespace llama_engine
