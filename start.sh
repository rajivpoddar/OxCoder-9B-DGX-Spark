#!/usr/bin/env bash
# Serve NeoHorse-1-9B on one NVIDIA DGX Spark with SGLang.
set -euo pipefail

IMAGE="${IMAGE:-lmsysorg/sglang:v0.5.17-cu130}"
CONTAINER="${CONTAINER:-neohorse-1-9b-sglang}"
REPO="TokenRhythm/NeoHorse-1-9B"
REVISION="${REVISION:-6cd9248d8070d8a0ad8d20aa19e2fe6848419e93}"
SERVED_MODEL_NAME="${SERVED_MODEL_NAME:-neohorse-1-9b}"
HOST="${HOST:-0.0.0.0}"
PORT="${PORT:-30000}"
CONTEXT_LENGTH="${CONTEXT_LENGTH:-262144}"
MAX_RUNNING_REQUESTS="${MAX_RUNNING_REQUESTS:-4}"
MEM_FRACTION_STATIC="${MEM_FRACTION_STATIC:-0.80}"
ENABLE_THINKING="${ENABLE_THINKING:-false}"
MIN_AVAILABLE_GIB="${MIN_AVAILABLE_GIB:-48}"
HF_CACHE="${HF_HOME:-$HOME/.cache/huggingface}"
CONTAINER_HF="/root/.cache/huggingface"

case "$ENABLE_THINKING" in
  true|false) ;;
  *) echo "ENABLE_THINKING must be true or false" >&2; exit 2 ;;
esac

for command in docker hf curl; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "required command not found: $command" >&2
    exit 1
  }
done

if [[ -f "$HF_CACHE/token" ]]; then
  HF_TOKEN="$(<"$HF_CACHE/token")"
  export HF_TOKEN
  export HUGGINGFACE_HUB_TOKEN="$HF_TOKEN"
fi

echo "Ensuring $REPO@$REVISION is cached..."
hf download "$REPO" --revision "$REVISION"

MODEL="$HF_CACHE/hub/models--TokenRhythm--NeoHorse-1-9B/snapshots/$REVISION"
for required in config.json tokenizer_config.json model.safetensors.index.json chat_template.jinja; do
  [[ -s "$MODEL/$required" ]] || {
    echo "incomplete checkpoint: missing $MODEL/$required" >&2
    exit 1
  }
done

if [[ "${DOWNLOAD_ONLY:-0}" == "1" ]]; then
  echo "Download complete: $MODEL"
  exit 0
fi

available_kib=$(awk '/^MemAvailable:/ { print $2 }' /proc/meminfo)
required_kib=$((MIN_AVAILABLE_GIB * 1024 * 1024))
if (( available_kib < required_kib )); then
  available_gib=$((available_kib / 1024 / 1024))
  echo "refusing to start NeoHorse: ${available_gib} GiB available, ${MIN_AVAILABLE_GIB} GiB required" >&2
  echo "stop the active inference backend in a maintenance window before retrying" >&2
  exit 1
fi

if ss -H -ltn "sport = :$PORT" | grep -q .; then
  echo "refusing to start NeoHorse: port $PORT is already in use" >&2
  exit 1
fi
if docker container inspect "$CONTAINER" >/dev/null 2>&1; then
  echo "refusing to replace existing container $CONTAINER; run ./stop.sh first" >&2
  exit 1
fi

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  echo "Pulling $IMAGE..."
  docker pull "$IMAGE"
fi

MODEL_IN_CONTAINER="$CONTAINER_HF/${MODEL#"$HF_CACHE"/}"
CHAT_TEMPLATE_KWARGS="{\"enable_thinking\":$ENABLE_THINKING}"

docker run -d \
  --name "$CONTAINER" \
  --gpus all \
  --network host \
  --ipc=host \
  -v "$HF_CACHE:$CONTAINER_HF:ro" \
  "$IMAGE" \
  python3 -m sglang.launch_server \
    --model-path "$MODEL_IN_CONTAINER" \
    --served-model-name "$SERVED_MODEL_NAME" \
    --host "$HOST" \
    --port "$PORT" \
    --tp-size 1 \
    --context-length "$CONTEXT_LENGTH" \
    --max-running-requests "$MAX_RUNNING_REQUESTS" \
    --mem-fraction-static "$MEM_FRACTION_STATIC" \
    --reasoning-parser qwen3 \
    --tool-call-parser qwen3_coder \
    --default-chat-template-kwargs "$CHAT_TEMPLATE_KWARGS"

echo "Launched $CONTAINER; waiting for http://127.0.0.1:$PORT/health"
deadline=$(( $(date +%s) + 1800 ))
while :; do
  if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
    echo "NeoHorse exited before becoming healthy" >&2
    docker logs --tail 100 "$CONTAINER" >&2 || true
    exit 1
  fi
  if curl -fsS --max-time 5 "http://127.0.0.1:$PORT/health" >/dev/null; then
    echo "NeoHorse is healthy on port $PORT"
    exit 0
  fi
  if (( $(date +%s) >= deadline )); then
    echo "health check timed out" >&2
    docker logs --tail 100 "$CONTAINER" >&2 || true
    exit 1
  fi
  sleep 2
done
