#!/bin/bash
# Load once per repetition, then replay CSV phases in one native request loop.
# Usage: bash vm-configs/c6525-25g/run_trace.sh [CSV]
# Local validation only: bash vm-configs/c6525-25g/run_trace.sh --check [CSV]
# Like run_ycsb.sh, an actual run invokes start.sh and recreates the PMDK pool.
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
source "${SCRIPT_DIR}/config.sh"
source "${SCRIPT_DIR}/benchmark_helpers.sh"

check_only=0
if [[ "${1:-}" == --check ]]; then check_only=1; shift; fi
if (( $# > 1 )); then echo "Usage: $0 [--check] [CSV]" >&2; exit 1; fi
TRACE_FILE="${1:-${SCRIPT_DIR}/traces/moving_hotspot.csv}"
TRACE_NUM_KEYS="${TRACE_NUM_KEYS:-1000000}"
TRACE_VALUE_SIZE="${TRACE_VALUE_SIZE:-${BENCH_VALUE_SIZE}}"
TRACE_REPORT_PERIOD="${TRACE_REPORT_PERIOD:-${BENCH_REPORT_PERIOD}}"
TRACE_OUTSTANDING="${TRACE_OUTSTANDING:-${BENCH_OUTSTANDING}}"
TRACE_SEED="${TRACE_SEED:-42}"
TRACE_REPETITIONS="${TRACE_REPETITIONS:-1}"
TRACE_LOAD_TIMEOUT="${TRACE_LOAD_TIMEOUT:-300}"
TRACE_DRAIN_TIMEOUT="${TRACE_DRAIN_TIMEOUT:-30}"
for name in TRACE_NUM_KEYS TRACE_VALUE_SIZE TRACE_REPORT_PERIOD TRACE_OUTSTANDING \
            TRACE_REPETITIONS TRACE_LOAD_TIMEOUT TRACE_DRAIN_TIMEOUT; do
  if ! [[ "${!name}" =~ ^[1-9][0-9]*$ ]]; then
    echo "ERROR: ${name} must be a positive decimal integer." >&2; exit 1
  fi
  value="${!name}"
  if (( ${#value} > 10 )) || (( value > 4294967295 )); then
    echo "ERROR: ${name} exceeds the unsigned 32-bit range." >&2; exit 1
  fi
done
if (( TRACE_NUM_KEYS > 2147483647 || TRACE_VALUE_SIZE > 2147483647 )); then
  echo "ERROR: key count and value size must fit the existing LOAD command's signed 32-bit range." >&2
  exit 1
fi
if ! [[ "${TRACE_SEED}" =~ ^(0|[1-9][0-9]*)$ ]] || (( ${#TRACE_SEED} > 10 )) || (( TRACE_SEED > 4294967295 )); then
  echo "ERROR: TRACE_SEED must be an unsigned 32-bit decimal integer." >&2; exit 1
fi
command -v python3 >/dev/null
command -v "${CXX:-g++}" >/dev/null
scratch_dir="$(mktemp -d /tmp/dinomo-trace-check.XXXXXXXX)"
trap 'rm -rf "${scratch_dir}"' EXIT
"${CXX:-g++}" -std=c++11 -O2 "${REPO_ROOT}/src/benchmark/trace_check.cpp" -o "${scratch_dir}/check"
# Freeze the input so validation, upload, and archived provenance use identical bytes.
cp -- "${TRACE_FILE}" "${scratch_dir}/trace.csv"
TRACE_DURATION="$("${scratch_dir}/check" "${scratch_dir}/trace.csv" "${TRACE_NUM_KEYS}")"
echo "Valid trace: ${TRACE_DURATION}s, ${TRACE_NUM_KEYS} loaded keys, seed ${TRACE_SEED}"
if (( check_only )); then exit 0; fi
TRACE_RUN_TIMEOUT="${TRACE_RUN_TIMEOUT:-$((TRACE_DURATION + TRACE_DRAIN_TIMEOUT + 90))}"
if ! [[ "${TRACE_RUN_TIMEOUT}" =~ ^[1-9][0-9]*$ ]] || (( ${#TRACE_RUN_TIMEOUT} > 11 )) || \
   (( TRACE_RUN_TIMEOUT <= TRACE_DURATION + TRACE_DRAIN_TIMEOUT )); then
  echo "ERROR: TRACE_RUN_TIMEOUT must exceed trace duration plus drain timeout." >&2; exit 1
fi

# Read-only preflight before the cluster reset; old and SINGLE_OUTSTANDING
# binaries fail this capability check without launching a benchmark client.
$SSH "${SSH_USER}@${CLOUDLAB_HOST}" \
  "ssh -o BatchMode=yes -o StrictHostKeyChecking=no ${VM_USER}@${VM_BENCH} 'bash -s'" << 'VMSSH'
set -e
cd "$HOME/projects/DINOMO"
if ! ./build/target/benchmark/dinomo-bench --supports-trace; then
  echo "ERROR: rebuild and deploy dinomo-bench with TRACE support first." >&2
  exit 1
fi
VMSSH

RUN_ID="$(date -u +%Y%m%dT%H%M%S%NZ)-$$"
RESULTS_DIR="${TRACE_RESULTS_ROOT:-${REPO_ROOT}/results/trace}/${RUN_ID}"
mkdir -p "${RESULTS_DIR}"
cp -- "${scratch_dir}/trace.csv" "${RESULTS_DIR}/trace.csv"
printf '%s\n' "run_id=${RUN_ID}" "host=${CLOUDLAB_HOST}" \
  "git_commit=$(git -C "${REPO_ROOT}" rev-parse HEAD 2>/dev/null || echo unknown)" \
  "active_benchmark_threads=1" "load_model=concurrency_limited" \
  "num_keys=${TRACE_NUM_KEYS}" "value_size_bytes=${TRACE_VALUE_SIZE}" \
  "duration_seconds=${TRACE_DURATION}" "report_period_seconds=${TRACE_REPORT_PERIOD}" \
  "outstanding_requests=${TRACE_OUTSTANDING}" "seed=${TRACE_SEED}" \
  "repetitions=${TRACE_REPETITIONS}" "drain_timeout_seconds=${TRACE_DRAIN_TIMEOUT}" \
  > "${RESULTS_DIR}/parameters.txt"
sha256sum "${RESULTS_DIR}/trace.csv" > "${RESULTS_DIR}/trace.sha256"
current_output_dir=""
on_error() {
  local status=$?
  set +e
  echo "ERROR: trace run failed. Results: ${RESULTS_DIR}" >&2
  if [[ -n "${current_output_dir}" ]]; then capture_logs "${current_output_dir}/failure-logs"; fi
  exit "${status}"
}
trap on_error ERR

for (( repetition=1; repetition<=TRACE_REPETITIONS; repetition++ )); do
  current_output_dir="${RESULTS_DIR}/run-$(printf '%02d' "${repetition}")"
  mkdir -p "${current_output_dir}"
  echo "[Trace ${repetition}/${TRACE_REPETITIONS}] Resetting and starting DINOMO..."
  bash "${SCRIPT_DIR}/start.sh" 2>&1 | tee "${current_output_dir}/start.log"
  remote_trace="/tmp/dinomo-trace-${RUN_ID}-${repetition}.csv"
  # Generated remote path contains only safe characters; CSV bytes use stdin.
  $SSH "${SSH_USER}@${CLOUDLAB_HOST}" \
    "ssh -o BatchMode=yes -o StrictHostKeyChecking=no ${VM_USER}@${VM_BENCH} 'cat > ${remote_trace}'" \
    < "${RESULTS_DIR}/trace.csv"
  $SSH "${SSH_USER}@${CLOUDLAB_HOST}" \
    "ssh -o BatchMode=yes -o StrictHostKeyChecking=no ${VM_USER}@${VM_BENCH} 'cd \$HOME/projects/DINOMO && sha256sum build/target/benchmark/dinomo-bench build/target/benchmark/dinomo-bench-trigger conf/dinomo-config.yml ${remote_trace}'" \
    > "${current_output_dir}/deployed.sha256"
  load_start=$(( $(bench_line_count) + 1 ))
  send_bench_command "LOAD:${TRACE_NUM_KEYS}:${TRACE_VALUE_SIZE}:1:1"
  wait_for_bench_log "${load_start}" "Loading data took" "${TRACE_LOAD_TIMEOUT}"
  capture_benchmark_segment "${load_start}" "${current_output_dir}/load.log"
  benchmark_start=$(( $(bench_line_count) + 1 ))
  kvs_log_snapshot "${current_output_dir}/kvs-log-start.csv"
  system_dir="${current_output_dir}/system"
  capture_system_snapshot "${system_dir}" before
  sar_remote_file="/tmp/dinomo-trace-${RUN_ID}-${repetition}.sar"
  start_host_sar "${sar_remote_file}" "$((TRACE_DURATION + TRACE_DRAIN_TIMEOUT + 90))"
  command="TRACE:${remote_trace}:${TRACE_NUM_KEYS}:${TRACE_VALUE_SIZE}:${TRACE_REPORT_PERIOD}:${TRACE_OUTSTANDING}:${TRACE_SEED}:${TRACE_DRAIN_TIMEOUT}"
  printf '%s\n' "${command}" > "${current_output_dir}/command.txt"
  send_bench_command "${command}"
  wait_for_bench_log "${benchmark_start}" "TRACE_DONE" "${TRACE_RUN_TIMEOUT}" "TRACE_ERROR:"
  capture_benchmark_segment "${benchmark_start}" "${current_output_dir}/benchmark.log"
  capture_kvs_log_segments "${current_output_dir}/kvs-log-start.csv" "${current_output_dir}/kvs-workload.log"
  write_rdma_csv "${current_output_dir}/kvs-workload.log" "${current_output_dir}/rdma.csv"
  write_cache_csv "${current_output_dir}/kvs-workload.log" "${current_output_dir}/cache.csv"
  capture_system_snapshot "${system_dir}" after
  capture_host_sar "${sar_remote_file}" "${system_dir}/host-sar.txt"
  capture_logs "${current_output_dir}/logs"
  python3 "${SCRIPT_DIR}/trace_results.py" "${current_output_dir}/benchmark.log" "${current_output_dir}"
done
trap - ERR
echo "Trace results: ${RESULTS_DIR}"
