#!/usr/bin/env bash
set -euo pipefail

# ------------------ Config (override via env vars) ------------------
DENSITY="${DENSITY:-1}"
WARMUP_SECS="${WARMUP_SECS:-20}"
TRACE_SECS="${TRACE_SECS:-30}"
SLICE="${SLICE:-faas.slice}"

REPO_ROOT="${REPO_ROOT:-$HOME/mphil/resctl-demo}"
RDH_BIN="${RDH_BIN:-$REPO_ROOT/target/release/rd-hashd}"

BASE_DIR="${BASE_DIR:-$HOME/rdh/base}"
ARGS_JSON="${ARGS_JSON:-$BASE_DIR/args.json}"
TESTFILES_DIR="${TESTFILES_DIR:-$BASE_DIR/testfiles}"

TOTAL_MEMORY="${TOTAL_MEMORY:-4294967296}"   # bytes
TOTAL_SWAP="${TOTAL_SWAP:-0}"

OUT_ROOT="${OUT_ROOT:-$HOME/rdh/experiments}"
# -------------------------------------------------------------------

require_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: missing $1" >&2; exit 1; }; }

RUN_ID=""
cleanup_units() {
  [[ -z "${RUN_ID:-}" ]] && return
  local pattern="hashd-${RUN_ID}-"
  for u in $(systemctl list-units --type=service --all --no-pager --plain | awk -v p="$pattern" '$1 ~ p {print $1}'); do
    sudo systemctl stop "$u" >/dev/null 2>&1 || true
  done
}

trap cleanup_units EXIT INT TERM

# Strip leading '//' comment lines and output valid JSON only.
extract_json() {
  awk '
    BEGIN { started=0 }
    /^[[:space:]]*{/ { started=1 }
    started { print }
  ' "$1"
}

# Return rps as float (or 0 if missing / parse fails)
rps_from_report() {
  local f="$1"
  extract_json "$f" | python3 - <<'PY'
import sys, json
try:
    obj = json.load(sys.stdin)
    v = obj.get("rps", 0.0)
    # print numeric safely
    try:
        print(float(v))
    except Exception:
        print(0.0)
except Exception:
    print(0.0)
PY
}

main() {
  require_cmd python3
  require_cmd awk
  require_cmd nproc

  sudo -v  # avoid hidden sudo password prompts later

  [[ -x "$RDH_BIN" ]] || { echo "ERROR: rd-hashd not executable at $RDH_BIN" >&2; exit 1; }
  [[ -f "$ARGS_JSON" ]] || { echo "ERROR: missing $ARGS_JSON (run --prepare first)" >&2; exit 1; }
  [[ -d "$TESTFILES_DIR" ]] || { echo "ERROR: missing $TESTFILES_DIR (run --prepare first)" >&2; exit 1; }

  local H N
  H="$(nproc)"
  N="$((DENSITY * H))"

  RUN_ID="$(date +%Y%m%d-%H%M%S)"
  local OUT_DIR="$OUT_ROOT/baseline-${RUN_ID}-d${DENSITY}-H${H}-N${N}"
  mkdir -p "$OUT_DIR/reports"

  echo "=== Baseline run ==="
  echo "  density      : $DENSITY"
  echo "  nproc (H)     : $H"
  echo "  instances (N) : $N"
  echo "  warmup secs   : $WARMUP_SECS"
  echo "  trace secs    : $TRACE_SECS"
  echo "  output dir    : $OUT_DIR"
  echo

  echo "Starting $N rd-hashd instances via systemd-run..."
  for i in $(seq 0 $((N-1))); do
    local unit report
    unit=$(printf "hashd-%s-%03d" "$RUN_ID" "$i")
    report=$(printf "%s/reports/rpt-%03d.json" "$OUT_DIR" "$i")

    sudo systemd-run \
      --unit="$unit" \
      --slice="$SLICE" \
      --property=CPUAccounting=yes \
      --property=MemoryAccounting=yes \
      "$RDH_BIN" \
        --args "$ARGS_JSON" \
        --testfiles "$TESTFILES_DIR" \
        --report "$report" \
        --interval 1 \
        --total-memory "$TOTAL_MEMORY" \
        --total-swap "$TOTAL_SWAP" >/dev/null
  done

  echo "Warmup for ${WARMUP_SECS}s..."
  sleep "$WARMUP_SECS"

  # Wait (briefly) until at least one report exists and has an rps field.
  echo "Waiting for report files to appear..."
  local deadline=$((SECONDS + 10))
  while true; do
    local count
    count=$(ls "$OUT_DIR"/reports/rpt-*.json >/dev/null 2>&1; echo $?)
    if [[ "$count" -eq 0 ]]; then
      # check if rpt-000 has a non-zero rps (or any float)
      local testfile="$OUT_DIR/reports/rpt-000.json"
      if [[ -f "$testfile" ]]; then
        local v
        v="$(rps_from_report "$testfile")"
        # accept even 0.0, as long as parse works and file exists
        echo "Reports detected (example rpt-000 rps=$v)."
        break
      fi
    fi
    if (( SECONDS >= deadline )); then
      echo "ERROR: report files not ready in $OUT_DIR/reports" >&2
      echo "Try: ls -lah $OUT_DIR/reports && systemctl --failed" >&2
      exit 1
    fi
    sleep 1
  done

  # Throughput: sum rps across all reports
  local TOTAL_RPS=0.0
  for f in "$OUT_DIR"/reports/rpt-*.json; do
    TOTAL_RPS="$(python3 - <<PY
import sys
total=float(sys.argv[1])
val=float(sys.argv[2])
print(total+val)
PY
"$TOTAL_RPS" "$(rps_from_report "$f")")"
  done
  echo "Total throughput (sum of rps): $TOTAL_RPS"

  # Trace schedule() if available
  if command -v trace-cmd >/dev/null 2>&1; then
    echo "Tracing schedule() for ${TRACE_SECS}s (blocking)..."
    date
    sudo trace-cmd reset >/dev/null 2>&1 || true
    sudo trace-cmd record -p function -l schedule sleep "$TRACE_SECS" >/dev/null 2>&1
    date
    echo "Tracing finished."

    sudo trace-cmd stat > "$OUT_DIR/schedule_stat.txt" 2>/dev/null || true
    grep -E ' schedule$' "$OUT_DIR/schedule_stat.txt" > "$OUT_DIR/schedule_schedule_only.txt" || true
    echo "Saved trace-cmd stats: $OUT_DIR/schedule_stat.txt"
  else
    echo "WARN: trace-cmd not installed; skipping schedule() tracing."
  fi

  cat > "$OUT_DIR/results.txt" <<EOF
run_id=$RUN_ID
density=$DENSITY
nproc=$H
instances=$N
total_rps=$TOTAL_RPS
out_dir=$OUT_DIR
EOF

  echo "Saved summary: $OUT_DIR/results.txt"
  cleanup_units
  echo "Done."
}

main "$@"
