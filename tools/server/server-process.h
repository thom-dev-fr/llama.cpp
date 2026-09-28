#pragma once

#include "subproc.h"

#include <cstdint>

// Temporary child-process adapter for the legacy router. Removed in P6/P8,
// never linked by the inference engine.
struct server_subproc {
    common_subproc sproc;
    std::atomic<bool> stopped{false}; // set by the monitor once the process exited and was reaped

    bool is_alive() { return sproc.alive(); }
    void terminate() { sproc.terminate(); }
    int  join() { return sproc.join(); }

    // true if the child's combined stdout/stderr pipe is available (call after create())
    bool has_output();

    // non-blocking read
    // returns the number of bytes read, 0 when nothing is available, -1 when the pipe is closed or broken
    int read_output(char * buf, size_t len);

    // wait until one of a set of children has output, wake() is called, or a timeout passes
    struct waiter {
        waiter();
        ~waiter();

        // thread-safe; on Windows this is a no-op, wait() returns within 50 ms anyway
        void wake();

        // timeout_ms < 0 waits until data or wake(); ready[i] is set for each child with data (or a broken pipe)
        void wait(const std::vector<server_subproc *> & procs, std::vector<bool> & ready, int64_t timeout_ms);

    private:
#ifndef _WIN32
        intptr_t wake_fd[2] = { -1, -1 }; // POSIX self-pipe
#endif
    };

private:
    intptr_t out_handle = -1; // fd on POSIX, HANDLE on Windows; taken lazily from sproc
};
