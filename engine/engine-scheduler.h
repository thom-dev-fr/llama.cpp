#pragma once

#include "ggml.h"

#include <cstdint>
#include <deque>
#include <functional>
#include <map>
#include <mutex>
#include <string>

namespace llama_engine { namespace detail {

// What the load policy needs to know about one catalog entry.
struct model_usage {
    bool running        = false; // counted against the limit: loading, resident or unloading
    bool ready_or_sleep = false; // resident, and able to take requests or wake up
    bool busy           = false; // at least one admitted request
    bool stopping       = false; // already asked to unload
    int64_t last_used   = 0;
};

// Queue of requests waiting for a model slot, and the LRU eviction policy.
// Extracted unchanged from the process router (server_lru_sched) so that the
// in-process engine and the legacy router share one policy until P6.
// Every call must hold the owner's mutex, passed at construction.
struct load_queue {
    using usage_visitor = std::function<void(const std::string &, const model_usage &)>;

    std::function<int()> max_models;                                  // <= 0 means no limit
    std::function<void(const usage_visitor &)> each_model;
    std::function<void(const std::string &)> evict;                   // must not block

    explicit load_queue(std::mutex & mutex) : mutex(mutex) {}

    bool has_capacity(std::unique_lock<std::mutex> & lk) {
        check_lock(lk);
        return max_models() <= 0 || count_running() < (size_t) max_models();
    }

    // returns "" if no model can be given up
    std::string pick_victim(std::unique_lock<std::mutex> & lk) {
        check_lock(lk);
        std::string victim;
        int64_t victim_last_used = 0;
        each_model([&](const std::string & name, const model_usage & m) {
            // a busy model is mid-request, one still coming up has no request to finish
            if (m.busy || !m.ready_or_sleep) {
                return;
            }
            // already on its way out, or a queued request wants it
            if (m.stopping || find(name)) {
                return;
            }
            if (victim.empty() || m.last_used < victim_last_used) {
                victim           = name;
                victim_last_used = m.last_used;
            }
        });
        return victim;
    }

    // requests wanting the same model share one entry, so they all need only one slot
    // and all get unblocked by the single load that entry performs
    // returns the number of requests waiting for this model
    int join(std::unique_lock<std::mutex> & lk, const std::string & model_id) {
        check_lock(lk);
        if (entry_t * e = find(model_id)) {
            return ++e->n_waiters;
        }
        queue.push_back({ model_id, 1, false });
        return 1;
    }

    void leave(std::unique_lock<std::mutex> & lk, const std::string & model_id) {
        check_lock(lk);
        for (auto it = queue.begin(); it != queue.end(); ++it) {
            if (it->model_id == model_id) {
                if (--it->n_waiters <= 0) {
                    queue.erase(it); // last one waiting for this model went away
                }
                return;
            }
        }
    }

    bool queue_empty(std::unique_lock<std::mutex> & lk) {
        check_lock(lk);
        return queue.empty();
    }

    // model at the head of the queue, "" if none; service order is first come, first served
    std::string front(std::unique_lock<std::mutex> & lk) {
        check_lock(lk);
        return queue.empty() ? std::string() : queue.front().model_id;
    }

    size_t position(std::unique_lock<std::mutex> & lk, const std::string & model_id) {
        check_lock(lk);
        for (size_t i = 0; i < queue.size(); ++i) {
            if (queue[i].model_id == model_id) {
                return i + 1;
            }
        }
        return 0;
    }

    // true if it is this model's turn to load, and nobody is loading it yet
    bool try_claim(std::unique_lock<std::mutex> & lk, const std::string & model_id) {
        check_lock(lk);
        if (queue.empty() || queue.front().model_id != model_id || queue.front().loading) {
            return false;
        }
        if (!has_capacity(lk)) {
            return false;
        }
        queue.front().loading = true;
        return true;
    }

    // on failure the entry is back in line; on success it stays until its waiters leave,
    // so the model coming up is never picked as a victim before they use it
    void claim_done(std::unique_lock<std::mutex> & lk, const std::string & model_id, bool ok) {
        check_lock(lk);
        if (ok) {
            return;
        }
        for (auto it = queue.begin(); it != queue.end(); ++it) {
            if (it->model_id == model_id) {
                it->loading = false;
                return;
            }
        }
    }

    // evict idle models while queued requests outnumber the slots that are free or being freed
    // caller must hold the owner's mutex; never blocks, so it is safe from any thread
    void tick(std::unique_lock<std::mutex> & lk) {
        check_lock(lk);
        if (max_models() <= 0 || queue.empty()) {
            return;
        }
        int n_running  = 0;
        int n_stopping = 0;
        std::map<std::string, bool> running;
        each_model([&](const std::string & name, const model_usage & m) {
            running[name] = m.running;
            if (m.running) {
                n_running++;
                if (m.stopping) {
                    n_stopping++;
                }
            }
        });
        int n_needed  = 0;
        int n_claimed = 0; // claimed the slot, but the load has not started yet
        for (const auto & e : queue) {
            if (!e.loading) {
                n_needed++;
                continue;
            }
            auto it = running.find(e.model_id);
            if (it != running.end() && !it->second) {
                n_claimed++;
            }
        }
        int n_free = max_models() - n_running + n_stopping - n_claimed;
        while (n_free < n_needed) {
            std::string victim = pick_victim(lk);
            if (victim.empty()) {
                return; // all remaining models are busy, wait for a request to end
            }
            evict(victim);
            n_free++;
        }
    }

  private:
    struct entry_t {
        std::string model_id;
        int  n_waiters; // requests waiting for this model
        bool loading;   // one of the waiters is doing the load right now
    };

    entry_t * find(const std::string & model_id) {
        for (auto & e : queue) {
            if (e.model_id == model_id) {
                return &e;
            }
        }
        return nullptr;
    }

    void check_lock(std::unique_lock<std::mutex> & lk) {
        GGML_ASSERT(lk.owns_lock() && lk.mutex() == &mutex);
    }

    size_t count_running() {
        size_t count = 0;
        each_model([&](const std::string &, const model_usage & m) {
            count += m.running ? 1 : 0;
        });
        return count;
    }

    std::mutex & mutex;
    std::deque<entry_t> queue;
};

// Exact name first, then aliases; the same resolution rule as the router.
template <typename Map, typename Aliases>
typename Map::iterator find_model(Map & models, const std::string & name, Aliases aliases_of) {
    auto it = models.find(name);
    if (it != models.end()) {
        return it;
    }
    for (it = models.begin(); it != models.end(); ++it) {
        if (aliases_of(it->second).count(name)) {
            return it;
        }
    }
    return models.end();
}

} } // namespace llama_engine::detail
