#!/bin/bash
# Load Soft-RoCE (rdma_rxe) in storage and kvs VMs.
# Must run after VM reboot since rdma_rxe is not persistent.
# Run from repo root: bash vm-configs/c6525-25g/01_setup_rdma.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

echo "Setting up Soft-RoCE on ${CLOUDLAB_HOST}..."
# rdma_rxe is not persistent across VM reboots — must be reloaded every time.
# We delete any existing rxe0 link first to avoid "already exists" errors on re-runs.
# rxe0 is attached to VM_RDMA_IFACE (enp2s0), the NIC on the br-rdma bridge.
# Only storage and kvs need Soft-RoCE — the other three VMs don't do any RDMA.
$SSH ${SSH_USER}@${CLOUDLAB_HOST} 'bash -s' << ENDSSH
for vm_ip in ${VM_STORAGE} ${VM_KVS}; do
  ssh -o StrictHostKeyChecking=no ${VM_USER}@\${vm_ip} "
    sudo modprobe rdma_rxe
    sudo rdma link delete rxe0/1 2>/dev/null || true
    sudo rdma link add rxe0 type rxe netdev ${VM_RDMA_IFACE}
    state=\$(rdma link show | grep rxe0 | awk '{print \$4}')
    echo \"  rxe0 on \$(hostname): \${state}\"
  " &
done
wait
ENDSSH
echo "Soft-RoCE setup done."
