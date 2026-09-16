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
# Phase 1: Prepare the host (data disk, KVM, and networks)
# -------------------------------------------------------
echo "[Phase 1/4] Preparing host..."
$SSH ${SSH_USER}@${CLOUDLAB_HOST} bash -s -- "${HOST_DATA_DIR}" "${HOST_DATA_DEVICE}" << 'ENDSSH'
set -e

DATA_DIR="$1"
DATA_DEVICE="$2"

# Fresh CloudLab c6525-25g nodes expose /dev/sdb as an unformatted scratch
# disk. Keep VM images off the small root partition. Existing filesystems are
# preserved; a disk with partitions is rejected instead of being overwritten.
echo "  Preparing VM data disk ${DATA_DEVICE} at ${DATA_DIR}..."
if [ ! -b "${DATA_DEVICE}" ]; then
  echo "ERROR: configured data device ${DATA_DEVICE} does not exist."
  exit 1
fi

mounted_at=$(findmnt -rn -S "${DATA_DEVICE}" -o TARGET | head -n 1 || true)
if [ -n "${mounted_at}" ] && [ "${mounted_at}" != "${DATA_DIR}" ]; then
  echo "ERROR: ${DATA_DEVICE} is already mounted at ${mounted_at}, not ${DATA_DIR}."
  exit 1
fi
if mountpoint -q "${DATA_DIR}"; then
  mounted_source=$(findmnt -rn -M "${DATA_DIR}" -o SOURCE)
  if [ "${mounted_source}" != "${DATA_DEVICE}" ]; then
    echo "ERROR: ${DATA_DIR} is already mounted from ${mounted_source}, not ${DATA_DEVICE}."
    exit 1
  fi
fi

if ! sudo blkid "${DATA_DEVICE}" >/dev/null 2>&1; then
  if [ "$(lsblk -nr -o TYPE "${DATA_DEVICE}" | wc -l)" -ne 1 ]; then
    echo "ERROR: ${DATA_DEVICE} has partitions but no filesystem on the whole disk."
    echo "Set HOST_DATA_DEVICE to the intended formatted partition."
    exit 1
  fi
  echo "  Creating ext4 filesystem on empty scratch disk ${DATA_DEVICE}..."
  sudo mkfs.ext4 -F "${DATA_DEVICE}" >/dev/null
fi
data_fstype=$(sudo blkid -s TYPE -o value "${DATA_DEVICE}")
if [ -z "${data_fstype}" ]; then
  echo "ERROR: unable to determine the filesystem type on ${DATA_DEVICE}."
  exit 1
fi

sudo mkdir -p "${DATA_DIR}"
if ! mountpoint -q "${DATA_DIR}"; then
  sudo mount "${DATA_DEVICE}" "${DATA_DIR}"
fi
data_uuid=$(sudo blkid -s UUID -o value "${DATA_DEVICE}")
if ! awk -v target="${DATA_DIR}" \
  '$1 !~ /^#/ && $2 == target { found=1 } END { exit !found }' /etc/fstab; then
  echo "UUID=${data_uuid} ${DATA_DIR} ${data_fstype} defaults,nofail 0 2" | sudo tee -a /etc/fstab >/dev/null
fi
sudo chown "$(id -u):$(id -g)" "${DATA_DIR}"

echo "  Installing KVM and libvirt..."
sudo apt-get update -qq
sudo apt-get install -y -qq \
  qemu-kvm libvirt-daemon-system libvirt-clients virtinst \
  bridge-utils cloud-image-utils genisoimage \
  rdma-core libibverbs-dev

# Ensure libvirt service is running
sudo systemctl enable --now libvirtd

# This key is used only for the host-to-VM SSH hop. cloud-init installs its
# public half in every VM below.
if [ ! -f ~/.ssh/id_ed25519 ]; then
  mkdir -p ~/.ssh
  chmod 700 ~/.ssh
  ssh-keygen -q -t ed25519 -N '' -f ~/.ssh/id_ed25519
fi

# Ubuntu normally ships the default NAT network with libvirt, but ensure it is
# defined and active before assigning the VMs their management interfaces.
if ! sudo virsh net-info default >/dev/null 2>&1; then
  sudo virsh net-define /usr/share/libvirt/networks/default.xml
fi
sudo virsh net-autostart default >/dev/null
if ! sudo virsh net-info default | grep -q 'Active:.*yes'; then
  sudo virsh net-start default >/dev/null
fi

# br-rdma is a separate Linux bridge from the default libvirt NAT bridge (virbr0).
# We use a dedicated bridge so RDMA traffic stays on its own subnet (10.0.0.x) and
# Soft-RoCE (rdma_rxe) can attach to a single predictable interface inside each VM.
echo "  Creating br-rdma bridge for RDMA traffic..."
if ! sudo ip link show br-rdma &>/dev/null; then
  sudo ip link add name br-rdma type bridge
  echo "  br-rdma created"
else
  echo "  br-rdma already exists"
fi
sudo ip link set br-rdma up
if ! ip -4 address show dev br-rdma | grep -q '10\.0\.0\.254/24'; then
  sudo ip addr add 10.0.0.254/24 dev br-rdma
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

# Download Ubuntu 20.04 cloud image if not present or invalid. Download to a
# temporary name so an interrupted transfer is never mistaken for a valid base.
if [ ! -f "\${BASE}" ] || ! sudo qemu-img info "\${BASE}" >/dev/null 2>&1; then
  echo "  Downloading Ubuntu 20.04 cloud image (~600MB)..."
  sudo rm -f "\${BASE}.download"
  sudo wget -q -O "\${BASE}.download" \
    https://cloud-images.ubuntu.com/focal/current/focal-server-cloudimg-amd64.img
  sudo qemu-img info "\${BASE}.download" >/dev/null
  sudo mv "\${BASE}.download" "\${BASE}"
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
  local mgmt_mac
  local rdma_mac
  case "\$name" in
    storage) mgmt_mac="52:54:00:00:00:25"; rdma_mac="52:54:00:10:00:25" ;;
    kvs)     mgmt_mac="52:54:00:00:00:50"; rdma_mac="52:54:00:10:00:50" ;;
    route)   mgmt_mac="52:54:00:00:00:99"; rdma_mac="52:54:00:10:00:99" ;;
    monitor) mgmt_mac="52:54:00:00:00:14"; rdma_mac="52:54:00:10:00:14" ;;
    bench)   mgmt_mac="52:54:00:00:00:67"; rdma_mac="52:54:00:10:00:67" ;;
  esac

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
      - \$(cat ~/.ssh/id_ed25519.pub)
package_update: false
packages: []
runcmd:
  - systemctl enable --now systemd-networkd
  - netplan generate
  - netplan apply
  - sleep 5
  - apt-get update
  - DEBIAN_FRONTEND=noninteractive apt-get install -y build-essential autoconf automake libtool pkg-config cmake git python3 libibverbs-dev librdmacm-dev rdma-core libtbb-dev libzmq3-dev libboost-all-dev libyaml-cpp-dev libpmemobj-dev libpmem-dev numactl wget
  - DEBIAN_FRONTEND=noninteractive apt-get install -y protobuf-compiler libprotobuf-dev libjemalloc-dev pciutils linux-modules-extra-generic
  - echo "cloud-init done" > /tmp/cloud-init-done
USERDATA

  # Build DHCP management network plus static RDMA network.
  if [ -n "\${rdma_ip}" ]; then
    cat > /tmp/network-\${name}.yaml << NETCFG
version: 2
renderer: networkd
ethernets:
  enp1s0:
    dhcp4: false
    addresses: [\${mgmt_ip}/24]
    routes:
      - to: default
        via: 192.168.122.1
    nameservers:
      addresses: [192.168.122.1]
  enp2s0:
    dhcp4: false
    addresses: [\${rdma_ip}/24]
NETCFG
    EXTRA_NIC="--network network=rdma-net,model=virtio,mac=\${rdma_mac}"
  else
    cat > /tmp/network-\${name}.yaml << NETCFG
version: 2
renderer: networkd
ethernets:
  enp1s0:
    dhcp4: false
    addresses: [\${mgmt_ip}/24]
    routes:
      - to: default
        via: 192.168.122.1
    nameservers:
      addresses: [192.168.122.1]
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
    --network network=default,model=virtio,mac=\${mgmt_mac} \
    \${EXTRA_NIC} \
    --os-variant ubuntu20.04 \
    --import \
    --noautoconsole \
    --autostart

  echo "  dinomo-\${name} created and booting."
}

# Reserve DINOMO management addresses in libvirt DHCP.
sudo virsh net-update default add ip-dhcp-host "<host mac='52:54:00:00:00:25' name='dinomo-storage' ip='192.168.122.25'/>" --live --config 2>/dev/null || true
sudo virsh net-update default add ip-dhcp-host "<host mac='52:54:00:00:00:50' name='dinomo-kvs' ip='192.168.122.150'/>" --live --config 2>/dev/null || true
sudo virsh net-update default add ip-dhcp-host "<host mac='52:54:00:00:00:99' name='dinomo-route' ip='192.168.122.99'/>" --live --config 2>/dev/null || true
sudo virsh net-update default add ip-dhcp-host "<host mac='52:54:00:00:00:14' name='dinomo-monitor' ip='192.168.122.114'/>" --live --config 2>/dev/null || true
sudo virsh net-update default add ip-dhcp-host "<host mac='52:54:00:00:00:67' name='dinomo-bench' ip='192.168.122.167'/>" --live --config 2>/dev/null || true

create_vm storage 8  24576 ${VM_STORAGE} "10.0.0.1"
create_vm kvs     8  24576 ${VM_KVS}     "10.0.0.2"
create_vm route   4  8192  ${VM_ROUTE}   ""
create_vm monitor 4  8192  ${VM_MONITOR} ""
create_vm bench   4  16384 ${VM_BENCH}   ""

echo "  Waiting for all VMs to finish booting and cloud-init (~5 min)..."
all_ready=1
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
      esac) 'cat /tmp/cloud-init-done 2>/dev/null' 2>/dev/null || true)
    if [ "\${done}" = "cloud-init done" ]; then
      echo " ready."
      break
    fi
    echo -n "."
    if [ \$i -eq 60 ]; then
      echo " TIMEOUT. Check: sudo virsh console dinomo-\${name}"
      all_ready=0
    fi
  done
done

if [ "\${all_ready}" -ne 1 ]; then
  echo "ERROR: one or more VMs did not finish cloud-init."
  exit 1
fi

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
  git clone --branch ${DINOMO_BRANCH} --single-branch ${DINOMO_REPO} DINOMO
  cd DINOMO
else
  cd projects/DINOMO
  git remote set-url origin ${DINOMO_REPO}
  git fetch origin ${DINOMO_BRANCH}
  git checkout ${DINOMO_BRANCH}
  git pull --ff-only origin ${DINOMO_BRANCH}
fi

# -mavx2 is in the original CMakeLists.txt but CloudLab VMs don't always expose AVX2
# to guests even if the host supports it, causing an illegal instruction crash at startup.
sed -i 's/-mavx2//g' CMakeLists.txt

# Keep the header-only logging dependency reproducible and include the header
# that declares basic_logger_mt in spdlog 1.x. These edits are idempotent and
# also cover installations made before the corresponding source change is pushed.
sed -i 's/GIT_TAG "master"/GIT_TAG "v1.10.0"/' common/vendor/spdlog/CMakeLists.txt
if ! grep -q 'spdlog/sinks/basic_file_sink.h' common/include/types.hpp; then
  sed -i '/#include "spdlog\/spdlog.h"/a #include "spdlog/sinks/basic_file_sink.h"' common/include/types.hpp
fi

# PMDK TLS crash fix: server_manager_thread calls pmemobj_zalloc() on demand, but PMDK 1.8
# doesn't initialize its thread-local storage in that thread — it only initializes TLS in the
# main thread. When pmemobj_zalloc() tries to read the error message via pmemobj_errormsg()
# it dereferences a NULL TLS pointer (NULL+0x1808) and crashes ~40s into a benchmark run.
# Fix: pre-allocate 32 spare log blocks from the main thread into reserved_alloc_queue before
# any worker threads start, so server_manager_thread never needs to call pmemobj_zalloc.
if ! grep -q "Pre-allocated %d spare log blocks" src/kvs/dinomo_storage.cpp; then
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
    print("PMDK fix marker not found; skipping because this fork may already contain the fix.")
else:
    line_start = content.rfind('\n', 0, idx) + 1
    content = content[:line_start] + fix + content[line_start:]

    with open('src/kvs/dinomo_storage.cpp', 'w') as f:
        f.write(content)

    print("Fix applied successfully.")
PYFIX
fi

# Build bundled libbloom first
cd src/kvs/libbloom
make -j\$(nproc)
cd ../../..

# Build DINOMO
mkdir -p build && cd build
cmake .. -DCMAKE_BUILD_TYPE=Release > /tmp/cmake.log 2>&1
make -j\$(nproc) > /tmp/make.log 2>&1
echo "Build complete on \$(hostname)"
VMSSH
ENDSSH
  echo "  Done: ${vm_name}"
}

# Build in parallel on all 5 VMs and preserve each failure status.
build_pids=()
build_names=()
for vm_spec in \
  "${VM_STORAGE}:storage" \
  "${VM_KVS}:kvs" \
  "${VM_ROUTE}:route" \
  "${VM_MONITOR}:monitor" \
  "${VM_BENCH}:bench"
do
  vm_ip="${vm_spec%%:*}"
  vm_name="${vm_spec#*:}"
  build_on_vm "${vm_ip}" "${vm_name}" &
  build_pids+=("$!")
  build_names+=("${vm_name}")
done

build_failed=0
for i in "${!build_pids[@]}"; do
  if ! wait "${build_pids[$i]}"; then
    echo "ERROR: build failed on ${build_names[$i]}."
    build_failed=1
  fi
done
if [ "${build_failed}" -ne 0 ]; then
  exit 1
fi

# Copy config files to each VM
echo ""
echo "  Deploying DINOMO config files..."
deploy_pids=()
deploy_ips=()
for vm_ip in ${VM_STORAGE} ${VM_KVS} ${VM_ROUTE} ${VM_MONITOR} ${VM_BENCH}; do
  $SSH ${SSH_USER}@${CLOUDLAB_HOST} 'bash -s' << ENDSSH &
    ssh -o StrictHostKeyChecking=no ${VM_USER}@${vm_ip} \
      "cat > ~/projects/DINOMO/conf/dinomo-base.yml" << 'CONFEOF'
$(cat "${SCRIPT_DIR}/conf/dinomo-base.yml")
CONFEOF
    ssh -o StrictHostKeyChecking=no ${VM_USER}@${vm_ip} \
      "cat > ~/projects/DINOMO/conf/dinomo-vm-config.yml" << 'CONFEOF'
$(cat "${SCRIPT_DIR}/conf/dinomo-vm-config.yml")
CONFEOF
    ssh -o StrictHostKeyChecking=no ${VM_USER}@${vm_ip} \
      "cat > ~/projects/DINOMO/conf/dinomo-config.yml" << 'CONFEOF'
$(cat "${SCRIPT_DIR}/conf/dinomo-vm-config.yml")
CONFEOF
ENDSSH
  deploy_pids+=("$!")
  deploy_ips+=("${vm_ip}")
done

deploy_failed=0
for i in "${!deploy_pids[@]}"; do
  if ! wait "${deploy_pids[$i]}"; then
    echo "ERROR: config deployment failed on ${deploy_ips[$i]}."
    deploy_failed=1
  fi
done
if [ "${deploy_failed}" -ne 0 ]; then
  exit 1
fi

echo "  Phase 4 done."

echo ""
echo "============================================"
echo " Setup complete!"
echo ""
echo " Next steps:"
echo "   1. Start DINOMO:  bash vm-configs/c6525-25g/start.sh"
echo "   2. Run tests:     bash vm-configs/c6525-25g/test.sh"
echo "============================================"
