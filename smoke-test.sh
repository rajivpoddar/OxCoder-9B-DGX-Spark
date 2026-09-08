#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${1:-http://127.0.0.1:30000}"
MODEL="${2:-neohorse-1-9b}"
EXPECT_METRICS="${EXPECT_METRICS:-true}"

case "$EXPECT_METRICS" in
  true|false) ;;
  *) echo "EXPECT_METRICS must be true or false" >&2; exit 2 ;;
esac

curl -fsS "$BASE_URL/v1/models" | grep -q "$MODEL"

if [[ "$EXPECT_METRICS" == "true" ]]; then
  curl -fsS "$BASE_URL/metrics" | awk '/^sglang:/ { found=1 } END { exit !found }'
fi

response=$(curl -fsS "$BASE_URL/v1/chat/completions" \
  -H 'content-type: application/json' \
  -d "{\"model\":\"$MODEL\",\"max_tokens\":32,\"temperature\":0,\"chat_template_kwargs\":{\"enable_thinking\":false},\"messages\":[{\"role\":\"user\",\"content\":\"Reply with exactly NEOHORSE_OK\"}]}")
grep -q 'NEOHORSE_OK' <<<"$response"
python3 -c 'import json,sys; m=json.load(sys.stdin)["choices"][0]["message"]; assert m.get("reasoning_content") in (None, ""), m' <<<"$response"

tool_response=$(curl -fsS "$BASE_URL/v1/chat/completions" \
  -H 'content-type: application/json' \
  -d "{\"model\":\"$MODEL\",\"max_tokens\":96,\"temperature\":0,\"chat_template_kwargs\":{\"enable_thinking\":false},\"messages\":[{\"role\":\"user\",\"content\":\"Call get_status for neohorse.\"}],\"tools\":[{\"type\":\"function\",\"function\":{\"name\":\"get_status\",\"description\":\"Get service status\",\"parameters\":{\"type\":\"object\",\"properties\":{\"service\":{\"type\":\"string\"}},\"required\":[\"service\"]}}}],\"tool_choice\":\"auto\"}")
grep -Eq 'tool_calls|get_status' <<<"$tool_response"

stream_response=$(curl -fsS -N "$BASE_URL/v1/chat/completions" \
  -H 'content-type: application/json' \
  -d "{\"model\":\"$MODEL\",\"stream\":true,\"max_tokens\":16,\"temperature\":0,\"chat_template_kwargs\":{\"enable_thinking\":false},\"messages\":[{\"role\":\"user\",\"content\":\"Reply OK\"}]}")
grep -q 'data:' <<<"$stream_response"

anthropic_response=$(curl -fsS "$BASE_URL/v1/messages" \
  -H 'content-type: application/json' \
  -H 'x-api-key: dummy' \
  -H 'anthropic-version: 2023-06-01' \
  -d "{\"model\":\"$MODEL\",\"max_tokens\":32,\"messages\":[{\"role\":\"user\",\"content\":\"Reply with exactly NEOHORSE_ANTHROPIC_OK\"}]}")
grep -q 'NEOHORSE_ANTHROPIC_OK' <<<"$anthropic_response"

anthropic_stream=$(curl -fsS -N "$BASE_URL/v1/messages" \
  -H 'content-type: application/json' \
  -H 'x-api-key: dummy' \
  -H 'anthropic-version: 2023-06-01' \
  -d "{\"model\":\"$MODEL\",\"stream\":true,\"max_tokens\":16,\"messages\":[{\"role\":\"user\",\"content\":\"Reply OK\"}]}")
grep -q 'event: message_start' <<<"$anthropic_stream"
grep -q 'event: message_stop' <<<"$anthropic_stream"

echo "NeoHorse OpenAI and native Anthropic API smoke tests passed"
