#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "${SCRIPT_DIR}/.." && pwd)
RESULTS_DIR=${RESULTS_DIR:-"${SCRIPT_DIR}/results"}
DINOMO_TEST=${DINOMO_TEST:-"${REPO_ROOT}/vm-configs/c6525-25g/test.sh"}

[[ $# -eq 0 ]] || {
  echo "Usage: ./run_dinomo_test.sh" >&2
  exit 1
}
[[ -x $DINOMO_TEST || -r $DINOMO_TEST ]] || {
  echo "DINOMO test harness not found: ${DINOMO_TEST}" >&2
  exit 1
}

mkdir -p "$RESULTS_DIR"
timestamp=$(date -u +%Y%m%dT%H%M%SZ)
raw_file=${RESULTS_DIR}/dinomo-operations-${timestamp}.log
csv_file=${RESULTS_DIR}/dinomo-operations-${timestamp}.csv

echo "This test uses the DINOMO deployment configured in:"
echo "  ${REPO_ROOT}/vm-configs/c6525-25g/config.sh"
echo "DINOMO must already be running. The test performs LOAD, write-only,"
echo "read-only, and 50/50 mixed workloads."
echo

bash "$DINOMO_TEST" | tee "$raw_file"

awk '
  BEGIN {
    print "workload,epoch,throughput_ops_s,average_us,min_us,max_us,median_us,p99_us"
    workload = "unknown"
    epoch = 0
  }
  /RUN write-only/ { workload = "write" }
  /RUN read-only/  { workload = "read" }
  /RUN mixed 50\/50/ { workload = "mixed" }
  /Throughput is / {
    value = $0
    sub(/^.*Throughput is /, "", value)
    sub(/ ops\/seconds.*$/, "", value)
    throughput = value
    epoch++
  }
  /Average latency / {
    value = $0
    sub(/^.*Average latency /, "", value)
    sub(/ us.*$/, "", value)
    average = value
  }
  /Min latency / {
    value = $0
    sub(/^.*Min latency /, "", value)
    sub(/ us.*$/, "", value)
    minimum = value
  }
  /Max latency / {
    value = $0
    sub(/^.*Max latency /, "", value)
    sub(/ us.*$/, "", value)
    maximum = value
  }
  /Median latency / {
    value = $0
    sub(/^.*Median latency /, "", value)
    sub(/ us.*$/, "", value)
    median = value
  }
  /99 tail latency / {
    value = $0
    sub(/^.*99 tail latency /, "", value)
    sub(/ us.*$/, "", value)
    p99 = value
    print workload "," epoch "," throughput "," average "," minimum "," \
          maximum "," median "," p99
  }
' "$raw_file" > "$csv_file"

echo
echo "DINOMO operation latency:"
awk -F, '
  NR == 1 {
    printf "%-9s %5s %14s %11s %11s %11s %11s %11s\n", \
           "WORKLOAD", "EPOCH", "OPS/S", "AVG us", "MIN us", "MAX us", \
           "MEDIAN us", "P99 us"
    next
  }
  {
    printf "%-9s %5d %14.1f %11.2f %11.2f %11.2f %11.2f %11.2f\n", \
           $1, $2, $3, $4, $5, $6, $7, $8
  }
' "$csv_file"
echo
echo "Raw log: ${raw_file}"
echo "CSV: ${csv_file}"
