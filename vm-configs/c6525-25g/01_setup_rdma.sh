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
$SSH ${SSH_USER}@${CLOUDLAB_HOST} bash -s -- \
  "${VM_STORAGE}" "${VM_KVS}" "${VM_USER}" "${VM_RDMA_IFACE}" << 'ENDSSH'
set -e
storage_ip="$1"
kvs_ip="$2"
vm_user="$3"
rdma_iface="$4"

for vm_ip in "${storage_ip}" "${kvs_ip}"; do
  ssh -o BatchMode=yes -o StrictHostKeyChecking=no \
    "${vm_user}@${vm_ip}" sudo bash -s -- "${rdma_iface}" << 'VMSSH'
set -e
rdma_iface="$1"
if ! modprobe rdma_rxe 2>/dev/null; then
  echo "  Installing Soft-RoCE kernel module on $(hostname)..."
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    "linux-modules-extra-$(uname -r)"
  modprobe rdma_rxe
fi
rdma link delete rxe0 2>/dev/null || true
rdma link add rxe0 type rxe netdev "${rdma_iface}"
state=$(rdma link show rxe0/1 | awk '{print $4}')
echo "  rxe0 on $(hostname): ${state}"
test "${state}" = "ACTIVE"
VMSSH
done
ENDSSH
echo "Soft-RoCE setup done."
