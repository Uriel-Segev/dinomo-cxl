#!/bin/bash
# Shared native-benchmark SSH, log collection, and legacy metric helpers.
# Source after config.sh; SCRIPT_DIR and repository paths belong to the caller.

bench_line_count() {
  $SSH "${SSH_USER}@${CLOUDLAB_HOST}" \
    "ssh -o BatchMode=yes -o StrictHostKeyChecking=no ${VM_USER}@${VM_BENCH} \
     'wc -l < \$HOME/projects/DINOMO/log_0.txt 2>/dev/null || echo 0'"
}

send_bench_command() {
  local command="$1"
  local vm_args remote_command
  printf -v vm_args '%q ' "${command}"

  # Quote the entire guest command for the host shell, preserving argument
  # boundaries through both SSH hops (including patterns containing spaces).
  printf -v remote_command '%q' "bash -s -- ${vm_args}"
  $SSH "${SSH_USER}@${CLOUDLAB_HOST}" \
    "ssh -o BatchMode=yes -o StrictHostKeyChecking=no ${VM_USER}@${VM_BENCH} ${remote_command}" << 'VMSSH'
set -e
command="$1"
cd "$HOME/projects/DINOMO"

# Keep stdin open after the command so ZeroMQ has time to deliver it. Kill the
# trigger before its known EOF loop can send an empty command to dinomo-bench.
set +e
(printf '%s\n' "${command}"; sleep 4) | \
  timeout 3s ./build/target/benchmark/dinomo-bench-trigger 1 \
  >/dev/null 2>&1
status=$?
set -e

if [ "${status}" -ne 0 ] && [ "${status}" -ne 124 ]; then
  exit "${status}"
fi
VMSSH
}

wait_for_bench_log() {
  local start_line="$1"
  local pattern="$2"
  local timeout_seconds="$3"
  local failure_pattern="${4:-}"
  local vm_args remote_command
  printf -v vm_args '%q ' "${start_line}" "${pattern}" "${timeout_seconds}" "${failure_pattern}"

  # Quote the entire guest command for the host shell, preserving argument
  # boundaries through both SSH hops (including patterns containing spaces).
  printf -v remote_command '%q' "bash -s -- ${vm_args}"
  $SSH "${SSH_USER}@${CLOUDLAB_HOST}" \
    "ssh -o BatchMode=yes -o StrictHostKeyChecking=no ${VM_USER}@${VM_BENCH} ${remote_command}" << 'VMSSH'
set -e
start_line="$1"
pattern="$2"
timeout_seconds="$3"
failure_pattern="$4"
log="$HOME/projects/DINOMO/log_0.txt"
deadline=$((SECONDS + timeout_seconds))

while [ "${SECONDS}" -lt "${deadline}" ]; do
  if [ -n "${failure_pattern}" ] && tail -n "+${start_line}" "${log}" 2>/dev/null | grep -Fq "${failure_pattern}"; then
    echo "ERROR: benchmark reported '${failure_pattern}'." >&2
    tail -40 "${log}" >&2
    exit 1
  fi
  if tail -n "+${start_line}" "${log}" 2>/dev/null | grep -Fq "${pattern}"; then
    exit 0
  fi
  if ! pgrep -x dinomo-bench >/dev/null; then
    echo "ERROR: dinomo-bench exited while waiting for '${pattern}'." >&2
    tail -40 /tmp/dinomo-bench.log >&2 2>/dev/null || true
    exit 1
  fi
  sleep 2
done

echo "ERROR: timed out after ${timeout_seconds}s waiting for '${pattern}'." >&2
exit 1
VMSSH
}

capture_vm_file() {
  local vm_ip="$1"
  local remote_file="$2"
  local local_file="$3"

  $SSH "${SSH_USER}@${CLOUDLAB_HOST}" \
    "ssh -o BatchMode=yes -o StrictHostKeyChecking=no ${VM_USER}@${vm_ip} \
     'cat ${remote_file} 2>/dev/null || true'" > "${local_file}"
}

capture_logs() {
  local output_dir="$1"
  mkdir -p "${output_dir}"

  capture_vm_file "${VM_STORAGE}" /tmp/dinomo-storage.log "${output_dir}/storage.log" || true
  capture_vm_file "${VM_KVS}" /tmp/dinomo-kvs.log "${output_dir}/kvs.log" || true
  capture_vm_file "${VM_KVS}" '$HOME/projects/DINOMO/log_0.txt' "${output_dir}/kvs-worker.log" || true
  capture_vm_file "${VM_ROUTE}" '$HOME/projects/DINOMO/log_0.txt' "${output_dir}/route.log" || true
  capture_vm_file "${VM_MONITOR}" '$HOME/projects/DINOMO/log.txt' "${output_dir}/monitor.log" || true
  capture_vm_file "${VM_BENCH}" /tmp/dinomo-bench.log "${output_dir}/bench-stderr.log" || true
  capture_vm_file "${VM_BENCH}" '$HOME/projects/DINOMO/log_0.txt' "${output_dir}/benchmark-full.log" || true
}

capture_system_snapshot() {
  local output_dir="$1"
  local phase="$2"
  mkdir -p "${output_dir}"

  # Use all interfaces so this remains valid when CloudLab NIC names change.
  $SSH "${SSH_USER}@${CLOUDLAB_HOST}" 'bash -s' > "${output_dir}/host-${phase}.txt" << 'HOSTSSH' || true
date --iso-8601=ns
free -b
cat /proc/meminfo
ip -s link
rdma statistic show 2>/dev/null || true
HOSTSSH

  $SSH "${SSH_USER}@${CLOUDLAB_HOST}" \
    "ssh -o BatchMode=yes -o StrictHostKeyChecking=no ${VM_USER}@${VM_KVS} 'bash -s'" \
    > "${output_dir}/kvs-${phase}.txt" << 'VMSSH' || true
date --iso-8601=ns
free -b
cat /proc/meminfo
ip -s link
rdma statistic show 2>/dev/null || true
VMSSH
}

start_host_sar() {
  local remote_file="$1"
  local sample_count="$2"
  $SSH "${SSH_USER}@${CLOUDLAB_HOST}" \
    "nohup sar -r -n DEV -n EDEV 1 ${sample_count} > ${remote_file} 2>&1 < /dev/null &" \
    >/dev/null 2>&1 || true
}

capture_host_sar() {
  local remote_file="$1"
  local output_file="$2"
  $SSH "${SSH_USER}@${CLOUDLAB_HOST}" \
    "cat ${remote_file} 2>/dev/null || true; rm -f ${remote_file}" \
    > "${output_file}" || true
}

capture_benchmark_segment() {
  local start_line="$1"
  local output_file="$2"

  $SSH "${SSH_USER}@${CLOUDLAB_HOST}" \
    "ssh -o BatchMode=yes -o StrictHostKeyChecking=no ${VM_USER}@${VM_BENCH} \
     'tail -n +${start_line} \$HOME/projects/DINOMO/log_0.txt'" \
    > "${output_file}"
}

kvs_log_snapshot() {
  local output_file="$1"
  $SSH "${SSH_USER}@${CLOUDLAB_HOST}" \
    "ssh -o BatchMode=yes -o StrictHostKeyChecking=no ${VM_USER}@${VM_KVS} \
     'for file in \$HOME/projects/DINOMO/log_*.txt; do
        [ -f \"\$file\" ] || continue
        printf \"%s,%s\\n\" \"\$file\" \"\$(wc -l < \"\$file\")\"
      done'" > "${output_file}"
}

capture_kvs_log_segments() {
  local snapshot_file="$1"
  local output_file="$2"
  : > "${output_file}"
  while IFS=, read -r remote_file line_count; do
    [ -n "${remote_file}" ] || continue
    local start_line=$((line_count + 1))
    # SSH must not consume the snapshot file that feeds this read loop.
    $SSH -n "${SSH_USER}@${CLOUDLAB_HOST}" \
      "ssh -o BatchMode=yes -o StrictHostKeyChecking=no ${VM_USER}@${VM_KVS} \
       'tail -n +${start_line} ${remote_file} 2>/dev/null'" >> "${output_file}"
  done < "${snapshot_file}"
}

write_rdma_csv() {
  local input_file="$1"
  local output_file="$2"
  awk '
    BEGIN {
      print "thread,epoch,interval_seconds,read_ops,read_bytes,write_ops,write_bytes,send_ops,send_bytes,recv_ops,recv_bytes,cas_ops,cas_bytes,faa_ops,faa_bytes"
    }
    /RDMA_STATS/ {
      delete value
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^[a-z_]+=[0-9]+$/) {
          split($i, pair, "="); value[pair[1]] = pair[2]
        }
      }
      print value["thread"] "," value["epoch"] "," value["interval_seconds"] "," \
            value["read_ops"] "," value["read_bytes"] "," \
            value["write_ops"] "," value["write_bytes"] "," \
            value["send_ops"] "," value["send_bytes"] "," \
            value["recv_ops"] "," value["recv_bytes"] "," \
            value["cas_ops"] "," value["cas_bytes"] "," \
            value["faa_ops"] "," value["faa_bytes"]
    }
  ' "${input_file}" > "${output_file}"
}

write_cache_csv() {
  local input_file="$1"
  local output_file="$2"
  awk '
    BEGIN {
      print "thread,epoch,interval_seconds,value_cache_size,value_cache_hits,shortcut_cache_hits,local_log_hits,cache_misses"
    }
    /CACHE_STATS/ {
      delete value
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^[a-z_]+=[0-9]+$/) {
          split($i, pair, "="); value[pair[1]] = pair[2]
        }
      }
      print value["thread"] "," value["epoch"] "," value["interval_seconds"] "," \
            value["value_cache_size"] "," value["value_cache_hits"] "," \
            value["shortcut_cache_hits"] "," value["local_log_hits"] "," \
            value["cache_misses"]
    }
  ' "${input_file}" > "${output_file}"
}

summarize_cache_csv() {
  local input_file="$1"
  awk -F, '
    NR > 1 {
      value_hits += $5; shortcut_hits += $6; log_hits += $7; misses += $8
    }
    END {
      hits = value_hits + shortcut_hits + log_hits
      accesses = hits + misses
      ratio = accesses ? hits / accesses : 0
      printf "%d,%d,%d,%d,%.6f", value_hits, shortcut_hits, log_hits, misses, ratio
    }
  ' "${input_file}"
}

sum_rdma_csv() {
  local input_file="$1"
  awk -F, '
    NR > 1 {
      for (i = 4; i <= 15; i++) total[i] += $i
    }
    END {
      for (i = 4; i <= 15; i++) printf "%s%s", total[i] + 0, (i < 15 ? "," : "")
    }
  ' "${input_file}"
}

mean_metric() {
  local phrase="$1"
  local marker="$2"
  local input_file="$3"

  awk -v phrase="${phrase}" -v marker="${marker}" '
    index($0, phrase) {
      for (i = 1; i <= NF; i++) {
        if ($i == marker) {
          value = $(i + 1)
          if (value ~ /^[0-9]+([.][0-9]+)?([eE][+-]?[0-9]+)?$/) {
            sum += value; count++
          }
        }
      }
    }
    END { if (count) printf "%.2f", sum / count; else printf "NA" }
  ' "${input_file}"
}
