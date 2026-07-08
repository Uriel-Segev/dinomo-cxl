#!/bin/bash
# Start dinomo-kvs on the kvs VM.
# Run AFTER storage is up and listening.
# Run from repo root: bash vm-configs/c6525-25g/03_run_kvs.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

echo "Starting dinomo-kvs on ${VM_KVS}..."
$SSH ${SSH_USER}@${CLOUDLAB_HOST} 'bash -s' << ENDSSH
ssh -o StrictHostKeyChecking=no ${VM_USER}@${VM_KVS} "
  cd ${DINOMO_DIR}
  sudo pkill -9 -x dinomo-kvs 2>/dev/null || true
  sleep 1
  # Must run after storage prints "start to listen" — kvs connects to storage immediately
  # at startup for the Queue Pair handshake; if storage isn't listening yet, kvs fails.
  # sudo is required for ibv_reg_mr() on Soft-RoCE (same as storage).
  nohup sudo ./build/target/kvs/dinomo-kvs > /tmp/dinomo-kvs.log 2>&1 < /dev/null &
  echo \"  kvs PID: \$!\"
"
ENDSSH
echo "Check log: bash vm-configs/c6525-25g/check_logs.sh"
