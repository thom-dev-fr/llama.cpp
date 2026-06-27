#include "test_util.hpp"

#include "inflight_registry.hpp"
#include "chat_route_adapter.hpp"  // for the full stream_handle definition

#include <atomic>
#include <chrono>
#include <thread>

using llama_engine::active_request;
using llama_engine::inflight_registry;
using llama_engine::stream_handle;

static void test_request_guard_unregisters_on_scope_exit() {
    CASE("track_request RAII guard unregisters on scope exit");
    inflight_registry registry;
    active_request req;
    EXPECT_EQ(registry.request_count(), (size_t) 0);

    {
        auto guard = registry.track_request(&req);
        EXPECT_EQ(registry.request_count(), (size_t) 1);
    }
    EXPECT_EQ(registry.request_count(), (size_t) 0);
}

static void test_track_request_null_is_noop() {
    CASE("track_request with null pointer is a no-op");
    inflight_registry registry;
    {
        auto guard = registry.track_request(nullptr);
        EXPECT_EQ(registry.request_count(), (size_t) 0);
    }
    EXPECT_EQ(registry.request_count(), (size_t) 0);
}

static void test_request_guard_move() {
    CASE("request_guard is movable; only the alive guard unregisters");
    inflight_registry registry;
    active_request req;

    {
        auto a = registry.track_request(&req);
        EXPECT_EQ(registry.request_count(), (size_t) 1);
        auto b = std::move(a);
        EXPECT_EQ(registry.request_count(), (size_t) 1);
        // a is now disarmed; only b unregisters at scope exit.
    }
    EXPECT_EQ(registry.request_count(), (size_t) 0);
}

static void test_add_remove_stream() {
    CASE("add_stream / remove_stream are idempotent");
    inflight_registry registry;
    stream_handle s;
    EXPECT_EQ(registry.stream_count(), (size_t) 0);

    registry.add_stream(&s);
    EXPECT_EQ(registry.stream_count(), (size_t) 1);
    registry.add_stream(&s);  // idempotent
    EXPECT_EQ(registry.stream_count(), (size_t) 1);

    registry.remove_stream(&s);
    EXPECT_EQ(registry.stream_count(), (size_t) 0);
    registry.remove_stream(&s);  // idempotent
    EXPECT_EQ(registry.stream_count(), (size_t) 0);
}

static void test_drain_calls_preempt_for_each_stream() {
    CASE("preempt_all_and_drain invokes the preempt callback on each stream");
    inflight_registry registry;
    stream_handle s1, s2, s3;
    registry.add_stream(&s1);
    registry.add_stream(&s2);
    registry.add_stream(&s3);

    std::atomic<int> preempt_count{0};
    auto preempt = [&](stream_handle * h) {
        (void) h;
        preempt_count.fetch_add(1);
        // Simulate the real adapter: cancellation tells stream_next to
        // unwind, and the owner eventually calls remove_stream.
    };

    // The streams aren't removed by the preempt callback in this fake, so
    // the drain will hit the deadline. We don't want to wait 2s in a unit
    // test — drain in another thread and remove the streams from the test
    // thread to unblock it before the deadline.
    std::thread drainer([&]() {
        registry.preempt_all_and_drain(preempt);
    });

    // Wait until the preempt callbacks have all fired, then remove.
    while (preempt_count.load() < 3) {
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    registry.remove_stream(&s1);
    registry.remove_stream(&s2);
    registry.remove_stream(&s3);

    drainer.join();
    EXPECT_EQ(preempt_count.load(), 3);
    EXPECT_EQ(registry.stream_count(),  (size_t) 0);
    EXPECT_EQ(registry.request_count(), (size_t) 0);
}

static void test_drain_marks_requests_cancelled() {
    CASE("preempt_all_and_drain marks all tracked requests as cancelled");
    inflight_registry registry;
    active_request r1, r2;
    auto g1 = registry.track_request(&r1);
    auto g2 = registry.track_request(&r2);

    EXPECT_EQ(r1.cancelled.load(), false);
    EXPECT_EQ(r2.cancelled.load(), false);

    std::thread drainer([&]() {
        registry.preempt_all_and_drain({});
    });

    // The drainer marks both requests cancelled before parking on the CV.
    // Then it will hit the deadline; we unblock by destroying the guards
    // via reset() — actually we have to do it from inside the test thread
    // before the deadline fires. Easiest: just wait for the cancellation
    // signal then drop the guards.
    while (!(r1.cancelled.load() && r2.cancelled.load())) {
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    g1 = inflight_registry::request_guard{};   // unregister r1
    g2 = inflight_registry::request_guard{};   // unregister r2

    drainer.join();
    EXPECT_EQ(r1.cancelled.load(), true);
    EXPECT_EQ(r2.cancelled.load(), true);
    EXPECT_EQ(registry.request_count(), (size_t) 0);
}

static void test_drain_deadline_forgets_leftover_handles() {
    CASE("preempt_all_and_drain forgets leftover handles after the deadline");
    // We use a tiny synthetic registry policy by NOT actually calling
    // remove_stream from anywhere — the drain has to fall through the
    // deadline and clear the sets itself. We don't want to wait the full 2s,
    // so we install a fake stream and rely on the drainer giving up.
    //
    // To keep this fast in CI, we cap the actual wait by polling: as soon as
    // the drainer thread joins, we observe stream_count == 0.
    inflight_registry registry;
    stream_handle s;
    registry.add_stream(&s);

    auto start = std::chrono::steady_clock::now();
    registry.preempt_all_and_drain([](stream_handle *){});
    auto elapsed = std::chrono::steady_clock::now() - start;

    EXPECT_EQ(registry.stream_count(), (size_t) 0);
    // Should have waited approximately the deadline (2s). Allow some slack.
    EXPECT(elapsed >= std::chrono::seconds(1));
    EXPECT(elapsed <= std::chrono::seconds(4));
}

void run_inflight_registry_tests() {
    std::fprintf(stderr, "InflightRegistry:\n");
    test_request_guard_unregisters_on_scope_exit();
    test_track_request_null_is_noop();
    test_request_guard_move();
    test_add_remove_stream();
    test_drain_calls_preempt_for_each_stream();
    test_drain_marks_requests_cancelled();
    test_drain_deadline_forgets_leftover_handles();
}
