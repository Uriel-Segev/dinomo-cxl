#!/bin/bash
# Start dinomo-bench on the bench VM.
# Run from repo root: bash vm-configs/c6525-25g/06_run_bench.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

echo "Starting dinomo-bench on ${VM_BENCH}..."
$SSH ${SSH_USER}@${CLOUDLAB_HOST} 'bash -s' << ENDSSH
ssh -o StrictHostKeyChecking=no ${VM_USER}@${VM_BENCH} "
  cd ${DINOMO_DIR}
  pkill -x dinomo-bench 2>/dev/null || true
  sleep 1
  # bench starts up and waits for a trigger command — it doesn't run a workload by itself.
  # Send workload commands with 07_trigger_bench.sh after bench is running.
  # Results go to ~/projects/DINOMO/log_0.txt (not /tmp/dinomo-bench.log).
  nohup ./build/target/benchmark/dinomo-bench > /tmp/dinomo-bench.log 2>&1 < /dev/null &
  echo \"  bench PID: \$!\"
"
ENDSSH
echo "When ready, trigger with: bash vm-configs/c6525-25g/07_trigger_bench.sh LOAD"
