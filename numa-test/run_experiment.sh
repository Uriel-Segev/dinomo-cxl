#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
HOST_NODE=${HOST_NODE:-0}
MEMORY_NODE=${MEMORY_NODE:-1}
SIZE_MB=${SIZE_MB:-256}
PASSES=${PASSES:-3}
REPETITIONS=${REPETITIONS:-5}
HOST_CPU=${HOST_CPU:-}
KEEP_OFFLINE=0
RESULTS_DIR=${RESULTS_DIR:-"${SCRIPT_DIR}/results"}

usage() {
  cat <<'EOF'
Usage: ./run_experiment.sh [--keep-offline]

Runs local-vs-remote latency before and after turning MEMORY_NODE into a
memory-only node. By default, all CPUs are restored when the script exits.

Environment overrides:
  HOST_NODE=0 MEMORY_NODE=1 HOST_CPU=2 SIZE_MB=256 PASSES=3 REPETITIONS=5
  RESULTS_DIR=/path/to/results
EOF
}

if [[ ${1:-} == --keep-offline ]]; then
  KEEP_OFFLINE=1
  shift
fi
[[ $# -eq 0 ]] || { usage; exit 1; }
[[ $HOST_NODE != "$MEMORY_NODE" ]] || {
  echo "HOST_NODE and MEMORY_NODE must differ" >&2
  exit 1
}
[[ -r /sys/devices/system/node/node${HOST_NODE}/cpulist ]] || {
  echo "Host NUMA node ${HOST_NODE} does not exist" >&2
  exit 1
}
[[ -r /sys/devices/system/node/node${MEMORY_NODE}/cpulist ]] || {
  echo "Memory NUMA node ${MEMORY_NODE} does not exist" >&2
  exit 1
}

if [[ -z $HOST_CPU ]]; then
  IFS=',' read -ra cpu_groups <<< "$(<"/sys/devices/system/node/node${HOST_NODE}/cpulist")"
  for group in "${cpu_groups[@]}"; do
    candidate=${group%%-*}
    if [[ $candidate != 0 ]]; then
      HOST_CPU=$candidate
      break
    fi
  done
  HOST_CPU=${HOST_CPU:-0}
fi

if [[ ! -e /sys/devices/system/node/node${HOST_NODE}/cpu${HOST_CPU} ]]; then
  echo "CPU ${HOST_CPU} is not in host NUMA node ${HOST_NODE}" >&2
  exit 1
fi

make -C "$SCRIPT_DIR"
sudo -v
mkdir -p "$RESULTS_DIR"
timestamp=$(date -u +%Y%m%dT%H%M%SZ)
result_file=${RESULTS_DIR}/latency-${timestamp}.csv
summary_file=${RESULTS_DIR}/latency-${timestamp}.txt

printf '%s\n' \
  'phase,repetition,access,cpu,memory_node,size_mb,passes,loads,seconds,ns_per_load,placement_samples,placement_on_target' \
  > "$result_file"

run_phase() {
  local phase=$1 repetition memory_node access output
  for ((repetition = 1; repetition <= REPETITIONS; ++repetition)); do
    for memory_node in "$HOST_NODE" "$MEMORY_NODE"; do
      if [[ $memory_node == "$HOST_NODE" ]]; then
        access=local
      else
        access=remote
      fi
      output=$("${SCRIPT_DIR}/numa_latency" \
        --cpu "$HOST_CPU" \
        --memory-node "$memory_node" \
        --size-mb "$SIZE_MB" \
        --passes "$PASSES" \
        --seed "$repetition")
      printf '%s,%s,%s,%s\n' "$phase" "$repetition" "$access" "$output" \
        | tee -a "$result_file"
    done
  done
}

offlined=0
cleanup() {
  if ((offlined == 1 && KEEP_OFFLINE == 0)); then
    sudo "${SCRIPT_DIR}/numa_cpu_control.sh" restore
  fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

echo "Benchmark CPU: ${HOST_CPU} on node ${HOST_NODE}"
echo "Memory-pool node: ${MEMORY_NODE}"
echo "Running baseline measurements..."
run_phase before_offline

sudo "${SCRIPT_DIR}/numa_cpu_control.sh" offline "$MEMORY_NODE"
offlined=1
"${SCRIPT_DIR}/numa_cpu_control.sh" status "$MEMORY_NODE"

echo "Running measurements with node ${MEMORY_NODE} CPUs offline..."
run_phase memory_only

awk -F, '
  NR > 1 {
    key = $1 SUBSEP $3
    sum[key] += $10
    count[key]++
  }
  END {
    print "Mean dependent-load latency (ns):"
    phases[1] = "before_offline"
    phases[2] = "memory_only"
    for (i = 1; i <= 2; ++i) {
      phase = phases[i]
      local_key = phase SUBSEP "local"
      remote_key = phase SUBSEP "remote"
      local_mean = sum[local_key] / count[local_key]
      remote_mean = sum[remote_key] / count[remote_key]
      printf "  %-15s local=%8.3f remote=%8.3f remote/local=%5.2fx\n", \
             phase, local_mean, remote_mean, remote_mean / local_mean
    }
  }
' "$result_file" | tee "$summary_file"

echo "Raw results: ${result_file}"
echo "Summary: ${summary_file}"
if ((KEEP_OFFLINE == 1)); then
  echo "Node ${MEMORY_NODE} CPUs remain offline. Restore with:"
  echo "  sudo ${SCRIPT_DIR}/numa_cpu_control.sh restore"
fi
