#!/bin/bash
# ============================================================
#  DINOMO VM Setup Script
#  Run ONCE on a fresh CloudLab node to create all 5 VMs,
#  install dependencies, and build DINOMO.
#
#  Prerequisites:
#    1. Edit config.sh and set CLOUDLAB_HOST to this node's hostname
#    2. Ensure SSH key is registered with CloudLab
#
#  Run from repo root: bash vm-configs/c6525-25g/setup_vms.sh
#
#  This will take 15-30 minutes on first run.
# ============================================================

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

echo "============================================"
echo " DINOMO VM Setup"
echo " Host:      ${CLOUDLAB_HOST}"
echo " Node type: ${NODE_TYPE}"
echo " Data dir:  ${HOST_DATA_DIR}"
echo "============================================"
echo ""
echo "This will take 15-30 minutes. Do not interrupt."
echo ""

# -------------------------------------------------------
# Phase 1: Prepare the host (install KVM, create networks)
# -------------------------------------------------------
echo "[Phase 1/4] Preparing host..."
$SSH ${SSH_USER}@${CLOUDLAB_HOST} 'bash -s' << 'ENDSSH'
set -e

echo "  Installing KVM and libvirt..."
sudo apt-get update -qq
sudo apt-get install -y -qq \
  qemu-kvm libvirt-daemon-system libvirt-clients virtinst \
  bridge-utils cloud-image-utils genisoimage \
  rdma-core libibverbs-dev

# Ensure libvirt service is running
sudo systemctl enable --now libvirtd

# br-rdma is a separate Linux bridge from the default libvirt NAT bridge (virbr0).
# We use a dedicated bridge so RDMA traffic stays on its own subnet (10.0.0.x) and
# Soft-RoCE (rdma_rxe) can attach to a single predictable interface inside each VM.
echo "  Creating br-rdma bridge for RDMA traffic..."
if ! sudo ip link show br-rdma &>/dev/null; then
  sudo ip link add name br-rdma type bridge
  sudo ip link set br-rdma up
  sudo ip addr add 10.0.0.254/24 dev br-rdma
  echo "  br-rdma created"
else
  echo "  br-rdma already exists"
fi

# Make br-rdma persistent across reboots
if ! grep -q br-rdma /etc/network/interfaces 2>/dev/null && \
   ! ls /etc/netplan/*.yaml 2>/dev/null | xargs grep -l br-rdma 2>/dev/null | grep -q .; then
  sudo tee /etc/netplan/99-br-rdma.yaml > /dev/null << 'NETPLAN'
network:
  version: 2
  bridges:
    br-rdma:
      addresses: [10.0.0.254/24]
      parameters:
        stp: false
NETPLAN
  sudo netplan apply 2>/dev/null || true
fi

# Define br-rdma as a libvirt network so VMs can attach to it
if ! sudo virsh net-info rdma-net &>/dev/null; then
  sudo tee /tmp/rdma-net.xml > /dev/null << 'NETXML'
<network>
  <name>rdma-net</name>
  <forward mode='bridge'/>
  <bridge name='br-rdma'/>
</network>
NETXML
  sudo virsh net-define /tmp/rdma-net.xml
  sudo virsh net-autostart rdma-net
  sudo virsh net-start rdma-net
  echo "  rdma-net libvirt network created"
else
  echo "  rdma-net already defined"
fi

echo "  Phase 1 done."
ENDSSH

# -------------------------------------------------------
# Phase 2: Download base image and create VM disks
# -------------------------------------------------------
echo ""
echo "[Phase 2/4] Creating VM disk images..."
$SSH ${SSH_USER}@${CLOUDLAB_HOST} 'bash -s' << ENDSSH
set -e

DATA="${HOST_DATA_DIR}"
BASE="${HOST_BASE_IMAGE}"

# Download Ubuntu 20.04 cloud image if not present
if [ ! -f "\${BASE}" ]; then
  echo "  Downloading Ubuntu 20.04 cloud image (~600MB)..."
  sudo wget -q -O "\${BASE}" \
    https://cloud-images.ubuntu.com/focal/current/focal-server-cloudimg-amd64.img
  echo "  Download done."
else
  echo "  Base image already exists."
fi

# Create qcow2 overlay disks backed by the base image (copy-on-write).
# Each VM gets its own overlay — they share the read-only base image on disk
# but writes go to the per-VM file, so they start near-empty and grow lazily.
for vm in storage kvs route monitor bench; do
  disk="\${DATA}/dinomo-\${vm}.qcow2"
  if [ ! -f "\${disk}" ]; then
    sudo qemu-img create -f qcow2 -b "\${BASE}" -F qcow2 "\${disk}" 20G
    echo "  Created \${disk}"
  else
    echo "  \${disk} already exists, skipping."
  fi
done

echo "  Phase 2 done."
ENDSSH

# -------------------------------------------------------
# Phase 3: Create and boot the VMs
# -------------------------------------------------------
echo ""
echo "[Phase 3/4] Creating and booting VMs..."

# VM definitions: name, vcpus, ram_mb, mgmt_ip, rdma_ip (empty = no rdma NIC)
declare -A VM_VCPUS=( [storage]=8 [kvs]=8 [route]=4 [monitor]=4 [bench]=4 )
declare -A VM_RAM=(   [storage]=24576 [kvs]=24576 [route]=8192 [monitor]=8192 [bench]=16384 )
declare -A VM_MGMT=(  [storage]=${VM_STORAGE} [kvs]=${VM_KVS} [route]=${VM_ROUTE} [monitor]=${VM_MONITOR} [bench]=${VM_BENCH} )
declare -A VM_RDMA=(  [storage]="10.0.0.1" [kvs]="10.0.0.2" [route]="" [monitor]="" [bench]="" )

$SSH ${SSH_USER}@${CLOUDLAB_HOST} 'bash -s' << ENDSSH
set -e
DATA="${HOST_DATA_DIR}"

create_vm() {
  local name="\$1"
  local vcpus="\$2"
  local ram="\$3"
  local mgmt_ip="\$4"
  local rdma_ip="\$5"

  if sudo virsh dominfo "dinomo-\${name}" &>/dev/null; then
    echo "  dinomo-\${name} already exists, skipping."
    return
  fi

  echo "  Creating dinomo-\${name} (${vcpus}vCPU, ${ram}MB)..."

  # Build cloud-init user-data
  cat > /tmp/user-data-\${name}.yaml << USERDATA
#cloud-config
hostname: dinomo-\${name}
users:
  - name: ubuntu
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys:
      - \$(cat ~/.ssh/authorized_keys | head -1)
package_update: true
packages:
  - build-essential
  - cmake
  - git
  - python3
  - libibverbs-dev
  - librdmacm-dev
  - rdma-core
  - libtbb-dev
  - libzmq3-dev
  - libboost-all-dev
  - libyaml-cpp-dev
  - libpmemobj-dev
  - libpmem-dev
  - numactl
  - wget
runcmd:
  - echo "cloud-init done" > /tmp/cloud-init-done
USERDATA

  # Build cloud-init network config (static mgmt IP + optional rdma IP)
  if [ -n "\${rdma_ip}" ]; then
    cat > /tmp/network-\${name}.yaml << NETCFG
version: 2
ethernets:
  enp1s0:
    dhcp4: false
    addresses: [\${mgmt_ip}/24]
    gateway4: 192.168.122.1
    nameservers:
      addresses: [8.8.8.8]
  enp2s0:
    dhcp4: false
    addresses: [\${rdma_ip}/24]
NETCFG
    EXTRA_NIC="--network network=rdma-net,model=virtio"
  else
    cat > /tmp/network-\${name}.yaml << NETCFG
version: 2
ethernets:
  enp1s0:
    dhcp4: false
    addresses: [\${mgmt_ip}/24]
    gateway4: 192.168.122.1
    nameservers:
      addresses: [8.8.8.8]
NETCFG
    EXTRA_NIC=""
  fi

  # Create cloud-init ISO
  cloud-localds /tmp/seed-\${name}.iso /tmp/user-data-\${name}.yaml \
    --network-config /tmp/network-\${name}.yaml

  # Install VM
  sudo virt-install \
    --name "dinomo-\${name}" \
    --vcpus \${vcpus} \
    --memory \${ram} \
    --disk path=\${DATA}/dinomo-\${name}.qcow2,format=qcow2 \
    --disk path=/tmp/seed-\${name}.iso,device=cdrom \
    --network network=default,model=virtio \
    \${EXTRA_NIC} \
    --os-type linux \
    --os-variant ubuntu20.04 \
    --import \
    --noautoconsole \
    --autostart

  echo "  dinomo-\${name} created and booting."
}

create_vm storage 8  24576 ${VM_STORAGE} "10.0.0.1"
create_vm kvs     8  24576 ${VM_KVS}     "10.0.0.2"
create_vm route   4  8192  ${VM_ROUTE}   ""
create_vm monitor 4  8192  ${VM_MONITOR} ""
create_vm bench   4  16384 ${VM_BENCH}   ""

echo "  Waiting for all VMs to finish booting and cloud-init (~5 min)..."
for name in storage kvs route monitor bench; do
  echo -n "  Waiting for dinomo-\${name}"
  for i in \$(seq 1 60); do
    sleep 10
    done=\$(ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
      ubuntu@\$(case \$name in
        storage) echo ${VM_STORAGE} ;;
        kvs)     echo ${VM_KVS} ;;
        route)   echo ${VM_ROUTE} ;;
        monitor) echo ${VM_MONITOR} ;;
        bench)   echo ${VM_BENCH} ;;
      esac) 'cat /tmp/cloud-init-done 2>/dev/null' 2>/dev/null)
    if [ "\${done}" = "cloud-init done" ]; then
      echo " ready."
      break
    fi
    echo -n "."
    if [ \$i -eq 60 ]; then
      echo " TIMEOUT. Check: sudo virsh console dinomo-\${name}"
    fi
  done
done

echo "  Phase 3 done."
ENDSSH

# -------------------------------------------------------
# Phase 4: Clone DINOMO and build on each VM
# -------------------------------------------------------
echo ""
echo "[Phase 4/4] Cloning and building DINOMO on each VM..."

build_on_vm() {
  local vm_ip="$1"
  local vm_name="$2"
  echo "  Building on ${vm_name} (${vm_ip})..."
  $SSH ${SSH_USER}@${CLOUDLAB_HOST} 'bash -s' << ENDSSH
ssh -o StrictHostKeyChecking=no ${VM_USER}@${vm_ip} 'bash -s' << 'VMSSH'
set -e
cd ~
if [ ! -d projects/DINOMO ]; then
  mkdir -p projects
  cd projects
  git clone ${DINOMO_REPO} DINOMO
  cd DINOMO
else
  cd projects/DINOMO
  git pull
fi

# -mavx2 is in the original CMakeLists.txt but CloudLab VMs don't always expose AVX2
# to guests even if the host supports it, causing an illegal instruction crash at startup.
sed -i 's/-mavx2//g' CMakeLists.txt

# PMDK TLS crash fix: server_manager_thread calls pmemobj_zalloc() on demand, but PMDK 1.8
# doesn't initialize its thread-local storage in that thread — it only initializes TLS in the
# main thread. When pmemobj_zalloc() tries to read the error message via pmemobj_errormsg()
# it dereferences a NULL TLS pointer (NULL+0x1808) and crashes ~40s into a benchmark run.
# Fix: pre-allocate 32 spare log blocks from the main thread into reserved_alloc_queue before
# any worker threads start, so server_manager_thread never needs to call pmemobj_zalloc.
if ! grep -q "Pre-allocate spare log blocks" src/kvs/dinomo_storage.cpp; then
  python3 - << 'PYFIX'
import re

with open('src/kvs/dinomo_storage.cpp', 'r') as f:
    content = f.read()

fix = """
    // Pre-allocate spare log blocks from the main thread where PMDK TLS is initialized.
    // server_manager_thread does not have PMDK TLS set up, so calling pmemobj_zalloc
    // from that thread crashes in pmemobj_errormsg (NULL TLS + offset 0x1808).
    // By pre-populating reserved_alloc_queue here, server_manager_thread can always
    // pop a block instead of calling pmemobj_zalloc directly.
    {
        const int spare_blocks = 32;
        int n_ok = 0;
        for (int b = 0; b < spare_blocks; b++) {
            PMEMoid ret;
            if (pmemobj_zalloc(pop, &ret, sizeof(log_block) + MAX_LOG_BLOCK_LEN, 0)) {
                fprintf(stderr, "[storage] pmemobj_zalloc failed at spare block %d\\n", b);
                break;
            }
            reserved_alloc_queue->push((uint64_t)pmemobj_direct(ret));
            n_ok++;
        }
        fprintf(stderr, "[storage] Pre-allocated %d spare log blocks (%lu MB each)\\n",
                n_ok, (sizeof(log_block) + MAX_LOG_BLOCK_LEN) / (1024*1024));
    }
"""

# Insert the fix before the line that starts server_manager_thread
marker = 'pthread_create(&server_manager_tid'
idx = content.find(marker)
if idx == -1:
    print("ERROR: could not find insertion point for fix")
    exit(1)

# Go back to start of that line
line_start = content.rfind('\n', 0, idx) + 1
content = content[:line_start] + fix + content[line_start:]

with open('src/kvs/dinomo_storage.cpp', 'w') as f:
    f.write(content)

print("Fix applied successfully.")
PYFIX
fi

# Build
mkdir -p build && cd build
cmake .. -DCMAKE_BUILD_TYPE=Release > /tmp/cmake.log 2>&1
make -j$(nproc) > /tmp/make.log 2>&1
echo "Build complete on $(hostname)"
VMSSH
ENDSSH
  echo "  Done: ${vm_name}"
}

# Build in parallel on all 5 VMs
build_on_vm "${VM_STORAGE}" "storage" &
build_on_vm "${VM_KVS}"     "kvs"     &
build_on_vm "${VM_ROUTE}"   "route"   &
build_on_vm "${VM_MONITOR}" "monitor" &
build_on_vm "${VM_BENCH}"   "bench"   &
wait

# Copy config files to each VM
echo ""
echo "  Deploying DINOMO config files..."
for vm_ip in ${VM_STORAGE} ${VM_KVS} ${VM_ROUTE} ${VM_MONITOR} ${VM_BENCH}; do
  $SSH ${SSH_USER}@${CLOUDLAB_HOST} 'bash -s' << ENDSSH &
    scp -o StrictHostKeyChecking=no \
      /dev/stdin ${VM_USER}@${vm_ip}:~/projects/DINOMO/conf/dinomo-base.yml << 'CONFEOF'
$(cat "${SCRIPT_DIR}/conf/dinomo-base.yml")
CONFEOF
    scp -o StrictHostKeyChecking=no \
      /dev/stdin ${VM_USER}@${vm_ip}:~/projects/DINOMO/conf/dinomo-vm-config.yml << 'CONFEOF'
$(cat "${SCRIPT_DIR}/conf/dinomo-vm-config.yml")
CONFEOF
ENDSSH
done
wait

echo "  Phase 4 done."

echo ""
echo "============================================"
echo " Setup complete!"
echo ""
echo " Next steps:"
echo "   1. Start DINOMO:  bash vm-configs/c6525-25g/start.sh"
echo "   2. Run tests:     bash vm-configs/c6525-25g/test.sh"
echo "============================================"
