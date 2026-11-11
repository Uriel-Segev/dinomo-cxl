#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
make -C "$SCRIPT_DIR" build/dinomo-numa-gc-check -j4
mkdir -p "$SCRIPT_DIR/results"
evidence=$(mktemp -d "$SCRIPT_DIR/results/gc-core-XXXXXXXX")
pool_dir=$(mktemp -d /dev/shm/dinomo-gc-core-XXXXXXXX)
cleanup() {
  local status=$?
  rm -f -- "$pool_dir/pool"
  rmdir -- "$pool_dir"
  echo "Evidence: $evidence"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP
git -C "$SCRIPT_DIR" rev-parse HEAD > "$evidence/commit.txt"
"$SCRIPT_DIR/../numa_cpu_control.sh" status > "$evidence/topology.txt"
timeout --signal=TERM --kill-after=5s 90s "$SCRIPT_DIR/build/dinomo-numa-gc-check" \
  "$pool_dir/pool" "${HOST_CPU:-2}" "${MEMORY_NODE:-0}" > "$evidence/test.log" 2>&1 || {
    tail -30 "$evidence/test.log"
    exit 1
  }
tail -6 "$evidence/test.log"
