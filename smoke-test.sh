#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${1:-http://127.0.0.1:30000}"
MODEL="${2:-neohorse-1-9b-q5-k-m}"

curl -fsS "$BASE_URL/health" >/dev/null
models="$(curl -fsS "$BASE_URL/v1/models")"
grep -q "$MODEL" <<<"$models"
metrics="$(curl -fsS "$BASE_URL/metrics")"
grep -q '^llamacpp:' <<<"$metrics"

response="$(curl -fsS "$BASE_URL/v1/chat/completions" \
  -H 'content-type: application/json' \
  -d "{\"model\":\"$MODEL\",\"max_tokens\":32,\"temperature\":0,\"messages\":[{\"role\":\"user\",\"content\":\"Reply with exactly NEOHORSE_OK\"}]}")"
grep -q 'NEOHORSE_OK' <<<"$response"
python3 -c 'import json,sys; m=json.load(sys.stdin)["choices"][0]["message"]; assert not m.get("reasoning_content"), m' <<<"$response"

tool_response="$(curl -fsS "$BASE_URL/v1/chat/completions" \
  -H 'content-type: application/json' \
  -d "{\"model\":\"$MODEL\",\"max_tokens\":128,\"temperature\":0,\"messages\":[{\"role\":\"user\",\"content\":\"Call get_status for neohorse.\"}],\"tools\":[{\"type\":\"function\",\"function\":{\"name\":\"get_status\",\"description\":\"Get service status\",\"parameters\":{\"type\":\"object\",\"properties\":{\"service\":{\"type\":\"string\"}},\"required\":[\"service\"]}}}],\"tool_choice\":\"auto\"}")"
grep -Eq 'tool_calls|get_status' <<<"$tool_response"

stream_response="$(curl -fsS -N "$BASE_URL/v1/chat/completions" \
  -H 'content-type: application/json' \
  -d "{\"model\":\"$MODEL\",\"stream\":true,\"max_tokens\":16,\"temperature\":0,\"messages\":[{\"role\":\"user\",\"content\":\"Reply OK\"}]}")"
grep -q 'data:' <<<"$stream_response"

echo "NeoHorse Q5_K_M OpenAI API smoke tests passed"
