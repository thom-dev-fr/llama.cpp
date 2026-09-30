#ifdef NDEBUG
#undef NDEBUG
#endif
#include "../tools/server/server-context.h"
#include "engine-runtime.h"
#include <cassert>
#include <atomic>

// The real HTTP adapter and request preparation, with a controlled decoder seam:
// a blocked generation must still yield keep-alives, and errors retain the
// before/after-headers distinction. No model-speed assumption or network port.
int main(int argc, char ** argv) {
    assert(argc == 2);
    common_params params;
    params.model.path = argv[1];
    params.n_ctx = 512;
    params.n_parallel = 1;
    params.n_gpu_layers = 0;
    params.cpuparams.n_threads = params.cpuparams_batch.n_threads = 2;
    params.fit_params = false;
    params.warmup = false;
    params.chat_template = "chatml";
    params.sleep_idle_seconds = -1;
    server_context context;
    llama_engine::detail::apply_http_compat_limits(*context.runtime);
    server_routes routes(params, &context);
    assert(context.load_model(params));
    routes.update_meta(context);
    std::atomic<int> task_id {-1};
    std::atomic<bool> fail_before_headers {false};
    context.tasks().on_new_task([&](server_task && task, bool) {
        if (task.type == SERVER_TASK_TYPE_CANCEL) {
            context.responses().finish_sink(task.id_target);
            return true;
        }
        assert(task.type == SERVER_TASK_TYPE_COMPLETION);
        task_id = task.id;
        if (fail_before_headers) {
            auto error = std::make_unique<server_task_result_error>();
            error->id = task.id;
            error->err_type = ERROR_TYPE_INVALID_REQUEST;
            error->err_msg = "controlled failure";
            context.responses().send(std::move(error));
        } else {
            auto begin = std::make_unique<server_task_result_cmpl_partial>();
            begin->id = task.id;
            begin->is_begin = true;
            begin->res_type = task.params.res_type;
            context.responses().send(std::move(begin));
        }
        return true;
    });
    context.tasks().on_update_slots([] {});
    context.start();
    std::function<bool()> connected = [] { return false; };
    server_http_req req {{}, {}, {}, {},
        R"({"messages":[{"role":"user","content":"Hello"}],"stream":true,"sse_ping_interval":1})", {}, connected};
    auto response = routes.post_chat_completions(req);
    assert(response->status == 200 && response->is_stream());
    std::string chunk;
    assert(response->next(chunk) && chunk == ":\n\n");
    auto error = std::make_unique<server_task_result_error>();
    error->id = task_id;
    error->err_msg = "controlled stream failure";
    context.responses().send(std::move(error));
    chunk.clear();
    assert(!response->next(chunk));
    assert(chunk.find("controlled stream failure") != std::string::npos);
    response.reset();

    fail_before_headers = true;
    response = routes.post_chat_completions(req);
    assert(response->status == 400 && !response->is_stream());
    assert(response->data.find("controlled failure") != std::string::npos);
    response.reset();

    fail_before_headers = false;
    response = routes.post_chat_completions(req);
    context.terminate();
    chunk.clear();
    assert(!response->next(chunk));
}
