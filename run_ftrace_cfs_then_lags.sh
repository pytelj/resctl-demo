#!/usr/bin/env bash
set -euo pipefail

# Run the existing run_ftrace.sh multiple times under normal CFS, then under
# scx_lags. This intentionally keeps run_ftrace.sh unchanged and gives each
# invocation a distinct RUN_ID.

RUNS="${RUNS:-5}"
SLEEP_BETWEEN_RUNS_SEC="${SLEEP_BETWEEN_RUNS_SEC:-60}"
RUN_FTRACE="${RUN_FTRACE:-./run_ftrace.sh}"
SCX_BIN="${SCX_BIN:-/home/janp/linux/tools/sched_ext/build/bin/scx_lags}"
SCX_ARGS="${SCX_ARGS:-}"
SCX_STARTUP_SEC="${SCX_STARTUP_SEC:-10}"
LOG_ROOT="${LOG_ROOT:-$PWD/../sched-ext/logs/ftrace_resctl}"
BATCH_ID="${BATCH_ID:-$(date +%Y%m%d_%H%M%S)}"
SCX_LOG_DIR="${SCX_LOG_DIR:-$LOG_ROOT/scx_lags_logs}"
SCX_LOG="$SCX_LOG_DIR/scx_lags_${BATCH_ID}.log"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: missing command '$1'" >&2
    exit 1
  }
}

SCX_PID=""
stop_scx_lags() {
  [[ -z "${SCX_PID:-}" ]] && return 0

  echo "Stopping scx_lags..."
  sudo kill -INT "$SCX_PID" >/dev/null 2>&1 || true

  local waited=0
  while kill -0 "$SCX_PID" >/dev/null 2>&1 && (( waited < 10 )); do
    sleep 1
    waited=$((waited + 1))
  done

  if kill -0 "$SCX_PID" >/dev/null 2>&1; then
    sudo kill -TERM "$SCX_PID" >/dev/null 2>&1 || true
  fi

  SCX_PID=""
}

trap 'stop_scx_lags' EXIT INT TERM

run_ftrace_batch() {
  local scheduler="$1"
  local i run_id

  for i in $(seq 1 "$RUNS"); do
    run_id=$(printf "%s_%s_r%02d" "$scheduler" "$BATCH_ID" "$i")

    echo "================================"
    echo "Scheduler: $scheduler"
    echo "Run: ${i}/${RUNS}"
    echo "RUN_ID: $run_id"
    echo "================================"

    RUN_ID="$run_id" LOG_ROOT="$LOG_ROOT" "$RUN_FTRACE"

    if (( i < RUNS )); then
      echo "Sleeping ${SLEEP_BETWEEN_RUNS_SEC}s before next run..."
      sleep "$SLEEP_BETWEEN_RUNS_SEC"
    fi
  done
}

start_scx_lags() {
  [[ -x "$SCX_BIN" ]] || { echo "ERROR: scx_lags not executable at $SCX_BIN" >&2; exit 1; }
  mkdir -p "$SCX_LOG_DIR"

  echo "Starting scx_lags..."
  echo "Command: sudo $SCX_BIN $SCX_ARGS"
  echo "Log: $SCX_LOG"

  # shellcheck disable=SC2086 # SCX_ARGS is intentionally split into argv words.
  sudo "$SCX_BIN" $SCX_ARGS >"$SCX_LOG" 2>&1 &
  SCX_PID="$!"

  sleep "$SCX_STARTUP_SEC"

  if ! kill -0 "$SCX_PID" >/dev/null 2>&1; then
    echo "ERROR: scx_lags exited during startup. Log follows:" >&2
    sed -n '1,120p' "$SCX_LOG" >&2 || true
    exit 1
  fi

  if [[ -r /sys/kernel/sched_ext/state ]]; then
    echo "sched_ext state: $(cat /sys/kernel/sched_ext/state)"
  fi
}

main() {
  require_cmd sudo
  require_cmd seq
  require_cmd date

  [[ -x "$RUN_FTRACE" ]] || { echo "ERROR: run_ftrace script not executable at $RUN_FTRACE" >&2; exit 1; }

  sudo -v

  echo "Batch ID: $BATCH_ID"
  echo "Runs per scheduler: $RUNS"
  echo "Sleep between runs: ${SLEEP_BETWEEN_RUNS_SEC}s"
  echo "LOG_ROOT: $LOG_ROOT"
  echo

  run_ftrace_batch "cfs"

  echo "Sleeping ${SLEEP_BETWEEN_RUNS_SEC}s before enabling scx_lags..."
  sleep "$SLEEP_BETWEEN_RUNS_SEC"

  start_scx_lags
  run_ftrace_batch "scx_lags"
  stop_scx_lags

  echo "Done."
  echo "scx_lags log: $SCX_LOG"
}

main "$@"
