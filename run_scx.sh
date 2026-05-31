#!/usr/bin/env bash
set -euo pipefail

SCX_NAME="${SCX_NAME:-scx}"

sudo -v
while true; do
  sudo -n true
  sleep 60
done &
SUDO_KEEPALIVE_PID=$!

cleanup() {
  kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
}
trap cleanup EXIT

for r in 1 2 3 4 5; do
  echo "repeat $r/5: controlled tenant_app_func ($SCX_NAME)"
  RUN_ID="$(date +%Y%m%d_%H%M%S)_${SCX_NAME}_resctl_taf_r${r}" ENABLE_SUDO_KEEPALIVE=0 REPEATS=1 USE_SCHED_EXT_WRAPPER=1 ENABLE_EEVDF_LAGS=0 DENSITIES="1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20" CGROUP_LAYOUT=tenant_app_func WORKLOAD_MODE=controlled WARMUP_SEC=10 TRACE_SEC=30 COOLDOWN_SEC=10 ENABLE_RDH_REPORTS=0 ./run_ftrace.sh
  sleep 180

  echo "repeat $r/5: azure2021 tenant_app_func ($SCX_NAME)"
  RUN_ID="$(date +%Y%m%d_%H%M%S)_${SCX_NAME}_azure_taf_r${r}" ENABLE_SUDO_KEEPALIVE=0 REPEATS=1 USE_SCHED_EXT_WRAPPER=1 ENABLE_EEVDF_LAGS=0 DENSITIES="1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20" CGROUP_LAYOUT=tenant_app_func WORKLOAD_MODE=trace TRACE_LAUNCH_SCALE=20 TRACE_START_AT_FIXED_BUDGET=10 TRACE_START_AT_BUDGET_PER_INSTANCE=0.25 TRACE_SEC=30 COOLDOWN_SEC=10 ENABLE_RDH_REPORTS=0 ./run_ftrace.sh
  sleep 180
done
