#!/usr/bin/env python3
"""Small reproducible HTTP reference for the embedded-engine migration.

Not a throughput benchmark or a correctness suite. Keeps every sample (including
warmup) and measures real timings, never LLAMA_SERVER_DEBUG_FAKE_TIMING. Run on an
otherwise idle host; compare only identical models, parameters and backends.
"""

import argparse
import concurrent.futures
import hashlib
import json
import os
from pathlib import Path
import platform
import resource
import socket
import subprocess
import time
import urllib.error
import urllib.request


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--server", required=True, type=Path)
    parser.add_argument("--model", required=True, type=Path)
    parser.add_argument("--gpu-layers", type=int, default=0)
    parser.add_argument("--threads", type=int, default=2)
    parser.add_argument("--repeats", type=int, default=3)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    if args.repeats < 1 or args.threads < 1:
        parser.error("repeats and threads must be positive")

    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
    base = f"http://127.0.0.1:{port}"
    command = [
        str(args.server.resolve()), "-m", str(args.model.resolve()),
        "--host", "127.0.0.1", "--port", str(port), "--offline", "--no-ui",
        "-ngl", str(args.gpu_layers), "-t", str(args.threads),
        "-tb", str(args.threads), "-c", "1024", "-np", "4", "-b", "128",
        "-ub", "128", "-n", "64", "--fit", "off", "--cache-ram", "0",
    ]
    env = {key: value for key, value in os.environ.items()
           if not key.startswith("LLAMA_ARG_") and key != "LLAMA_SERVER_DEBUG_FAKE_TIMING"}
    body = {
        "prompt": "Once upon a time, in a village beside a forest, a child found",
        "n_predict": 64, "seed": 42, "temperature": 0.0,
        "ignore_eos": True, "cache_prompt": False, "stream": True,
    }

    def completion():
        start = time.perf_counter()
        first = None
        final = None
        request = urllib.request.Request(
            base + "/completion", json.dumps(body).encode(),
            headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(request, timeout=60) as response:
            for line in response:
                if not line.startswith(b"data: "):
                    continue
                event = json.loads(line[6:])
                if "error" in event:
                    raise RuntimeError(event)
                if first is None and (event.get("content") or event.get("tokens")):
                    first = time.perf_counter()
                if event.get("stop"):
                    final = event
        if first is None or final is None or final["timings"]["predicted_n"] != 64:
            raise RuntimeError(f"incomplete generation: {final}")
        return {"first_event_ms": (first - start) * 1000,
                "elapsed_ms": (time.perf_counter() - start) * 1000,
                "timings": final["timings"]}

    args.output.parent.mkdir(parents=True, exist_ok=True)
    samples = []
    with args.output.with_suffix(".server.log").open("w") as log:
        process = subprocess.Popen(command, env=env, stdout=log, stderr=log)
        try:
            deadline = time.monotonic() + 120
            while True:
                if process.poll() is not None:
                    raise RuntimeError(f"server exited: {process.returncode}")
                try:
                    with urllib.request.urlopen(base + "/health", timeout=1) as response:
                        if response.status == 200:
                            break
                except (urllib.error.URLError, TimeoutError):
                    pass
                if time.monotonic() >= deadline:
                    raise TimeoutError("server not ready after 120s")
                time.sleep(0.05)
            warmup = completion()
            for concurrency in (1, 4):
                for repeat in range(args.repeats):
                    start = time.perf_counter()
                    with concurrent.futures.ThreadPoolExecutor(max_workers=concurrency) as pool:
                        results = list(pool.map(lambda _: completion(), range(concurrency)))
                    elapsed = time.perf_counter() - start
                    samples.append({"concurrency": concurrency, "repeat": repeat,
                                    "wall_ms": elapsed * 1000,
                                    "aggregate_tokens_per_second": 64 * concurrency / elapsed,
                                    "requests": results})
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=30)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
                    raise
    if process.returncode != 0:
        raise RuntimeError(f"unclean server shutdown: {process.returncode}")

    with args.model.open("rb") as model:
        model_hash = hashlib.file_digest(model, "sha256").hexdigest()
    peak_rss = resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss
    # macOS reports bytes, Linux reports KiB. This is whole-server peak RSS,
    # not the (as yet uninstrumented) memory occupied by inference event queues.
    if platform.system() != "Darwin":
        peak_rss *= 1024
    report = {"platform": platform.platform(), "command": command,
              "model_sha256": model_hash, "request": body,
              "server_peak_rss_bytes": peak_rss,
              "warmup": warmup, "samples": samples}
    args.output.write_text(json.dumps(report, indent=2) + "\n")
    print(args.output)


if __name__ == "__main__":
    main()
