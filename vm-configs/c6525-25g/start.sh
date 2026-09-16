#!/bin/bash
# ============================================================
#  DINOMO Start Script
#  Starts all 5 DINOMO components in the correct order with
#  proper waits and verification at each step.
#  Run from repo root: bash vm-configs/c6525-25g/start.sh
# ============================================================

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

echo "============================================"
echo " Starting DINOMO on ${CLOUDLAB_HOST}"
echo "============================================"

# ------------------------------------------------------------
# Step 1: Kill any leftover processes and delete the pool
# ------------------------------------------------------------
echo ""
echo "[1/6] Cleaning up old processes..."
# Kill across all VMs in parallel (& ... wait) so cleanup is fast.
# /dev/shm/pool is the PMDK persistent memory pool on the storage VM. It must be
# deleted before each run so storage creates it fresh and remote_start_addr is valid.
$SSH ${SSH_USER}@${CLOUDLAB_HOST} 'bash -s' << ENDSSH
for vm_ip in ${VM_STORAGE} ${VM_KVS} ${VM_ROUTE} ${VM_MONITOR} ${VM_BENCH}; do
  ssh -o StrictHostKeyChecking=no ${VM_USER}@\${vm_ip} \
    'sudo pkill -9 -f "dinomo-(storage|kvs|route|monitor|bench)" 2>/dev/null; sudo rm -f /dev/shm/pool; echo "  clean: \$(hostname)"' &
done
wait
ENDSSH
echo "  Done."

# ------------------------------------------------------------
# Step 2: Load Soft-RoCE in storage and kvs VMs
# ------------------------------------------------------------
echo ""
echo "[2/6] Setting up Soft-RoCE (rdma_rxe)..."
# rdma_rxe is a kernel module that implements RDMA over a regular Ethernet interface.
# It is not persistent across VM reboots so it must be loaded every time.
# We delete any existing rxe0 device first to avoid "device busy" errors on re-runs,
# then attach a fresh one to VM_RDMA_IFACE (the NIC on the br-rdma bridge).
# The port state must show ACTIVE before DINOMO can use it.
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

# Minimal Ubuntu cloud images do not include optional kernel modules. Install
# the package matching the running kernel only when rdma_rxe is absent.
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
if [ "${state}" != "ACTIVE" ]; then
  echo "ERROR: rxe0 is not ACTIVE on $(hostname)."
  exit 1
fi
VMSSH
done
ENDSSH
echo "  Done."

# ------------------------------------------------------------
# Step 3: Start storage and wait until it is ready
# ------------------------------------------------------------
echo ""
echo "[3/6] Starting dinomo-storage..."
$SSH ${SSH_USER}@${CLOUDLAB_HOST} 'bash -s' << ENDSSH
ssh -o StrictHostKeyChecking=no ${VM_USER}@${VM_STORAGE} "
  cd ${DINOMO_DIR}
  sudo rm -f /dev/shm/pool
  nohup sudo ./build/target/kvs/dinomo-storage > /tmp/dinomo-storage.log 2>&1 < /dev/null &
  echo \"  storage launch requested\"
"
ENDSSH

# Wait for "start to listen" in storage log before starting kvs.
# This line is printed by connect_qp_server() once storage has opened its TCP socket
# for the Queue Pair handshake. kvs connects immediately at startup — if storage is
# not ready yet, the connection fails and both processes must be restarted.
echo -n "  Waiting for storage to open RDMA socket"
for i in $(seq 1 30); do
  sleep 2
  ready=$($SSH ${SSH_USER}@${CLOUDLAB_HOST} \
    "ssh -o StrictHostKeyChecking=no ${VM_USER}@${VM_STORAGE} \
     'grep -c \"start to listen\" /tmp/dinomo-storage.log 2>/dev/null || echo 0'")
  if [ "${ready}" -ge 1 ] 2>/dev/null; then
    echo " ready."
    break
  fi
  echo -n "."
  if [ $i -eq 30 ]; then
    echo ""
    echo "ERROR: storage did not become ready after 60s. Check /tmp/dinomo-storage.log"
    $SSH ${SSH_USER}@${CLOUDLAB_HOST} \
      "ssh -o StrictHostKeyChecking=no ${VM_USER}@${VM_STORAGE} \
       'tail -40 /tmp/dinomo-storage.log 2>/dev/null || true'" || true
    exit 1
  fi
done

# ------------------------------------------------------------
# Step 4: Start kvs (must happen after storage is ready)
# ------------------------------------------------------------
echo ""
echo "[4/6] Starting dinomo-kvs..."
$SSH ${SSH_USER}@${CLOUDLAB_HOST} 'bash -s' << ENDSSH
ssh -o StrictHostKeyChecking=no ${VM_USER}@${VM_KVS} "
  cd ${DINOMO_DIR}
  # < /dev/null prevents nohup from holding the SSH session open waiting for stdin.
  nohup sudo ./build/target/kvs/dinomo-kvs > /tmp/dinomo-kvs.log 2>&1 < /dev/null &
  echo \"  kvs launch requested\"
"
ENDSSH

# Short wait so kvs can initiate its TCP connection to storage for the Queue Pair
# handshake before route/monitor/bench start sending ZMQ messages to kvs.
sleep 3

# ------------------------------------------------------------
# Step 5: Start route, monitor, bench
# ------------------------------------------------------------
echo ""
echo "[5/6] Starting route, monitor, bench..."
$SSH ${SSH_USER}@${CLOUDLAB_HOST} 'bash -s' << ENDSSH
ssh -o StrictHostKeyChecking=no ${VM_USER}@${VM_ROUTE} "
  cd ${DINOMO_DIR}
  nohup ./build/target/kvs/dinomo-route > /tmp/dinomo-route.log 2>&1 < /dev/null &
  echo \"  route launch requested\"
" &
ssh -o StrictHostKeyChecking=no ${VM_USER}@${VM_MONITOR} "
  cd ${DINOMO_DIR}
  nohup ./build/target/kvs/dinomo-monitor > /tmp/dinomo-monitor.log 2>&1 < /dev/null &
  echo \"  monitor launch requested\"
" &
ssh -o StrictHostKeyChecking=no ${VM_USER}@${VM_BENCH} "
  # benchmark.cpp derives node_id from characters after the 'bench' prefix.
  # This single benchmark VM must therefore identify itself as bench0.
  sudo hostnamectl set-hostname bench0
  cd ${DINOMO_DIR}
  nohup ./build/target/benchmark/dinomo-bench > /tmp/dinomo-bench.log 2>&1 < /dev/null &
  echo \"  bench launch requested\"
" &
wait
ENDSSH

# ------------------------------------------------------------
# Step 6: Wait for kvs to complete RDMA handshake (STEP4 x4)
# ------------------------------------------------------------
echo ""
echo "[6/6] Waiting for kvs RDMA handshake (STEP4 on all 4 threads)..."
# "raddr_pool=" is printed by each kvs worker thread in dinomo_compute.hpp after it
# reads the hash table header from storage via RDMA and confirms remote_start_addr
# matches raddr_pool. Four such lines means all threads completed the handshake.
for i in $(seq 1 30); do
  sleep 2
  step4_count=$($SSH ${SSH_USER}@${CLOUDLAB_HOST} \
    "ssh -o StrictHostKeyChecking=no ${VM_USER}@${VM_KVS} \
     'grep -c \"raddr_pool=\" /tmp/dinomo-kvs.log 2>/dev/null || echo 0'")
  echo -n "  ${step4_count}/4 threads ready..."
  if [ "${step4_count}" -ge 4 ] 2>/dev/null; then
    echo " done."
    break
  fi
  echo ""
  if [ $i -eq 30 ]; then
    echo ""
    echo "ERROR: kvs did not complete RDMA handshake after 60s. Check /tmp/dinomo-kvs.log"
    exit 1
  fi
done

echo ""
echo "============================================"
echo " DINOMO is ready."
echo " Run test:  bash vm-configs/c6525-25g/test.sh"
echo " Check logs: bash vm-configs/c6525-25g/check_logs.sh"
echo " Stop:      bash vm-configs/c6525-25g/stop.sh"
echo "============================================"
