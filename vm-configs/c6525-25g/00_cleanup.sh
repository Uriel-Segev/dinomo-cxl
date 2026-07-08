#!/bin/bash
# Kill all DINOMO processes in all VMs and delete the pool.
# Run from repo root: bash vm-configs/c6525-25g/00_cleanup.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

echo "Killing DINOMO processes on ${CLOUDLAB_HOST}..."
$SSH ${SSH_USER}@${CLOUDLAB_HOST} 'bash -s' << ENDSSH
# sudo is needed because storage and kvs run with elevated privileges.
# /dev/shm/pool is the PMDK memory pool on the storage VM — deleting it before
# each run ensures storage creates it fresh with a valid remote_start_addr.
for vm_ip in ${VM_STORAGE} ${VM_KVS} ${VM_ROUTE} ${VM_MONITOR} ${VM_BENCH}; do
  ssh -o StrictHostKeyChecking=no ${VM_USER}@\${vm_ip} \
    'sudo pkill -9 -f "dinomo-(storage|kvs|route|monitor|bench)" 2>/dev/null; sudo rm -f /dev/shm/pool; echo "  clean: \$(hostname)"' &
done
wait
echo "Done."
ENDSSH
