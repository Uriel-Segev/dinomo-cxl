#!/bin/bash
# ============================================================
#  DINOMO Test Script
#  Runs LOAD then three benchmark workloads (write-only,
#  read-only, 50/50 mixed) and prints a results summary.
#
#  Prerequisites: DINOMO must already be started via start.sh
#  Run from repo root: bash vm-configs/c6525-25g/test.sh
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

WAIT_AFTER_TRIGGER=$(( BENCH_DURATION + BENCH_REPORT_PERIOD + 5 ))

# Helper: send a command to the bench trigger and wait
send_bench_cmd() {
  local cmd="$1"
  local wait_sec="$2"
  local trigger_timeout=$(( wait_sec - 1 ))
  $SSH ${SSH_USER}@${CLOUDLAB_HOST} 'bash -s' << ENDSSH
ssh -o StrictHostKeyChecking=no ${VM_USER}@${VM_BENCH} "
  cd ${DINOMO_DIR}
  # bench-trigger loops forever after stdin reaches EOF. Keep the pipe open for
  # the requested wait and stop the helper just before it closes. The benchmark
  # process continues independently and writes results to log_0.txt.
  (printf '%s\\n' '${cmd}'; sleep ${wait_sec}) | \
    timeout ${trigger_timeout}s ./build/target/benchmark/dinomo-bench-trigger 1 \
    >/dev/null 2>&1
" 2>/dev/null || true
ENDSSH
}

# Helper: collect benchmark epoch results from bench log (lines after a timestamp)
collect_results() {
  local since_line="$1"
  $SSH ${SSH_USER}@${CLOUDLAB_HOST} \
    "ssh -o StrictHostKeyChecking=no ${VM_USER}@${VM_BENCH} \
     'tail -n +${since_line} ~/projects/DINOMO/log_0.txt 2>/dev/null'" \
    | grep -E "Throughput|Median|tail latency|Average|Finished"
}

# Check storage is alive before running tests
check_storage() {
  alive=$($SSH ${SSH_USER}@${CLOUDLAB_HOST} \
    "ssh -o StrictHostKeyChecking=no ${VM_USER}@${VM_STORAGE} \
     'pgrep -x dinomo-storage > /dev/null 2>&1 && echo YES || echo NO'")
  if [ "$alive" != "YES" ]; then
    echo "  FAIL: dinomo-storage is not running. Run start.sh first."
    return 1
  fi
}

echo "============================================"
echo " DINOMO Test Suite"
echo " Host: ${CLOUDLAB_HOST}"
echo " Keys: ${BENCH_NUM_KEYS}  Duration: ${BENCH_DURATION}s"
echo "============================================"

# ------------------------------------------------------------
# Pre-check
# ------------------------------------------------------------
echo ""
echo "Checking processes..."
check_storage || exit 1
echo "  Storage alive. Proceeding."

# Snapshot the bench log line count before each run so collect_results can
# read only the lines added by that run (tail -n +N skips everything before).
# Both dinomo-bench and kvs thread 0 write to log_0.txt (same spdlog filename),
# so the file accumulates across runs — snapshotting the line count is how we separate them.
bench_log_lines() {
  $SSH ${SSH_USER}@${CLOUDLAB_HOST} \
    "ssh -o StrictHostKeyChecking=no ${VM_USER}@${VM_BENCH} \
     'wc -l < ~/projects/DINOMO/log_0.txt 2>/dev/null || echo 0'"
}

# ------------------------------------------------------------
# LOAD
# ------------------------------------------------------------
echo ""
echo "[1/4] LOAD: inserting ${BENCH_NUM_KEYS} keys..."
LOAD_CMD="LOAD:${BENCH_NUM_KEYS}:${BENCH_VALUE_SIZE}:1:1"
send_bench_cmd "$LOAD_CMD" 15
sleep 5

# Verify LOAD completed
load_done=$($SSH ${SSH_USER}@${CLOUDLAB_HOST} \
  "ssh -o StrictHostKeyChecking=no ${VM_USER}@${VM_BENCH} \
   'grep -c \"Loading data took\" ~/projects/DINOMO/log_0.txt 2>/dev/null || echo 0'")
if [ "${load_done}" -ge 1 ] 2>/dev/null; then
  duration=$($SSH ${SSH_USER}@${CLOUDLAB_HOST} \
    "ssh -o StrictHostKeyChecking=no ${VM_USER}@${VM_BENCH} \
     'grep \"Loading data took\" ~/projects/DINOMO/log_0.txt | tail -1'")
  echo "  PASS: ${duration}"
else
  echo "  FAIL: LOAD did not complete. Check /tmp/dinomo-kvs.log and /tmp/dinomo-storage.log"
  exit 1
fi

# ------------------------------------------------------------
# RUN 1: Write-only
# ------------------------------------------------------------
echo ""
echo "[2/4] RUN write-only (${BENCH_DURATION}s, 100% writes, UPDATE)..."
LINE_BEFORE=$(bench_log_lines)
RUN_WRITE="RUN:0:${BENCH_NUM_KEYS}:${BENCH_VALUE_SIZE}:${BENCH_REPORT_PERIOD}:${BENCH_DURATION}:0:${BENCH_OUTSTANDING}:1"
send_bench_cmd "$RUN_WRITE" $WAIT_AFTER_TRIGGER
sleep 5

finished=$($SSH ${SSH_USER}@${CLOUDLAB_HOST} \
  "ssh -o StrictHostKeyChecking=no ${VM_USER}@${VM_BENCH} \
   'tail -n +${LINE_BEFORE} ~/projects/DINOMO/log_0.txt 2>/dev/null | grep -c Finished || echo 0'")
if [ "${finished}" -ge 1 ] 2>/dev/null; then
  echo "  PASS"
  $SSH ${SSH_USER}@${CLOUDLAB_HOST} \
    "ssh -o StrictHostKeyChecking=no ${VM_USER}@${VM_BENCH} \
     'tail -n +${LINE_BEFORE} ~/projects/DINOMO/log_0.txt'" \
    | grep -E "Epoch [0-9]+\] Throughput|Median latency|tail latency" \
    | sed 's/^/    /'
else
  echo "  FAIL: RUN write-only did not complete."
  check_storage || echo "  (storage died during write test)"
  exit 1
fi

# ------------------------------------------------------------
# RUN 2: Read-only
# ------------------------------------------------------------
echo ""
echo "[3/4] RUN read-only (${BENCH_DURATION}s, 100% reads)..."
LINE_BEFORE=$(bench_log_lines)
RUN_READ="RUN:100:${BENCH_NUM_KEYS}:${BENCH_VALUE_SIZE}:${BENCH_REPORT_PERIOD}:${BENCH_DURATION}:0:${BENCH_OUTSTANDING}:0"
send_bench_cmd "$RUN_READ" $WAIT_AFTER_TRIGGER
sleep 5

finished=$($SSH ${SSH_USER}@${CLOUDLAB_HOST} \
  "ssh -o StrictHostKeyChecking=no ${VM_USER}@${VM_BENCH} \
   'tail -n +${LINE_BEFORE} ~/projects/DINOMO/log_0.txt 2>/dev/null | grep -c Finished || echo 0'")
if [ "${finished}" -ge 1 ] 2>/dev/null; then
  echo "  PASS"
  $SSH ${SSH_USER}@${CLOUDLAB_HOST} \
    "ssh -o StrictHostKeyChecking=no ${VM_USER}@${VM_BENCH} \
     'tail -n +${LINE_BEFORE} ~/projects/DINOMO/log_0.txt'" \
    | grep -E "Epoch [0-9]+\] Throughput|Median latency|tail latency" \
    | sed 's/^/    /'
else
  echo "  FAIL: RUN read-only did not complete."
  check_storage || echo "  (storage died during read test)"
  exit 1
fi

# ------------------------------------------------------------
# RUN 3: Mixed 50/50
# ------------------------------------------------------------
echo ""
echo "[4/4] RUN mixed 50/50 (${BENCH_DURATION}s, 50% reads / 50% writes)..."
LINE_BEFORE=$(bench_log_lines)
RUN_MIXED="RUN:50:${BENCH_NUM_KEYS}:${BENCH_VALUE_SIZE}:${BENCH_REPORT_PERIOD}:${BENCH_DURATION}:0:${BENCH_OUTSTANDING}:0"
send_bench_cmd "$RUN_MIXED" $WAIT_AFTER_TRIGGER
sleep 5

finished=$($SSH ${SSH_USER}@${CLOUDLAB_HOST} \
  "ssh -o StrictHostKeyChecking=no ${VM_USER}@${VM_BENCH} \
   'tail -n +${LINE_BEFORE} ~/projects/DINOMO/log_0.txt 2>/dev/null | grep -c Finished || echo 0'")
if [ "${finished}" -ge 1 ] 2>/dev/null; then
  echo "  PASS"
  $SSH ${SSH_USER}@${CLOUDLAB_HOST} \
    "ssh -o StrictHostKeyChecking=no ${VM_USER}@${VM_BENCH} \
     'tail -n +${LINE_BEFORE} ~/projects/DINOMO/log_0.txt'" \
    | grep -E "Epoch [0-9]+\] Throughput|Median latency|tail latency" \
    | sed 's/^/    /'
else
  echo "  FAIL: RUN mixed did not complete."
  check_storage || echo "  (storage died during mixed test)"
  exit 1
fi

# ------------------------------------------------------------
# Summary
# ------------------------------------------------------------
echo ""
echo "============================================"
echo " All tests PASSED"
echo "============================================"
