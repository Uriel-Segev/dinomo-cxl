#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
RESULTS_DIR="${SCRIPT_DIR}/results"

if [[ $# -gt 1 ]]; then
  echo "Usage: ./show_memory_results.sh [memory-suite-CSV]" >&2
  exit 1
fi

if [[ $# -eq 1 ]]; then
  result_file=$1
else
  shopt -s nullglob
  files=("${RESULTS_DIR}"/memory-suite-*.csv)
  shopt -u nullglob
  (("${#files[@]}" > 0)) || {
    echo "No memory-suite CSV files found under ${RESULTS_DIR}" >&2
    exit 1
  }
  result_file=${files[0]}
  for candidate in "${files[@]:1}"; do
    [[ $candidate -nt $result_file ]] && result_file=$candidate
  done
fi

[[ -r $result_file ]] || {
  echo "Cannot read ${result_file}" >&2
  exit 1
}

echo "Results: ${result_file}"
echo
awk -F, '
  NR == 1 {
    printf "%-16s %3s %-6s %3s %10s %11s %11s %12s\n", \
           "TEST", "RUN", "ACCESS", "THR", "MOPS", "GiB/s", "NS/OP", "PLACEMENT"
    printf "%-16s %3s %-6s %3s %10s %11s %11s %12s\n", \
           "----------------", "---", "------", "---", "----------", \
           "-----------", "-----------", "------------"
    next
  }
  {
    placement = ($12 == 0) ? "unverified" : $13 "/" $12
    printf "%-16s %3d %-6s %3d %10.3f %11.3f %11.3f %12s\n", \
           $3, $1, $2, $5, $9, $10, $11, placement
    key = $3 SUBSEP $2
    mops[key] += $9
    bandwidth[key] += $10
    latency[key] += $11
    count[key]++
    if (!($3 in seen)) {
      tests[++test_count] = $3
      seen[$3] = 1
    }
  }
  END {
    print ""
    print "Mean local versus remote:"
    printf "%-16s %12s %12s %12s %12s\n", \
           "TEST", "LOCAL", "REMOTE", "REMOTE/LOCAL", "METRIC"
    printf "%-16s %12s %12s %12s %12s\n", \
           "----------------", "------------", "------------", \
           "------------", "------------"
    for (i = 1; i <= test_count; ++i) {
      test = tests[i]
      local = test SUBSEP "local"
      remote = test SUBSEP "remote"
      if (test == "read-bandwidth" || test == "write-bandwidth") {
        lv = bandwidth[local] / count[local]
        rv = bandwidth[remote] / count[remote]
        printf "%-16s %8.3f GiB/s %8.3f GiB/s %11.2fx %12s\n", \
               test, lv, rv, rv / lv, "bandwidth"
      } else {
        lv = latency[local] / count[local]
        rv = latency[remote] / count[remote]
        printf "%-16s %9.3f ns %9.3f ns %11.2fx %12s\n", \
               test, lv, rv, rv / lv, "ns/op"
      }
    }
  }
' "$result_file"
