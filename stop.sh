#!/usr/bin/env bash
set -euo pipefail

STATE_DIR="${STATE_DIR:-$HOME/.local/state/oxcoder-9b-gguf}"
PID_FILE="$STATE_DIR/server.pid"
BRIDGE_PID_FILE="$STATE_DIR/metrics-bridge.pid"

stop_metrics_bridge() {
  [[ -s "$BRIDGE_PID_FILE" ]] || return 0
  local bridge_pid
  bridge_pid="$(<"$BRIDGE_PID_FILE")"
  if [[ "$bridge_pid" =~ ^[0-9]+$ ]] && kill -0 "$bridge_pid" 2>/dev/null; then
    kill "$bridge_pid"
  fi
  rm -f "$BRIDGE_PID_FILE"
}

if [[ ! -s "$PID_FILE" ]]; then
  stop_metrics_bridge
  echo "No managed OxCoder process is recorded."
  exit 0
fi

pid="$(<"$PID_FILE")"
if [[ ! "$pid" =~ ^[0-9]+$ ]]; then
  echo "invalid PID file: $PID_FILE" >&2
  exit 1
fi

if ! kill -0 "$pid" 2>/dev/null; then
  rm -f "$PID_FILE"
  stop_metrics_bridge
  echo "Removed stale OxCoder PID file."
  exit 0
fi

cmdline="$(tr '\0' ' ' <"/proc/$pid/cmdline")"
if [[ "$cmdline" != *llama-server* || "$cmdline" != *OxCoder-9B* ]]; then
  echo "refusing to stop PID $pid because it is not the managed OxCoder llama-server" >&2
  exit 1
fi

kill "$pid"
for _ in {1..30}; do
  if ! kill -0 "$pid" 2>/dev/null; then
    rm -f "$PID_FILE"
    stop_metrics_bridge
    echo "Stopped OxCoder llama-server and metrics bridge."
    exit 0
  fi
  sleep 1
done

echo "OxCoder did not exit after SIGTERM; PID $pid remains running" >&2
exit 1
