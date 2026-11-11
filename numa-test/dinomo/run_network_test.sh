#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
HOST_CPU=${HOST_CPU:-2}
HOST_NODE=${HOST_NODE:-0}
MEMORY_NODE=${MEMORY_NODE:-1}
NUM_KEYS=${NUM_KEYS:-256}
BUILD_DIR=${BUILD_DIR:-$ROOT/build/numa}
offline=1
if [[ ${1:-} == --no-offline ]]; then offline=0; shift; fi
[[ $# == 0 ]] || { echo "Usage: $0 [--no-offline]" >&2; exit 2; }
for value in "$HOST_CPU" "$HOST_NODE" "$MEMORY_NODE" "$NUM_KEYS"; do
  [[ $value =~ ^[0-9]+$ ]] || { echo "Expected numeric settings" >&2; exit 2; }
done
(( NUM_KEYS >= 1 && NUM_KEYS <= 2000 )) || { echo "NUM_KEYS must be 1..2000" >&2; exit 2; }
[[ -e /sys/devices/system/node/node${HOST_NODE}/cpu${HOST_CPU} ]] || {
  echo "Host CPU does not belong to host node" >&2; exit 2;
}
if ((offline)) && [[ $HOST_NODE == "$MEMORY_NODE" ]]; then
  echo "Cannot offline the compute node" >&2; exit 2
fi
make -C "$ROOT/src/kvs/libbloom" -j4
cmake -S "$ROOT" -B "$BUILD_DIR" -DCMAKE_BUILD_TYPE=Release -DBUILD_NUMA_SERVER=ON
cmake --build "$BUILD_DIR" --target dinomo-kvs-numa dinomo-numa-client-check dinomo-route -j4
changed=0
child_pid=
cleanup() {
  local status=$?
  trap - EXIT
  if [[ -n $child_pid ]] && kill -0 "$child_pid" 2>/dev/null; then
    kill -TERM "$child_pid" 2>/dev/null || true
    wait "$child_pid" || true
  fi
  if ((changed)); then
    sudo "$SCRIPT_DIR/../numa_cpu_control.sh" restore || status=1
  fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP
args=()
if ((offline)); then
  sudo "$SCRIPT_DIR/../numa_cpu_control.sh" offline "$MEMORY_NODE"
  changed=1
  args+=(--require-offline)
fi
python3 "$SCRIPT_DIR/test_server_startup.py" --build-dir "$BUILD_DIR" \
  --host-cpu "$HOST_CPU" --memory-node "$MEMORY_NODE" --client-check --keys "$NUM_KEYS" "${args[@]}" &
child_pid=$!
wait "$child_pid"
child_pid=
