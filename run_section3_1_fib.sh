#!/usr/bin/env bash
set -euo pipefail

# Section 3.1-style density sweep for pure-Fibonacci rd-hashd.
#
# Notebook-compatible output layout (../sched-ext/notebooks/ftrace.ipynb):
#   LOG_ROOT/<RUN_ID>/
#     params.txt
#     results.csv
#     d<density>/
#       trace.txt
#       summary.txt
#       reports/*.json

DENSITIES="${DENSITIES:-1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19}"
REPEATS="${REPEATS:-1}"
WARMUP_SEC="${WARMUP_SEC:-10}"
TRACE_SEC="${TRACE_SEC:-30}"
COOLDOWN_SEC="${COOLDOWN_SEC:-5}"
SLICE="${SLICE:-faas.slice}"

REPO_ROOT="${REPO_ROOT:-$PWD}"
RDH_BIN="${RDH_BIN:-$REPO_ROOT/target/release/rd-hashd}"
PARAMS_JSON="${PARAMS_JSON:-$REPO_ROOT/rdh/params.json}"

# Keep these names to stay aligned with the existing notebook schema.
THREADS="${THREADS:-1}"
WORK_US="${WORK_US:-0}"
SLEEP_US="${SLEEP_US:-0}"

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
      echo nop > current_tracer 2>/dev/null || true
      : > set_graph_function 2>/dev/null || true
      : > set_ftrace_filter 2>/dev/null || true
    " >/dev/null 2>&1 || true
  fi
}

trap 'cleanup_units; cleanup_tracing' EXIT INT TERM

extract_json() {
  awk '
    BEGIN { started=0 }
    /^[[:space:]]*{/ { started=1 }
    started { print }
  ' "$1"
}

sum_rps_reports() {
  local report_glob="$1"
  python3 - "$report_glob" <<'PY'
import glob, json, sys

def load_json(path):
    started = False
    lines = []
    with open(path, "r", encoding="utf-8", errors="ignore") as f:
        for line in f:
            if not started and line.lstrip().startswith("{"):
                started = True
            if started:
                lines.append(line)
    if not lines:
        return {}
    try:
        return json.loads("".join(lines))
    except Exception:
        return {}

total = 0.0
for p in sorted(glob.glob(sys.argv[1])):
    total += float(load_json(p).get("rps", 0.0) or 0.0)
print(total)
PY
}

start_ftrace() {
  sudo sh -c "
    cd '$TRACING_DIR' || exit 1
    echo 0 > tracing_on
    echo nop > current_tracer
    : > trace

    echo function_graph > current_tracer
    echo schedule > set_graph_function

    echo 1 > options/funcgraph-duration
    echo 1 > options/funcgraph-proc

    echo 1 > tracing_on
  "
}

stop_ftrace_dump() {
  local outfile="$1"
  sudo sh -c "
    cd '$TRACING_DIR' || exit 1
    echo 0 > tracing_on
    cat trace
  " > "$outfile"
}

summarize_trace() {
  local infile="$1"
  awk '
  /\} \/\* schedule \*\// {
    line = $0
    # function_graph prints duration in the 2nd "|" field, e.g.:
    #   | # 2938.648 us |  } /* schedule */
    #   | ! 168.741 us  |  } /* schedule */
    #   | * 25174.75 us |  } /* schedule */
    nf = split(line, parts, /\|/)
    if (nf >= 2) {
      mid = parts[2]
      # Extract first "<number> us" token regardless of leading marker.
      if (match(mid, /[0-9]+([.][0-9]+)?[[:space:]]+us/)) {
        dur = substr(mid, RSTART, RLENGTH)
        sub(/[[:space:]]+us$/, "", dur)
        sum += dur + 0.0
        n++
      }
    }
  }
  END {
    if (n == 0)
      print "calls=0 total_us=0 avg_us=0"
    else
      printf("calls=%d total_us=%.1f avg_us=%.3f\n", n, sum, sum/n)
  }
  ' "$infile"
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
  echo "Params: threads=$THREADS, work_us=$WORK_US, sleep_us=$SLEEP_US"
  echo "Warmup=${WARMUP_SEC}s, Trace=${TRACE_SEC}s"
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
TRACING_DIR=$TRACING_DIR
LOG_ROOT=$LOG_ROOT
OUT_DIR=$OUT_DIR
RDH_BIN=$RDH_BIN
PARAMS_JSON=$PARAMS_JSON
SLICE=$SLICE
NPROC=$H
PARAMS

  CSV="$OUT_DIR/results.csv"
  EXTRA_CSV="$OUT_DIR/results_extra.csv"
  echo "density,calls,total_us,avg_us,trace_sec,warmup_sec,threads,work_us,sleep_us" > "$CSV"
  echo "density,total_rps,instances" > "$EXTRA_CSV"

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

    echo "[ftrace] starting..."
    start_ftrace
    sleep "$TRACE_SEC"
    echo "[ftrace] stopping + dumping..."
    stop_ftrace_dump "$DDIR/trace.txt"

    grep -E '\} /\* schedule \*/' "$DDIR/trace.txt" > "$DDIR/schedule_events.txt" || true

    SUM_LINE="$(summarize_trace "$DDIR/trace.txt")"
    echo "$SUM_LINE" | tee "$DDIR/summary.txt"

    calls="$(echo "$SUM_LINE" | sed -n 's/.*calls=\([0-9]*\).*/\1/p')"
    total_us="$(echo "$SUM_LINE" | sed -n 's/.*total_us=\([0-9.]*\).*/\1/p')"
    avg_us="$(echo "$SUM_LINE" | sed -n 's/.*avg_us=\([0-9.]*\).*/\1/p')"

    total_rps="$(sum_rps_reports "$DDIR/reports/report-*.json")"

    echo "${density},${calls},${total_us},${avg_us},${TRACE_SEC},${WARMUP_SEC},${THREADS},${WORK_US},${SLEEP_US}" >> "$CSV"
    echo "${density},${total_rps},${N}" >> "$EXTRA_CSV"

    cleanup_units
    RUN_TAG=""
    sleep "$COOLDOWN_SEC"
    echo
  done

  echo "Done."
  echo "Results CSV: $CSV"
}

main "$@"
