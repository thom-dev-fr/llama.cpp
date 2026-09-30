#pragma once

#include "server-task.h"

#include <condition_variable>
#include <deque>
#include <exception>
#include <mutex>
#include <thread>
#include <vector>
#include <unordered_set>
#include <unordered_map>

// Task queue of one decoder: requests post tasks, the decoder thread runs them.
struct server_queue {
private:
    int id = 0;
    bool running  = true;
    bool sleeping = false;
    bool req_stop_sleeping = false;
    uint64_t wake_failures = 0;   // failed attempts to exit the sleeping state
    std::string last_wake_error;
    size_t preparation_readers = 0;
    int64_t time_last_task = 0;

    // queues
    std::deque<server_task> queue_tasks;
    std::deque<server_task> queue_tasks_deferred;
    // tasks declined while yielding, put back in queue_tasks once the yield is done
    // note: kept as a member so that cleanup_pending_task() can also reach them
    std::deque<server_task> queue_tasks_unhandled;

    std::mutex mutex_tasks;
    std::condition_variable condition_tasks;

    // used by yield_to_queue, all fields are guarded by mutex_tasks
    struct worker_t {
        std::thread             thread;
        std::condition_variable cv;        // the worker sleeps on this until a yield starts
        std::exception_ptr      exception; // exception thrown while processing tasks, if any
        bool stop     = false;
        bool busy     = false; // set by yield_to_queue(), cleared by the worker once it is done processing tasks
        bool yielding = false; // work() is still running on the start_loop() thread
    };
    worker_t worker;

    // callback functions
    std::function<bool(server_task &&, bool)> callback_new_task;
    std::function<void(void)>                 callback_update_slots;
    std::vector<std::function<void(bool)>>    callback_sleeping_state;

public:
    ~server_queue() { worker_stop(); }

    // Add a new task to the end of the queue
    int post(server_task && task, bool front = false);

    // multi-task version of post()
    int post(std::vector<server_task> && tasks, bool front = false);

    // Add a new task, but defer until one slot is available
    void defer(server_task && task);

    // Get the next id for creating a new task
    int get_new_id();

    // Call when the state of one slot is changed, it will move one task from deferred to main queue
    // prioritize tasks that use the specified slot (otherwise, pop the first deferred task)
    void pop_deferred_task(int id_slot);

    // if sleeping, request exiting sleep state and wait until it is done
    // returns immediately if not sleeping, and after a failed attempt
    void wait_until_no_sleep();

    bool is_sleeping() {
        std::unique_lock<std::mutex> lock(mutex_tasks);
        return sleeping;
    }

    // Pin model resources during transport-independent request preparation.
    // Returns false if stopped, or if waking up failed (the queue stays asleep).
    bool acquire_context(bool wake = true);
    void release_context();
    // True, with the error, while asleep after a failed attempt to wake up.
    bool wake_failed(std::string & error);

    // end the start_loop routine
    void terminate();

    /**
     * Main loop consists of these steps:
     * - Wait until a new task arrives
     * - Process the task (i.e. maybe copy data into slot)
     * - Check if multitask is finished
     * - Update all slots
     *
     * Sleeping procedure (disabled if idle_sleep_ms < 0):
     * - If there is no task after idle_sleep_ms, enter sleeping state
     *   note: metrics tasks are processed as usual, but do not reset the idle timer
     * - Call callback_sleeping_state(true)
     * - Wait until req_stop_sleeping is set to true
     * - Call callback_sleeping_state(false)
     * - Exit sleeping state
     */
    void start_loop(int64_t idle_sleep_ms = -1);

    // while waiting for work() to finish, run process_new_tasks on the worker thread
    // returns once work() is done (may throw exceptions)
    // must be called from start_loop() thread (ideally inside callback_update_slots)
    // use case: return metrics while encode/decode is running
    // ref: https://github.com/ggml-org/llama.cpp/pull/27041
    //
    // tasks declined by callback_new_task are put back in the queue once this returns
    void yield_to_queue(std::function<void()> && work);

    // for metrics
    size_t queue_tasks_deferred_size() {
        std::unique_lock<std::mutex> lock(mutex_tasks);
        return queue_tasks_deferred.size();
    }

    //
    // Functions below are not thread-safe, must only be used before start_loop() is called
    //

    // Register function to process a new task
    // the second argument tells whether the queue is currently yielding (see yield_to_queue)
    // only then may the callback return false to decline the task, and it must leave it
    // untouched, so that it can be put back in the queue later
    // note: while yielding, the callback runs on worker thread, not main thread
    void on_new_task(std::function<bool(server_task &&, bool)> callback) {
        callback_new_task = std::move(callback);
    }

    // Register the function to be called when all slots data is ready to be processed
    void on_update_slots(std::function<void(void)> callback) {
        callback_update_slots = std::move(callback);
    }

    // Register callback for sleeping state change; multiple callbacks are allowed
    // for example: register order cb0, cb1, cb2
    // entering sleep: queue.sleeping = true --> cb0(true) --> cb1(true) --> cb2(true)
    // leaving sleep: cb2(false) --> cb1(false) --> cb0(false) --> queue.sleeping = false
    // note: caller will hold mutex_tasks while calling the callbacks
    void on_sleeping_state(std::function<void(bool)> callback) {
        callback_sleeping_state.push_back(std::move(callback));
    }

private:
    void cleanup_pending_task(int id_target);

    // process all pending tasks in the queue
    // returns true if the queue is terminated, false if there is no more task to process
    // while yielding, declined tasks are moved to queue_tasks_unhandled
    bool process_new_tasks(bool is_yielding);

    // for worker_t
    void worker_loop();
    void worker_stop();
};

// Delivery of decoder results to the requests that own the tasks.
struct server_response {
public:
    using sink_t = std::function<void(server_task_result_ptr)>;
private:
    std::unordered_map<int, sink_t> sinks;
    std::unordered_set<int> cancelling_sinks;
    std::mutex mutex_results;

public:
    // Direct bounded engine delivery. Sink registrations are admission leases:
    // released only by decoder completion or acknowledgement of cancellation.
    bool add_sinks(const std::unordered_set<int> & ids, size_t limit, sink_t sink);
    void finish_sink(int id);
    void cancel_sinks(const std::unordered_set<int> & ids, server_queue & tasks);

    // Passes a result to the sink of its task; results of unknown tasks are dropped.
    void send(server_task_result_ptr && result);
};
