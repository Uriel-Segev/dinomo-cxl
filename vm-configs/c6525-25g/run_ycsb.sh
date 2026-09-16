#!/bin/bash
# Run YCSB-style workloads supported by DINOMO's native benchmark harness.
#
# Supported workloads:
#   A: 50% reads, 50% updates
#   B: 95% reads, 5% updates
#   C: 100% reads
#
# Every workload repetition calls start.sh, which stops all DINOMO processes,
# deletes the PMDK pool, recreates the Soft-RoCE links, and starts a clean
# cluster. The script then loads a fresh keyspace before running the workload.
#

# Usage:
#   bash vm-configs/c6525-25g/run_ycsb.sh
#   bash vm-configs/c6525-25g/run_ycsb.sh A C
#   YCSB_REPETITIONS=3 YCSB_DURATION=60 bash vm-configs/c6525-25g/run_ycsb.sh

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
source "${SCRIPT_DIR}/config.sh"

YCSB_NUM_KEYS="${YCSB_NUM_KEYS:-${BENCH_NUM_KEYS}}"
YCSB_VALUE_SIZE="${YCSB_VALUE_SIZE:-${BENCH_VALUE_SIZE}}"
YCSB_DURATION="${YCSB_DURATION:-${BENCH_DURATION}}"
YCSB_REPORT_PERIOD="${YCSB_REPORT_PERIOD:-${BENCH_REPORT_PERIOD}}"
YCSB_OUTSTANDING="${YCSB_OUTSTANDING:-${BENCH_OUTSTANDING}}"
YCSB_ZIPF="${YCSB_ZIPF:-0}"
YCSB_REPETITIONS="${YCSB_REPETITIONS:-1}"
YCSB_LOAD_TIMEOUT="${YCSB_LOAD_TIMEOUT:-120}"
# Validate before arithmetic expansion or sending values through SSH.
for name in YCSB_NUM_KEYS YCSB_VALUE_SIZE YCSB_DURATION YCSB_REPORT_PERIOD \
            YCSB_OUTSTANDING YCSB_REPETITIONS YCSB_LOAD_TIMEOUT; do
  if ! [[ "${!name}" =~ ^[1-9][0-9]*$ ]]; then
    echo "ERROR: ${name} must be a positive decimal integer." >&2
    exit 1
  fi
done
YCSB_RUN_TIMEOUT="${YCSB_RUN_TIMEOUT:-$((YCSB_DURATION + 90))}"
if ! [[ "${YCSB_RUN_TIMEOUT}" =~ ^[1-9][0-9]*$ ]] || \
   (( YCSB_RUN_TIMEOUT <= YCSB_DURATION || YCSB_REPORT_PERIOD > YCSB_DURATION )); then
  echo "ERROR: run timeout must exceed duration, and report period must not exceed duration." >&2
  exit 1
fi
# Existing guest binaries may contain the unsafe Zipf implementation. Keep this
# runner uniform until the patched benchmark has been rebuilt and deployed.
if [[ "${YCSB_ZIPF}" != 0 ]]; then
  echo "ERROR: this runner currently supports YCSB_ZIPF=0 only." >&2
  exit 1
fi

if [ "$#" -gt 0 ]; then
  WORKLOADS=("$@")
else
  WORKLOADS=(A B C)
fi

for workload in "${WORKLOADS[@]}"; do
  case "${workload^^}" in
    A|B|C) ;;
    *)
      echo "ERROR: unsupported workload '${workload}'. Choose A, B, or C."
      exit 1
      ;;
  esac
done

if ! [[ "${YCSB_REPETITIONS}" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: YCSB_REPETITIONS must be a positive integer."
  exit 1
fi

RUN_ID="$(date -u +%Y%m%dT%H%M%S%NZ)-$$"
RESULTS_BASE="${YCSB_RESULTS_ROOT:-${REPO_ROOT}/results/ycsb}"
RESULTS_DIR="${RESULTS_BASE}/${RUN_ID}"
SUMMARY_FILE="${RESULTS_DIR}/summary.csv"
mkdir -p "${RESULTS_DIR}"

printf '%s\n' \
  "run_id=${RUN_ID}" \
  "host=${CLOUDLAB_HOST}" \
  "git_commit=$(git -C "${REPO_ROOT}" rev-parse HEAD 2>/dev/null || echo unknown)" \
  "workloads=${WORKLOADS[*]}" \
  "active_benchmark_threads=1" \
  "repetitions=${YCSB_REPETITIONS}" \
  "num_keys=${YCSB_NUM_KEYS}" \
  "value_size_bytes=${YCSB_VALUE_SIZE}" \
  "duration_seconds=${YCSB_DURATION}" \
  "report_period_seconds=${YCSB_REPORT_PERIOD}" \
  "outstanding_requests=${YCSB_OUTSTANDING}" \
  "zipf_coefficient=${YCSB_ZIPF}" \
  > "${RESULTS_DIR}/parameters.txt"

printf '%s\n' \
  'workload,repetition,read_percent,update_percent,mean_epoch_throughput_ops_s,mean_epoch_median_latency_us,mean_epoch_p99_latency_us,rdma_read_ops,rdma_read_bytes,rdma_write_ops,rdma_write_bytes,rdma_send_ops,rdma_send_bytes,rdma_recv_ops,rdma_recv_bytes,rdma_cas_ops,rdma_cas_bytes,rdma_faa_ops,rdma_faa_bytes,value_cache_hits,shortcut_cache_hits,local_log_hits,cache_misses,cache_hit_ratio,status' \
  > "${SUMMARY_FILE}"

source "${SCRIPT_DIR}/benchmark_helpers.sh"

current_output_dir=""
on_error() {
  local status=$?
  set +e
  echo ""
  echo "ERROR: YCSB suite failed."
  if [ -n "${current_output_dir}" ]; then
    printf '%s\n' "${workload},${repetition},${read_percent},${update_percent},NA,NA,NA,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,NA,FAIL" >> "${SUMMARY_FILE}"
  fi
  if [ -n "${current_output_dir}" ]; then
    capture_logs "${current_output_dir}/failure-logs"
    echo "Failure logs: ${current_output_dir}/failure-logs"
  fi
  echo "Partial results: ${RESULTS_DIR}"
  exit "${status}"
}
trap on_error ERR

echo "============================================"
echo " DINOMO YCSB-style Suite"
echo " Workloads: ${WORKLOADS[*]}"
echo " Repetitions: ${YCSB_REPETITIONS}"
echo " Keys: ${YCSB_NUM_KEYS}  Value: ${YCSB_VALUE_SIZE} bytes"
echo " Duration: ${YCSB_DURATION}s  Outstanding: ${YCSB_OUTSTANDING}"
echo " Zipf: ${YCSB_ZIPF}"
echo " Results: ${RESULTS_DIR}"
echo "============================================"

for workload_arg in "${WORKLOADS[@]}"; do
  workload="${workload_arg^^}"
  case "${workload}" in
    A) read_percent=50; update_percent=50; read_ratio=0.50 ;;
    B) read_percent=95; update_percent=5; read_ratio=0.95 ;;
    C) read_percent=100; update_percent=0; read_ratio=1.00 ;;
  esac

  for repetition in $(seq 1 "${YCSB_REPETITIONS}"); do
    run_name="workload-${workload,,}/run-$(printf '%02d' "${repetition}")"
    current_output_dir="${RESULTS_DIR}/${run_name}"
    mkdir -p "${current_output_dir}"

    echo ""
    echo "[${workload} run ${repetition}/${YCSB_REPETITIONS}] Resetting DINOMO..."
    bash "${SCRIPT_DIR}/start.sh" 2>&1 | tee "${current_output_dir}/start.log"

    echo "[${workload} run ${repetition}/${YCSB_REPETITIONS}] Loading ${YCSB_NUM_KEYS} keys..."
    load_start=$(( $(bench_line_count) + 1 ))
    load_command="LOAD:${YCSB_NUM_KEYS}:${YCSB_VALUE_SIZE}:1:1"
    send_bench_command "${load_command}"
    wait_for_bench_log "${load_start}" "Loading data took" "${YCSB_LOAD_TIMEOUT}"
    capture_benchmark_segment "${load_start}" "${current_output_dir}/load.log"

    echo "[${workload} run ${repetition}/${YCSB_REPETITIONS}] Running workload for ${YCSB_DURATION}s..."
    benchmark_start=$(( $(bench_line_count) + 1 ))
    kvs_log_snapshot "${current_output_dir}/kvs-log-start.csv"
    system_dir="${current_output_dir}/system"
    capture_system_snapshot "${system_dir}" before
    sar_remote_file="/tmp/dinomo-ycsb-${RUN_ID}-${workload}-${repetition}.sar"
    start_host_sar "${sar_remote_file}" "${YCSB_DURATION}"
    run_command="RUN:${read_ratio}:${YCSB_NUM_KEYS}:${YCSB_VALUE_SIZE}:${YCSB_REPORT_PERIOD}:${YCSB_DURATION}:${YCSB_ZIPF}:${YCSB_OUTSTANDING}:1"
    printf '%s\n' "${run_command}" > "${current_output_dir}/command.txt"
    send_bench_command "${run_command}"
    wait_for_bench_log "${benchmark_start}" "Finished" "${YCSB_RUN_TIMEOUT}"
    capture_benchmark_segment "${benchmark_start}" "${current_output_dir}/benchmark.log"
    capture_kvs_log_segments "${current_output_dir}/kvs-log-start.csv" \
      "${current_output_dir}/kvs-workload.log"
    write_rdma_csv "${current_output_dir}/kvs-workload.log" \
      "${current_output_dir}/rdma.csv"
    write_cache_csv "${current_output_dir}/kvs-workload.log" \
      "${current_output_dir}/cache.csv"
    capture_system_snapshot "${system_dir}" after
    capture_host_sar "${sar_remote_file}" "${system_dir}/host-sar.txt"
    capture_logs "${current_output_dir}/logs"

    throughput=$(mean_metric "Throughput is" "is" "${current_output_dir}/benchmark.log")
    median=$(mean_metric "Median latency" "latency" "${current_output_dir}/benchmark.log")
    p99=$(mean_metric "99 tail latency" "latency" "${current_output_dir}/benchmark.log")
    rdma_totals=$(sum_rdma_csv "${current_output_dir}/rdma.csv")
    cache_totals=$(summarize_cache_csv "${current_output_dir}/cache.csv")

    if ! awk -v throughput="${throughput}" -v median="${median}" -v p99="${p99}" \
      'BEGIN { exit !(throughput != "NA" && throughput > 0 && median != "NA" && p99 != "NA") }'; then
      echo "ERROR: missing metrics or zero throughput in ${current_output_dir}/benchmark.log" >&2
      false
    fi

    printf '%s\n' \
      "${workload},${repetition},${read_percent},${update_percent},${throughput},${median},${p99},${rdma_totals},${cache_totals},PASS" \
      >> "${SUMMARY_FILE}"

    echo "  PASS: mean throughput=${throughput} ops/s, median=${median} us, p99=${p99} us"
  done
done

trap - ERR
current_output_dir=""

echo ""
echo "============================================"
echo " All YCSB-style workloads PASSED"
echo " Summary: ${SUMMARY_FILE}"
echo "============================================"
column -s, -t "${SUMMARY_FILE}" 2>/dev/null || cat "${SUMMARY_FILE}"
