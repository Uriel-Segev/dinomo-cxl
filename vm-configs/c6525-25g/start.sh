#!/bin/bash
# ============================================================
#  DINOMO Start Script
#  Starts all 5 DINOMO components in the correct order with
#  proper waits and verification at each step.
#  Run from repo root: bash vm-configs/c6525-25g/start.sh
# ============================================================
#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

echo "============================================"
echo " Starting DINOMO on ${CLOUDLAB_HOST}"
echo "============================================"

# ------------------------------------------------------------
# Step 1: Install dependencies and build DINOMO binaries
# ------------------------------------------------------------
echo ""
echo "[1/7] Installing dependencies & building DINOMO across nodes..."
$SSH ${SSH_USER}@${CLOUDLAB_HOST} "VM_STORAGE='${VM_STORAGE}' VM_KVS='${VM_KVS}' VM_ROUTE='${VM_ROUTE}' VM_MONITOR='${VM_MONITOR}' VM_BENCH='${VM_BENCH}' VM_USER='${VM_USER}' DINOMO_DIR='${DINOMO_DIR}' bash -s" << 'ENDSSH'
for vm_ip in ${VM_STORAGE} ${VM_KVS} ${VM_ROUTE} ${VM_MONITOR} ${VM_BENCH}; do
  ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ${VM_USER}@${vm_ip} "
    # Install build tools and libraries (including jemalloc and protobuf)
    sudo apt-get update -qq && sudo apt-get install -y -qq \
      build-essential cmake pkg-config libjemalloc-dev libprotobuf-dev \
      protobuf-compiler libibverbs-dev librdmacm-dev libgflags-dev \
      libgoogle-glog-dev libsnappy-dev libboost-all-dev libgrpc++-dev protobuf-compiler-grpc \
      ibverbs-utils

    cd ${DINOMO_DIR}
    git submodule update --init --recursive

    # Link dinomo-config.yml on every node
    # dinomo binary looks for conf/dinomo-config.yml instead of conf/dinomo-base.yml
    ln -sf dinomo-base.yml conf/dinomo-config.yml 2>/dev/null || true

    # Build libbloom dependency if libbloom.so is missing
    if [ ! -f src/kvs/libbloom/build/libbloom.so ]; then
      echo '  Building libbloom dependency...'
      (cd src/kvs/libbloom && make)
    fi

    # Build DINOMO if target binary does not exist
    if [ ! -f ${DINOMO_DIR}/build/target/kvs/dinomo-storage ]; then
      echo '  Building DINOMO on \$(hostname)...'
      cd ${DINOMO_DIR}
      rm -rf build && mkdir -p build && cd build
      cmake .. && make -j\$(nproc)
    fi
  " &
done
wait
ENDSSH
echo "  Done."

# ------------------------------------------------------------
# Step 2: Kill any leftover processes and delete the pool
# ------------------------------------------------------------
echo ""
echo "[2/7] Cleaning up old processes..."
$SSH ${SSH_USER}@${CLOUDLAB_HOST} "VM_STORAGE='${VM_STORAGE}' VM_KVS='${VM_KVS}' VM_ROUTE='${VM_ROUTE}' VM_MONITOR='${VM_MONITOR}' VM_BENCH='${VM_BENCH}' VM_USER='${VM_USER}' bash -s" << 'ENDSSH'
for vm_ip in ${VM_STORAGE} ${VM_KVS} ${VM_ROUTE} ${VM_MONITOR} ${VM_BENCH}; do
  ssh -o StrictHostKeyChecking=no ${VM_USER}@${vm_ip} \
    'sudo pkill -9 -f "dinomo-(storage|kvs|route|monitor|bench)" 2>/dev/null; sudo rm -f /dev/shm/pool; echo "  clean: $(hostname)"' &
done
wait
ENDSSH
echo "  Done."

# ------------------------------------------------------------
# Step 3: Load Soft-RoCE in storage and kvs VMs
# ------------------------------------------------------------
echo ""
echo "[3/7] Setting up Soft-RoCE (rdma_rxe)..."
$SSH ${SSH_USER}@${CLOUDLAB_HOST} "VM_STORAGE='${VM_STORAGE}' VM_KVS='${VM_KVS}' VM_USER='${VM_USER}' VM_RDMA_IFACE='${VM_RDMA_IFACE}' bash -s" << 'ENDSSH'
for vm_ip in ${VM_STORAGE} ${VM_KVS}; do
  ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ${VM_USER}@${vm_ip} "
    if ! modinfo rdma_rxe &>/dev/null; then
      echo '  Installing linux-modules-extra...'
      sudo apt-get update -qq
      sudo apt-get install -y -qq linux-modules-extra-\$(uname -r) || \
        sudo apt-get install -y -qq linux-modules-extra-generic
    fi
    sudo modprobe rdma_rxe
    sudo rdma link delete rxe0 2>/dev/null || true
    sudo rdma link add rxe0 type rxe netdev ${VM_RDMA_IFACE}
    state=\$(rdma link show | grep rxe0 | awk '{print \$4}')
    echo \"  rxe0 on \$(hostname): \${state}\"
  " &
done
wait
ENDSSH
echo "  Done."

# ------------------------------------------------------------
# Step 4: Start storage and wait until it is ready
# ------------------------------------------------------------
echo ""
echo "[4/7] Starting dinomo-storage..."
$SSH ${SSH_USER}@${CLOUDLAB_HOST} "VM_STORAGE='${VM_STORAGE}' VM_USER='${VM_USER}' DINOMO_DIR='${DINOMO_DIR}' bash -s" << 'ENDSSH'
# In Step 4 before running dinomo-storage:
ssh -o StrictHostKeyChecking=no ${VM_USER}@${VM_STORAGE} "
  cd ${DINOMO_DIR}

  sudo rm -f /dev/shm/pool
  nohup sudo ./build/target/kvs/dinomo-storage > /tmp/dinomo-storage.log 2>&1 < /dev/null &
  echo \"  storage PID: \$!\"
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
    exit 1
  fi
done

# ------------------------------------------------------------
# Step 5: Start kvs (must happen after storage is ready)
# ------------------------------------------------------------
echo ""
echo "[5/7] Starting dinomo-kvs..."
$SSH ${SSH_USER}@${CLOUDLAB_HOST} "VM_KVS='${VM_KVS}' VM_USER='${VM_USER}' DINOMO_DIR='${DINOMO_DIR}' bash -s" << 'ENDSSH'
ssh -o StrictHostKeyChecking=no ${VM_USER}@${VM_KVS} "
  cd ${DINOMO_DIR}
  nohup sudo ./build/target/kvs/dinomo-kvs > /tmp/dinomo-kvs.log 2>&1 < /dev/null &
  echo \"  kvs PID: \$!\"
"
ENDSSH

sleep 3

# ------------------------------------------------------------
# Step 6: Start route, monitor, bench
# ------------------------------------------------------------
echo ""
echo "[6/7] Starting route, monitor, bench..."
$SSH ${SSH_USER}@${CLOUDLAB_HOST} "VM_ROUTE='${VM_ROUTE}' VM_MONITOR='${VM_MONITOR}' VM_BENCH='${VM_BENCH}' VM_USER='${VM_USER}' DINOMO_DIR='${DINOMO_DIR}' bash -s" << 'ENDSSH'
ssh -o StrictHostKeyChecking=no ${VM_USER}@${VM_ROUTE} "
  cd ${DINOMO_DIR}
  nohup ./build/target/kvs/dinomo-route > /tmp/dinomo-route.log 2>&1 < /dev/null &
  echo \"  route PID: \$!\"
" &
ssh -o StrictHostKeyChecking=no ${VM_USER}@${VM_MONITOR} "
  cd ${DINOMO_DIR}
  nohup ./build/target/kvs/dinomo-monitor > /tmp/dinomo-monitor.log 2>&1 < /dev/null &
  echo \"  monitor PID: \$!\"
" &
ssh -o StrictHostKeyChecking=no ${VM_USER}@${VM_BENCH} "
  cd ${DINOMO_DIR}
  nohup ./build/target/benchmark/dinomo-bench > /tmp/dinomo-bench.log 2>&1 < /dev/null &
  echo \"  bench PID: \$!\"
" &
wait
ENDSSH

# ------------------------------------------------------------
# Step 7: Wait for kvs to complete RDMA handshake
# ------------------------------------------------------------
echo ""
echo "[7/7] Waiting for kvs RDMA handshake (STEP4 on all 4 threads)..."
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
echo " Run test:   bash vm-configs/c6525-25g/test.sh"
echo " Check logs: bash vm-configs/c6525-25g/check_logs.sh"
echo " Stop:       bash vm-configs/c6525-25g/stop.sh"
echo "============================================"
