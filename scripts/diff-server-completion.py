#!/usr/bin/env python3
"""Compare native /completion HTTP responses of two llama-server binaries.

Usage: diff-server-completion.py UPSTREAM_SERVER CANDIDATE_SERVER MODEL.gguf
Status, content type and bodies (JSON field order included) must be identical;
timing and id fields are masked. Not a conformance test for other endpoints.
"""
import json, re, subprocess, sys, time, urllib.request, http.client
UP, NEW, MODEL = sys.argv[1], sys.argv[2], sys.argv[3]
VOLATILE = {"timings","t_prompt_processing","t_token_generation","prompt_ms","predicted_ms",
            "prompt_per_second","predicted_per_second","prompt_per_token_ms","predicted_per_token_ms","created","id","system_fingerprint"}
def norm(v):
    if isinstance(v, list) and v and all(isinstance(x, tuple) for x in v):  # object pairs
        return [(k, "<v>" if k in VOLATILE else norm(x)) for k, x in v]
    if isinstance(v, list): return [norm(x) for x in v]
    return v
def parse(b):
    try: return norm(json.loads(b, object_pairs_hook=lambda p: p))
    except Exception: return b
def start(binary, port):
    p = subprocess.Popen([binary, "-m", MODEL, "--port", str(port), "-np", "2", "-c", "1024", "-ngl", "0", "-t", "2",
                          "--offline", "--no-ui"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for _ in range(120):
        try:
            urllib.request.urlopen(f"http://127.0.0.1:{port}/health", timeout=1); return p
        except Exception: time.sleep(0.25)
    raise RuntimeError("server did not start")
def call(port, path, body):
    c = http.client.HTTPConnection("127.0.0.1", port, timeout=60)
    data = body if isinstance(body, (bytes, str)) else json.dumps(body)
    c.request("POST", path, body=data, headers={"Content-Type": "application/json"})
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
