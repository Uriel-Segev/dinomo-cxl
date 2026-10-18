#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
RESULTS_DIR="${SCRIPT_DIR}/results"

usage() {
  cat <<'EOF'
Usage:
  ./show_results.sh
  ./show_results.sh results/latency-TIMESTAMP.csv

With no argument, the newest latency CSV under results/ is displayed.
EOF
}

[[ $# -le 1 ]] || {
  usage
  exit 1
}

if [[ $# -eq 1 ]]; then
  result_file=$1
else
  shopt -s nullglob
  result_files=("${RESULTS_DIR}"/latency-*.csv)
  shopt -u nullglob
  (("${#result_files[@]}" > 0)) || {
    echo "No latency CSV files found under ${RESULTS_DIR}" >&2
    exit 1
  }
  result_file=${result_files[0]}
  for candidate in "${result_files[@]:1}"; do
    [[ $candidate -nt $result_file ]] && result_file=$candidate
  done
fi

[[ -r $result_file ]] || {
  echo "Cannot read result file: ${result_file}" >&2
  exit 1
}

echo "Results: ${result_file}"
echo

awk -F, '
  NR == 1 {
    if ($1 != "phase" || $10 != "ns_per_load") {
      print "Unexpected CSV format" > "/dev/stderr"
      exit 2
    }
    printf "%-15s %3s %-6s %4s %4s %9s %10s %12s %12s\n", \
           "PHASE", "RUN", "ACCESS", "CPU", "MEM", "SIZE MiB", \
           "TIME (s)", "LATENCY (ns)", "PLACEMENT"
    printf "%-15s %3s %-6s %4s %4s %9s %10s %12s %12s\n", \
           "---------------", "---", "------", "----", "----", \
           "---------", "----------", "------------", "------------"
    next
  }
  {
    placement = ($11 == 0) ? "unverified" : $12 "/" $11
    printf "%-15s %3d %-6s %4d %4d %9d %10.3f %12.3f %12s\n", \
           $1, $2, $3, $4, $5, $6, $9, $10, placement

    key = $1 SUBSEP $3
    sum[key] += $10
    count[key]++
    if (!(key in minimum) || $10 < minimum[key])
      minimum[key] = $10
    if (!(key in maximum) || $10 > maximum[key])
      maximum[key] = $10
    if (!($1 in seen_phase)) {
      phases[++phase_count] = $1
      seen_phase[$1] = 1
    }
  }
  END {
    if (NR <= 1)
      exit
    print ""
    print "Aggregate latency:"
    printf "%-15s %12s %12s %12s %12s\n", \
           "PHASE", "LOCAL MEAN", "REMOTE MEAN", "REMOTE/LOCAL", "REMOTE EXTRA"
    printf "%-15s %12s %12s %12s %12s\n", \
           "---------------", "------------", "------------", "------------", "------------"
    for (i = 1; i <= phase_count; ++i) {
      phase = phases[i]
      local_key = phase SUBSEP "local"
      remote_key = phase SUBSEP "remote"
      local_mean = sum[local_key] / count[local_key]
      remote_mean = sum[remote_key] / count[remote_key]
      printf "%-15s %9.3f ns %9.3f ns %11.2fx %10.1f%%\n", \
             phase, local_mean, remote_mean, remote_mean / local_mean, \
             (remote_mean / local_mean - 1) * 100
      printf "  ranges: local %.3f-%.3f ns, remote %.3f-%.3f ns\n", \
             minimum[local_key], maximum[local_key], \
             minimum[remote_key], maximum[remote_key]
    }
  }
' "$result_file"
