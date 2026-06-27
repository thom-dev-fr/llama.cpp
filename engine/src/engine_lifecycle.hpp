#pragma once

#include "llama_engine.h"

#include <atomic>
#include <condition_variable>
#include <mutex>

namespace llama_engine {

// **Engine Lifecycle** — owns the model-loading state machine, the
// preemption flags observed by the llama.cpp progress callback during
// load/resume, and the lifecycle CV used to wait for pause-preempt resolution.
//
// Locking model: Engine Lifecycle does NOT own a mutex. It shares the
// **Engine Core** mutex (the one that also protects `ctx`/`routes`/`meta`)
// because the invariant `state == READY ⇔ ctx is non-null` would otherwise
// require its own re-establishment. Methods that wait take a
// `std::unique_lock<std::mutex>&` from the caller.
//
// State observation (`state()`, `can_start_load()`, `should_continue_loading()`)
// is lock-free: the underlying state and flags are atomics. Mutating
// transitions are short critical sections that the caller is expected to be
// holding the Engine Core mutex for.
class engine_lifecycle {
public:
    // Lock-free observation
    llama_engine_state state() const;
    bool can_start_load() const;

    // Intent-named transitions. Each one stores the new state and notifies
    // the lifecycle CV, so callers do not have to remember to notify.
    // Preconditions are documented per-method; violations are not asserted
    // (Engine Core enforces the higher-level state machine).
    //
    // `enter_loading` is the only transition that takes a parameter: it
    // distinguishes a fresh load from a resume. It also clears the load
    // preemption flag so a previous preemption does not bleed into this load.
    // It deliberately does NOT clear `pause_requested_`: pause() may have
    // posted that flag before the caller entered the load path, and the
    // caller will honour it after `load_model()` returns.
    void enter_loading(bool from_resume);
    void complete_load_success();    // state := READY
    void fail_load();                // state := UNLOADED   (load_model returned false)
    void cancel_to_paused();         // state := PAUSED     (load was preempted by pause())
    void enter_pausing();            // state := PAUSING
    void enter_paused();             // state := PAUSED
    void enter_unloading();          // state := UNLOADING
    void enter_unloaded();           // state := UNLOADED

    // Pause-preempt protocol.
    //
    // `request_pause_preemption` is called by pause() when it observes a
    // concurrent LOADING or RESUMING state. It atomically asks the
    // load-progress callback to abort and remembers (via `pause_requested_`)
    // that the load was preempted by pause rather than by an unrelated
    // failure.
    //
    // `consume_pause_preemption` is called once by the loading thread after
    // `load_model()` returns, to consume the flag. It is one-shot.
    //
    // `clear_load_preemption` resets the cancel flag after a load has fully
    // resolved, so a subsequent load does not start with the flag set.
    //
    // `wait_until_pause_resolved` is called by pause() to block until the
    // loading thread has flipped the state to PAUSED, UNLOADED, or READY
    // (the three terminal post-load states). Takes the caller's lock.
    void request_pause_preemption();
    bool consume_pause_preemption();
    void clear_load_preemption();
    void wait_until_pause_resolved(std::unique_lock<std::mutex> & lock);

    // llama.cpp `load_progress_callback` bridge.
    //
    // The callback is invoked every ~1% of loaded tensor data and returns
    // false to abort the load cleanly. Engine Core plugs `progress_hook()`'s
    // pair directly into `common_params.load_progress_callback` /
    // `_user_data`; the void* points at this lifecycle instance, so Engine
    // Core never participates in the cancellation read.
    struct load_progress_hook {
        bool (*callback)(float progress, void * user_data);
        void * user_data;
    };
    load_progress_hook progress_hook();

    // Used by `progress_hook()`'s thunk. Lock-free.
    bool should_continue_loading() const;

private:
    void set_state_and_notify_(llama_engine_state s);

    std::atomic<llama_engine_state> state_{LLAMA_ENGINE_STATE_UNLOADED};
    std::atomic<bool>               cancel_load_{false};
    std::atomic<bool>               pause_requested_{false};
    std::condition_variable         cv_lifecycle_;
};

} // namespace llama_engine
