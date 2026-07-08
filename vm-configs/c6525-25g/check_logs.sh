#!/bin/bash
# Show last few lines of all DINOMO logs.
# Run from repo root: bash vm-configs/c6525-25g/check_logs.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

$SSH ${SSH_USER}@${CLOUDLAB_HOST} 'bash -s' << ENDSSH
# Note: bench results go to log_0.txt (spdlog file), not /tmp/dinomo-bench.log.
# /tmp/dinomo-bench.log only captures stderr from the bench process itself.
for entry in \
  "${VM_STORAGE}:dinomo-storage:/tmp/dinomo-storage.log" \
  "${VM_KVS}:dinomo-kvs:/tmp/dinomo-kvs.log" \
  "${VM_ROUTE}:dinomo-route:/tmp/dinomo-route.log" \
  "${VM_MONITOR}:dinomo-monitor:/tmp/dinomo-monitor.log" \
  "${VM_BENCH}:dinomo-bench:~/projects/DINOMO/log_0.txt"
do
  vm_ip=\$(echo \$entry | cut -d: -f1)
  proc=\$(echo \$entry | cut -d: -f2)
  log=\$(echo \$entry | cut -d: -f3)
  echo "=== \${proc} (\${vm_ip}) ==="
  ssh -o StrictHostKeyChecking=no ${VM_USER}@\${vm_ip} "tail -5 \${log} 2>/dev/null || echo '(no log)'"
  echo ""
done
ENDSSH
