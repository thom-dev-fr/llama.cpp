#include "server-process.h"
#include "ggml.h"
#include "log.h"

#include <algorithm>
#include <chrono>
#include <cstring>
#include <limits>
#include <thread>

#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#ifndef NOMINMAX
#   define NOMINMAX
#endif
#include <windows.h>
#include <io.h>
#else
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <unistd.h>
#endif

bool server_subproc::has_output() {
    if (out_handle >= 0) {
        return true;
    }
    FILE * f = sproc.stdout_file(); // combined stdout/stderr
    if (!f) {
        return false;
    }
#ifdef _WIN32
    HANDLE h = (HANDLE) _get_osfhandle(_fileno(f));
    if (h != INVALID_HANDLE_VALUE) {
        out_handle = (intptr_t) h;
    }
#else
    int fd = fileno(f);
    if (fd >= 0) {
        fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK);
        out_handle = fd;
    }
#endif
    return out_handle >= 0;
}

int server_subproc::read_output(char * buf, size_t len) {
    if (!has_output()) {
        return -1;
    }
#ifdef _WIN32
    HANDLE h     = (HANDLE) out_handle;
    DWORD  avail = 0;
    if (!PeekNamedPipe(h, NULL, 0, NULL, &avail, NULL)) {
        return -1; // pipe broken, child gone
    }
    if (avail == 0) {
        return 0;
    }
    DWORD to_read = avail < (DWORD) len ? avail : (DWORD) len;
    DWORD got     = 0;
    if (!ReadFile(h, buf, to_read, &got, NULL) || got == 0) {
        return -1;
    }
    return (int) got;
#else
    while (true) {
        ssize_t r = read((int) out_handle, buf, len);
        if (r > 0) {
            return (int) r;
        }
        if (r == 0) {
            return -1; // EOF
        }
        if (errno == EINTR) {
            continue;
        }
        if (errno == EAGAIN || errno == EWOULDBLOCK) {
            return 0;
        }
        return -1;
    }
#endif
}

server_subproc::waiter::waiter() {
#ifndef _WIN32
    int fds[2];
    GGML_ASSERT(pipe(fds) == 0);
    for (int fd : fds) {
        fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK);
    }
    wake_fd[0] = fds[0];
    wake_fd[1] = fds[1];
#endif
}

server_subproc::waiter::~waiter() {
#ifndef _WIN32
    close((int) wake_fd[0]);
    close((int) wake_fd[1]);
#endif
}

void server_subproc::waiter::wake() {
#ifndef _WIN32
    char c = 1;
    (void) !write((int) wake_fd[1], &c, 1);
#endif
}

void server_subproc::waiter::wait(const std::vector<server_subproc *> & procs, std::vector<bool> & ready, int64_t timeout_ms) {
    ready.assign(procs.size(), false);
#ifdef _WIN32
    // no waitable wait exists for anonymous pipes, so poll them in 50 ms steps
    bool any = false;
    for (size_t i = 0; i < procs.size(); i++) {
        DWORD avail = 0;
        if (!procs[i]->has_output() || !PeekNamedPipe((HANDLE) procs[i]->out_handle, NULL, 0, NULL, &avail, NULL) || avail > 0) {
            ready[i] = true; // data or broken pipe, read_output() tells which
            any = true;
        }
    }
    if (!any) {
        int64_t step = timeout_ms < 0 ? 50 : std::min<int64_t>(timeout_ms, 50);
        std::this_thread::sleep_for(std::chrono::milliseconds(step));
    }
#else
    std::vector<pollfd> pfds;
    pfds.reserve(procs.size() + 1);
    pfds.push_back({ (int) wake_fd[0], POLLIN, 0 });
    for (auto * p : procs) {
        pfds.push_back({ p->has_output() ? (int) p->out_handle : -1, POLLIN, 0 }); // poll() skips negative fds
    }
    int timeout = timeout_ms < 0 ? -1 : (int) std::min<int64_t>(timeout_ms, std::numeric_limits<int>::max());
    int r = poll(pfds.data(), pfds.size(), timeout);
    if (r < 0 && errno != EINTR) {
        LOG_ERR("%s: poll() failed: %s\n", __func__, strerror(errno));
    }
    if (pfds[0].revents) {
        char buf[64];
        while (read((int) wake_fd[0], buf, sizeof(buf)) > 0) {}
    }
    for (size_t i = 0; i < procs.size(); i++) {
        ready[i] = pfds[i + 1].fd < 0 || pfds[i + 1].revents != 0;
    }
#endif
}
