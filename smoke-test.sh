#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${1:-http://127.0.0.1:30000}"
MODEL="${2:-oxcoder-9b-q5-k-m}"
METRICS_BRIDGE_URL="${METRICS_BRIDGE_URL:-http://127.0.0.1:30001}"
ENABLE_METRICS_BRIDGE="${ENABLE_METRICS_BRIDGE:-false}"
ENABLE_DASHBOARD="${ENABLE_DASHBOARD:-true}"
DASHBOARD_URL="${DASHBOARD_URL:-http://127.0.0.1:8092}"

curl -fsS "$BASE_URL/health" >/dev/null
models="$(curl -fsS "$BASE_URL/v1/models")"
grep -q "$MODEL" <<<"$models"
metrics="$(curl -fsS "$BASE_URL/metrics")"
grep -q '^llamacpp:' <<<"$metrics"
python3 "$(dirname "$0")/metrics-bridge.py" --self-test
if [[ "$ENABLE_METRICS_BRIDGE" == "true" ]]; then
  bridge_metrics="$(curl -fsS "$METRICS_BRIDGE_URL/metrics")"
  grep -q '^vllm:num_requests_running ' <<<"$bridge_metrics"
  grep -q '^vllm:prompt_tokens_total ' <<<"$bridge_metrics"
  curl -fsS "$METRICS_BRIDGE_URL/v1/models" | grep -q "$MODEL"
fi

if [[ "$ENABLE_DASHBOARD" == "true" ]]; then
  curl -fsS "$DASHBOARD_URL/health" >/dev/null
  dashboard_metrics="$(curl -fsS "$DASHBOARD_URL/metrics")"
  python3 -c 'import json,sys; data=json.load(sys.stdin); assert data["worker_port"] == int(sys.argv[1]), data' \
    "${BASE_URL##*:}" <<<"$dashboard_metrics"
fi

response="$(curl -fsS "$BASE_URL/v1/chat/completions" \
  -H 'content-type: application/json' \
  -d "{\"model\":\"$MODEL\",\"max_tokens\":32,\"temperature\":0,\"messages\":[{\"role\":\"user\",\"content\":\"Reply with exactly OXCODER_OK\"}]}")"
grep -q 'OXCODER_OK' <<<"$response"
python3 -c 'import json,sys; m=json.load(sys.stdin)["choices"][0]["message"]; assert not m.get("reasoning_content"), m' <<<"$response"

tool_response="$(curl -fsS "$BASE_URL/v1/chat/completions" \
  -H 'content-type: application/json' \
  -d "{\"model\":\"$MODEL\",\"max_tokens\":128,\"temperature\":0,\"messages\":[{\"role\":\"user\",\"content\":\"Call get_status for oxcoder.\"}],\"tools\":[{\"type\":\"function\",\"function\":{\"name\":\"get_status\",\"description\":\"Get service status\",\"parameters\":{\"type\":\"object\",\"properties\":{\"service\":{\"type\":\"string\"}},\"required\":[\"service\"]}}}],\"tool_choice\":\"auto\"}")"
grep -Eq 'tool_calls|get_status' <<<"$tool_response"

stream_response="$(curl -fsS -N "$BASE_URL/v1/chat/completions" \
  -H 'content-type: application/json' \
  -d "{\"model\":\"$MODEL\",\"stream\":true,\"max_tokens\":16,\"temperature\":0,\"messages\":[{\"role\":\"user\",\"content\":\"Reply OK\"}]}")"
grep -q 'data:' <<<"$stream_response"

anthropic_response="$(curl -fsS "$BASE_URL/v1/messages" \
  -H 'content-type: application/json' \
  -H 'anthropic-version: 2023-06-01' \
  -d "{\"model\":\"$MODEL\",\"max_tokens\":24,\"system\":[{\"type\":\"text\",\"text\":\"First system block.\"},{\"type\":\"text\",\"text\":\"Second system block.\"}],\"messages\":[{\"role\":\"user\",\"content\":\"Reply OK\"}]}")"
python3 -c 'import json,sys; r=json.load(sys.stdin); assert r["type"] == "message" and r["content"], r' <<<"$anthropic_response"

echo "OxCoder Q5_K_M APIs and dashboard metrics bridge smoke tests passed"
