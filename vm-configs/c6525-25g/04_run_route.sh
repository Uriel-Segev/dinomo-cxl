#!/bin/bash
# Start dinomo-route on the route VM.
# Run from repo root: bash vm-configs/c6525-25g/04_run_route.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

echo "Starting dinomo-route on ${VM_ROUTE}..."
$SSH ${SSH_USER}@${CLOUDLAB_HOST} 'bash -s' << ENDSSH
ssh -o StrictHostKeyChecking=no ${VM_USER}@${VM_ROUTE} "
  cd ${DINOMO_DIR}
  pkill -x dinomo-route 2>/dev/null || true
  sleep 1
  nohup ./build/target/kvs/dinomo-route > /tmp/dinomo-route.log 2>&1 < /dev/null &
  echo \"  route launch requested\"
"
ENDSSH
echo "Check log: bash vm-configs/c6525-25g/check_logs.sh"
