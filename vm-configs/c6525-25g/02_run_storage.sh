#!/bin/bash
# Start dinomo-storage on the storage VM.
# Run from repo root: bash vm-configs/c6525-25g/02_run_storage.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

echo "Starting dinomo-storage on ${VM_STORAGE}..."
$SSH ${SSH_USER}@${CLOUDLAB_HOST} 'bash -s' << ENDSSH
ssh -o StrictHostKeyChecking=no ${VM_USER}@${VM_STORAGE} "
  cd ${DINOMO_DIR}
  sudo pkill -9 -x dinomo-storage 2>/dev/null || true
  # Delete the pool so storage creates it fresh — reusing an old pool gives kvs a stale remote_start_addr.
  sudo rm -f /dev/shm/pool
  sleep 1
  # sudo is required: storage calls ibv_reg_mr() which needs CAP_NET_ADMIN on Soft-RoCE.
  # < /dev/null detaches stdin so the SSH session doesn't hang waiting for input.
  nohup sudo ./build/target/kvs/dinomo-storage > /tmp/dinomo-storage.log 2>&1 < /dev/null &
  echo \"  storage launch requested\"
"
ENDSSH
echo "Check log: bash vm-configs/c6525-25g/check_logs.sh"
