#include "server-task.h"
#include "server-queue.h"

#include "log.h"

#include <algorithm>
#include <chrono>
#include <thread>

#define QUE_INF(fmt, ...) LOG_INF("que  %12.*s: " fmt, 12, __func__, __VA_ARGS__)
#define QUE_WRN(fmt, ...) LOG_WRN("que  %12.*s: " fmt, 12, __func__, __VA_ARGS__)
#define QUE_ERR(fmt, ...) LOG_ERR("que  %12.*s: " fmt, 12, __func__, __VA_ARGS__)
#define QUE_DBG(fmt, ...) LOG_DBG("que  %12.*s: " fmt, 12, __func__, __VA_ARGS__)

#define RES_INF(fmt, ...) LOG_INF("res  %12.*s: " fmt, 12, __func__, __VA_ARGS__)
#define RES_WRN(fmt, ...) LOG_WRN("res  %12.*s: " fmt, 12, __func__, __VA_ARGS__)
#define RES_ERR(fmt, ...) LOG_ERR("res  %12.*s: " fmt, 12, __func__, __VA_ARGS__)
#define RES_DBG(fmt, ...) LOG_DBG("res  %12.*s: " fmt, 12, __func__, __VA_ARGS__)

//
// server_queue
//

static bool task_resets_idle_timer(server_task_type type) {
    return type != SERVER_TASK_TYPE_METRICS;
}

int server_queue::post(server_task && task, bool front) {
    std::unique_lock<std::mutex> lock(mutex_tasks);
    GGML_ASSERT(task.id != -1);
    // if this is cancel task make sure to clean up pending tasks
    if (task.type == SERVER_TASK_TYPE_CANCEL) {
        cleanup_pending_task(task.id_target);
    }
    const int  task_id     = task.id;
    const bool reset_timer = task_resets_idle_timer(task.type);
    QUE_DBG("new task, id = %d, front = %d\n", task_id, front);
    if (front) {
        queue_tasks.push_front(std::move(task));
    } else {
        queue_tasks.push_back(std::move(task));
    }
    if (reset_timer) {
        time_last_task = ggml_time_ms();
    }
    condition_tasks.notify_one();
    return task_id;
}

int server_queue::post(std::vector<server_task> && tasks, bool front) {
    std::unique_lock<std::mutex> lock(mutex_tasks);
    bool reset_timer = false;
    for (auto & task : tasks) {
        if (task.id == -1) {
            task.id = id++;
        }
        // if this is cancel task make sure to clean up pending tasks
        if (task.type == SERVER_TASK_TYPE_CANCEL) {
            cleanup_pending_task(task.id_target);
        }
        reset_timer |= task_resets_idle_timer(task.type);
        QUE_DBG("new task, id = %d/%d, front = %d\n", task.id, (int) tasks.size(), front);
        if (front) {
            queue_tasks.push_front(std::move(task));
        } else {
            queue_tasks.push_back(std::move(task));
        }
    }
    if (reset_timer) {
        time_last_task = ggml_time_ms();
    }
    condition_tasks.notify_one();
    return 0;
}

void server_queue::defer(server_task && task) {
    std::unique_lock<std::mutex> lock(mutex_tasks);
    QUE_DBG("defer task, id = %d\n", task.id);
    queue_tasks_deferred.push_back(std::move(task));
    time_last_task = ggml_time_ms();
    condition_tasks.notify_one();
}

int server_queue::get_new_id() {
    std::unique_lock<std::mutex> lock(mutex_tasks);
    int new_id = id++;
    return new_id;
}

void server_queue::pop_deferred_task(int id_slot) {
    std::unique_lock<std::mutex> lock(mutex_tasks);
    if (!queue_tasks_deferred.empty()) {
        // try to find a task that uses the specified slot
        bool found = false;
        for (auto it = queue_tasks_deferred.begin(); it != queue_tasks_deferred.end(); ++it) {
            if (it->id_slot == id_slot) {
                QUE_DBG("pop deferred task (use slot %d), id_task = %d\n", id_slot, it->id);
                queue_tasks.emplace_front(std::move(*it));
                queue_tasks_deferred.erase(it);
                found = true;
                break;
            }
        }
        // if not tasks found using the slot, just pop the first deferred task (default behavior)
        if (!found) {
            QUE_DBG("pop deferred task, id_task = %d\n", queue_tasks_deferred.front().id);
            queue_tasks.emplace_front(std::move(queue_tasks_deferred.front()));
            queue_tasks_deferred.pop_front();
        }
    }
    time_last_task = ggml_time_ms();
    condition_tasks.notify_one();
}

void server_queue::wait_until_no_sleep() {
    std::unique_lock<std::mutex> lock(mutex_tasks);
    if (!sleeping) {
        return;
    } else {
        if (!req_stop_sleeping) {
            QUE_DBG("%s", "requesting to stop sleeping\n");
            req_stop_sleeping = true;
            condition_tasks.notify_one(); // only main thread is waiting on this
        }
        QUE_DBG("%s", "waiting until no sleep\n");
        const uint64_t failures = wake_failures;
        condition_tasks.wait(lock, [&]{
            return !sleeping || !running || wake_failures != failures;
        });
    }
}

bool server_queue::acquire_context(bool wake) {
    std::unique_lock<std::mutex> lock(mutex_tasks);
    if (sleeping) {
        if (!wake) { return false; }
        const uint64_t failures = wake_failures;
        req_stop_sleeping = true;
        condition_tasks.notify_all();
        condition_tasks.wait(lock, [&] { return !sleeping || !running || wake_failures != failures; });
        if (sleeping) { return false; } // stopped, or the reload failed
    }
    if (!running) { return false; }
    ++preparation_readers;
    return true;
}

bool server_queue::wake_failed(std::string & error) {
    std::lock_guard<std::mutex> lock(mutex_tasks);
    if (!running || !sleeping || wake_failures == 0) { return false; }
    error = last_wake_error;
    return true;
}

void server_queue::release_context() {
    std::lock_guard<std::mutex> lock(mutex_tasks);
    --preparation_readers;
    condition_tasks.notify_all();
}

void server_queue::terminate() {
    std::unique_lock<std::mutex> lock(mutex_tasks);
    running = false;
    condition_tasks.notify_all();
}

bool server_queue::process_new_tasks(bool is_yielding) {
    while (true) {
        std::unique_lock<std::mutex> lock(mutex_tasks);
        if (!running) {
            QUE_DBG("%s", "terminate\n");
            return true;
        }
        if (queue_tasks.empty()) {
            return false;
        }
        server_task task = std::move(queue_tasks.front());
        queue_tasks.pop_front();
        lock.unlock();

        QUE_DBG("processing task, id = %d\n", task.id);
        if (!callback_new_task(std::move(task), is_yielding)) {
            // set it aside, do not put it back in the queue, else we offer it again in a loop
            GGML_ASSERT(is_yielding && "a task can only be declined while yielding");
            QUE_DBG("task declined, id = %d\n", task.id);
            lock.lock();
            queue_tasks_unhandled.push_back(std::move(task));
        }
    }
}

void server_queue::worker_loop() {
    while (true) {
        {
            std::unique_lock<std::mutex> lock(mutex_tasks);
            // wait on busy instead of yielding - busy stays set even when the yield already ended
            worker.cv.wait(lock, [&]{
                return worker.stop || worker.busy;
            });
            if (worker.stop) {
                return;
            }
        }

        // process tasks while the yield is active
        while (true) {
            bool terminated = false;
            try {
                // note: do not hold any lock here, the callback may post new tasks
                terminated = process_new_tasks(true);
            } catch (...) {
                std::unique_lock<std::mutex> lock(mutex_tasks);
                worker.exception = std::current_exception();
                break;
            }

            std::unique_lock<std::mutex> lock(mutex_tasks);
            if (terminated || worker.stop || !worker.yielding) {
                break;
            }
            if (!queue_tasks.empty()) {
                continue; // a new task arrived in the meantime
            }
            condition_tasks.wait(lock, [&]{
                return worker.stop || !running || !worker.yielding || !queue_tasks.empty();
            });
        }

        // signal to yield_to_queue() that no more tasks will be processed
        {
            std::unique_lock<std::mutex> lock(mutex_tasks);
            worker.busy = false;
        }
        condition_tasks.notify_all();
    }
}

void server_queue::worker_stop() {
    if (!worker.thread.joinable()) {
        return;
    }
    {
        std::unique_lock<std::mutex> lock(mutex_tasks);
        worker.stop = true;
    }
    worker.cv.notify_one();
    condition_tasks.notify_all();
    worker.thread.join();
}

void server_queue::yield_to_queue(std::function<void()> && work) {
    GGML_ASSERT(worker.thread.joinable() && "yield_to_queue() requires start_loop() to be running");

    QUE_DBG("%s", "yielding to queue\n");

    {
        std::unique_lock<std::mutex> lock(mutex_tasks);
        GGML_ASSERT(!worker.busy && "yield_to_queue() cannot be nested");
        worker.busy     = true;
        worker.yielding = true;
    }
    worker.cv.notify_one();

    // run the work on the current thread, so that all ggml compute stays on the same thread
    std::exception_ptr exception;
    try {
        work();
    } catch (...) {
        exception = std::current_exception();
    }

    {
        std::unique_lock<std::mutex> lock(mutex_tasks);

        // the yield is over, wait for the worker to finish its current task
        worker.yielding = false;
        condition_tasks.notify_all();
        condition_tasks.wait(lock, [&]{
            return !worker.busy;
        });

        // put the declined tasks back, keeping their order
        while (!queue_tasks_unhandled.empty()) {
            queue_tasks.push_front(std::move(queue_tasks_unhandled.back()));
            queue_tasks_unhandled.pop_back();
        }

        // make sure to avoid idle timeout here
        time_last_task = ggml_time_ms();

        // an exception from work() takes precedence over the one from the worker
        if (!exception) {
            std::swap(exception, worker.exception);
        } else {
            worker.exception = nullptr;
        }
    }

    QUE_DBG("%s", "done yielding to queue\n");

    // note: rethrow only after the declined tasks are back in the queue, so they are not lost
    if (exception) {
        std::rethrow_exception(exception);
    }
}

void server_queue::start_loop(int64_t idle_sleep_ms) {
    {
        std::lock_guard<std::mutex> lock(mutex_tasks);
        time_last_task = ggml_time_ms();
    }

    // spawn the worker thread used by yield_to_queue()
    GGML_ASSERT(!worker.thread.joinable() && "start_loop() is already running");
    worker.stop     = false;
    worker.busy     = false;
    worker.yielding = false;
    worker.thread = std::thread([this]() { worker_loop(); });

    constexpr auto max_wait_time = std::chrono::seconds(1);
    auto should_sleep = [&]() -> bool {
        // caller must hold mutex_tasks
        if (idle_sleep_ms < 0 || preparation_readers != 0) {
            return false;
        }
        int64_t now = ggml_time_ms();
        return (now - time_last_task) >= idle_sleep_ms;
    };

    while (true) {
        QUE_DBG("%s", "processing new tasks\n");
        if (process_new_tasks(false)) {
            break; // terminate
        }

        // all tasks in the current loop is processed, slots data is now ready
        QUE_DBG("%s", "update slots\n");

        // this will run the main inference process for all slots
        const int64_t t_update_slots = ggml_time_ms();
        callback_update_slots();
        {
            // update_slots() may take a while to finish, we need to make sure it's not counted as idle
            // shift instead of reset, so that non-task_resets_idle_timer tasks do not delay the sleep
            std::unique_lock<std::mutex> lock(mutex_tasks);
            const int64_t now = ggml_time_ms();
            time_last_task = std::min(now, time_last_task + (now - t_update_slots));
        }

        QUE_DBG("%s", "waiting for new tasks\n");
        while (true) {
            std::unique_lock<std::mutex> lock(mutex_tasks);
            if (!running || !queue_tasks.empty()) {
                break; // go back to process new tasks or terminate
            }

            // no tasks, check for sleeping state
            if (should_sleep()) {
                QUE_INF("%s", "entering sleeping state\n");
                sleeping = true;
                // Call order cb0 -> cb1 -> cb{N}
                for (auto & cb : callback_sleeping_state) {
                    cb(true);
                }
                req_stop_sleeping = false;
                bool woken = false;
                while (!woken) {
                    // wait until we are requested to exit sleeping state
                    condition_tasks.wait(lock, [&]{
                        return (!running || req_stop_sleeping);
                    });
                    if (!running) { // may changed during sleep
                        break;
                    }
                    QUE_INF("%s", "exiting sleeping state\n");
                    req_stop_sleeping = false;
                    try {
                        // Call order cb{N} -> cb1 -> cb0
                        for (size_t i = callback_sleeping_state.size(); i > 0; i--) {
                            callback_sleeping_state[i - 1](false);
                        }
                        woken = true;
                    } catch (const std::exception & e) {
                        // recoverable: stay asleep, report to the waiters, retry on the next request
                        QUE_ERR("failed to exit sleeping state: %s\n", e.what());
                        last_wake_error = e.what();
                        wake_failures++;
                        condition_tasks.notify_all();
                    }
                }
                if (!woken) {
                    break; // terminate
                }
                sleeping = false;
                time_last_task = ggml_time_ms();
                condition_tasks.notify_all(); // notify wait_until_no_sleep()
                break; // process new tasks
            } else {
                // wait for new tasks or timeout for checking sleeping condition
                bool res = condition_tasks.wait_for(lock, max_wait_time, [&]{
                    return (!queue_tasks.empty() || !running);
                });
                if (res) {
                    break; // new task arrived or terminate
                }
                // otherwise, loop again to check sleeping condition
            }
        }
    }

    worker_stop();
}

void server_queue::cleanup_pending_task(int id_target) {
    // no need lock because this is called exclusively by post()
    auto rm_func = [id_target](const server_task & task) {
        return task.id == id_target;
    };
    queue_tasks.erase(
        std::remove_if(queue_tasks.begin(),           queue_tasks.end(),           rm_func),
        queue_tasks.end());
    queue_tasks_deferred.erase(
        std::remove_if(queue_tasks_deferred.begin(),  queue_tasks_deferred.end(),  rm_func),
        queue_tasks_deferred.end());
    // a task declined while yielding is not in queue_tasks yet, but it can still be cancelled
    queue_tasks_unhandled.erase(
        std::remove_if(queue_tasks_unhandled.begin(), queue_tasks_unhandled.end(), rm_func),
        queue_tasks_unhandled.end());
}

//
// server_response
//

void server_response::send(server_task_result_ptr && result) {
    RES_DBG("sending result for task id = %d\n", result->id);

    std::unique_lock<std::mutex> lock(mutex_results);
    auto found = sinks.find(result->id);
    if (found == sinks.end()) {
        return;
    }
    auto sink = found->second;
    // a cancelling sink stays reserved until the decoder acknowledges the cancel
    if ((result->is_stop() || result->is_error()) && !cancelling_sinks.count(result->id)) {
        sinks.erase(found);
    }
    lock.unlock();
    sink(std::move(result));
}

bool server_response::add_sinks(const std::unordered_set<int> & ids, size_t limit, sink_t sink) {
    std::lock_guard<std::mutex> lock(mutex_results);
    if (ids.size() > limit || sinks.size() > limit - ids.size()) { return false; }
    for (int id : ids) { sinks.emplace(id, sink); }
    return true;
}

void server_response::finish_sink(int id) {
    std::lock_guard<std::mutex> lock(mutex_results);
    sinks.erase(id);
    cancelling_sinks.erase(id);
}

void server_response::cancel_sinks(const std::unordered_set<int> & ids, server_queue & tasks) {
    std::lock_guard<std::mutex> lock(mutex_results);
    std::vector<server_task> cancellations;
    for (int id : ids) {
        if (sinks.count(id) && cancelling_sinks.insert(id).second) {
            server_task task(SERVER_TASK_TYPE_CANCEL);
            task.id_target = id;
            cancellations.push_back(std::move(task));
        }
    }
    if (!cancellations.empty()) { tasks.post(std::move(cancellations), true); }
}
