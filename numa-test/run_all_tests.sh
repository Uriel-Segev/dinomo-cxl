#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
INCLUDE_DINOMO=0

if [[ ${1:-} == --include-dinomo ]]; then
  INCLUDE_DINOMO=1
  shift
fi
[[ $# -eq 0 ]] || {
  echo "Usage: ./run_all_tests.sh [--include-dinomo]" >&2
  exit 1
}

echo "=== 1/2: dependent-load latency before and after CPU offlining ==="
"${SCRIPT_DIR}/run_experiment.sh"

echo
echo "=== 2/2: bandwidth, concurrency, atomics, and mixed operations ==="
"${SCRIPT_DIR}/run_memory_test.sh" all

if ((INCLUDE_DINOMO == 1)); then
  echo
  echo "=== DINOMO end-to-end operation latency ==="
  "${SCRIPT_DIR}/run_dinomo_test.sh"
else
  echo
  echo "DINOMO operation test skipped because it requires a running deployment."
  echo "Run it separately with ./run_dinomo_test.sh, or use:"
  echo "  ./run_all_tests.sh --include-dinomo"
fi
