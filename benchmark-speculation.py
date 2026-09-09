#!/usr/bin/env python3
"""Bounded, synthetic C1/C4, short/long-context two-turn benchmark.

Run only with normal inference clients paused. Writes JSONL to stdout; never
executes generated code, clears server caches or changes the serving config.
"""
import argparse
import concurrent.futures
import hashlib
import json
import statistics
import time
import urllib.request


def post(base, path, body):
    request = urllib.request.Request(base + path, json.dumps(body).encode(),
                                    {"Content-Type": "application/json"})
    return urllib.request.urlopen(request, timeout=600)


def metrics(base):
    with urllib.request.urlopen(base + "/metrics", timeout=10) as response:
        return {line.split()[0]: float(line.split()[1])
                for line in response.read().decode().splitlines()
                if line and not line.startswith("#") and "{" not in line}


def emit(value):
    print(json.dumps(value, sort_keys=True), flush=True)


def generate(base, model, messages, slot, max_tokens, cache):
    start = time.monotonic()
    first = None
    content = ""
    timings = {}
    usage = {}
    finished = False
    with post(base, "/v1/chat/completions", {
        "model": model, "messages": messages, "stream": True,
        "stream_options": {"include_usage": True}, "temperature": 0,
        "max_tokens": max_tokens, "id_slot": slot, "cache_prompt": cache,
    }) as response:
        for line in response:
            if not line.startswith(b"data: "):
                continue
            data = line[6:].strip()
            if data == b"[DONE]":
                finished = True
                break
            packet = json.loads(data)
            if "error" in packet:
                raise RuntimeError(packet["error"])
            timings = packet.get("timings", timings)
            usage = packet.get("usage") or usage
            for choice in packet.get("choices", []):
                delta = choice.get("delta", {})
                if delta.get("reasoning_content"):
                    raise RuntimeError("Unexpected reasoning output with thinking off")
                fragment = delta.get("content") or ""
                if fragment:
                    first = first or time.monotonic()
                    content += fragment
    if not finished or not content:
        raise RuntimeError("Incomplete or empty stream")
    return content, {"ttft_s": first - start, "wall_s": time.monotonic() - start,
                     "timings": timings, "usage": usage,
                     "output_sha256": hashlib.sha256(content.encode()).hexdigest()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base-url", default="http://127.0.0.1:30000")
    parser.add_argument("--model", default="oxcoder-9b-q5-k-m")
    parser.add_argument("--label", required=True)
    parser.add_argument("--contexts", type=int, nargs="+", default=[4096, 100000])
    parser.add_argument("--concurrency", type=int, nargs="+", default=[1, 4])
    parser.add_argument("--max-tokens", type=int, default=256)
    args = parser.parse_args()
    base = args.base_url.rstrip("/")
    initial = metrics(base)
    for key in ("llamacpp:requests_processing", "llamacpp:requests_deferred"):
        if initial.get(key, 0):
            raise RuntimeError("Normal requests must be paused before benchmarking")
    # Publicly shareable, deterministic, synthetic source context only.
    corpus = "\n".join(
        f"def normalize_{i}(value, lower={i % 97}, upper={1000 + i}):\n"
        f"    # Reject missing input before clamping range {i}.\n"
        "    if value is None: raise ValueError('missing value')\n"
        "    return max(lower, min(upper, int(value)))\n"
        for i in range(5000))
    with post(base, "/tokenize", {"content": corpus}) as response:
        tokens = json.load(response)["tokens"]
    if max(args.contexts) > len(tokens):
        raise ValueError("Synthetic corpus too small for requested context")
    for context in args.contexts:
        with post(base, "/detokenize", {"tokens": tokens[:context]}) as response:
            source = json.load(response)["content"]
        for concurrency in args.concurrency:
            before = metrics(base)
            start = time.monotonic()

            def run(slot):
                messages = [
                    {"role": "system", "content": "You are a Python coding assistant. Return code without reasoning."},
                    {"role": "user", "content": f"Benchmark case {context}/{concurrency}/{slot}.\n"
                     + source + "\nImplement a production-ready Python LRU cache with get, put, "
                     "capacity validation, and unit tests. Do not copy the functions above."},
                ]
                output, cold = generate(base, args.model, messages, slot, args.max_tokens, False)
                messages += [{"role": "assistant", "content": output},
                             {"role": "user", "content": "Add a thread-safe wrapper and tests for eviction and missing keys."}]
                _, warm = generate(base, args.model, messages, slot, args.max_tokens, True)
                row = {"type": "request", "label": args.label, "context": context,
                       "concurrency": concurrency, "slot": slot, "cold": cold, "followup": warm}
                emit(row)
                return row

            with concurrent.futures.ThreadPoolExecutor(max_workers=concurrency) as pool:
                rows = list(pool.map(run, range(concurrency)))
            elapsed = time.monotonic() - start
            after = metrics(base)
            delta = {key: after[key] - before.get(key, 0) for key in after if key.endswith("_total")}
            drafts = delta.get("llamacpp:spec_decode_num_draft_tokens_total", 0)
            accepted = delta.get("llamacpp:spec_decode_num_accepted_tokens_total", 0)
            generated = sum(turn["timings"].get("predicted_n", turn["usage"].get("completion_tokens", 0))
                            for row in rows for turn in (row["cold"], row["followup"]))
            emit({"type": "summary", "label": args.label, "context": context,
                  "concurrency": concurrency, "wall_s": elapsed, "generated_tokens": generated,
                  "end_to_end_tps": generated / elapsed,
                  "cold_ttft_median_s": statistics.median(row["cold"]["ttft_s"] for row in rows),
                  "followup_ttft_median_s": statistics.median(row["followup"]["ttft_s"] for row in rows),
                  "draft_acceptance": accepted / drafts if drafts else None, "counter_deltas": delta})


if __name__ == "__main__":
    main()
