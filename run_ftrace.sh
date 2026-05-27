#!/usr/bin/env bash
set -euo pipefail

DENSITIES="${DENSITIES:-1 5 10 20}"
REPEATS="${REPEATS:-1}"
WARMUP_SEC="${WARMUP_SEC:-10}"
TRACE_SEC="${TRACE_SEC:-30}"
COOLDOWN_SEC="${COOLDOWN_SEC:-10}"
REPEAT_SLEEP_SEC="${REPEAT_SLEEP_SEC:-300}"
SLICE="${SLICE:-faas.slice}"
CGROUP_LAYOUT="${CGROUP_LAYOUT:-tenant_app_func}"  # flat | app_func | tenant_app_func
FUNCS_PER_APP="${FUNCS_PER_APP:-4}"
APPS_PER_TENANT="${APPS_PER_TENANT:-4}"
USE_SCHED_EXT_WRAPPER="${USE_SCHED_EXT_WRAPPER:-0}"
ENABLE_EEVDF_LAGS="${ENABLE_EEVDF_LAGS:-0}"
LAGS_EMA_WINDOW="${LAGS_EMA_WINDOW:-1000}"
LAGS_CGROUP_ROOT="${LAGS_CGROUP_ROOT:-}"
ENABLE_RDH_REPORTS="${ENABLE_RDH_REPORTS:-0}"

REPO_ROOT="${REPO_ROOT:-$PWD}"
RDH_BIN="${RDH_BIN:-$REPO_ROOT/target/release/rd-hashd}"
PARAMS_JSON="${PARAMS_JSON:-$REPO_ROOT/rdh/params.json}"
SCHED_EXT_EXEC="${SCHED_EXT_EXEC:-$REPO_ROOT/sched_ext_exec}"

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

start_sudo_keepalive() {
  if [[ "${SUDO_KEEPALIVE_ACTIVE:-0}" == "1" ]]; then
    return
  fi

  sudo -v
  while true; do
    sudo -n true
    sleep 60
  done &

  SUDO_KEEPALIVE_PID="$!"
  SUDO_KEEPALIVE_ACTIVE=1
  export SUDO_KEEPALIVE_ACTIVE
  trap 'kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true' EXIT
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
  local -a units=()
  local u

  while IFS= read -r u; do
    [[ -n "$u" ]] && units+=("$u")
  done < <(systemctl list-units --type=service --all --no-pager --plain | awk -v p="$pattern" '$1 ~ p {print $1}')

  if [[ "${#units[@]}" -gt 0 ]]; then
    sudo systemctl stop "${units[@]}" >/dev/null 2>&1 || true
  fi
}

record_thermal() {
  local out="$1"
  local label="$2"

  {
    echo "==== $label ===="
    echo "timestamp_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    if command -v vcgencmd >/dev/null 2>&1; then
      vcgencmd measure_temp 2>/dev/null || true
      vcgencmd get_throttled 2>/dev/null || true
    else
      echo "vcgencmd=missing"
    fi
    if [[ -r /sys/class/thermal/thermal_zone0/temp ]]; then
      awk '{ printf "thermal_zone0_millicelsius=%s\n", $1 }' /sys/class/thermal/thermal_zone0/temp
    fi
    echo
  } >> "$out"
}

record_cpu_freq() {
  local out="$1"
  local label="$2"
  local cpu

  {
    echo "==== $label ===="
    echo "timestamp_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    for cpu in /sys/devices/system/cpu/cpu[0-9]*; do
      [[ -d "$cpu/cpufreq" ]] || continue
      echo "[$(basename "$cpu")]"
      [[ -r "$cpu/cpufreq/scaling_governor" ]] && printf "scaling_governor=%s\n" "$(cat "$cpu/cpufreq/scaling_governor")"
      [[ -r "$cpu/cpufreq/scaling_cur_freq" ]] && printf "scaling_cur_freq=%s\n" "$(cat "$cpu/cpufreq/scaling_cur_freq")"
      [[ -r "$cpu/cpufreq/scaling_max_freq" ]] && printf "scaling_max_freq=%s\n" "$(cat "$cpu/cpufreq/scaling_max_freq")"
    done
    echo
  } >> "$out"
}

record_sched_ext_state() {
  local out="$1"
  local label="$2"
  local f

  {
    echo "==== $label ===="
    echo "timestamp_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    if [[ -d /sys/kernel/sched_ext ]]; then
      for f in state root/ops enable_seq nr_rejected switch_all; do
        if [[ -r "/sys/kernel/sched_ext/$f" ]]; then
          printf "%s=%s\n" "$f" "$(cat "/sys/kernel/sched_ext/$f")"
        fi
      done
      printf "scx_cmdline=%s\n" "$(pgrep -af '/scx_' | paste -sd '|' -)"
    else
      echo "sched_ext=missing"
    fi
    echo
  } >> "$out"
}

record_cgroup_cpu_state() {
  local out="$1"
  local label="$2"
  local root="$3"

  {
    echo "==== $label ===="
    echo "timestamp_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "root=$root"
    if [[ -d "$root" ]]; then
      echo "total_cgroups=$(find "$root" -type d | wc -l)"
      echo "cgroups_with_cpu_controller=$(find "$root" -type f -name cgroup.controllers -exec grep -lqw cpu {} \; | wc -l)"
      echo "cgroups_with_cpu_subtree_enabled=$(find "$root" -type f -name cgroup.subtree_control -exec grep -lqw cpu {} \; | wc -l)"
      echo "cgroups_with_cpu_stat=$(find "$root" -type f -name cpu.stat | wc -l)"
    else
      echo "root_missing=1"
    fi
    echo
  } >> "$out"
}

record_sched_ext_task_count() {
  local out="$1"
  local label="$2"
  local proc_count=0
  local thread_count=0
  local p t

  for p in $(pgrep -x rd-hashd 2>/dev/null || true); do
    if grep -q 'ext.enabled[[:space:]]*:.*1' "/proc/$p/sched" 2>/dev/null; then
      proc_count=$((proc_count + 1))
    fi
    for t in /proc/"$p"/task/[0-9]*; do
      [[ -f "$t/sched" ]] || continue
      if grep -q 'ext.enabled[[:space:]]*:.*1' "$t/sched" 2>/dev/null; then
        thread_count=$((thread_count + 1))
      fi
    done
  done

  {
    echo "==== $label ===="
    echo "timestamp_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "rd_hashd_ext_enabled_processes=$proc_count"
    echo "rd_hashd_ext_enabled_threads=$thread_count"
    echo
  } >> "$out"
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


set_eevdf_lags_sysctls() {
  local enable="$1"
  if [[ "$enable" == "1" ]]; then
    sudo sysctl -q kernel.sched_tg_load_avg_ema=1
    sudo sysctl -q kernel.sched_tg_load_avg_ema_window="$LAGS_EMA_WINDOW"
    sudo sysctl -q kernel.sched_entity_before_policy=1
    sudo sysctl -q kernel.sched_cpu_has_higher_load_task=0
    sudo sysctl -q kernel.sched_check_preempt_wakeup_latency_awareness=0
  else
    sudo sysctl -q kernel.sched_tg_load_avg_ema=0 2>/dev/null || true
    sudo sysctl -q kernel.sched_tg_load_avg_ema_window=0 2>/dev/null || true
    sudo sysctl -q kernel.sched_entity_before_policy=0 2>/dev/null || true
    sudo sysctl -q kernel.sched_cpu_has_higher_load_task=0 2>/dev/null || true
    sudo sysctl -q kernel.sched_check_preempt_wakeup_latency_awareness=0 2>/dev/null || true
  fi
}

record_eevdf_lags_sysctls() {
  local out="$1"
  {
    echo "==== EEVDF-LAGS sysctls ===="
    sysctl kernel.sched_tg_load_avg_ema 2>/dev/null || true
    sysctl kernel.sched_tg_load_avg_ema_window 2>/dev/null || true
    sysctl kernel.sched_entity_before_policy 2>/dev/null || true
    sysctl kernel.sched_cpu_has_higher_load_task 2>/dev/null || true
    sysctl kernel.sched_check_preempt_wakeup_latency_awareness 2>/dev/null || true
  } >> "$out"
}

enable_cpu_controller_tree() {
  local root="$1"

  [[ -d "$root" ]] || return 0

  # cgroup v2 exposes cpu.* files to children only if +cpu is enabled in the
  # parent's subtree_control. Do this top-down through the experiment tree.
  find "$root" -type d |
    awk '{ print gsub("/", "/"), $0 }' |
    sort -n |
    cut -d' ' -f2- |
    while IFS= read -r d; do
      find "$d" -mindepth 1 -maxdepth 1 -type d | grep -q . || continue
      [[ -f "$d/cgroup.controllers" ]] || continue
      grep -qw cpu "$d/cgroup.controllers" || continue
      echo +cpu | sudo tee "$d/cgroup.subtree_control" >/dev/null || true
    done
}

mark_eevdf_lags_cgroups() {
  local root="$1"
  local out="$2"

  {
    echo "LAGS_CGROUP_ROOT=$root"
    if [[ ! -d "$root" ]]; then
      echo "ERROR: cgroup root does not exist"
      return 1
    fi
  } > "$out"

  # Mark experiment cgroups latency aware
  sudo find "$root" -name cpu.latency_awareness -exec sh -c 'echo 1 > "$1"' _ {} \;

  find "$root" -type d | sort |
    while IFS= read -r d; do
      {
        echo
        echo "[$d]"
        [[ -f "$d/cgroup.controllers" ]] && printf "cgroup.controllers=%s\n" "$(cat "$d/cgroup.controllers")"
        [[ -f "$d/cgroup.subtree_control" ]] && printf "cgroup.subtree_control=%s\n" "$(cat "$d/cgroup.subtree_control")"
        [[ -f "$d/cpu.latency_awareness" ]] && printf "cpu.latency_awareness=%s\n" "$(cat "$d/cpu.latency_awareness")"
        [[ -f "$d/cpu.load_avg_ema" ]] && printf "cpu.load_avg_ema=%s\n" "$(cat "$d/cpu.load_avg_ema")"
      } >> "$out"
    done
}

reset_eevdf_lags_cgroups() {
  local root="$1"
  [[ -d "$root" ]] || return 0
  sudo find "$root" -name cpu.latency_awareness -exec sh -c 'echo 0 > "$1"' _ {} \; 2>/dev/null || true
}

trap 'cleanup_units; cleanup_tracing; set_eevdf_lags_sysctls 0; reset_eevdf_lags_cgroups "${LAGS_CGROUP_ROOT:-}"' EXIT INT TERM

start_ftrace() {
  sudo sh -c "
    cd '$TRACING_DIR' || exit 1
    echo 0 > tracing_on
    echo 0 > function_profile_enabled
    echo nop > current_tracer
    : > set_ftrace_filter

    echo schedule > set_ftrace_filter

    # fair class (CFS/EEVDF)
    echo dequeue_task_fair >> set_ftrace_filter
    echo pick_next_task_fair >> set_ftrace_filter
    echo pick_task_fair >> set_ftrace_filter

    # CFS/EEVDF internals
    echo put_prev_entity >> set_ftrace_filter

    # sched_ext
    echo dequeue_task_scx >> set_ftrace_filter
    echo balance_scx >> set_ftrace_filter
    echo pick_task_scx >> set_ftrace_filter
    echo put_prev_task_scx >> set_ftrace_filter
    echo set_next_task_scx >> set_ftrace_filter

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

  [[ "$REPEATS" =~ ^[0-9]+$ && "$REPEATS" -gt 0 ]] || { echo "ERROR: REPEATS must be a positive integer" >&2; exit 1; }
  [[ "$REPEAT_SLEEP_SEC" =~ ^[0-9]+$ ]] || { echo "ERROR: REPEAT_SLEEP_SEC must be a non-negative integer" >&2; exit 1; }

  if [[ "$REPEATS" -gt 1 ]]; then
    local requested_repeats="$REPEATS"
    local rep

    start_sudo_keepalive

    for rep in $(seq 1 "$requested_repeats"); do
      echo "=============================="
      echo "Repeat $rep / $requested_repeats"
      echo "Started: $(date --iso-8601=seconds)"
      echo "=============================="

      RUN_ID="$(date +%Y%m%d_%H%M%S)"
      OUT_DIR="${LOG_ROOT}/${RUN_ID}"
      RUN_ID_SAFE="$(echo "$RUN_ID" | tr -c 'A-Za-z0-9_.-' '_')"
      REPEATS=1 main "$@"

      if [[ "$rep" -lt "$requested_repeats" ]]; then
        echo "Finished repeat $rep / $requested_repeats"
        echo "Sleeping ${REPEAT_SLEEP_SEC}s before next repeat..."
        echo
        sleep "$REPEAT_SLEEP_SEC"
      fi
    done

    echo "Finished all repeats."
    return
  fi

  start_sudo_keepalive

  [[ -x "$RDH_BIN" ]] || { echo "ERROR: rd-hashd not executable at $RDH_BIN" >&2; exit 1; }
  [[ -f "$PARAMS_JSON" ]] || { echo "ERROR: params file missing at $PARAMS_JSON" >&2; exit 1; }
  [[ -d "$TRACING_DIR" ]] || { echo "ERROR: tracing dir missing at $TRACING_DIR" >&2; exit 1; }
  [[ "$FUNCS_PER_APP" =~ ^[0-9]+$ && "$FUNCS_PER_APP" -gt 0 ]] || { echo "ERROR: FUNCS_PER_APP must be a positive integer" >&2; exit 1; }
  [[ "$APPS_PER_TENANT" =~ ^[0-9]+$ && "$APPS_PER_TENANT" -gt 0 ]] || { echo "ERROR: APPS_PER_TENANT must be a positive integer" >&2; exit 1; }
  [[ "$USE_SCHED_EXT_WRAPPER" == "0" || "$USE_SCHED_EXT_WRAPPER" == "1" ]] || { echo "ERROR: USE_SCHED_EXT_WRAPPER must be 0 or 1" >&2; exit 1; }
  [[ "$ENABLE_EEVDF_LAGS" == "0" || "$ENABLE_EEVDF_LAGS" == "1" ]] || { echo "ERROR: ENABLE_EEVDF_LAGS must be 0 or 1" >&2; exit 1; }
  [[ "$ENABLE_RDH_REPORTS" == "0" || "$ENABLE_RDH_REPORTS" == "1" ]] || { echo "ERROR: ENABLE_RDH_REPORTS must be 0 or 1" >&2; exit 1; }
  [[ "$LAGS_EMA_WINDOW" =~ ^[0-9]+$ ]] || { echo "ERROR: LAGS_EMA_WINDOW must be a non-negative integer" >&2; exit 1; }
  if [[ "$USE_SCHED_EXT_WRAPPER" == "1" ]]; then
    [[ -x "$SCHED_EXT_EXEC" ]] || { echo "ERROR: sched_ext wrapper not executable at $SCHED_EXT_EXEC" >&2; exit 1; }
  fi

  local H SLICE_BASE
  H="$(nproc)"
  SLICE_BASE="$(slice_base_name "$SLICE")"
  if [[ -z "$LAGS_CGROUP_ROOT" ]]; then
    LAGS_CGROUP_ROOT="/sys/fs/cgroup/$SLICE"
  fi

  set_eevdf_lags_sysctls 0
  if [[ "$ENABLE_EEVDF_LAGS" == "1" ]]; then
    set_eevdf_lags_sysctls 1
  fi

  mkdir -p "$OUT_DIR"

  echo "Logs: $OUT_DIR"
  echo "Densities: $DENSITIES"
  echo "Cgroup layout: $CGROUP_LAYOUT (root=$SLICE)"
  echo "sched_ext wrapper: $USE_SCHED_EXT_WRAPPER"
  echo "EEVDF-LAGS: $ENABLE_EEVDF_LAGS (ema_window=$LAGS_EMA_WINDOW, root=$LAGS_CGROUP_ROOT)"
  echo "rd-hashd reports: $ENABLE_RDH_REPORTS"
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
ENABLE_RDH_REPORTS=$ENABLE_RDH_REPORTS
USE_SCHED_EXT_WRAPPER=$USE_SCHED_EXT_WRAPPER
SCHED_EXT_EXEC=$SCHED_EXT_EXEC
ENABLE_EEVDF_LAGS=$ENABLE_EEVDF_LAGS
LAGS_EMA_WINDOW=$LAGS_EMA_WINDOW
LAGS_CGROUP_ROOT=$LAGS_CGROUP_ROOT
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
    echo
  } >> "$OUT_DIR/params.txt"
  record_eevdf_lags_sysctls "$OUT_DIR/params.txt"
  record_cpu_freq "$OUT_DIR/cpu_freq.txt" "run_start"
  record_sched_ext_state "$OUT_DIR/sched_ext_state.txt" "run_start"

  local density
  for density in $DENSITIES; do
    local N DDIR
    N=$((density * H))
    DDIR="$OUT_DIR/d${density}"
    mkdir -p "$DDIR/latencies"
    if [[ "$ENABLE_RDH_REPORTS" == "1" ]]; then
      mkdir -p "$DDIR/reports"
    fi

    RUN_TAG="${RUN_ID_SAFE}-d${density}"

    echo "=============================="
    echo "Density factor = ${density} (instances=${N})"
    echo "=============================="

    printf "instance,unit,slice\n" > "$DDIR/cgroup_layout.csv"
    record_thermal "$DDIR/thermal.txt" "before_start"

    local i unit rpt logdir unit_slice
    for i in $(seq 0 $((N - 1))); do
      unit=$(printf "hashd-%s-%03d" "$RUN_TAG" "$i")
      rpt=$(printf "%s/reports/report-%03d.json" "$DDIR" "$i")
      logdir=$(printf "%s/latencies/logs-%03d" "$DDIR" "$i")
      unit_slice="$(cgroup_slice_for_instance "$i" "$SLICE_BASE")"
      mkdir -p "$logdir"
      printf "%d,%s,%s\n" "$i" "$unit" "$unit_slice" >> "$DDIR/cgroup_layout.csv"

      local -a cmd=()
      if [[ "$USE_SCHED_EXT_WRAPPER" == "1" ]]; then
        cmd+=("$SCHED_EXT_EXEC")
      fi
      cmd+=("$RDH_BIN")
      cmd+=(--params "$PARAMS_JSON" --log-dir "$logdir" --interval 1)
      if [[ "$ENABLE_RDH_REPORTS" == "1" ]]; then
        cmd+=(--report "$rpt")
      fi

      sudo systemd-run \
        --unit="$unit" \
        --slice="$unit_slice" \
        --property=CPUAccounting=yes \
        --property=MemoryAccounting=yes \
        --property=TimeoutStopSec=5s \
        --property=KillMode=control-group \
        "${cmd[@]}" >/dev/null
    done

    enable_cpu_controller_tree "$LAGS_CGROUP_ROOT"
    if [[ "$ENABLE_EEVDF_LAGS" == "1" ]]; then
      mark_eevdf_lags_cgroups "$LAGS_CGROUP_ROOT" "$DDIR/lags_cgroups.txt"
    else
      reset_eevdf_lags_cgroups "$LAGS_CGROUP_ROOT"
    fi

    sleep "$WARMUP_SEC"
    record_thermal "$DDIR/thermal.txt" "before_trace"
    record_cgroup_cpu_state "$DDIR/cgroup_cpu_state.txt" "before_trace" "$LAGS_CGROUP_ROOT"
    record_sched_ext_task_count "$DDIR/sched_ext_task_count.txt" "before_trace"

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

    if [[ "$ENABLE_EEVDF_LAGS" == "1" ]]; then
      mark_eevdf_lags_cgroups "$LAGS_CGROUP_ROOT" "$DDIR/lags_cgroups_after.txt"
    fi

    record_thermal "$DDIR/thermal.txt" "after_trace_before_cleanup"
    record_cgroup_cpu_state "$DDIR/cgroup_cpu_state.txt" "after_trace_before_cleanup" "$LAGS_CGROUP_ROOT"
    record_sched_ext_task_count "$DDIR/sched_ext_task_count.txt" "after_trace_before_cleanup"
    cleanup_units
    RUN_TAG=""
    record_thermal "$DDIR/thermal.txt" "after_cleanup"
    sleep "$COOLDOWN_SEC"
    echo
  done

  echo "Done."
  record_cpu_freq "$OUT_DIR/cpu_freq.txt" "run_end"
  record_sched_ext_state "$OUT_DIR/sched_ext_state.txt" "run_end"
}

main "$@"
