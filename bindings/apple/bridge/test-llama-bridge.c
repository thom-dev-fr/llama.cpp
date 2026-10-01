// Lifetime tests of the C bridge, from a C consumer.
//
// Infinite generations (context shift, ignore_eos, no token budget) make the
// races deterministic: a reader is always busy or blocked when the other
// thread cancels, unloads or stops.

#undef NDEBUG
#include "llama_bridge.h"

#include <assert.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static char config_json[4096];

static void make_config(const char * model, int parallel) {
    snprintf(config_json, sizeof config_json,
             "{\"max_loaded\":1,\"max_waiting\":4,\"models\":[{\"id\":\"m\",\"settings\":{"
             "\"model_path\":\"%s\",\"context_size\":256,\"parallel\":%d,\"gpu_layers\":0,"
             "\"chat_template\":\"chatml\",\"options\":{\"context-shift\":true}}}]}",
             model, parallel);
}

static const char * CHAT_SHORT =
    "{\"model\":\"m\",\"messages\":[{\"role\":\"user\",\"content\":\"Hello\"}],"
    "\"max_tokens\":8,\"temperature\":0,\"ignore_eos\":true,\"stream\":true}";
static const char * CHAT_ENDLESS =
    "{\"model\":\"m\",\"messages\":[{\"role\":\"user\",\"content\":\"Hello\"}],"
    "\"max_tokens\":-1,\"temperature\":0,\"ignore_eos\":true,\"stream\":true}";

typedef struct {
    llama_bridge_request * request;
    int payloads;
    llama_bridge_event_type end;
    char category[64];
    atomic_int started;
} reader;

// Reads until the terminal event and records it.
static void * read_all(void * arg) {
    reader * r = arg;
    for (;;) {
        llama_bridge_event * event = llama_bridge_request_next(r->request, -1);
        assert(event);
        if (llama_bridge_event_is_terminal(event)) {
            r->end = llama_bridge_event_get_type(event);
            snprintf(r->category, sizeof r->category, "%s", llama_bridge_event_get_category(event));
            llama_bridge_event_free(event);
            return NULL;
        }
        if (llama_bridge_event_get_type(event) == LLAMA_BRIDGE_EVENT_PAYLOAD) {
            r->payloads++;
            atomic_store(&r->started, 1);
        }
        llama_bridge_event_free(event);
    }
}

static llama_bridge_request * submit(llama_bridge_engine * engine, const char * body) {
    llama_bridge_event * error = NULL;
    llama_bridge_request * request = llama_bridge_engine_submit(engine, "chat", body, NULL, 0, &error);
    if (!request) {
        fprintf(stderr, "submit: %s: %s\n", llama_bridge_event_get_category(error), llama_bridge_event_get_message(error));
        llama_bridge_event_free(error);
    }
    assert(request);
    return request;
}

static void wait_started(reader * r) {
    for (int i = 0; i < 3000 && !atomic_load(&r->started); ++i) {
        usleep(1000);
    }
    assert(atomic_load(&r->started));
}

static llama_bridge_engine * create(void) {
    llama_bridge_event * error = NULL;
    llama_bridge_engine * engine = llama_bridge_engine_create(config_json, &error);
    if (!engine) {
        fprintf(stderr, "create: %s\n", llama_bridge_event_get_message(error));
    }
    assert(engine && !error);
    return engine;
}

int main(int argc, char ** argv) {
    assert(argc == 2);
    llama_bridge_event * error = NULL;

    // Invalid inputs come back as owned errors, never as exceptions.
    assert(!llama_bridge_engine_create("{not json", &error));
    assert(error && strcmp(llama_bridge_event_get_category(error), "invalid_request") == 0);
    llama_bridge_event_free(error);
    error = NULL;
    assert(!llama_bridge_engine_create(NULL, &error));
    llama_bridge_event_free(error);
    error = NULL;
    assert(!llama_bridge_engine_create("{\"models\":[{\"settings\":{}}]}", NULL)); // no id, no error out-parameter

    make_config(argv[1], 1);
    llama_bridge_engine * engine = create();

    // Catalog and subscription: nothing loaded yet, a snapshot first.
    char * catalog = llama_bridge_engine_catalog(engine, NULL);
    assert(catalog && strstr(catalog, "\"unloaded\""));
    llama_bridge_string_free(catalog);
    llama_bridge_subscription * subscription = llama_bridge_engine_subscribe(engine, NULL);
    assert(subscription);
    llama_bridge_event * snapshot = llama_bridge_subscription_next(subscription, 5000);
    assert(llama_bridge_event_get_type(snapshot) == LLAMA_BRIDGE_EVENT_PAYLOAD);
    assert(strstr(llama_bridge_event_get_data(snapshot), "snapshot"));
    llama_bridge_event_free(snapshot);

    // Unknown operation, malformed request, invalid attachment.
    assert(!llama_bridge_engine_submit(engine, "nope", "{}", NULL, 0, &error));
    assert(strcmp(llama_bridge_event_get_category(error), "invalid_request") == 0);
    llama_bridge_event_free(error);
    error = NULL;
    assert(!llama_bridge_engine_submit(engine, "chat", "[", NULL, 0, &error));
    llama_bridge_event_free(error);
    error = NULL;
    llama_bridge_attachment broken = {"img", NULL, 4};
    assert(!llama_bridge_engine_submit(engine, "chat", CHAT_SHORT, &broken, 1, &error));
    llama_bridge_event_free(error);
    error = NULL;
    llama_bridge_event * bad_update = llama_bridge_engine_update_catalog(engine, "{");
    assert(llama_bridge_event_get_type(bad_update) == LLAMA_BRIDGE_EVENT_ERROR);
    llama_bridge_event_free(bad_update);

    // A streamed chat loads the model on demand and succeeds.
    reader simple = {submit(engine, CHAT_SHORT)};
    read_all(&simple);
    assert(simple.end == LLAMA_BRIDGE_EVENT_SUCCESS && simple.payloads > 1);
    llama_bridge_request_destroy(simple.request);
    printf("streamed chat: %d payloads\n", simple.payloads);

    // Owned attachment bytes: the caller's buffer may go away after submit.
    {
        uint8_t * bytes = malloc(16);
        memset(bytes, 0, 16);
        llama_bridge_attachment attachment = {"img", bytes, 16};
        const char * body = "{\"model\":\"m\",\"max_tokens\":4,\"messages\":[{\"role\":\"user\",\"content\":["
                            "{\"type\":\"image_url\",\"image_url\":{\"url\":\"attachment:img\"}}]}]}";
        llama_bridge_request * request = llama_bridge_engine_submit(engine, "chat", body, &attachment, 1, &error);
        free(bytes);
        if (request) { // the error (no projector) arrives as the terminal event
            reader r = {request};
            read_all(&r);
            assert(r.end == LLAMA_BRIDGE_EVENT_ERROR);
            llama_bridge_request_destroy(request);
        } else {
            llama_bridge_event_free(error);
            error = NULL;
        }
    }

    // Cancel while another thread reads an endless generation.
    reader endless = {submit(engine, CHAT_ENDLESS)};
    pthread_t thread;
    pthread_create(&thread, NULL, read_all, &endless);
    wait_started(&endless);
    llama_bridge_request_cancel(endless.request);
    pthread_join(thread, NULL);
    assert(endless.end == LLAMA_BRIDGE_EVENT_CANCELLED);
    llama_bridge_event * again = llama_bridge_request_next(endless.request, 0); // same terminal, immediately
    assert(llama_bridge_event_get_type(again) == LLAMA_BRIDGE_EVENT_CANCELLED);
    llama_bridge_event_free(again);
    llama_bridge_request_destroy(endless.request);

    // Cancel a request blocked behind the only slot.
    reader busy = {submit(engine, CHAT_ENDLESS)};
    pthread_t busy_thread;
    pthread_create(&busy_thread, NULL, read_all, &busy);
    wait_started(&busy);
    reader queued = {submit(engine, CHAT_SHORT)};
    llama_bridge_event * waiting = llama_bridge_request_next(queued.request, 100);
    assert(llama_bridge_event_get_type(waiting) == LLAMA_BRIDGE_EVENT_TIMEOUT);
    llama_bridge_event_free(waiting);
    pthread_t queued_thread;
    pthread_create(&queued_thread, NULL, read_all, &queued);
    usleep(50000);
    llama_bridge_request_cancel(queued.request);
    pthread_join(queued_thread, NULL);
    assert(queued.end == LLAMA_BRIDGE_EVENT_CANCELLED && queued.payloads == 0);
    llama_bridge_request_destroy(queued.request);

    // Explicit unload during a generation: the reader ends, the model is freed.
    llama_bridge_event * unloaded = llama_bridge_engine_unload(engine, "m");
    assert(llama_bridge_event_get_type(unloaded) == LLAMA_BRIDGE_EVENT_SUCCESS);
    llama_bridge_event_free(unloaded);
    pthread_join(busy_thread, NULL);
    assert(busy.end == LLAMA_BRIDGE_EVENT_CANCELLED);
    printf("unload during generation: reader ended with %s\n", busy.category);
    llama_bridge_request_destroy(busy.request);
    catalog = llama_bridge_engine_catalog(engine, NULL);
    assert(strstr(catalog, "\"unloaded\""));
    llama_bridge_string_free(catalog);

    // A new request reloads the model.
    reader reload = {submit(engine, CHAT_SHORT)};
    read_all(&reload);
    assert(reload.end == LLAMA_BRIDGE_EVENT_SUCCESS);
    llama_bridge_request_destroy(reload.request);

    // Engine destruction while a reader is busy: the reader wakes, and its
    // handle outlives the engine.
    reader orphan = {submit(engine, CHAT_ENDLESS)};
    pthread_t orphan_thread;
    pthread_create(&orphan_thread, NULL, read_all, &orphan);
    wait_started(&orphan);
    llama_bridge_engine_destroy(engine);
    pthread_join(orphan_thread, NULL);
    assert(orphan.end == LLAMA_BRIDGE_EVENT_CANCELLED);
    printf("engine destroyed during generation: reader ended with %s\n", orphan.category);
    llama_bridge_event * after = llama_bridge_request_next(orphan.request, 0);
    assert(llama_bridge_event_is_terminal(after));
    llama_bridge_event_free(after);
    llama_bridge_request_destroy(orphan.request);
    llama_bridge_event * ended = llama_bridge_subscription_next(subscription, 1000);
    while (!llama_bridge_event_is_terminal(ended)) { // drain status events, then the end
        llama_bridge_event_free(ended);
        ended = llama_bridge_subscription_next(subscription, 1000);
    }
    assert(llama_bridge_event_get_type(ended) == LLAMA_BRIDGE_EVENT_CANCELLED);
    llama_bridge_event_free(ended);
    llama_bridge_subscription_destroy(subscription);

    // Destroying a request that was never read cancels it.
    engine = create();
    llama_bridge_request_destroy(submit(engine, CHAT_ENDLESS));
    llama_bridge_engine_stop(engine);
    llama_bridge_engine_stop(engine); // idempotent
    llama_bridge_request * late = llama_bridge_engine_submit(engine, "chat", CHAT_SHORT, NULL, 0, NULL);
    if (late) { // submitted after stop: explicitly cancelled
        llama_bridge_event * end = llama_bridge_request_next(late, -1);
        assert(llama_bridge_event_get_type(end) == LLAMA_BRIDGE_EVENT_CANCELLED);
        llama_bridge_event_free(end);
        llama_bridge_request_destroy(late);
    }
    llama_bridge_engine_destroy(engine);

    printf("PASS bridge lifetimes: errors, streaming, cancellation, unload and engine destruction\n");
    return 0;
}
