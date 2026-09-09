# DFlash validation on one DGX Spark — 2026-09-09

Target: pinned OxCoder-9B Q5_K_M; pinned llama.cpp `b31b71f`; Q8_0 target
KV, four slots with 262,144 context each, thinking off, GPU clock capped at
2,200 MHz. Draft: `z-lab/Qwen3.5-9B-DFlash` at
`5fc3b3d474760f18c516db87d84c37edbfd3ede6`, converted to BF16 with OxCoder's
tokenizer. `SPEC_TYPE=draft-dflash SPEC_DRAFT_MAX=3`; no ngram combination.

## Matched measurements

One run per configuration, synthetic Python coding followed by a second coding
turn, 256 generated tokens per turn. These are bounded engineering checks,
not a coding-quality benchmark or a statistical performance guarantee.

| Prompt / concurrent streams | Speculation-off end-to-end tok/s | DFlash end-to-end tok/s | Change |
|---|---:|---:|---:|
| ~4K / C1 | 30.68 | 47.10 | +53.5% |
| ~4K / C4, aggregate | 76.00 | 81.50 | +7.2% |
| ~100K / C1 | 6.95 | 6.67 | -4.0% |

End-to-end includes cold prefill, decoding and the cached follow-up. Do not
compare that metric directly to decode-only headline throughput.

| C1 measurement | Speculation off | DFlash |
|---|---:|---:|
| 4K cold-turn decode | 34.92 tok/s | 60.10 tok/s |
| 4K follow-up decode | 34.93 tok/s | 74.86 tok/s |
| 4K cold TTFT | 1.85 s | 2.85 s |
| 100K cold-turn decode | 26.36 tok/s | 35.05 tok/s |
| 100K follow-up decode | 26.34 tok/s | 44.37 tok/s |
| 100K cold TTFT | 53.74 s | 62.93 s |
| 100K cached follow-up TTFT | 0.61 s | 0.80 s |

Draft acceptance: 83.3% at 4K/C1, 82.1% at 4K/C4, 81.5% at 100K/C1.
All four C1 output hashes match their speculation-off counterparts. C4 output
hashes differ, so bit-exact batched reproducibility is **not** established.
The 100K follow-up retained 100,069 cached prompt tokens in both modes.

## Long-context four-stream stability check

The isolated DFlash 100K/C4 run completed all eight requests (four cold plus
four cached follow-ups), generating exactly 2,048 tokens in 310.49 seconds:
**6.60 aggregate end-to-end tok/s**, 78.8% draft acceptance, 170.42 seconds
median cold TTFT and 4.60 seconds median follow-up TTFT. Metrics counted the
same 2,048 tokens, with no background inference traffic. Each follow-up reused
100,069 cached tokens. No inference crash or unexpected restart occurred;
after the run, the host had about 70 GiB available and no swap used.

There is no uncontaminated speculation-off 100K/C4 comparison. This proves
completion and cache reuse, not a four-stream long-context speedup. The large
cold-prefill queue still starves decoding: request timing includes time spent
sharing the engine with other long prefills.

## Compatibility and limitations

- All 248,320 token strings, token types, EOS and pad IDs match the deployed
  target GGUF. Draft conversion completed without loading either model on GPU.
- Native Anthropic multi-system prompts, thinking-off text, structured tool
  calls and a tool-result round trip passed with DFlash.
- An initial C4/100K baseline received background client traffic and was
  cancelled. It is excluded from comparison. Subsequent DFlash measurements
  used a localhost-only listener to isolate them from clients.
- DFlash increases prefill work. It is a decode optimization, not a fix for
  simultaneous cold long-prompt congestion. Cold 100K/short-output requests
  did not get faster end-to-end.
- This does not prove four simultaneous full-262K requests or arbitrary coding
  correctness. Base-model draft transfer to this fine-tune needs monitoring.
- A restart with unexpected client requests still in flight logged a shutdown
  `double free or corruption` after cancellation. The replacement loaded;
  this is not evidence of an inference-time crash, but clean draining before
  restart is required and the shutdown defect remains a follow-up.

Rollback remains `SPEC_TYPE=ngram-mod` (previous deployment) or `SPEC_TYPE=none`
followed by a controlled same-model service restart.
