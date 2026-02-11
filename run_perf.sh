#!/usr/bin/env bash
set -euo pipefail

DENSITIES="${DENSITIES:-1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19}"
REPEATS="${REPEATS:-1}"
WARMUP_SEC="${WARMUP_SEC:-5}"
TRACE_SEC="${TRACE_SEC:-30}"
COOLDOWN_SEC="${COOLDOWN_SEC:-2}"
SLICE="${SLICE:-faas.slice}"

REPO_ROOT="${REPO_ROOT:-$PWD}"
RDH_BIN="${RDH_BIN:-$REPO_ROOT/target/release/rd-hashd}"
PARAMS_JSON="${PARAMS_JSON:-$REPO_ROOT/rdh/params.json}"

THREADS="${THREADS:-1}"
WORK_US="${WORK_US:-0}"
SLEEP_US="${SLEEP_US:-0}"

LOG_ROOT="${LOG_ROOT:-$REPO_ROOT/../sched-ext/logs/perf_resctl}"
RUN_ID="${RUN_ID:-$(date +%Y%m%d_%H%M%S)}"
OUT_DIR="${LOG_ROOT}/${RUN_ID}"
RUN_ID_SAFE="$(echo "$RUN_ID" | tr -c 'A-Za-z0-9_.-' '_')"

TRACING_DIR="${TRACING_DIR:-}"
if [[ -z "$TRACING_DIR" ]]; then
  if [[ -d /sys/kernel/tracing ]]; then
    TRACING_DIR="/sys/kernel/tracing"
  else
    TRACING_DIR="/sys/kernel/debug/tracing"
  fi
fi

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: missing command '$1'" >&2
    exit 1
  }
}

RUN_TAG=""
cleanup_units() {
  [[ -z "${RUN_TAG:-}" ]] && return 0
  local pattern="hashd-${RUN_TAG}-"
  local u
  for u in $(systemctl list-units --type=service --all --no-pager --plain | awk -v p="$pattern" '$1 ~ p {print $1}'); do
    sudo systemctl stop "$u" >/dev/null 2>&1 || true
  done
}

cleanup_tracing() {
  if [[ -d "$TRACING_DIR" ]]; then
    sudo sh -c "
      cd '$TRACING_DIR' || exit 0
      echo 0 > tracing_on 2>/dev/null || true
      echo nop > current_tracer 2>/dev/null || true
      : > set_graph_function 2>/dev/null || true
      : > set_ftrace_filter 2>/dev/null || true
    " >/dev/null 2>&1 || true
  fi
}

trap 'cleanup_units; cleanup_tracing' EXIT INT TERM

run_perf_stat() {
  local outfile="$1"
  local dur="$2"

  sudo perf stat -a \
    -e sched:sched_switch \
    -e cycles:k \
    -e task-clock \
    -- sleep "$dur" 2> "$outfile"
}

main() {
  require_cmd sudo
  require_cmd awk
  require_cmd nproc
  require_cmd python3
  require_cmd systemd-run
  require_cmd perf

  if [[ "$REPEATS" != "1" ]]; then
    echo "ERROR: REPEATS=$REPEATS is not notebook-compatible. Use REPEATS=1." >&2
    exit 1
  fi

  sudo -v

  [[ -x "$RDH_BIN" ]] || { echo "ERROR: rd-hashd not executable at $RDH_BIN" >&2; exit 1; }
  [[ -f "$PARAMS_JSON" ]] || { echo "ERROR: params file missing at $PARAMS_JSON" >&2; exit 1; }
  [[ -d "$TRACING_DIR" ]] || { echo "ERROR: tracing dir missing at $TRACING_DIR" >&2; exit 1; }

  local H
  H="$(nproc)"

  mkdir -p "$OUT_DIR"

  echo "Logs: $OUT_DIR"
  echo "Densities: $DENSITIES"
  echo "Params: threads=$THREADS, work_us=$WORK_US, sleep_us=$SLEEP_US"
  echo "Warmup=${WARMUP_SEC}s, Trace=${TRACE_SEC}s"
  echo

  cat > "$OUT_DIR/params.txt" <<PARAMS
RUN_ID=$RUN_ID
HOSTNAME=$(hostname)
DATE_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)
KERNEL=$(uname -r)
PERF_VERSION=$(perf --version 2>/dev/null || true)
DENSITIES=$DENSITIES
THREADS=$THREADS
WORK_US=$WORK_US
SLEEP_US=$SLEEP_US
WARMUP_SEC=$WARMUP_SEC
TRACE_SEC=$TRACE_SEC
COOLDOWN_SEC=$COOLDOWN_SEC
TRACING_DIR=$TRACING_DIR
LOG_ROOT=$LOG_ROOT
OUT_DIR=$OUT_DIR
RDH_BIN=$RDH_BIN
PARAMS_JSON=$PARAMS_JSON
SLICE=$SLICE
NPROC=$H
PARAMS

  local density
  for density in $DENSITIES; do
    local N DDIR
    N=$((density * H))
    DDIR="$OUT_DIR/d${density}"
    mkdir -p "$DDIR/reports"

    RUN_TAG="${RUN_ID_SAFE}-d${density}"

    echo "=============================="
    echo "Density factor = ${density} (instances=${N})"
    echo "=============================="

    local i unit rpt
    for i in $(seq 0 $((N - 1))); do
      unit=$(printf "hashd-%s-%03d" "$RUN_TAG" "$i")
      rpt=$(printf "%s/reports/report-%03d.json" "$DDIR" "$i")

      sudo systemd-run \
        --unit="$unit" \
        --slice="$SLICE" \
        --property=CPUAccounting=yes \
        --property=MemoryAccounting=yes \
        "$RDH_BIN" \
          --params "$PARAMS_JSON" \
          --report "$rpt" \
          --interval 1 >/dev/null
    done

    sleep "$WARMUP_SEC"

    echo "[perf] measuring sched_switch + cycles..."

    run_perf_stat "$DDIR/trace.txt" "$TRACE_SEC"

    cleanup_units
    RUN_TAG=""
    sleep "$COOLDOWN_SEC"
    echo
  done

  echo "Done."
}

main "$@"
