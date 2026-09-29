#!/usr/bin/env python3
"""Compare native /completion HTTP responses of two llama-server binaries.

Usage: diff-server-completion.py UPSTREAM_SERVER CANDIDATE_SERVER MODEL.gguf
Status, content type and bodies (JSON field order included) must be identical;
timing and id fields are masked. Optional fourth argument selects a P3 profile:
contracts, infill, embeddings, or rerank (use the corresponding GGUF).
"""
import json, re, subprocess, sys, time, urllib.request, http.client
UP, NEW, MODEL = sys.argv[1], sys.argv[2], sys.argv[3]
PROFILE = sys.argv[4] if len(sys.argv) > 4 else "native"
VOLATILE = {"timings","t_prompt_processing","t_token_generation","prompt_ms","predicted_ms",
            "prompt_per_second","predicted_per_second","prompt_per_token_ms","predicted_per_token_ms","created","created_at","id","item_id","response_id","system_fingerprint","build_info"}
def norm(v):
    if isinstance(v, list) and v and all(isinstance(x, tuple) for x in v):  # object pairs
        return [(k, "<v>" if k in VOLATILE else norm(x)) for k, x in v]
    if isinstance(v, list): return [norm(x) for x in v]
    return v
def parse(b):
    try: return norm(json.loads(b, object_pairs_hook=lambda p: p))
    except Exception: return b
def start(binary, port):
    extra = ["--jinja", "--chat-template", "chatml"]
    if PROFILE == "embeddings": extra += ["--embeddings", "--pooling", "last", "-b", "512", "-ub", "512"]
    if PROFILE == "rerank": extra += ["--reranking", "-b", "512", "-ub", "512"]
    p = subprocess.Popen([binary, "-m", MODEL, "--port", str(port), "-np", "2", "-c", "1024", "-ngl", "0", "-t", "2",
                          "--offline", "--no-ui"] + extra, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for _ in range(120):
        try:
            urllib.request.urlopen(f"http://127.0.0.1:{port}/health", timeout=1); return p
        except Exception: time.sleep(0.25)
    raise RuntimeError("server did not start")
def call(port, path, body):
    c = http.client.HTTPConnection("127.0.0.1", port, timeout=60)
    data = body if isinstance(body, (bytes, str)) else json.dumps(body)
    method = "POST"
    if path.startswith("GET "):
        method, path = path.split(" ", 1)
    c.request(method, path, body=data, headers={"Content-Type": "application/json"})
    r = c.getresponse(); raw = r.read(); ct = r.getheader("Content-Type")
    if ct and "event-stream" in ct:
        events = [parse(l[6:]) if l.startswith(b"data: ") else l for l in raw.split(b"\n") if l]
        return r.status, ct, events
    return r.status, ct, parse(raw)
base = {"prompt": "Once upon a time", "n_predict": 12, "temperature": 0, "seed": 42, "cache_prompt": False}
cases = [
    ("/completion", base),
    ("/completions", base),
    ("/completion", {**base, "stream": True}),
    ("/completion", {**base, "stream": True, "return_progress": True, "return_tokens": True}),
    ("/completion", {**base, "prompt": ["Once", "Twice"]}),
    ("/completion", {**base, "prompt": ["Once", "Twice"], "stream": True}),
    ("/completion", {**base, "n": 2}),
    ("/completion", {**base, "n": 2, "stream": True}),
    ("/completion", {**base, "prompt": [1, 2, 3, "Once"]}),
    ("/completion", {**base, "n_probs": 3}),
    ("/completion", {**base, "n_probs": 3, "stream": True, "post_sampling_probs": True}),
    ("/completion", {**base, "stop": ["the"], "n_predict": 40}),
    ("/completion", {**base, "response_fields": ["content", "generation_settings/n_predict"]}),
    ("/completion", {**base, "ignore_eos": True, "n_predict": 64}),
    ("/completion", {**base, "id_slot": 1}),
    ("/completion", {**base, "id_slot": 7}),
    ("/completion", {**base, "grammar": "root ::= \"yes\" | \"no\""}),
    ("/completion", {**base, "json_schema": {"type": "object", "properties": {"a": {"type": "integer"}}}}),
    ("/completion", {**base, "stream": "yes"}),
    ("/completion", {**base, "n_predict": "many"}),
    ("/completion", {**base, "sse_ping_interval": "x", "stream": True}),
    ("/completion", {**base, "n": 1000000}),
    ("/completion", {"n_predict": 4}),
    ("/completion", {**base, "prompt": []}),
    ("/completion", {**base, "prompt": ""}),
    ("/completion", {**base, "prompt": {"bad": 1}}),
    ("/completion", {**base, "multimodal_data": ["aGVsbG8="], "prompt": "x"}),
    ("/completion", b"{bad"),
    ("/completion", b"[1,2]"),
    ("/completion", {**base, "lora": [{"id": 0, "scale": 1}]}),
    ("/completion", {**base, "stream": True, "n_predict": 0}),
    ("/completion", {**base, "n_predict": -1, "n_ctx_limit": 1, "ignore_eos": True, "stream": True, "t_max_predict_ms": 5}),
]
if PROFILE == "contracts":
    chat = {"messages": [{"role": "user", "content": "Hello"}], "max_tokens": 8,
            "temperature": 0, "seed": 42, "cache_prompt": False}
    resp = {"input": "Hello", "max_output_tokens": 8, "temperature": 0, "seed": 42, "cache_prompt": False}
    for path, body in [("/v1/completions", base), ("/v1/chat/completions", chat),
                       ("/v1/responses", resp), ("/v1/messages", chat)]:
        cases += [(path, body), (path, {**body, "stream": True}),
                  (path, {**body, "stream": "wrong"}), (path, {}), (path, [])]
    cases += [("/v1/completions", {**base, "n": 2}),
              ("/v1/chat/completions", {**chat, "n": 2}),
              ("/v1/chat/completions", {**chat, "response_format": {"type": "json_schema", "json_schema": {"schema": {"type": "boolean"}}}, "max_tokens": 32}),
              ("/v1/chat/completions", {**chat, "messages": [{"role": "user", "content": [{"type": "image_url", "image_url": {"url": "bad"}}]}]})]
    for path, body in [("/tokenize", {"content": "Once", "with_pieces": True}),
                       ("/detokenize", {"tokens": [1, 2, 3]}), ("/apply-template", chat),
                       ("/v1/chat/completions/input_tokens", chat), ("/v1/responses/input_tokens", resp),
                       ("/v1/messages/count_tokens", chat), ("/lora-adapters", []),
                       ("/v1/chat/completions/control", {"id": "absent", "action": "reasoning_end"})]:
        cases += [(path, body), (path, {}), (path, [])]
    cases += [(path, b"{bad") for path in ["/embeddings", "/v1/embeddings", "/rerank", "/infill", "/v1/audio/transcriptions"]]
    cases += [("GET " + path, {}) for path in ["/props", "/models", "/v1/models", "/lora-adapters"]]
elif PROFILE == "infill":
    body = {"input_prefix": "One", "input_suffix": "time", "n_predict": 8, "temperature": 0, "seed": 42}
    cases = [("/infill", body), ("/infill", {**body, "stream": True}),
             ("/infill", {**body, "input_extra": [{"filename": "x", "text": "hello"}]}),
             ("/infill", {}), ("/infill", {**body, "prompt": 123}), ("/infill", {**body, "input_extra": [{}]})]
elif PROFILE == "embeddings":
    cases = [(path, body) for path in ["/embeddings", "/v1/embeddings"] for body in [
        {"input": "Hello"}, {"input": ["Hello", "World"]}, {"input": "Hello", "encoding_format": "base64"},
        {"content": "Hello"}, {}, {"input": []}, {"input": ""}, {"input": "x", "encoding_format": "wrong"}]]
elif PROFILE == "rerank":
    cases = [("/rerank", body) for body in [
        {"query": "hello", "documents": ["world", "hello"]},
        {"query": "hello", "texts": ["world", "hello"]},
        {"query": "hello", "documents": ["world", "hello"], "top_n": 1},
        {}, {"query": 5, "documents": ["a"]}, {"query": "x", "documents": []}]]
up, new = start(UP, 18201), start(NEW, 18202)
fails = 0
try:
    for path, body in cases:
        a, b = call(18201, path, body), call(18202, path, body)
        same = a == b
        # t_max_predict_ms is time dependent: compare status/type only
        if not same and isinstance(body, dict) and "t_max_predict_ms" in body: same = a[:2] == b[:2]
        if not same:
            fails += 1
            print("DIFF", path, str(body)[:100]); print("  upstream:", str(a)[:600]); print("  engine:  ", str(b)[:600])
        else:
            print("same", a[0], path, str(body)[:80])
finally:
    up.terminate(); new.terminate(); up.wait(); new.wait()
print(f"{len(cases)-fails}/{len(cases)} identical")
sys.exit(1 if fails else 0)
