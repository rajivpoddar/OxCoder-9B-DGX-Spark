#!/usr/bin/env bash
# CPU-only staging; never starts/stops inference or changes slot sessions.
set -euo pipefail
DFLASH_REVISION="${DFLASH_REVISION:-5fc3b3d474760f18c516db87d84c37edbfd3ede6}"
TOKENIZER_REVISION="2419e16b3e3cc00606ec1e5507de227867baa789"
LLAMA_CPP_REVISION="${LLAMA_CPP_REVISION:-b31b71f3a076bfc4278daad442203a9c51c6e676}"
LLAMA_CPP_DIR="${LLAMA_CPP_DIR:-$HOME/.local/share/llama.cpp-oxcoder}"
DFLASH_DIR="${DFLASH_DIR:-$HOME/.cache/huggingface/oxcoder-dflash/$DFLASH_REVISION}"
HF_CLI="${HF_CLI:-hf}"
PYTHON="${PYTHON:-python3}"
[[ "$(git -C "$LLAMA_CPP_DIR" rev-parse HEAD)" == "$LLAMA_CPP_REVISION" ]] || {
  echo "Build/stage the recipe's pinned llama.cpp before converting DFlash" >&2; exit 1;
}
mkdir -p "$DFLASH_DIR"
"$HF_CLI" download z-lab/Qwen3.5-9B-DFlash config.json model.safetensors \
  --revision "$DFLASH_REVISION" --local-dir "$DFLASH_DIR/source"
"$HF_CLI" download OrionLLM/OxCoder-9B config.json tokenizer.json tokenizer_config.json \
  --revision "$TOKENIZER_REVISION" --local-dir "$DFLASH_DIR/target-tokenizer"

output="$DFLASH_DIR/Qwen3.5-9B-DFlash-BF16.gguf"
if [[ -e "$output" ]]; then
  echo "Refusing to overwrite existing conversion: $output" >&2; exit 1
fi
CUDA_VISIBLE_DEVICES='' OMP_NUM_THREADS=4 "$PYTHON" "$LLAMA_CPP_DIR/convert_hf_to_gguf.py" \
  "$DFLASH_DIR/source" --target-model-dir "$DFLASH_DIR/target-tokenizer" \
  --outtype bf16 --outfile "$output.partial"
[[ -s "$output.partial" ]] || { echo "Empty DFlash conversion" >&2; exit 1; }
mv "$output.partial" "$output"
sha256sum "$output"
echo "Staged DFlash: $output (requires OxCoder acceptance/throughput validation)"
