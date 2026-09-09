# NeoHorse-1-9B Q5_K_M on one DGX Spark

Serve TokenRhythm's official
[NeoHorse-1-9B Q5_K_M GGUF](https://huggingface.co/TokenRhythm/NeoHorse-1-9B-GGUF)
on one NVIDIA DGX Spark with a native CUDA llama.cpp build.

This recipe follows NVIDIA's official
[llama.cpp DGX Spark playbook](https://build.nvidia.com/spark/llama-cpp/instructions):
CUDA is compiled for GB10 `sm_121`, model layers are offloaded to the GPU, and
llama-server exposes an OpenAI-compatible API. The NeoHorse checkpoint and
llama.cpp source revisions are pinned so a later upstream update cannot silently
change the runtime.

## Defaults

| Setting | Value |
|---|---|
| Checkpoint | `TokenRhythm/NeoHorse-1-9B-GGUF` |
| Quant | Official `Q5_K_M`, 6.47 GB |
| Runtime | Native CUDA llama.cpp, pinned revision |
| Context allocation | 262,144 tokens per slot |
| Concurrent slots | 4 (1,048,576 tokens of shared KV allocation) |
| KV cache | Q8_0 keys and values |
| Thinking | Disabled server-side with `--reasoning off` |
| Metrics | llama.cpp Prometheus endpoint at `/metrics` |
| API | OpenAI and Anthropic Messages-compatible, port 30000 |

The GGUF is text-only and has no MTP draft head. The recipe supplies a
Claude-compatible variant of TokenRhythm's chat template that consolidates
Claude Code's multiple system blocks into the single leading system turn the
model expects. TokenRhythm reports short compatibility checks for thinking,
tool calls, parallel tool calls, and tool-result continuation; it does not
report a separate quantized quality benchmark.

## Install prerequisites

The DGX Spark needs `git`, `clang`, `cmake`, the CUDA toolkit, the Hugging Face
CLI, `curl`, and development packages required by llama.cpp. NVIDIA's base
command is:

```bash
sudo apt update
sudo apt install -y git clang cmake libcurl4-openssl-dev libssl-dev
```

Install the Hugging Face CLI if it is not already present:

```bash
python3 -m pip install --user -U huggingface_hub
```

## Stage without touching the live service

```bash
DOWNLOAD_ONLY=1 ./start.sh
```

This downloads only the pinned Q5_K_M artifact. It does not build the runtime,
bind port 30000, stop another backend, or change any Claude slot.

To download the model and compile the pinned CUDA runtime without starting a
server:

```bash
BUILD_ONLY=1 ./start.sh
```

This is the preferred preparation step while another model is live.

## Start and validate

During an approved maintenance window, first stop the existing inference
backend and confirm port 30000 is free. Then run:

```bash
./start.sh
./smoke-test.sh
```

`start.sh` builds the pinned llama.cpp revision using NVIDIA's GB10 CUDA flags,
starts a managed background process, and waits for `/health`. It refuses an
occupied port, a dirty llama.cpp checkout, a live recorded process, or less than
32 GiB of available system memory.

Useful inspection commands:

```bash
curl -fsS http://127.0.0.1:30000/v1/models
curl -fsS http://127.0.0.1:30000/metrics | grep '^llamacpp:' | head
tail -f ~/.local/state/neohorse-1-9b-gguf/server.log
```

Stop only the process managed by this recipe:

```bash
./stop.sh
```

## Context and concurrency

The pinned llama.cpp runtime exposes `--kv-unified-per-slot`, so the recipe
allocates the context limit explicitly instead of relying on implicit division.
The default `CONTEXT_PER_SLOT=262144 PARALLEL=4` allocates a 1,048,576-token
shared KV pool: four independent native-context slots. On a 128 GB DGX Spark,
the validated Q5_K_M configuration uses about 27.7 GiB after load. For a smaller
single-slot validation:

```bash
CONTEXT_PER_SLOT=262144 PARALLEL=1 PORT=30002 ./start.sh
```

Reduce `PARALLEL` or `CONTEXT_PER_SLOT` when sharing the host with another
memory-intensive service.

## Claude Code routing

The pinned llama-server exposes both OpenAI-compatible endpoints and native
Anthropic Messages at `/v1/messages`. Claude Code can connect directly to:

```text
http://127.0.0.1:30000
```

Before moving a real slot, validate non-streaming output, streaming, tool calls,
tool results, and Claude's multi-system request shape. The included smoke test
checks both OpenAI and Anthropic endpoints.

## Overrides

All operational settings are environment-variable overrides. For example:

```bash
PORT=30002 PARALLEL=1 CONTEXT_PER_SLOT=131072 ./start.sh
```

The recipe never stops an unrelated server or restarts Claude slots.

## License

The recipe is MIT licensed. NeoHorse weights are distributed separately under
Apache 2.0. llama.cpp is distributed under its own MIT license.
