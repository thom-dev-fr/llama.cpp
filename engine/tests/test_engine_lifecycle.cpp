#include "test_util.hpp"

#include "engine_lifecycle.hpp"
#include "llama_engine.h"

#include <atomic>
#include <chrono>
#include <mutex>
#include <thread>

using llama_engine::engine_lifecycle;

static void test_initial_state_is_unloaded() {
    CASE("initial state is UNLOADED");
    engine_lifecycle lc;
    EXPECT_EQ((int) lc.state(), (int) LLAMA_ENGINE_STATE_UNLOADED);
    EXPECT(lc.can_start_load());
}

static void test_can_start_load_from_paused() {
    CASE("can_start_load is true from UNLOADED and PAUSED only");
    engine_lifecycle lc;
    EXPECT(lc.can_start_load());                   // UNLOADED

    lc.enter_loading(/*from_resume=*/false);
    EXPECT(!lc.can_start_load());                  // LOADING

    lc.complete_load_success();
    EXPECT(!lc.can_start_load());                  // READY

    lc.enter_pausing();
    EXPECT(!lc.can_start_load());                  // PAUSING

    lc.enter_paused();
    EXPECT(lc.can_start_load());                   // PAUSED

    lc.enter_loading(/*from_resume=*/true);
    EXPECT_EQ((int) lc.state(), (int) LLAMA_ENGINE_STATE_RESUMING);
}

static void test_intent_named_transitions() {
    CASE("intent-named transitions store the expected state");
    engine_lifecycle lc;

    lc.enter_loading(false);
    EXPECT_EQ((int) lc.state(), (int) LLAMA_ENGINE_STATE_LOADING);

    lc.complete_load_success();
    EXPECT_EQ((int) lc.state(), (int) LLAMA_ENGINE_STATE_READY);

    lc.enter_pausing();
    EXPECT_EQ((int) lc.state(), (int) LLAMA_ENGINE_STATE_PAUSING);

    lc.enter_paused();
    EXPECT_EQ((int) lc.state(), (int) LLAMA_ENGINE_STATE_PAUSED);

    lc.enter_loading(true);
    EXPECT_EQ((int) lc.state(), (int) LLAMA_ENGINE_STATE_RESUMING);

    lc.fail_load();
    EXPECT_EQ((int) lc.state(), (int) LLAMA_ENGINE_STATE_UNLOADED);

    lc.enter_loading(false);
    lc.cancel_to_paused();
    EXPECT_EQ((int) lc.state(), (int) LLAMA_ENGINE_STATE_PAUSED);

    lc.enter_loading(true);
    lc.complete_load_success();
    lc.enter_unloading();
    EXPECT_EQ((int) lc.state(), (int) LLAMA_ENGINE_STATE_UNLOADING);
    lc.enter_unloaded();
    EXPECT_EQ((int) lc.state(), (int) LLAMA_ENGINE_STATE_UNLOADED);
}

static void test_consume_pause_preemption_is_one_shot() {
    CASE("consume_pause_preemption returns the flag exactly once");
    engine_lifecycle lc;
    EXPECT_EQ(lc.consume_pause_preemption(), false);

    lc.request_pause_preemption();
    EXPECT_EQ(lc.consume_pause_preemption(), true);
    EXPECT_EQ(lc.consume_pause_preemption(), false);
}

static void test_request_pause_aborts_progress_callback() {
    CASE("request_pause_preemption flips should_continue_loading to false");
    engine_lifecycle lc;
    lc.enter_loading(false);
    EXPECT(lc.should_continue_loading());

    lc.request_pause_preemption();
    EXPECT(!lc.should_continue_loading());

    // enter_loading clears the cancel flag for the next load.
    lc.cancel_to_paused();
    lc.enter_loading(true);
    EXPECT(lc.should_continue_loading());
}

static void test_progress_hook_thunk() {
    CASE("progress_hook bridges to should_continue_loading without engine_core");
    engine_lifecycle lc;
    auto hook = lc.progress_hook();

    lc.enter_loading(false);
    EXPECT_EQ(hook.callback(0.5f, hook.user_data), true);

    lc.request_pause_preemption();
    EXPECT_EQ(hook.callback(0.6f, hook.user_data), false);
}

static void test_pause_during_load_unblocks_after_terminal() {
    CASE("wait_until_pause_resolved unblocks once a terminal state is reached");
    engine_lifecycle lc;
    std::mutex mtx;

    lc.enter_loading(false);

    std::atomic<bool> waiter_returned{false};
    std::thread waiter([&]() {
        std::unique_lock<std::mutex> lock(mtx);
        lc.wait_until_pause_resolved(lock);
        waiter_returned.store(true);
    });

    // Give the waiter a moment to actually park on the CV. (No public way to
    // observe this, so we just yield a few times.)
    std::this_thread::sleep_for(std::chrono::milliseconds(20));
    EXPECT_EQ(waiter_returned.load(), false);

    {
        std::lock_guard<std::mutex> lock(mtx);
        lc.cancel_to_paused();
    }

    waiter.join();
    EXPECT_EQ(waiter_returned.load(), true);
    EXPECT_EQ((int) lc.state(), (int) LLAMA_ENGINE_STATE_PAUSED);
}

void run_engine_lifecycle_tests() {
    std::fprintf(stderr, "EngineLifecycle:\n");
    test_initial_state_is_unloaded();
    test_can_start_load_from_paused();
    test_intent_named_transitions();
    test_consume_pause_preemption_is_one_shot();
    test_request_pause_aborts_progress_callback();
    test_progress_hook_thunk();
    test_pause_during_load_unblocks_after_terminal();
}
