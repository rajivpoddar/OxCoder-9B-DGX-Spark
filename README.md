# NeoHorse-1-9B on one DGX Spark

Serve [TokenRhythm/NeoHorse-1-9B](https://huggingface.co/TokenRhythm/NeoHorse-1-9B) on a single NVIDIA DGX Spark with the model authors' tested SGLang 0.5.17 runtime, native 262,144-token context, Qwen reasoning/tool parsers, and an OpenAI-compatible API.

This repository is adapted from our [Ornith-1.5 DGX Spark recipe](https://github.com/rajivpoddar/Ornith-1.5-35B-A3B-DGX-Spark). It preserves its defensive download, memory, port, container, and readiness checks while removing Ornith-specific NVFP4, MoE, MTP, and b12x patches.

## Defaults

| Setting | Value |
|---|---|
| Checkpoint | `TokenRhythm/NeoHorse-1-9B` |
| Pinned revision | `6cd9248d8070d8a0ad8d20aa19e2fe6848419e93` |
| Weights | BF16, approximately 18 GB |
| Runtime | `lmsysorg/sglang:v0.5.17-cu130` |
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

## CLIProxyAPI bridge for Claude Code

The included `cliproxyapi/neohorse.conf.example` translates Claude's Anthropic requests to the Spark's OpenAI-compatible endpoint and enforces thinking off. Install it on the Mac running Claude Code, adjust the DGX address if necessary, and use a dedicated loopback port:

```bash
mkdir -p ~/.config/cliproxyapi ~/.cli-proxy-api-neohorse
cp cliproxyapi/neohorse.conf.example ~/.config/cliproxyapi/neohorse.conf
cp cliproxyapi/com.heydonna.cliproxyapi-neohorse.plist.example \
  ~/Library/LaunchAgents/com.heydonna.cliproxyapi-neohorse.plist
launchctl bootstrap gui/$(id -u) \
  ~/Library/LaunchAgents/com.heydonna.cliproxyapi-neohorse.plist
```

Validate the translated API before pointing a Claude slot at it:

```bash
curl -fsS http://127.0.0.1:8320/v1/messages \
  -H 'content-type: application/json' \
  -H 'x-api-key: local-neohorse-loopback' \
  -H 'anthropic-version: 2023-06-01' \
  -d '{"model":"neohorse-1-9b","max_tokens":32,"messages":[{"role":"user","content":"Reply NEOHORSE_PROXY_OK"}]}'
```

The bridge is an integration aid, not proof of Claude Code compatibility. Before moving a slot, test non-streaming, streaming, tool calls, tool results, cancellation, and compaction through the exact proxy route.

## Benchmark status

No DGX Spark throughput claim is included yet. The upstream evaluation used SGLang 0.5.17 with thinking enabled; it did not publish Spark-specific TPS, concurrency, prefix-cache, or Claude Code results. Add measurements only after a clean local C1/C2/C4 sweep.

## License

The recipe retains the upstream repository's MIT license. NeoHorse weights are distributed separately under Apache 2.0.
