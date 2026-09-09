#!/usr/bin/env bash
set -euo pipefail

STATE_DIR="${STATE_DIR:-$HOME/.local/state/oxcoder-9b-gguf}"
PID_FILE="$STATE_DIR/server.pid"
BRIDGE_PID_FILE="$STATE_DIR/metrics-bridge.pid"
DASHBOARD_PID_FILE="$STATE_DIR/dashboard.pid"

stop_companion() {
  local pid_file="$1"
  local marker="$2"
  [[ -s "$pid_file" ]] || return 0
  local companion_pid cmdline
  companion_pid="$(<"$pid_file")"
  if [[ "$companion_pid" =~ ^[0-9]+$ ]] && kill -0 "$companion_pid" 2>/dev/null; then
    cmdline="$(tr '\0' ' ' <"/proc/$companion_pid/cmdline")"
    if [[ "$cmdline" != *"$marker"* ]]; then
      echo "refusing to stop PID $companion_pid because it does not match $marker" >&2
      return 1
    fi
    kill "$companion_pid"
  fi
  rm -f "$pid_file"
}

stop_companions() {
  stop_companion "$BRIDGE_PID_FILE" "metrics-bridge.py"
  stop_companion "$DASHBOARD_PID_FILE" "fleet-metrics.py"
}

if [[ ! -s "$PID_FILE" ]]; then
  stop_companions
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
  stop_companions
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
    stop_companions
    echo "Stopped OxCoder llama-server and managed dashboard processes."
    exit 0
  fi
  sleep 1
done

echo "OxCoder did not exit after SIGTERM; PID $pid remains running" >&2
exit 1
