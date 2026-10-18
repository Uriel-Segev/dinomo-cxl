#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
HOST_CPU=${HOST_CPU:-2}
HOST_NODE=${HOST_NODE:-0}
MEMORY_NODE=${MEMORY_NODE:-1}
NUM_KEYS=${NUM_KEYS:-1000}
offline=1
if [[ ${1:-} == --no-offline ]]; then
  offline=0
  shift
fi
[[ $# == 0 ]] || {
  echo "Usage: ./run_milestone.sh [--no-offline]" >&2
  exit 2
}
for value in "$HOST_CPU" "$HOST_NODE" "$MEMORY_NODE" "$NUM_KEYS"; do
  [[ $value =~ ^[0-9]+$ ]] || { echo "Expected nonnegative numeric settings" >&2; exit 2; }
done
[[ -e /sys/devices/system/node/node${HOST_NODE}/cpu${HOST_CPU} ]] || {
  echo "CPU $HOST_CPU does not belong to host node $HOST_NODE" >&2
  exit 2
}
if ((offline)) && [[ $HOST_NODE == "$MEMORY_NODE" ]]; then
  echo "Compute and memory nodes must differ when offlining CPUs" >&2
  exit 2
fi
make -C "$SCRIPT_DIR" -j4
if ((offline)); then sudo -v; fi
mkdir -p "$SCRIPT_DIR/results"
result_dir=$(mktemp -d "$SCRIPT_DIR/results/milestone-XXXXXXXX")
pool_dir=$(mktemp -d /dev/shm/dinomo-numa-XXXXXXXX)
changed=0
cleanup() {
  local status=$?
  trap - EXIT
  if ((changed)); then
    sudo "$SCRIPT_DIR/../numa_cpu_control.sh" restore || status=1
  fi
  # Only this run owns this temporary pool; the RDMA /dev/shm/pool is untouched.
  rm -f -- "$pool_dir/pool"
  rmdir -- "$pool_dir"
  echo "Evidence: $result_dir"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

if ((offline)); then
  sudo "$SCRIPT_DIR/../numa_cpu_control.sh" offline "$MEMORY_NODE"
  changed=1
  # cpulist is online-only on this kernel. Check that no CPUs remain online.
  [[ -z $(<"/sys/devices/system/node/node${MEMORY_NODE}/cpulist") ]] || {
    echo "Memory node still has online CPUs" >&2
    exit 1
  }
fi
{
  date -u --iso-8601=seconds
  echo "HOST_CPU=$HOST_CPU HOST_NODE=$HOST_NODE MEMORY_NODE=$MEMORY_NODE NUM_KEYS=$NUM_KEYS"
  "$SCRIPT_DIR/../numa_cpu_control.sh" status
} | tee "$result_dir/topology.txt"
timeout --signal=TERM --kill-after=5s 90s \
  "$SCRIPT_DIR/build/dinomo-numa-milestone" "$pool_dir/pool" \
  "$HOST_CPU" "$MEMORY_NODE" "$NUM_KEYS" \
  >"$result_dir/test.log" 2>&1 || {
    tail -60 "$result_dir/test.log"
    exit 1
  }
tail -8 "$result_dir/test.log"
