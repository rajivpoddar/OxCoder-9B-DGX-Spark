#!/usr/bin/env bash
set -euo pipefail

STATE_DIR="${STATE_DIR:-$HOME/.local/state/neohorse-1-9b-gguf}"
PID_FILE="$STATE_DIR/server.pid"

if [[ ! -s "$PID_FILE" ]]; then
  echo "No managed NeoHorse process is recorded."
  exit 0
fi

pid="$(<"$PID_FILE")"
if [[ ! "$pid" =~ ^[0-9]+$ ]]; then
  echo "invalid PID file: $PID_FILE" >&2
  exit 1
fi

if ! kill -0 "$pid" 2>/dev/null; then
  rm -f "$PID_FILE"
  echo "Removed stale NeoHorse PID file."
  exit 0
fi

cmdline="$(tr '\0' ' ' <"/proc/$pid/cmdline")"
if [[ "$cmdline" != *llama-server* || "$cmdline" != *NeoHorse-1-9B* ]]; then
  echo "refusing to stop PID $pid because it is not the managed NeoHorse llama-server" >&2
  exit 1
fi

kill "$pid"
for _ in {1..30}; do
  if ! kill -0 "$pid" 2>/dev/null; then
    rm -f "$PID_FILE"
    echo "Stopped NeoHorse llama-server."
    exit 0
  fi
  sleep 1
done

echo "NeoHorse did not exit after SIGTERM; PID $pid remains running" >&2
exit 1
