# NeoHorse-1-9B on one DGX Spark

Serve [TokenRhythm/NeoHorse-1-9B](https://huggingface.co/TokenRhythm/NeoHorse-1-9B) on a single NVIDIA DGX Spark with SGLang 0.5.19, native 262,144-token context, Qwen reasoning/tool parsers, and native OpenAI- and Anthropic-compatible APIs.

This repository is adapted from our [Ornith-1.5 DGX Spark recipe](https://github.com/rajivpoddar/Ornith-1.5-35B-A3B-DGX-Spark). It preserves its defensive download, memory, port, container, and readiness checks while removing Ornith-specific NVFP4, MoE, MTP, and b12x patches.

## Defaults

| Setting | Value |
|---|---|
| Checkpoint | `TokenRhythm/NeoHorse-1-9B` |
| Pinned revision | `6cd9248d8070d8a0ad8d20aa19e2fe6848419e93` |
| Weights | BF16, approximately 18 GB |
| Runtime | `lmsysorg/sglang:v0.5.19-cu130` |
| Context | 262,144 tokens |
| Concurrent requests | 4 |
| Reasoning parser | `qwen3` |
| Tool parser | `qwen3_coder` |
| Thinking | Off by default; set `ENABLE_THINKING=true` to enable |
| API | OpenAI-compatible, port 30000 |

The model is text-only. The authors report that its base architecture can be extended toward one million tokens, but this recipe deliberately starts at the native, evaluated 262K context.

## Download without changing the live server

```bash
DOWNLOAD_ONLY=1 ./start.sh
```

This is safe to run while another inference backend is serving because it only populates the Hugging Face cache.
The launcher accepts either `hf` or `huggingface-cli`. If the client is installed in a virtual environment outside `PATH`, set `HF_CLI=/absolute/path/to/hf`.

## Start and validate

Stop the active inference backend during a maintenance window, then:

```bash
./start.sh
./smoke-test.sh
```

The launcher refuses to replace an existing NeoHorse container, refuses an occupied port, and requires at least 48 GiB of available host memory. Override conservative defaults when testing:

```bash
PORT=30002 MAX_RUNNING_REQUESTS=2 CONTEXT_LENGTH=131072 ./start.sh
```

Stop it with:

```bash
./stop.sh
```

## Thinking behavior

Thinking is disabled server-side by default using the model's native chat-template switch. A client may also send:

```json
{"chat_template_kwargs":{"enable_thinking":false}}
```

Set `ENABLE_THINKING=true` before launch to reproduce the thinking-enabled protocol used by the authors' published benchmark. Do not compare thinking-on quality results with thinking-off latency results as if they were the same workload.

## Native Anthropic API for Claude Code

SGLang exposes `/v1/messages` directly, so Claude Code does not need a protocol proxy. Point Claude Code at the DGX server:

```bash
export ANTHROPIC_BASE_URL="http://192.168.68.113:30000"
export ANTHROPIC_AUTH_TOKEN="dummy"
export ANTHROPIC_DEFAULT_HAIKU_MODEL="neohorse-1-9b"
export ANTHROPIC_DEFAULT_SONNET_MODEL="neohorse-1-9b"
export ANTHROPIC_DEFAULT_OPUS_MODEL="neohorse-1-9b"
claude
```

Validate the native endpoint before pointing a Claude slot at it:

```bash
curl -fsS http://192.168.68.113:30000/v1/messages \
  -H 'content-type: application/json' \
  -H 'x-api-key: dummy' \
  -H 'anthropic-version: 2023-06-01' \
  -d '{"model":"neohorse-1-9b","max_tokens":32,"messages":[{"role":"user","content":"Reply NEOHORSE_ANTHROPIC_OK"}]}'
```

Before moving a slot, test non-streaming, streaming, tool calls, tool results, cancellation, and compaction through this exact native route.

## Benchmark status

No DGX Spark throughput claim is included yet. The upstream evaluation used SGLang 0.5.17 with thinking enabled, while this recipe uses SGLang 0.5.19 for its newer runtime and native Anthropic API fixes. The upstream evaluation did not publish Spark-specific TPS, concurrency, prefix-cache, or Claude Code results. Add measurements only after a clean local C1/C2/C4 sweep.

## License

The recipe retains the upstream repository's MIT license. NeoHorse weights are distributed separately under Apache 2.0.
