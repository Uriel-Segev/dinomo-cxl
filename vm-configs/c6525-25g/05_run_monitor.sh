#!/bin/bash
# Start dinomo-monitor on the monitor VM.
# Run from repo root: bash vm-configs/c6525-25g/05_run_monitor.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

echo "Starting dinomo-monitor on ${VM_MONITOR}..."
$SSH ${SSH_USER}@${CLOUDLAB_HOST} 'bash -s' << ENDSSH
ssh -o StrictHostKeyChecking=no ${VM_USER}@${VM_MONITOR} "
  cd ${DINOMO_DIR}
  pkill -x dinomo-monitor 2>/dev/null || true
  sleep 1
  nohup ./build/target/kvs/dinomo-monitor > /tmp/dinomo-monitor.log 2>&1 < /dev/null &
  echo \"  monitor PID: \$!\"
"
ENDSSH
echo "Check log: bash vm-configs/c6525-25g/check_logs.sh"
