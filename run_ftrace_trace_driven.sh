#!/usr/bin/env bash
set -euo pipefail

DENSITIES="${DENSITIES:-1 5 10 20 30 50}"
REPEATS="${REPEATS:-1}"
WARMUP_SEC="${WARMUP_SEC:-10}"
TRACE_SEC="${TRACE_SEC:-30}"
COOLDOWN_SEC="${COOLDOWN_SEC:-10}"
SLICE="${SLICE:-faas.slice}"
CGROUP_LAYOUT="${CGROUP_LAYOUT:-tenant_app_func}"  # flat | app_func | tenant_app_func
FUNCS_PER_APP="${FUNCS_PER_APP:-4}"
APPS_PER_TENANT="${APPS_PER_TENANT:-4}"
USE_SCHED_EXT_WRAPPER="${USE_SCHED_EXT_WRAPPER:-0}"

REPO_ROOT="${REPO_ROOT:-$PWD}"
RDH_BIN="${RDH_BIN:-$REPO_ROOT/target/release/rd-hashd}"
PARAMS_JSON="${PARAMS_JSON:-$REPO_ROOT/rdh/params.json}"
SCHED_EXT_EXEC="${SCHED_EXT_EXEC:-$REPO_ROOT/sched_ext_exec}"
TRACE_SAMPLE_ROOT="${TRACE_SAMPLE_ROOT:-/home/janp/mphil/sched-ext/azure_traces/sampled_30s/rpi4}"

# LOG_ROOT="${LOG_ROOT:-$REPO_ROOT/../sched-ext/logs/ftrace_resctl_trace_driven_5m}"
LOG_ROOT="${LOG_ROOT:-$REPO_ROOT/../sched-ext/logs/ftrace_resctl_trace_driven_30s}"
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

slice_base_name() {
  local slice="$1"
  [[ "$slice" == *.slice ]] || {
    echo "ERROR: SLICE must end with .slice, got '$slice'" >&2
    exit 1
  }
  printf "%s" "${slice%.slice}"
}

cgroup_slice_for_instance() {
  local idx="$1"
  local base="$2"
  local app func tenant

  case "$CGROUP_LAYOUT" in
    flat)
      printf "%s.slice" "$base"
      ;;
    app_func)
      app=$((idx / FUNCS_PER_APP))
      func=$((idx % FUNCS_PER_APP))
      printf "%s-app%03d-func%03d.slice" "$base" "$app" "$func"
      ;;
    tenant_app_func)
      tenant=$((idx / (APPS_PER_TENANT * FUNCS_PER_APP)))
      app=$(((idx / FUNCS_PER_APP) % APPS_PER_TENANT))
      func=$((idx % FUNCS_PER_APP))
      printf "%s-tenant%03d-app%03d-func%03d.slice" "$base" "$tenant" "$app" "$func"
      ;;
    *)
      echo "ERROR: CGROUP_LAYOUT must be flat, app_func, or tenant_app_func; got '$CGROUP_LAYOUT'" >&2
      exit 1
      ;;
  esac
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

    # fair class (CFS)
    echo pick_next_task_fair >> set_ftrace_filter
    echo put_prev_task_fair >> set_ftrace_filter
    echo enqueue_task_fair >> set_ftrace_filter
    echo dequeue_task_fair >> set_ftrace_filter
    echo task_tick_fair >> set_ftrace_filter

    # sched_ext
    echo pick_task_scx >> set_ftrace_filter
    echo put_prev_task_scx >> set_ftrace_filter
    echo enqueue_task_scx >> set_ftrace_filter
    echo dequeue_task_scx >> set_ftrace_filter
    echo task_tick_scx >> set_ftrace_filter

    # CFS internals
    echo put_prev_entity >> set_ftrace_filter
    echo enqueue_entity >> set_ftrace_filter
    echo dequeue_entity >> set_ftrace_filter

    echo function_graph > current_tracer
    echo 0 > options/sleep-time
    echo 1 > options/graph-time
    echo 1 > options/funcgraph-duration
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

  sudo sh -c "
    cd '$TRACING_DIR' || exit 1
    for i in \$(seq 0 $((cpu_count - 1))); do
      f=trace_stat/function\$i
      [ -f \"\$f\" ] && cp \"\$f\" \"$outdir/trace_stat/function\$i\"
    done
  "
}

sample_dir_for_density() {
  local density="$1"
  printf "%s/d%02d" "$TRACE_SAMPLE_ROOT" "$density"
}

main() {
  require_cmd sudo
  require_cmd awk
  require_cmd nproc
  require_cmd python3
  require_cmd systemd-run
  require_cmd find

  if [[ "$REPEATS" != "1" ]]; then
    echo "ERROR: REPEATS=$REPEATS is not notebook-compatible. Use REPEATS=1." >&2
    exit 1
  fi

  sudo -v

  [[ -x "$RDH_BIN" ]] || { echo "ERROR: rd-hashd not executable at $RDH_BIN" >&2; exit 1; }
  if [[ "$USE_SCHED_EXT_WRAPPER" == "1" ]]; then
    [[ -x "$SCHED_EXT_EXEC" ]] || { echo "ERROR: sched_ext_exec not executable at $SCHED_EXT_EXEC" >&2; exit 1; }
  fi
  [[ -f "$PARAMS_JSON" ]] || { echo "ERROR: params file missing at $PARAMS_JSON" >&2; exit 1; }
  [[ -n "$TRACE_SAMPLE_ROOT" ]] || { echo "ERROR: TRACE_SAMPLE_ROOT must point at sampled trace dirs" >&2; exit 1; }
  [[ -d "$TRACE_SAMPLE_ROOT" ]] || { echo "ERROR: sampled trace root missing at $TRACE_SAMPLE_ROOT" >&2; exit 1; }
  [[ -d "$TRACING_DIR" ]] || { echo "ERROR: tracing dir missing at $TRACING_DIR" >&2; exit 1; }
  [[ "$FUNCS_PER_APP" =~ ^[0-9]+$ && "$FUNCS_PER_APP" -gt 0 ]] || { echo "ERROR: FUNCS_PER_APP must be a positive integer" >&2; exit 1; }
  [[ "$APPS_PER_TENANT" =~ ^[0-9]+$ && "$APPS_PER_TENANT" -gt 0 ]] || { echo "ERROR: APPS_PER_TENANT must be a positive integer" >&2; exit 1; }

  local H SLICE_BASE
  H="$(nproc)"
  SLICE_BASE="$(slice_base_name "$SLICE")"

  mkdir -p "$OUT_DIR"

  echo "Logs: $OUT_DIR"
  echo "Densities: $DENSITIES"
  echo "Trace samples: $TRACE_SAMPLE_ROOT"
  echo "Cgroup layout: $CGROUP_LAYOUT (root=$SLICE)"
  echo "sched_ext wrapper: $USE_SCHED_EXT_WRAPPER"
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
USE_SCHED_EXT_WRAPPER=$USE_SCHED_EXT_WRAPPER
SCHED_EXT_EXEC=$SCHED_EXT_EXEC
TRACE_SAMPLE_ROOT=$TRACE_SAMPLE_ROOT
SLICE=$SLICE
CGROUP_LAYOUT=$CGROUP_LAYOUT
FUNCS_PER_APP=$FUNCS_PER_APP
APPS_PER_TENANT=$APPS_PER_TENANT
NPROC=$H
PARAMS

  {
    echo
    echo "==== rdh/params.json ===="
    cat "$PARAMS_JSON"
  } >> "$OUT_DIR/params.txt"

  local density
  for density in $DENSITIES; do
    local sample_dir DDIR N
    sample_dir="$(sample_dir_for_density "$density")"
    [[ -d "$sample_dir" ]] || { echo "ERROR: missing sampled density dir $sample_dir" >&2; exit 1; }

    DDIR="$OUT_DIR/d${density}"
    mkdir -p "$DDIR/reports" "$DDIR/latencies" "$DDIR/trace_inputs"

    if [[ -f "$sample_dir/manifest.csv" ]]; then
      cp "$sample_dir/manifest.csv" "$DDIR/trace_inputs/"
    fi
    if [[ -f "$sample_dir/summary.txt" ]]; then
      cp "$sample_dir/summary.txt" "$DDIR/trace_inputs/"
    fi

    mapfile -t trace_files < <(find "$sample_dir" -maxdepth 1 -type f -name 'trace-*.csv' | sort)
    N="${#trace_files[@]}"
    [[ "$N" -gt 0 ]] || { echo "ERROR: no sampled trace CSVs found in $sample_dir" >&2; exit 1; }

    RUN_TAG="${RUN_ID_SAFE}-d${density}"

    echo "=============================="
    echo "Density factor = ${density} (instances=${N})"
    echo "Sample dir     = ${sample_dir}"
    echo "=============================="

    printf "instance,unit,slice,trace\n" > "$DDIR/cgroup_layout.csv"

    local i unit rpt logdir trace_src trace_name unit_slice
    for i in "${!trace_files[@]}"; do
      unit=$(printf "hashd-%s-%03d" "$RUN_TAG" "$i")
      rpt=$(printf "%s/reports/report-%03d.json" "$DDIR" "$i")
      logdir=$(printf "%s/latencies/logs-%03d" "$DDIR" "$i")
      trace_src="${trace_files[$i]}"
      trace_name="$(basename "$trace_src")"
      unit_slice="$(cgroup_slice_for_instance "$i" "$SLICE_BASE")"
      mkdir -p "$logdir"
      cp "$trace_src" "$DDIR/trace_inputs/$trace_name"
      printf "%d,%s,%s,%s\n" "$i" "$unit" "$unit_slice" "$trace_name" >> "$DDIR/cgroup_layout.csv"

      local -a cmd=()
      if [[ "$USE_SCHED_EXT_WRAPPER" == "1" ]]; then
        cmd+=("$SCHED_EXT_EXEC")
      fi
      cmd+=("$RDH_BIN")

      sudo systemd-run \
        --unit="$unit" \
        --slice="$unit_slice" \
        --property=CPUAccounting=yes \
        --property=MemoryAccounting=yes \
        "${cmd[@]}" \
          --params "$PARAMS_JSON" \
          --report "$rpt" \
          --log-dir "$logdir" \
          --trace-path "$trace_src" \
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
TRACE_SAMPLE_DIR=$sample_dir
TRACE_INSTANCE_COUNT=$N
TRACE_WINDOW

    cleanup_units
    RUN_TAG=""
    sleep "$COOLDOWN_SEC"
    echo
  done

  echo "Done."
}

main "$@"
