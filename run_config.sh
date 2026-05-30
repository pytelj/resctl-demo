#!/usr/bin/env bash
set -euo pipefail

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

ENABLE_SUDO_KEEPALIVE=0 CGROUP_LAYOUT=flat ./run_ftrace.sh
ENABLE_SUDO_KEEPALIVE=0 CGROUP_LAYOUT=app_func ./run_ftrace.sh
ENABLE_SUDO_KEEPALIVE=0 CGROUP_LAYOUT=tenant_app_func ./run_ftrace.sh
