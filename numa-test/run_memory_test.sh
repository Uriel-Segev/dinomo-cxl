#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
HOST_NODE=${HOST_NODE:-0}
MEMORY_NODE=${MEMORY_NODE:-1}
SIZE_MB=${SIZE_MB:-256}
DURATION=${DURATION:-3}
REPETITIONS=${REPETITIONS:-3}
THREADS=${THREADS:-8}
ATOMIC_THREADS=${ATOMIC_THREADS:-1}
RESULTS_DIR=${RESULTS_DIR:-"${SCRIPT_DIR}/results"}
KEEP_OFFLINE=0

usage() {
  cat <<'EOF'
Usage: ./run_memory_test.sh TEST [--keep-offline]

TEST is one of:
  read-bandwidth   Sequential read bandwidth with one worker
  write-bandwidth  Sequential write bandwidth with one worker
  concurrent-read  Random reads from several CPU cores
  atomic           Random atomic fetch-add operations
  mixed            60% reads, 30% writes, and 10% atomic operations
  all              Run every test above

Environment overrides:
  HOST_NODE=0 MEMORY_NODE=1 SIZE_MB=256 DURATION=3 REPETITIONS=3
  THREADS=8 ATOMIC_THREADS=1 RESULTS_DIR=/path/to/results
EOF
}

[[ $# -ge 1 && $# -le 2 ]] || { usage; exit 1; }
requested_test=$1
if [[ ${2:-} == --keep-offline ]]; then
  KEEP_OFFLINE=1
elif [[ $# -eq 2 ]]; then
  usage
  exit 1
fi

case $requested_test in
  read-bandwidth|write-bandwidth|concurrent-read|atomic|mixed)
    tests=("$requested_test")
    ;;
  all)
    tests=(read-bandwidth write-bandwidth concurrent-read atomic mixed)
    ;;
  *)
    usage
    exit 1
    ;;
esac

expand_cpu_list() {
  local list=$1 item start end cpu
  IFS=',' read -ra items <<< "$list"
  for item in "${items[@]}"; do
    if [[ $item == *-* ]]; then
      start=${item%-*}
      end=${item#*-}
      for ((cpu = start; cpu <= end; ++cpu)); do
        printf '%s\n' "$cpu"
      done
    else
      printf '%s\n' "$item"
    fi
  done
}

[[ $HOST_NODE != "$MEMORY_NODE" ]] || {
  echo "HOST_NODE and MEMORY_NODE must differ" >&2
  exit 1
}
for node in "$HOST_NODE" "$MEMORY_NODE"; do
  [[ -r /sys/devices/system/node/node${node}/cpulist ]] || {
    echo "NUMA node ${node} does not exist" >&2
    exit 1
  }
done

physical_cpus=()
all_host_cpus=()
while read -r cpu; do
  [[ -r /sys/devices/system/cpu/cpu${cpu}/topology/thread_siblings_list ]] || continue
  all_host_cpus+=("$cpu")
  siblings=$(</sys/devices/system/cpu/cpu${cpu}/topology/thread_siblings_list)
  primary=${siblings%%,*}
  primary=${primary%%-*}
  if [[ $cpu == "$primary" && $cpu != 0 ]]; then
    physical_cpus+=("$cpu")
  fi
done < <(expand_cpu_list "$(<"/sys/devices/system/node/node${HOST_NODE}/cpulist")")

required_threads=$THREADS
if ((ATOMIC_THREADS > required_threads)); then
  required_threads=$ATOMIC_THREADS
fi
if (("${#physical_cpus[@]}" < required_threads)); then
  physical_cpus=("${all_host_cpus[@]}")
fi
if (("${#physical_cpus[@]}" < required_threads)); then
  echo "Requested ${required_threads} threads but node ${HOST_NODE} has only ${#physical_cpus[@]} usable CPUs" >&2
  exit 1
fi
cpu_csv=$(IFS=,; echo "${physical_cpus[*]:0:required_threads}")

make -C "$SCRIPT_DIR"
sudo -v
mkdir -p "$RESULTS_DIR"
timestamp=$(date -u +%Y%m%dT%H%M%SZ)
result_file=${RESULTS_DIR}/memory-suite-${requested_test}-${timestamp}.csv
printf '%s\n' \
  'repetition,access,test,memory_node,threads,size_mb,duration_s,operations,mops,logical_gib_s,ns_per_op,placement_samples,placement_on_target' \
  > "$result_file"

offlined=0
cleanup() {
  if ((offlined == 1 && KEEP_OFFLINE == 0)); then
    sudo "${SCRIPT_DIR}/numa_cpu_control.sh" restore
  fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

sudo "${SCRIPT_DIR}/numa_cpu_control.sh" offline "$MEMORY_NODE"
offlined=1

for test_name in "${tests[@]}"; do
  case $test_name in
    read-bandwidth|write-bandwidth)
      test_threads=1
      ;;
    atomic)
      test_threads=$ATOMIC_THREADS
      ;;
    concurrent-read|mixed)
      test_threads=$THREADS
      ;;
  esac
  echo "Running ${test_name} with ${test_threads} thread(s)..."
  for ((repetition = 1; repetition <= REPETITIONS; ++repetition)); do
    for memory_node in "$HOST_NODE" "$MEMORY_NODE"; do
      if [[ $memory_node == "$HOST_NODE" ]]; then
        access=local
      else
        access=remote
      fi
      output=$("${SCRIPT_DIR}/numa_workload" \
        --test "$test_name" \
        --cpus "$cpu_csv" \
        --threads "$test_threads" \
        --memory-node "$memory_node" \
        --size-mb "$SIZE_MB" \
        --duration "$DURATION")
      printf '%s,%s,%s\n' "$repetition" "$access" "$output" | tee -a "$result_file"
    done
  done
done

echo
echo "Raw results: ${result_file}"
"${SCRIPT_DIR}/show_memory_results.sh" "$result_file"
if ((KEEP_OFFLINE == 1)); then
  echo "Node ${MEMORY_NODE} CPUs remain offline. Restore with:"
  echo "  sudo ${SCRIPT_DIR}/numa_cpu_control.sh restore"
fi
