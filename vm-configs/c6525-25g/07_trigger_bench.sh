#!/bin/bash
# Send a benchmark command to dinomo-bench-trigger.
# Usage:
#   bash vm-configs/c6525-25g/07_trigger_bench.sh LOAD
#   bash vm-configs/c6525-25g/07_trigger_bench.sh WRITE
#   bash vm-configs/c6525-25g/07_trigger_bench.sh READ
#   bash vm-configs/c6525-25g/07_trigger_bench.sh MIXED

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

MODE="${1:-LOAD}"

# RUN command format: RUN:<read_pct>:<num_keys>:<value_size>:<report_period>:<duration>:<zipf>:<outstanding>:<is_update_only>
#   read_pct=0   → all writes; read_pct=100 → all reads; read_pct=50 → mixed
#   is_update_only=1 → UPDATE ops (modify existing key); 0 → PUT/GET ops
# LOAD command format: LOAD:<num_keys>:<value_size>:<node_id>:<unused>
#   Inserts num_keys keys starting at node_id*100000+1 (so node_id=1 gives keys 100001–200000)
case "$MODE" in
  LOAD)
    CMD="LOAD:${BENCH_NUM_KEYS}:${BENCH_VALUE_SIZE}:1:1"
    WAIT=15
    ;;
  WRITE)
    CMD="RUN:0:${BENCH_NUM_KEYS}:${BENCH_VALUE_SIZE}:${BENCH_REPORT_PERIOD}:${BENCH_DURATION}:0:${BENCH_OUTSTANDING}:1"
    WAIT=$(( BENCH_DURATION + 10 ))
    ;;
  READ)
    CMD="RUN:100:${BENCH_NUM_KEYS}:${BENCH_VALUE_SIZE}:${BENCH_REPORT_PERIOD}:${BENCH_DURATION}:0:${BENCH_OUTSTANDING}:0"
    WAIT=$(( BENCH_DURATION + 10 ))
    ;;
  MIXED)
    CMD="RUN:50:${BENCH_NUM_KEYS}:${BENCH_VALUE_SIZE}:${BENCH_REPORT_PERIOD}:${BENCH_DURATION}:0:${BENCH_OUTSTANDING}:0"
    WAIT=$(( BENCH_DURATION + 10 ))
    ;;
  *)
    echo "Usage: $0 [LOAD|WRITE|READ|MIXED]"
    exit 1
    ;;
esac

echo "Sending: ${CMD}"
$SSH ${SSH_USER}@${CLOUDLAB_HOST} 'bash -s' << ENDSSH
ssh -o StrictHostKeyChecking=no ${VM_USER}@${VM_BENCH} "
  cd ${DINOMO_DIR}
  # bench-trigger reads a command from stdin and sends it over ZMQ, then exits when stdin closes.
  # The problem is it segfaults immediately when stdin closes before ZMQ finishes delivering.
  # The fix: pipe (echo CMD; sleep N) so stdin stays open for N seconds after the echo.
  (echo '${CMD}'; sleep ${WAIT}) | ./build/target/benchmark/dinomo-bench-trigger 1
" 2>/dev/null || true
ENDSSH
echo "Done. Results: ssh ${SSH_USER}@${CLOUDLAB_HOST} 'ssh ${VM_USER}@${VM_BENCH} tail -30 ~/projects/DINOMO/log_0.txt'"
