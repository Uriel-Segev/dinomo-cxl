#!/bin/bash
# ============================================================
#  DINOMO Stop Script
#  Kills all DINOMO processes on all VMs and deletes the pool.
#  Run from repo root: bash vm-configs/c6525-25g/stop.sh
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

echo "Stopping all DINOMO processes on ${CLOUDLAB_HOST}..."

$SSH ${SSH_USER}@${CLOUDLAB_HOST} 'bash -s' << ENDSSH
for vm_ip in ${VM_STORAGE} ${VM_KVS} ${VM_ROUTE} ${VM_MONITOR} ${VM_BENCH}; do
  ssh -o StrictHostKeyChecking=no ${VM_USER}@\${vm_ip} \
    'sudo pkill -9 -f "dinomo-(storage|kvs|route|monitor|bench)" 2>/dev/null; sudo rm -f /dev/shm/pool; echo "  stopped: \$(hostname)"' &
done
wait
ENDSSH

echo "Done. All DINOMO processes stopped."
