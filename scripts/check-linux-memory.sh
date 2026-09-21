#!/bin/sh
# CI-only, isolated transient systemd unit. Never invoked by setup/build.
set -eu
[ "$(uname -s)" = Linux ] || { echo 'Linux required' >&2; exit 2; }
[ "$#" = 1 ] || { echo 'Usage: check-linux-memory.sh native-memory-fixture' >&2; exit 2; }
stiff_unit="stiff-memory-check-$$"
stiff_fixture=$(realpath "$1")
cleanup() { sudo systemctl reset-failed "$stiff_unit.service" >/dev/null 2>&1 || true; }
trap cleanup EXIT
set +e
sudo systemd-run --unit="$stiff_unit" --wait --pipe \
  --property=MemoryMax=64M --property=MemorySwapMax=0 \
  --property=TimeoutStartSec=10 --property=RuntimeMaxSec=10 \
  "$stiff_fixture" resident
stiff_status=$?
set -e
[ "$stiff_status" -ne 0 ] || { echo 'Memory stress unexpectedly survived' >&2; exit 1; }
stiff_result=$(sudo systemctl show "$stiff_unit.service" --property=Result --value)
[ "$stiff_result" = oom-kill ] || { echo "Expected kernel oom-kill, got $stiff_result" >&2; exit 1; }
echo 'Kernel cgroup resident-memory limit enforced.'
