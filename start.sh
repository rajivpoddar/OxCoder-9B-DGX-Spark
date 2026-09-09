#!/usr/bin/env bash
# Serve the official NeoHorse Q5_K_M GGUF on one NVIDIA DGX Spark.
set -euo pipefail

REPO="TokenRhythm/NeoHorse-1-9B-GGUF"
REVISION="${REVISION:-ddcb4c939b5392c86a9d2733c7c0ed30db2554fd}"
MODEL_FILE="${MODEL_FILE:-NeoHorse-1-9B-Q5_K_M.gguf}"
SERVED_MODEL_NAME="${SERVED_MODEL_NAME:-neohorse-1-9b-q5-k-m}"
HOST="${HOST:-0.0.0.0}"
PORT="${PORT:-30000}"
CONTEXT_PER_SLOT="${CONTEXT_PER_SLOT:-65536}"
PARALLEL="${PARALLEL:-4}"
CACHE_TYPE_K="${CACHE_TYPE_K:-q8_0}"
CACHE_TYPE_V="${CACHE_TYPE_V:-q8_0}"
MIN_AVAILABLE_GIB="${MIN_AVAILABLE_GIB:-32}"
RECIPE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CHAT_TEMPLATE_FILE="${CHAT_TEMPLATE_FILE:-$RECIPE_DIR/claude-chat-template.jinja}"

LLAMA_CPP_REVISION="${LLAMA_CPP_REVISION:-b31b71f3a076bfc4278daad442203a9c51c6e676}"
LLAMA_CPP_DIR="${LLAMA_CPP_DIR:-$HOME/.local/share/llama.cpp-neohorse}"
MODEL_DIR="${MODEL_DIR:-$HOME/.cache/huggingface/neohorse-1-9b-gguf/$REVISION}"
STATE_DIR="${STATE_DIR:-$HOME/.local/state/neohorse-1-9b-gguf}"
PID_FILE="$STATE_DIR/server.pid"
LOG_FILE="$STATE_DIR/server.log"

for command in git cmake clang curl ss awk nproc; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "required command not found: $command" >&2
    exit 1
  }
done

HF_CLI="${HF_CLI:-}"
if [[ -z "$HF_CLI" ]]; then
  if command -v hf >/dev/null 2>&1; then
    HF_CLI="$(command -v hf)"
  elif command -v huggingface-cli >/dev/null 2>&1; then
    HF_CLI="$(command -v huggingface-cli)"
  else
    echo "required Hugging Face CLI not found; set HF_CLI explicitly" >&2
    exit 1
  fi
fi
[[ -x "$HF_CLI" ]] || { echo "HF_CLI is not executable: $HF_CLI" >&2; exit 1; }
[[ -s "$CHAT_TEMPLATE_FILE" ]] || { echo "chat template missing: $CHAT_TEMPLATE_FILE" >&2; exit 1; }

mkdir -p "$MODEL_DIR" "$STATE_DIR" "$(dirname "$LLAMA_CPP_DIR")"

echo "Ensuring $REPO/$MODEL_FILE@$REVISION is cached..."
"$HF_CLI" download "$REPO" "$MODEL_FILE" \
  --revision "$REVISION" \
  --local-dir "$MODEL_DIR"
MODEL_PATH="$MODEL_DIR/$MODEL_FILE"
[[ -s "$MODEL_PATH" ]] || { echo "missing model file: $MODEL_PATH" >&2; exit 1; }

if [[ "${DOWNLOAD_ONLY:-0}" == "1" ]]; then
  echo "Download complete: $MODEL_PATH"
  exit 0
fi

if [[ ! -d "$LLAMA_CPP_DIR/.git" ]]; then
  [[ ! -e "$LLAMA_CPP_DIR" ]] || {
    echo "refusing to replace non-git path: $LLAMA_CPP_DIR" >&2
    exit 1
  }
  git clone https://github.com/ggml-org/llama.cpp.git "$LLAMA_CPP_DIR"
fi

if [[ -n "$(git -C "$LLAMA_CPP_DIR" status --porcelain)" ]]; then
  echo "refusing to change dirty llama.cpp checkout: $LLAMA_CPP_DIR" >&2
  exit 1
fi

git -C "$LLAMA_CPP_DIR" fetch --quiet origin "$LLAMA_CPP_REVISION"
git -C "$LLAMA_CPP_DIR" checkout --quiet --detach "$LLAMA_CPP_REVISION"

echo "Building llama.cpp $LLAMA_CPP_REVISION for GB10 (sm_121)..."
cmake -S "$LLAMA_CPP_DIR" -B "$LLAMA_CPP_DIR/build" \
  -DGGML_NATIVE=ON \
  -DGGML_CUDA=ON \
  -DGGML_CURL=ON \
  -DGGML_RPC=ON \
  -DCMAKE_CUDA_ARCHITECTURES=121a-real \
  -DCMAKE_BUILD_TYPE=Release
cmake --build "$LLAMA_CPP_DIR/build" --config Release --target llama-server -j "$(nproc)"
SERVER="$LLAMA_CPP_DIR/build/bin/llama-server"
[[ -x "$SERVER" ]] || { echo "llama-server build missing: $SERVER" >&2; exit 1; }

if [[ "${BUILD_ONLY:-0}" == "1" ]]; then
  echo "Build complete: $SERVER"
  echo "Model ready: $MODEL_PATH"
  exit 0
fi

if [[ -s "$PID_FILE" ]]; then
  old_pid="$(<"$PID_FILE")"
  if [[ "$old_pid" =~ ^[0-9]+$ ]] && kill -0 "$old_pid" 2>/dev/null; then
    echo "refusing to replace running NeoHorse process $old_pid; run ./stop.sh first" >&2
    exit 1
  fi
  rm -f "$PID_FILE"
fi

if ss -H -ltn "sport = :$PORT" | grep -q .; then
  echo "refusing to start NeoHorse: port $PORT is already in use" >&2
  exit 1
fi

available_kib="$(awk '/^MemAvailable:/ { print $2 }' /proc/meminfo)"
required_kib=$((MIN_AVAILABLE_GIB * 1024 * 1024))
if (( available_kib < required_kib )); then
  available_gib=$((available_kib / 1024 / 1024))
  echo "refusing to start NeoHorse: ${available_gib} GiB available, ${MIN_AVAILABLE_GIB} GiB required" >&2
  exit 1
fi

echo "Starting $SERVED_MODEL_NAME on port $PORT..."
nohup "$SERVER" \
  --model "$MODEL_PATH" \
  --alias "$SERVED_MODEL_NAME" \
  --host "$HOST" \
  --port "$PORT" \
  --parallel "$PARALLEL" \
  --kv-unified-per-slot "$CONTEXT_PER_SLOT" \
  --cont-batching \
  --cache-prompt \
  --flash-attn on \
  --cache-type-k "$CACHE_TYPE_K" \
  --cache-type-v "$CACHE_TYPE_V" \
  --jinja \
  --chat-template-file "$CHAT_TEMPLATE_FILE" \
  --reasoning off \
  --n-gpu-layers 99 \
  --metrics \
  >"$LOG_FILE" 2>&1 &
server_pid=$!
echo "$server_pid" >"$PID_FILE"

cleanup_failed_start() {
  if kill -0 "$server_pid" 2>/dev/null; then
    kill "$server_pid" 2>/dev/null || true
  fi
  rm -f "$PID_FILE"
}

deadline=$(( $(date +%s) + 900 ))
while :; do
  if ! kill -0 "$server_pid" 2>/dev/null; then
    echo "NeoHorse exited before becoming healthy" >&2
    tail -100 "$LOG_FILE" >&2 || true
    cleanup_failed_start
    exit 1
  fi
  if curl -fsS --max-time 5 "http://127.0.0.1:$PORT/health" >/dev/null; then
    echo "NeoHorse is healthy on port $PORT (pid $server_pid)"
    echo "Log: $LOG_FILE"
    exit 0
  fi
  if (( $(date +%s) >= deadline )); then
    echo "health check timed out" >&2
    tail -100 "$LOG_FILE" >&2 || true
    cleanup_failed_start
    exit 1
  fi
  sleep 2
done
