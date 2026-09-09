#!/usr/bin/env python3
"""Expose llama.cpp counters under the vLLM names used by Spark Dashboard."""

from __future__ import annotations

import argparse
import math
import re
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen


SAMPLE_RE = re.compile(
    r"^(?P<name>[a-zA-Z_:][a-zA-Z0-9_:]*)(?:\{[^}]*\})?\s+"
    r"(?P<value>[-+]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][-+]?\d+)?|[-+]?Inf|NaN)"
    r"(?:\s+\d+)?$"
)


def parse_samples(payload: str) -> dict[str, float]:
    """Sum Prometheus samples by name; llama.cpp emits one model per server."""
    totals: dict[str, float] = {}
    for raw_line in payload.splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        match = SAMPLE_RE.match(line)
        if not match:
            continue
        value = float(match.group("value"))
        if math.isfinite(value):
            name = match.group("name")
            totals[name] = totals.get(name, 0.0) + value
    return totals


def prometheus_number(value: float) -> str:
    return str(int(value)) if value.is_integer() else format(value, ".17g")


def translate_metrics(payload: str) -> str:
    source = parse_samples(payload)
    processed = source.get("llamacpp:prompt_tokens_total", 0.0)
    cached = source.get("llamacpp:prompt_tokens_cached_total", 0.0)
    prompt_total = processed + cached

    mappings = [
        (
            "vllm:num_requests_running",
            "Number of requests currently processing.",
            "gauge",
            source.get("llamacpp:requests_processing", 0.0),
        ),
        (
            "vllm:num_requests_waiting",
            "Number of requests currently deferred.",
            "gauge",
            source.get("llamacpp:requests_deferred", 0.0),
        ),
        (
            "vllm:prompt_tokens_total",
            "Total prompt tokens, including tokens served from prompt cache.",
            "counter",
            prompt_total,
        ),
        (
            "vllm:generation_tokens_total",
            "Total generated tokens.",
            "counter",
            source.get("llamacpp:tokens_predicted_total", 0.0),
        ),
        (
            "vllm:prefix_cache_queries_total",
            "Total prompt tokens considered for prefix caching.",
            "counter",
            prompt_total,
        ),
        (
            "vllm:prefix_cache_hits_total",
            "Total prompt tokens served from the llama.cpp prompt cache.",
            "counter",
            cached,
        ),
    ]

    optional = {
        "llamacpp:spec_decode_num_draft_tokens_total": "vllm:spec_decode_num_draft_tokens_total",
        "llamacpp:spec_decode_num_accepted_tokens_total": "vllm:spec_decode_num_accepted_tokens_total",
        "llamacpp:spec_decode_num_drafts_total": "vllm:spec_decode_num_drafts_total",
    }
    if "llamacpp:kv_cache_usage_ratio" in source:
        mappings.append(
            (
                "vllm:kv_cache_usage_perc",
                "Fraction of the KV cache currently in use.",
                "gauge",
                source["llamacpp:kv_cache_usage_ratio"],
            )
        )
    for source_name, target_name in optional.items():
        if source_name in source:
            mappings.append(
                (target_name, f"Translated from {source_name}.", "counter", source[source_name])
            )

    lines = [
        "# llama.cpp metrics translated for dashboards expecting vLLM metric names.",
        "# Raw llama.cpp metrics remain available on the upstream server.",
    ]
    for name, help_text, metric_type, value in mappings:
        lines.extend(
            [
                f"# HELP {name} {help_text}",
                f"# TYPE {name} {metric_type}",
                f"{name} {prometheus_number(value)}",
            ]
        )
    return "\n".join(lines) + "\n"


def fetch(upstream: str, path: str, timeout: float) -> tuple[int, str, bytes]:
    request = Request(f"{upstream.rstrip('/')}{path}", headers={"User-Agent": "oxcoder-metrics-bridge/1"})
    try:
        with urlopen(request, timeout=timeout) as response:
            return response.status, response.headers.get("Content-Type", "application/octet-stream"), response.read()
    except HTTPError as error:
        return error.code, error.headers.get("Content-Type", "text/plain"), error.read()


def make_handler(upstream: str, timeout: float):
    class Handler(BaseHTTPRequestHandler):
        def do_GET(self) -> None:  # noqa: N802
            path = self.path.split("?", 1)[0]
            if path not in {"/metrics", "/health", "/v1/models", "/version"}:
                self.send_error(404, "not found")
                return
            try:
                status, content_type, body = fetch(upstream, path, timeout)
                if path == "/metrics" and status == 200:
                    body = translate_metrics(body.decode("utf-8", errors="replace")).encode()
                    content_type = "text/plain; version=0.0.4; charset=utf-8"
            except (URLError, TimeoutError) as error:
                body = f"upstream unavailable: {error}\n".encode()
                status = 502
                content_type = "text/plain; charset=utf-8"
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, format_string: str, *args: object) -> None:
            sys.stderr.write("metrics-bridge: " + format_string % args + "\n")

    return Handler


def self_test() -> None:
    fixture = """
# TYPE llamacpp:prompt_tokens_total counter
llamacpp:prompt_tokens_total 100
llamacpp:prompt_tokens_cached_total 300
llamacpp:tokens_predicted_total 50
llamacpp:requests_processing 2
llamacpp:requests_deferred 3
llamacpp:kv_cache_usage_ratio 0.25
"""
    result = parse_samples(translate_metrics(fixture))
    expected = {
        "vllm:prompt_tokens_total": 400.0,
        "vllm:prefix_cache_queries_total": 400.0,
        "vllm:prefix_cache_hits_total": 300.0,
        "vllm:generation_tokens_total": 50.0,
        "vllm:num_requests_running": 2.0,
        "vllm:num_requests_waiting": 3.0,
        "vllm:kv_cache_usage_perc": 0.25,
    }
    assert all(result.get(name) == value for name, value in expected.items()), result
    print("metrics bridge self-test passed")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--listen-host", default="127.0.0.1")
    parser.add_argument("--listen-port", type=int, default=30001)
    parser.add_argument("--upstream", default="http://127.0.0.1:30000")
    parser.add_argument("--timeout", type=float, default=5.0)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return
    server = ThreadingHTTPServer(
        (args.listen_host, args.listen_port), make_handler(args.upstream, args.timeout)
    )
    print(
        f"metrics bridge listening on http://{args.listen_host}:{args.listen_port}; "
        f"upstream={args.upstream}",
        flush=True,
    )
    server.serve_forever()


if __name__ == "__main__":
    main()
