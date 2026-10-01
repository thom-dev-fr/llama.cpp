#ifdef NDEBUG
#undef NDEBUG
#endif
#include "llama-engine.h"
#include <cassert>
#include <chrono>
#include <fstream>
#include <iostream>
#include <iterator>
#include <string>

// Context signals of embedded consumers (fail_on_context_full, return_context):
// the three stop reasons, per-request context reports of interleaved requests,
// reasoning token counts, and the unchanged behaviour without these fields.

using namespace llama_engine;
using namespace std::chrono_literals;

static json chat(const std::string & text, int max_tokens) {
    return {{"messages", {{{"role", "user"}, {"content", text}}}},
            {"max_tokens", max_tokens}, {"temperature", 0}, {"ignore_eos", true}};
}

struct outcome {
    event end;
    json last_context;          // last "context" object seen
    std::string finish_reason;  // last non-null finish_reason
    int payloads = 0;
    int contexts = 0;
    bool monotonic = true;      // n_decoded never decreases between reports
    int prompt_tokens = -1;     // n_prompt_tokens, constant over the request
};

static void observe(outcome & out, const json & chunk) {
    if (!chunk.is_object()) { return; }
    if (chunk.contains("choices")) {
        for (const auto & choice : chunk["choices"]) {
            if (choice.contains("finish_reason") && !choice["finish_reason"].is_null()) {
                out.finish_reason = choice["finish_reason"].get<std::string>();
            }
        }
    }
    if (chunk.contains("context")) {
        const auto & ctx = chunk["context"];
        if (out.contexts > 0 && ctx["n_decoded"].get<int>() < out.last_context["n_decoded"].get<int>()) {
            out.monotonic = false;
        }
        if (out.prompt_tokens < 0) { out.prompt_tokens = ctx["n_prompt_tokens"].get<int>(); }
        assert(out.prompt_tokens == ctx["n_prompt_tokens"].get<int>());
        out.last_context = ctx;
        ++out.contexts;
    }
}

static bool step(request & req, outcome & out) {
    auto item = req.next_for(30s);
    assert(item.type != event_type::timeout);
    if (item.terminal()) {
        out.end = item;
        return false;
    }
    ++out.payloads;
    const auto chunks = item.data.is_array() ? item.data : json::array({item.data});
    for (const auto & chunk : chunks) { observe(out, chunk); }
    return true;
}

static outcome run(engine & owner, json body) {
    outcome out;
    auto req = owner.submit(operation::chat, body);
    if (body.value("stream", false)) {
        while (step(*req, out)) {}
    } else {
        out.end = req->result();
        if (out.end.type == event_type::success) { observe(out, out.end.data); }
    }
    return out;
}

static std::string long_text(int words) {
    std::string text;
    for (int i = 0; i < words; ++i) { text += "once upon a time "; }
    return text;
}

int main(int argc, char ** argv) {
    assert(argc == 3);
    std::ifstream input(argv[2]);
    assert(input);
    const std::string thinking_template(std::istreambuf_iterator<char>(input), {});

    config settings;
    settings.model_path = argv[1];
    settings.context_size = 512;
    settings.parallel = 2;
    settings.chat_template = "chatml";
    event error;
    auto owner = engine::create(settings, error);
    assert(owner);

    // 1. Output budget: success with finish_reason "length", context reported.
    auto body = chat("Hello", 8);
    body["stream"] = true;
    body["fail_on_context_full"] = true;
    body["return_context"] = true;
    auto budget = run(*owner, body);
    assert(budget.end.type == event_type::success);
    assert(budget.finish_reason == "length");
    assert(budget.contexts > 1 && budget.monotonic);
    const int n_ctx = budget.last_context["n_ctx"].get<int>();
    assert(n_ctx > 0 && n_ctx <= 512);
    assert(budget.last_context["n_decoded"] == 8);
    assert(budget.last_context["n_tokens"].get<int>() == budget.prompt_tokens + 8);
    assert(budget.last_context["n_reasoning_tokens"] == 0); // chatml has no reasoning tags
    std::cout << "slot context: " << n_ctx << " tokens, prompt: " << budget.prompt_tokens << " tokens\n";

    // Non-streamed: the same report on the final object.
    body["stream"] = false;
    auto whole = run(*owner, body);
    assert(whole.end.type == event_type::success);
    assert(whole.end.data["choices"][0]["finish_reason"] == "length");
    assert(whole.last_context["n_decoded"] == 8 && whole.last_context["n_ctx"] == n_ctx);

    // 2. Context full during generation: an explicit error after the streamed tokens.
    body = chat("Hello", 4 * n_ctx); // budget larger than the context
    body["stream"] = true;
    body["fail_on_context_full"] = true;
    body["return_context"] = true;
    auto full = run(*owner, body);
    assert(full.end.type == event_type::error);
    assert(full.end.category == "context_exceeded");
    assert(full.end.data["type"] == "exceed_context_size_error");
    assert(full.end.data["context_phase"] == "generation");
    assert(full.end.data["n_ctx"] == n_ctx);
    const int decoded = full.end.data["n_decoded"].get<int>();
    assert(decoded > 0 && full.end.data["n_prompt_tokens"].get<int>() + decoded + 1 >= n_ctx);
    assert(full.contexts > 0 && full.last_context["n_decoded"] == decoded);
    assert(full.finish_reason.empty()); // never reported as a successful "length" stop
    std::cout << "context full after " << decoded << " generated tokens: " << full.end.message << '\n';

    body["stream"] = false;
    auto full_whole = run(*owner, body);
    assert(full_whole.end.type == event_type::error && full_whole.end.data["context_phase"] == "generation");

    // Unchanged without the field: a "length" stop, no context report.
    body = chat("Hello", 4 * n_ctx);
    auto legacy = run(*owner, body);
    assert(legacy.end.type == event_type::success);
    assert(legacy.end.data["choices"][0]["finish_reason"] == "length");
    assert(!legacy.end.data.contains("context"));

    // 3. Prompt larger than the context: phase "prompt" only when asked.
    body = chat(long_text(n_ctx), 8);
    body["fail_on_context_full"] = true;
    auto too_long = run(*owner, body);
    assert(too_long.end.type == event_type::error && too_long.end.category == "context_exceeded");
    assert(too_long.end.data["context_phase"] == "prompt");
    assert(too_long.end.data["n_prompt_tokens"].get<int>() >= n_ctx);
    body.erase("fail_on_context_full");
    auto too_long_legacy = run(*owner, body);
    assert(too_long_legacy.end.type == event_type::error && too_long_legacy.end.category == "context_exceeded");
    assert(!too_long_legacy.end.data.contains("context_phase"));

    // 4. Two interleaved requests: each report belongs to its own request.
    auto short_body = chat("Hi", 6);
    auto long_body = chat("Tell me a long story about a little dog and a cat", 20);
    for (auto * b : {&short_body, &long_body}) {
        (*b)["stream"] = true;
        (*b)["return_context"] = true;
        (*b)["fail_on_context_full"] = true;
    }
    auto first = owner->submit(operation::chat, short_body);
    auto second = owner->submit(operation::chat, long_body);
    outcome a, b;
    bool a_open = true, b_open = true;
    while (a_open || b_open) { // alternate the readers
        if (a_open) { a_open = step(*first, a); }
        if (b_open) { b_open = step(*second, b); }
    }
    assert(a.end.type == event_type::success && b.end.type == event_type::success);
    assert(a.monotonic && b.monotonic);
    assert(a.last_context["n_decoded"] == 6 && b.last_context["n_decoded"] == 20);
    assert(a.prompt_tokens > 0 && b.prompt_tokens > a.prompt_tokens);
    assert(a.last_context["n_tokens"].get<int>() == a.prompt_tokens + 6);
    assert(b.last_context["n_tokens"].get<int>() == b.prompt_tokens + 20);

    // 5. A context shift never applies to a request that asked for context errors.
    owner->stop();
    config shifting = settings;
    shifting.options["context-shift"] = "true";
    auto shifter = engine::create(shifting, error);
    assert(shifter);
    body = chat("Hello", n_ctx + 16);
    auto shifted = run(*shifter, body);
    assert(shifted.end.type == event_type::success); // shifted, as before
    body["fail_on_context_full"] = true;
    auto refused = run(*shifter, body);
    assert(refused.end.type == event_type::error && refused.end.data["context_phase"] == "generation");
    shifter->stop();

    // 6. Reasoning tokens follow the template's tags, including a reasoning
    // opened by the generation prompt.
    config thinking = settings;
    thinking.chat_template = thinking_template;
    auto reasoner = engine::create(thinking, error);
    assert(reasoner);
    body = chat("Hello", 12);
    body["stream"] = true;
    body["return_context"] = true;
    body["chat_template_kwargs"] = {{"enable_thinking", true}};
    auto reasoning = run(*reasoner, body);
    assert(reasoning.end.type == event_type::success);
    const int n_reasoning = reasoning.last_context["n_reasoning_tokens"].get<int>();
    std::cout << "reasoning tokens with thinking: " << n_reasoning << "/12\n";
    assert(n_reasoning == 12); // the model never closes the opened reasoning
    body["chat_template_kwargs"] = {{"enable_thinking", false}};
    auto plain = run(*reasoner, body);
    assert(plain.end.type == event_type::success);
    assert(plain.last_context["n_reasoning_tokens"] == 0);
    reasoner->stop();

    std::cout << "PASS context stop reasons, per-request context reports and reasoning counts\n";
}
