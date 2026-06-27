#include "engine_lifecycle.hpp"

namespace llama_engine {

llama_engine_state engine_lifecycle::state() const {
    return state_.load();
}

bool engine_lifecycle::can_start_load() const {
    const auto s = state_.load();
    return s == LLAMA_ENGINE_STATE_UNLOADED || s == LLAMA_ENGINE_STATE_PAUSED;
}

void engine_lifecycle::set_state_and_notify_(llama_engine_state s) {
    state_.store(s);
    cv_lifecycle_.notify_all();
}

void engine_lifecycle::enter_loading(bool from_resume) {
    cancel_load_.store(false);
    set_state_and_notify_(from_resume ? LLAMA_ENGINE_STATE_RESUMING
                                      : LLAMA_ENGINE_STATE_LOADING);
}

void engine_lifecycle::complete_load_success() {
    set_state_and_notify_(LLAMA_ENGINE_STATE_READY);
}

void engine_lifecycle::fail_load() {
    set_state_and_notify_(LLAMA_ENGINE_STATE_UNLOADED);
}

void engine_lifecycle::cancel_to_paused() {
    set_state_and_notify_(LLAMA_ENGINE_STATE_PAUSED);
}

void engine_lifecycle::enter_pausing() {
    set_state_and_notify_(LLAMA_ENGINE_STATE_PAUSING);
}

void engine_lifecycle::enter_paused() {
    set_state_and_notify_(LLAMA_ENGINE_STATE_PAUSED);
}

void engine_lifecycle::enter_unloading() {
    set_state_and_notify_(LLAMA_ENGINE_STATE_UNLOADING);
}

void engine_lifecycle::enter_unloaded() {
    set_state_and_notify_(LLAMA_ENGINE_STATE_UNLOADED);
}

void engine_lifecycle::request_pause_preemption() {
    pause_requested_.store(true);
    cancel_load_.store(true);
}

bool engine_lifecycle::consume_pause_preemption() {
    return pause_requested_.exchange(false);
}

void engine_lifecycle::clear_load_preemption() {
    cancel_load_.store(false);
}

void engine_lifecycle::wait_until_pause_resolved(std::unique_lock<std::mutex> & lock) {
    cv_lifecycle_.wait(lock, [this]() {
        const auto s = state_.load();
        return s == LLAMA_ENGINE_STATE_PAUSED
            || s == LLAMA_ENGINE_STATE_UNLOADED
            || s == LLAMA_ENGINE_STATE_READY;
    });
}

bool engine_lifecycle::should_continue_loading() const {
    return !cancel_load_.load();
}

engine_lifecycle::load_progress_hook engine_lifecycle::progress_hook() {
    return load_progress_hook{
        [](float /*progress*/, void * ud) -> bool {
            auto * self = static_cast<engine_lifecycle *>(ud);
            return self->should_continue_loading();
        },
        this,
    };
}

} // namespace llama_engine
