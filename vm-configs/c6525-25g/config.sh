#!/bin/bash
# ============================================================
#  DINOMO Configuration
#  Edit this file for each CloudLab experiment.
#  All other scripts source this file — you should not need
#  to edit anything else.
# ============================================================

# -------------------------------------------------------
# CHANGE THIS for each new CloudLab experiment
# -------------------------------------------------------
CLOUDLAB_HOST="sabro.idav.ucdavis.edu"

# -------------------------------------------------------
# Change these if your SSH setup is different
# -------------------------------------------------------
SSH_USER="lredivo"
SSH_KEY="${HOME}/.ssh/sabro_ed25519"

# Host sudo password (leave blank to prompt interactively, or set as env var)
if [ -z "${HOST_SUDO_PASS:-}" ] && [ -t 0 ]; then
  read -sp "Enter sudo password for ${SSH_USER}@${CLOUDLAB_HOST}: " HOST_SUDO_PASS
  echo ""
fi

# -------------------------------------------------------
# Node type — determines VM interface names and disk path.
# Supported values: c6525-25g
# -------------------------------------------------------
NODE_TYPE="c6525-25g"

# -------------------------------------------------------
# VM network addresses (fixed — do not change)
# These are on the private virtual networks we create,
# so they are the same on every CloudLab node.
# -------------------------------------------------------
VM_STORAGE="192.168.122.25"
VM_KVS="192.168.122.150"
VM_ROUTE="192.168.122.99"
VM_MONITOR="192.168.122.114"
VM_BENCH="192.168.122.167"
VM_USER="ubuntu"
DINOMO_DIR="~/projects/DINOMO"
DINOMO_REPO="https://github.com/utsaslab/dinomo.git"  # update to your fork when ready

# -------------------------------------------------------
# Node-type-specific settings
# -------------------------------------------------------
case "$NODE_TYPE" in
  c6525-25g)
    # Network interface inside each VM that carries Soft-RoCE (br-rdma bridge)
    VM_RDMA_IFACE="eth1"
    # Where VM disk images are stored on the host
    HOST_DATA_DIR="/scr/lredivo"
    # Ubuntu base image filename
    HOST_BASE_IMAGE="/scr/lredivo/ubuntu-20.04-base.img"
    ;;
  *)
    echo "ERROR: Unknown NODE_TYPE '${NODE_TYPE}'. Edit config.sh."
    exit 1
    ;;
esac

# -------------------------------------------------------
# Benchmark parameters (change if desired)
# -------------------------------------------------------
BENCH_NUM_KEYS=100000
BENCH_VALUE_SIZE=64
BENCH_DURATION=30        # seconds per RUN workload
BENCH_REPORT_PERIOD=5   # seconds between epoch reports
BENCH_OUTSTANDING=64     # max outstanding requests

# -------------------------------------------------------
# SSH command shorthand — used by all scripts
# -------------------------------------------------------
SSH="ssh -i ${SSH_KEY} -o StrictHostKeyChecking=no -o BatchMode=yes"
