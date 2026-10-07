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
# Step 1: Sync local source to every VM, install deps, build
# ------------------------------------------------------------
# The VMs build from *this* working tree (including uncommitted changes), not
# from a git remote: the fork is private, so the VMs cannot fetch it. Source goes
# local -> host staging dir -> each VM. --checksum without -t means only files
# whose content changed are rewritten, and they get a fresh mtime, so the
# incremental `make` below rebuilds exactly what changed.
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
VM_DINOMO_REL="${DINOMO_DIR#\~/}"   # rsync dest relative to the VM user's home
HOST_STAGING="dinomo-src-sync"      # relative to the host user's home
# Excluded paths are also protected from --delete on the receiving side:
# build dirs, the VM's old .git, the deployed config, and runtime logs.
RSYNC_EXCLUDES=(--exclude=.git/ --exclude=build/ --exclude=/conf/dinomo-config.yml
                --exclude='/log_*.txt' --exclude='/client*.log')

echo ""
echo "[1/7] Syncing source, installing dependencies & building DINOMO..."
echo "  Syncing ${REPO_ROOT} -> ${CLOUDLAB_HOST}:~/${HOST_STAGING}"
rsync -rlp --checksum --delete --filter=':- .gitignore' "${RSYNC_EXCLUDES[@]}" \
  -e "${SSH}" "${REPO_ROOT}/" ${SSH_USER}@${CLOUDLAB_HOST}:${HOST_STAGING}/

$SSH ${SSH_USER}@${CLOUDLAB_HOST} "VM_STORAGE='${VM_STORAGE}' VM_KVS='${VM_KVS}' VM_ROUTE='${VM_ROUTE}' VM_MONITOR='${VM_MONITOR}' VM_BENCH='${VM_BENCH}' VM_USER='${VM_USER}' VM_DINOMO_REL='${VM_DINOMO_REL}' HOST_STAGING='${HOST_STAGING}' RSYNC_EXCLUDES='${RSYNC_EXCLUDES[*]}' bash -s" << 'ENDSSH'
set -f   # RSYNC_EXCLUDES arrives as one string; split it on spaces but do not glob "log_*.txt"
VM_SSH="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
pids=()
for vm_ip in ${VM_STORAGE} ${VM_KVS} ${VM_ROUTE} ${VM_MONITOR} ${VM_BENCH}; do
  (
    set -e
    rsync -rlp --checksum --delete ${RSYNC_EXCLUDES} -e "${VM_SSH}" \
      ~/${HOST_STAGING}/ ${VM_USER}@${vm_ip}:${VM_DINOMO_REL}/
    ${VM_SSH} ${VM_USER}@${vm_ip} "DIR='${VM_DINOMO_REL}' bash -s" << 'VMSSH'
set -e
# Install build tools and libraries (including jemalloc and protobuf)
sudo apt-get update -qq && sudo apt-get install -y -qq \
  build-essential cmake pkg-config libjemalloc-dev libprotobuf-dev \
  protobuf-compiler libibverbs-dev librdmacm-dev libgflags-dev \
  libgoogle-glog-dev libsnappy-dev libboost-all-dev libgrpc++-dev protobuf-compiler-grpc \
  ibverbs-utils rsync > /dev/null

cd ~/${DIR}

# -mavx2 crashes with an illegal instruction if the VM CPU does not expose AVX2.
grep -qw avx2 /proc/cpuinfo || sed -i 's/-mavx2//g' CMakeLists.txt

# Build libbloom dependency if libbloom.so is missing
if [ ! -f src/kvs/libbloom/build/libbloom.so ]; then
  (cd src/kvs/libbloom && make > /tmp/libbloom-make.log 2>&1)
fi

# Incremental build: configure once, then make picks up whatever the sync changed.
mkdir -p build && cd build
[ -f Makefile ] || cmake .. -DCMAKE_BUILD_TYPE=Release > /tmp/cmake.log 2>&1
if ! make -j$(nproc) > /tmp/make.log 2>&1; then
  echo "  BUILD FAILED on $(hostname). Last lines of /tmp/make.log:"
  tail -20 /tmp/make.log | sed 's/^/    /'
  exit 1
fi
echo "  built: $(hostname)"
VMSSH
  ) &
  pids+=($!)
done
fail=0
for p in "${pids[@]}"; do wait $p || fail=1; done
exit $fail
ENDSSH

# Deploy conf/dinomo-config.yml (the file every binary loads) to each VM.
# Do NOT link it to conf/dinomo-base.yml: that is the Kubernetes template, which
# has a NODE_UID placeholder for ib_config.rank and no server/user sections.
# rm first so we replace any old symlink instead of writing through it.
echo "  Deploying conf/dinomo-config.yml..."
for vm_ip in ${VM_STORAGE} ${VM_KVS} ${VM_ROUTE} ${VM_MONITOR} ${VM_BENCH}; do
  $SSH ${SSH_USER}@${CLOUDLAB_HOST} \
    "ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ${VM_USER}@${vm_ip} \
     'rm -f ${DINOMO_DIR}/conf/dinomo-config.yml && cat > ${DINOMO_DIR}/conf/dinomo-config.yml'" \
    < "${SCRIPT_DIR}/conf/dinomo-vm-config.yml"
done
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
     'grep -c \"start to listen\" /tmp/dinomo-storage.log 2>/dev/null || true'")
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

# Pre-check TCP from kvs to storage over br-rdma (port 22 so the waiting storage
# listener is not consumed). If host firewall drops bridged traffic, the kvs
# connect() would hang ~127s before failing; catch it here instead.
STORAGE_RDMA_IP=$(awk '/storage_node_ips:/ {getline; print $2; exit}' "${SCRIPT_DIR}/conf/dinomo-vm-config.yml")
if ! $SSH ${SSH_USER}@${CLOUDLAB_HOST} \
    "ssh -o StrictHostKeyChecking=no ${VM_USER}@${VM_KVS} \
     'timeout 5 bash -c \"</dev/tcp/${STORAGE_RDMA_IP}/22\"'" 2>/dev/null; then
  echo "ERROR: kvs cannot open TCP to storage at ${STORAGE_RDMA_IP} over br-rdma."
  echo "  Host firewall is likely dropping bridged traffic. On ${CLOUDLAB_HOST} run:"
  echo "    sudo iptables -I FORWARD 1 -i br-rdma -o br-rdma -j ACCEPT"
  exit 1
fi
echo "  TCP to storage (${STORAGE_RDMA_IP}) over br-rdma: ok"

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
  # One round trip returns: <threads ready> <kvs alive 1/0> <[ERROR] lines>
  read -r step4_count kvs_alive err_count <<< "$($SSH ${SSH_USER}@${CLOUDLAB_HOST} \
    "ssh -o StrictHostKeyChecking=no ${VM_USER}@${VM_KVS} \
     'c=\$(grep -c \"raddr_pool=\" /tmp/dinomo-kvs.log 2>/dev/null); \
      e=\$(grep -c -F \"[ERROR]\" /tmp/dinomo-kvs.log 2>/dev/null); \
      pgrep -x dinomo-kvs >/dev/null && a=1 || a=0; \
      echo \${c:-0} \$a \${e:-0}'")"
  # Fail fast instead of waiting out the full 60s when kvs has already died.
  if [ "${kvs_alive}" = "0" ] || [ "${err_count:-0}" -gt 0 ] 2>/dev/null; then
    echo ""
    echo "ERROR: dinomo-kvs failed (alive=${kvs_alive}, [ERROR] lines=${err_count}). Last log lines:"
    $SSH ${SSH_USER}@${CLOUDLAB_HOST} \
      "ssh -o StrictHostKeyChecking=no ${VM_USER}@${VM_KVS} 'tail -15 /tmp/dinomo-kvs.log'" | sed 's/^/    /'
    exit 1
  fi
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
