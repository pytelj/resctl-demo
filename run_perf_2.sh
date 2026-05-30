#!/usr/bin/env bash
set -euo pipefail

# Measures "scheduling overhead" correctly as:
#   (A) context-switch rate + migrations (perf stat)
#   (B) %CPU in scheduler-related kernel functions (perf record/report)
#
# Outputs per density directory:
#   - perf_stat.txt                 (raw perf stat output)
#   - perf_stat_parsed.txt          (easy-to-grep key metrics)
#   - perf_sched_report.txt         (perf report focused on scheduler symbols)
#   - perf_sched_report_full.txt    (full perf report)
#   - trace_window.txt              (timing metadata)
#   - params.txt                    (run metadata)

DENSITIES="${DENSITIES:-1 5 10 15 20}"
REPEATS="${REPEATS:-1}"
WARMUP_SEC="${WARMUP_SEC:-5}"
TRACE_SEC="${TRACE_SEC:-15}"
COOLDOWN_SEC="${COOLDOWN_SEC:-5}"
SLICE="${SLICE:-faas.slice}"
PERF_STAT="${PERF_STAT:-0}"
PERF_SCHED="${PERF_SCHED:-1}"

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

# Scheduler symbol set for perf report filtering.
# You can extend this depending on what you consider "scheduler overhead".
SCHED_REGEX_DEFAULT='(__schedule|schedule|pick_next_task|finish_task_switch|context_switch|try_to_wake_up|ttwu_do_wakeup|enqueue_task|dequeue_task|wake_up_new_task|psi_task_switch|update_rq_clock|rcu_note_context_switch)'
SCHED_REGEX="${SCHED_REGEX:-$SCHED_REGEX_DEFAULT}"

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

trap 'cleanup_units' EXIT INT TERM

# Run perf stat system-wide for TRACE_SEC, output to file.
# Uses task-clock as denominator and captures context-switch/migration rate.
run_perf_stat() {
  local outdir="$1"
  local duration="$2"

  # -a: system-wide
  # --no-big-num: easier parsing
  # -x, : CSV
  # -e: explicit events
  sudo perf stat -a --no-big-num -x, \
    -e task-clock,context-switches,cpu-migrations,page-faults,cycles,instructions,branches,branch-misses \
    -- sleep "$duration" \
    2> "$outdir/perf_stat.csv" || true

  # Also keep a human-friendly version
  sudo perf stat -a \
    -e task-clock,context-switches,cpu-migrations,page-faults,cycles,instructions,branches,branch-misses \
    -- sleep 0 \
    2>/dev/null || true

  # Parse key metrics into a simple text file (best-effort).
  # CSV format: value,unit,event,run_time,percent,metric_name
  {
    echo "TRACE_SEC=$duration"
    awk -F, '
      function trim(s){gsub(/^[ \t]+|[ \t]+$/, "", s); return s}
      $3=="task-clock"        {print "TASK_CLOCK_MS=" trim($1)}
      $3=="context-switches"  {print "CONTEXT_SWITCHES=" trim($1)}
      $3=="cpu-migrations"    {print "CPU_MIGRATIONS=" trim($1)}
      $3=="cycles"            {print "CYCLES=" trim($1)}
      $3=="instructions"      {print "INSTRUCTIONS=" trim($1)}
      $3=="page-faults"       {print "PAGE_FAULTS=" trim($1)}
      END{}
    ' "$outdir/perf_stat.csv" 2>/dev/null || true
  } > "$outdir/perf_stat_parsed.txt"

  # Also save raw stderr-style output (some people prefer it)
  # Convert CSV to readable-ish table:
  awk -F, '
    BEGIN { printf "%-20s %-18s %-12s\n", "EVENT", "VALUE", "UNIT"; printf "%s\n", "-----------------------------------------------------------" }
    $3!="" && $1!="" { printf "%-20s %-18s %-12s\n", $3, $1, $2 }
  ' "$outdir/perf_stat.csv" > "$outdir/perf_stat.txt" 2>/dev/null || true
}

# Record samples and then produce a report showing %CPU in scheduler functions.
# This measures CPU time attribution (what % utilisation is scheduler code).
run_perf_sched_profile() {
  local outdir="$1"
  local duration="$2"

  local data="$outdir/perf.data"
  local report_full="$outdir/perf_sched_report_full.txt"
  local report_sched="$outdir/perf_sched_report.txt"

  # -a: system wide
  # -g: callgraph (if supported)
  # -F: sample frequency (keep moderate to reduce overhead)
  # We record in a fixed window and then produce a report.
  sudo perf record -a -g -F 199 -o "$data" -- sleep "$duration" >/dev/null 2>&1 || {
    echo "WARN: perf record failed (insufficient perms? no perf_event_paranoid access?)." >&2
    echo "You may need: sudo sysctl kernel.perf_event_paranoid=1 (or 0) and kernel.kptr_restrict=0." >&2
    return 0
  }

  # Full report (callgraph + symbol %)
  sudo perf report --stdio -i "$data" --no-children --percent-limit 0.5 > "$report_full" 2>/dev/null || true

  # Focused report: grep scheduler-related symbols.
  # This isn't perfect (symbols may be inlined/renamed), but it's very useful for density sweeps.
  {
    echo "SCHED_REGEX=$SCHED_REGEX"
    echo
    grep -E "$SCHED_REGEX" "$report_full" || true
  } > "$report_sched"
}

main() {
  require_cmd sudo
  require_cmd awk
  require_cmd nproc
  require_cmd systemd-run
  require_cmd perf
  require_cmd grep
  require_cmd sed
  require_cmd date
  require_cmd uname
  require_cmd hostname

  if [[ "$REPEATS" != "1" ]]; then
    echo "ERROR: REPEATS=$REPEATS is not notebook-compatible. Use REPEATS=1." >&2
    exit 1
  fi

  sudo -v

  [[ -x "$RDH_BIN" ]] || { echo "ERROR: rd-hashd not executable at $RDH_BIN" >&2; exit 1; }
  [[ -f "$PARAMS_JSON" ]] || { echo "ERROR: params file missing at $PARAMS_JSON" >&2; exit 1; }

  local H
  H="$(nproc)"

  mkdir -p "$OUT_DIR"

  echo "Logs: $OUT_DIR"
  echo "Densities: $DENSITIES"
  echo "Params: threads=$THREADS, work_us=$WORK_US, sleep_us=$SLEEP_US"
  echo "Warmup=${WARMUP_SEC}s, Trace=${TRACE_SEC}s, Cooldown=${COOLDOWN_SEC}s"
  echo "Perf stat: ${PERF_STAT}, Perf sched: ${PERF_SCHED}"
  echo "Scheduler symbol regex: $SCHED_REGEX"
  echo

  cat > "$OUT_DIR/params.txt" <<PARAMS
RUN_ID=$RUN_ID
HOSTNAME=$(hostname)
DATE_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)
KERNEL=$(uname -r)
DENSITIES=$DENSITIES
THREADS=$THREADS
WORK_US=$WORK_US
SLEEP_US=$SLEEP_US
WARMUP_SEC=$WARMUP_SEC
TRACE_SEC=$TRACE_SEC
COOLDOWN_SEC=$COOLDOWN_SEC
PERF_STAT=$PERF_STAT
PERF_SCHED=$PERF_SCHED
LOG_ROOT=$LOG_ROOT
OUT_DIR=$OUT_DIR
RDH_BIN=$RDH_BIN
PARAMS_JSON=$PARAMS_JSON
SLICE=$SLICE
NPROC=$H
SCHED_REGEX=$SCHED_REGEX
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

    local trace_start_epoch trace_end_epoch trace_actual_sec
    local trace_start_utc trace_end_utc

    trace_start_epoch="$(date +%s.%N)"
    trace_start_utc="$(date -u +%Y-%m-%dT%H:%M:%S.%NZ)"
    echo "[perf] collecting perf stat + perf record for ${TRACE_SEC}s ..."

    if [[ "$PERF_STAT" == "1" ]]; then
      run_perf_stat "$DDIR" "$TRACE_SEC"
    fi
    if [[ "$PERF_SCHED" == "1" ]]; then
      run_perf_sched_profile "$DDIR" "$TRACE_SEC"
    fi

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

    # Stop workload instances
    cleanup_units
    RUN_TAG=""

    sleep "$COOLDOWN_SEC"
    echo
  done

  echo "Done."
}

main "$@"
