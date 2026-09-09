# OxCoder-9B Q5_K_M on one DGX Spark

Serve the community
[OxCoder-9B Q5_K_M GGUF](https://huggingface.co/prithivMLmods/OxCoder-9B-GGUF)
on one NVIDIA DGX Spark with a native CUDA llama.cpp build. OxCoder is an
Apache-2.0 coding fine-tune of Qwen3.5-9B with a native 262K context window.

This recipe is adapted from the clean
[NeoHorse DGX Spark recipe](https://github.com/rajivpoddar/NeoHorse-1-9B-DGX-Spark)
and follows NVIDIA's official
[llama.cpp DGX Spark playbook](https://build.nvidia.com/spark/llama-cpp/instructions).
CUDA is compiled for GB10 `sm_121`, model layers are offloaded to the GPU, and
llama-server exposes OpenAI-compatible and Anthropic Messages APIs. Model and
llama.cpp revisions are pinned so upstream changes cannot silently alter the
runtime.

## Defaults

| Setting | Value |
|---|---|
| Checkpoint | `prithivMLmods/OxCoder-9B-GGUF` at pinned revision |
| Quant | `OxCoder-9B.Q5_K_M.gguf` |
| Runtime | Native CUDA llama.cpp at pinned revision |
| Context allocation | 262,144 tokens per slot |
| Concurrent slots | 4 (1,048,576 tokens of shared KV allocation) |
| KV cache | Q8_0 keys and values |
| Thinking | Disabled server-side with `--reasoning off` |
| Raw metrics | llama.cpp Prometheus endpoint on port 30000 |
| HTTP dashboard | Native llama.cpp dashboard on port 8092 |
| Compatibility bridge | Optional vLLM-named endpoint on localhost:30001 |
| API | OpenAI and Anthropic Messages-compatible, port 30000 |

This deployment is text-only: it does not download or load the separate vision
projector published with the GGUF, and it has no MTP draft head. The included
chat template consolidates Claude Code's multiple system blocks into the single
leading system turn expected by Qwen-family templates.

## Install prerequisites

The DGX Spark needs `git`, `clang`, `cmake`, the CUDA toolkit, the Hugging Face
CLI, `curl`, Python 3, and development packages required by llama.cpp:

```bash
sudo apt update
sudo apt install -y git clang cmake libcurl4-openssl-dev libssl-dev python3
python3 -m pip install --user -U huggingface_hub
```

## Stage without touching the live service

```bash
DOWNLOAD_ONLY=1 ./start.sh
```

This downloads only the pinned Q5_K_M artifact. It does not bind port 30000,
stop another backend, or change any Claude slot.

To download the model and compile the pinned CUDA runtime without starting a
server:

```bash
BUILD_ONLY=1 ./start.sh
```

## Start and validate

During an approved maintenance window, stop the existing inference backend and
confirm ports 30000 and 8092 are free. Then run:

```bash
./start.sh
./smoke-test.sh
```

`start.sh` builds the pinned llama.cpp revision using NVIDIA's GB10 CUDA flags,
starts a managed background process, waits for `/health`, then starts a pinned
copy of LLM Serve Dashboard. It refuses occupied ports, dirty dependency
checkouts, a live recorded process, or less than 32 GiB of available memory.

Useful inspection commands:

```bash
curl -fsS http://127.0.0.1:30000/v1/models
curl -fsS http://127.0.0.1:30000/metrics | grep '^llamacpp:' | head
curl -fsS http://127.0.0.1:8092/metrics | python3 -m json.tool | head
tail -f ~/.local/state/oxcoder-9b-gguf/server.log
```

Stop only the processes managed by this recipe:

```bash
./stop.sh
```

## HTTP metrics dashboard

llama.cpp already exports native Prometheus metrics when launched with
`--metrics`; Prometheus and Grafana are not required. The recipe downloads a
pinned revision of
[LLM Serve Dashboard](https://github.com/Forge-the-Kingdom/llm-serve-dashboard),
starts it with the model, and points it directly at llama-server port 30000.
It displays GPU status, prompt/decode throughput, request pressure, context,
model details, and host/network information.

The dashboard listens on the LAN by default so it can be opened from another
machine:

```text
http://<spark-ip>:8092/
```

Its JSON feed is at `/metrics`. It is unauthenticated and includes host and LAN
telemetry, so do not expose port 8092 beyond the trusted local network. Override
the bind address or disable it when necessary:

```bash
DASHBOARD_BIND=127.0.0.1 ./start.sh
ENABLE_DASHBOARD=false ./start.sh
```

## Existing Spark Dashboard compatibility

The included stdlib-only `metrics-bridge.py` translates the subset consumed by
the existing vLLM-oriented Spark Dashboard into its expected metric names and
proxies `/health` and `/v1/models`. It is off by default now that the native
dashboard is integrated. Enable it with:

```bash
ENABLE_METRICS_BRIDGE=true ./start.sh
```

Then point Spark Dashboard at `http://127.0.0.1:30001`. The bridge reports
running and waiting requests, prompt and generation token counters, and
prompt-cache hit/query counters. Prefix cache queries are all prompt tokens and
hits are llama.cpp cached prompt tokens.

This is a compatibility layer, not a claim that llama.cpp is vLLM. It cannot
invent metrics llama.cpp does not export, including current KV-cache occupancy,
or vLLM-only histograms such as TTFT, inter-token latency, preemption, and swap
counters; dashboard panels requiring those metrics remain unavailable.
The raw llama.cpp endpoint remains the source of truth.

## Why llama.cpp instead of loading the GGUF in vLLM?

vLLM can load a single-file GGUF (including the `repo:quant` shorthand), but
its documentation describes GGUF support as highly experimental,
under-optimized, and potentially incompatible with other features. This recipe
therefore uses the mature GGUF path in llama.cpp. Use a native safetensors or
supported quantized checkpoint when evaluating OxCoder under vLLM rather than
using GGUF as the production path.

## Context and concurrency

The pinned llama.cpp runtime exposes `--kv-unified-per-slot`, so the recipe
allocates the context limit explicitly instead of relying on implicit division.
The default `CONTEXT_PER_SLOT=262144 PARALLEL=4` requests a 1,048,576-token
shared KV pool: four independent native-context slots. This is the inherited
starting configuration and must be validated on the actual OxCoder quant before
cutover; reduce `PARALLEL`, context, or KV precision if memory headroom is
insufficient.

For a smaller single-slot validation:

```bash
CONTEXT_PER_SLOT=262144 PARALLEL=1 PORT=30002 \
DASHBOARD_PORT=8093 ./start.sh
```

## Claude Code routing

The pinned llama-server exposes both OpenAI-compatible endpoints and native
Anthropic Messages at `/v1/messages`. Claude Code can connect directly to:

```text
http://127.0.0.1:30000
```

Before moving a real slot, validate non-streaming output, streaming, tool calls,
tool results, and Claude's multi-system request shape. The included smoke test
checks both API families and the metrics bridge.

All operational settings are environment-variable overrides. The recipe never
stops an unrelated server or restarts Claude slots.

## License

The recipe is MIT licensed. OxCoder weights are distributed separately under
Apache 2.0. llama.cpp and LLM Serve Dashboard are distributed under their own
MIT licenses.
