#!/usr/bin/env bash
set -euo pipefail

DENSITIES="${DENSITIES:-1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20}"
REPEATS="${REPEATS:-1}"
WARMUP_SEC="${WARMUP_SEC:-10}"
TRACE_SEC="${TRACE_SEC:-30}"
COOLDOWN_SEC="${COOLDOWN_SEC:-10}"
SLICE="${SLICE:-faas.slice}"

REPO_ROOT="${REPO_ROOT:-$PWD}"
RDH_BIN="${RDH_BIN:-$REPO_ROOT/target/release/rd-hashd}"
PARAMS_JSON="${PARAMS_JSON:-$REPO_ROOT/rdh/params.json}"

LOG_ROOT="${LOG_ROOT:-$REPO_ROOT/../sched-ext/logs/ftrace_resctl}"
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
      echo 0 > function_profile_enabled 2>/dev/null || true
      echo nop > current_tracer 2>/dev/null || true
      : > set_graph_function 2>/dev/null || true
      : > set_ftrace_filter 2>/dev/null || true
    " >/dev/null 2>&1 || true
  fi
}

trap 'cleanup_units; cleanup_tracing' EXIT INT TERM

start_ftrace() {
  sudo sh -c "
    cd '$TRACING_DIR' || exit 1
    echo 0 > tracing_on
    echo 0 > function_profile_enabled
    echo nop > current_tracer
    : > set_ftrace_filter

    echo schedule > set_ftrace_filter
    echo function > current_tracer
    echo 1 > function_profile_enabled
    echo 1 > tracing_on
  "
}

stop_ftrace_dump() {
  local outdir="$1"
  local cpu_count="$2"

  mkdir -p "$outdir/trace_stat"

  sudo sh -c "
    cd '$TRACING_DIR' || exit 1
    echo 0 > tracing_on
    echo 0 > function_profile_enabled

    for i in \$(seq 0 $((cpu_count - 1))); do
      f=trace_stat/function\$i
      [ -f \"\$f\" ] && cat \"\$f\"
    done
  " > "$outdir/trace_stat.txt"

  # per-CPU stats
  sudo sh -c "
    cd '$TRACING_DIR' || exit 1
    for i in \$(seq 0 $((cpu_count - 1))); do
      f=trace_stat/function\$i
      [ -f \"\$f\" ] && cp \"\$f\" \"$outdir/trace_stat/function\$i\"
    done
  "
}

main() {
  require_cmd sudo
  require_cmd awk
  require_cmd nproc
  require_cmd python3
  require_cmd systemd-run

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
  echo "Warmup=${WARMUP_SEC}s, Trace=${TRACE_SEC}s"
  echo

  cat > "$OUT_DIR/params.txt" <<PARAMS
RUN_ID=$RUN_ID
HOSTNAME=$(hostname)
DATE_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)
KERNEL=$(uname -r)
DENSITIES=$DENSITIES
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

  {
    echo
    echo "==== rdh/params.json ===="
    cat "$PARAMS_JSON"
  } >> "$OUT_DIR/params.txt"

  local density
  for density in $DENSITIES; do
    local N DDIR
    N=$((density * H))
    DDIR="$OUT_DIR/d${density}"
    mkdir -p "$DDIR/reports" "$DDIR/latencies"

    RUN_TAG="${RUN_ID_SAFE}-d${density}"

    echo "=============================="
    echo "Density factor = ${density} (instances=${N})"
    echo "=============================="

    local i unit rpt logdir
    for i in $(seq 0 $((N - 1))); do
      unit=$(printf "hashd-%s-%03d" "$RUN_TAG" "$i")
      rpt=$(printf "%s/reports/report-%03d.json" "$DDIR" "$i")
      logdir=$(printf "%s/latencies/logs-%03d" "$DDIR" "$i")
      mkdir -p "$logdir"

      sudo systemd-run \
        --unit="$unit" \
        --slice="$SLICE" \
        --property=CPUAccounting=yes \
        --property=MemoryAccounting=yes \
        "$RDH_BIN" \
          --params "$PARAMS_JSON" \
          --report "$rpt" \
          --log-dir "$logdir" \
          --interval 1 >/dev/null
    done

    sleep "$WARMUP_SEC"

    local trace_start_epoch trace_end_epoch trace_actual_sec
    local trace_start_utc trace_end_utc

    trace_start_epoch="$(date +%s.%N)"
    trace_start_utc="$(date -u +%Y-%m-%dT%H:%M:%S.%NZ)"
    echo "[ftrace] starting..."
    start_ftrace
    sleep "$TRACE_SEC"
    echo "[ftrace] stopping + dumping..."
    stop_ftrace_dump "$DDIR" "$H"
    trace_end_epoch="$(date +%s.%N)"
    trace_end_utc="$(date -u +%Y-%m-%dT%H:%M:%S.%NZ)"
    trace_actual_sec="$(awk -v s="$trace_start_epoch" -v e="$trace_end_epoch" 'BEGIN{printf "%.6f", e-s}')"

    cat > "$DDIR/trace_window.txt" <<TRACE_WINDOW
TRACE_CONFIG_SEC=$TRACE_SEC
TRACE_START_EPOCH=$trace_start_epoch
TRACE_END_EPOCH=$trace_end_epoch
TRACE_ACTUAL_SEC=$trace_actual_sec
TRACE_START_UTC=$trace_start_utc
TRACE_END_UTC=$trace_end_utc
TRACE_WINDOW

    cleanup_units
    RUN_TAG=""
    sleep "$COOLDOWN_SEC"
    echo
  done

  echo "Done."
}

main "$@"
