#!/usr/bin/env bash
set -euo pipefail

STATE_DIR=/run/dinomo-numa-test
STATE_FILE=${STATE_DIR}/offlined-cpus
SYS_CPU=/sys/devices/system/cpu
SYS_NODE=/sys/devices/system/node

usage() {
  cat <<'EOF'
Usage:
  sudo ./numa_cpu_control.sh offline NODE
  sudo ./numa_cpu_control.sh restore
  ./numa_cpu_control.sh status [NODE]

"offline" removes every hot-pluggable CPU in NODE while leaving its memory
online. The exact CPUs changed are recorded so "restore" only re-enables those
CPUs. CPU 0 and the NUMA node containing CPU 0 are protected.
EOF
}

expand_cpu_list() {
  local list=$1 item start end cpu
  IFS=',' read -ra items <<< "$list"
  for item in "${items[@]}"; do
    if [[ $item == *-* ]]; then
      start=${item%-*}
      end=${item#*-}
      for ((cpu = start; cpu <= end; ++cpu)); do
        printf '%s\n' "$cpu"
      done
    else
      printf '%s\n' "$item"
    fi
  done
}

cpu_is_online() {
  local cpu=$1
  [[ $cpu == 0 ]] || [[ $(<"${SYS_CPU}/cpu${cpu}/online") == 1 ]]
}

show_status() {
  local requested_node=${1:-}
  local node_dir cpu_link node cpu online=() offline=()
  for node_dir in "${SYS_NODE}"/node[0-9]*; do
    [[ -d $node_dir ]] || continue
    node=${node_dir##*node}
    [[ -z $requested_node || $node == "$requested_node" ]] || continue
    # nodeN/cpulist contains only online CPUs. The cpuN symlinks remain for
    # offline CPUs, so enumerate those to report the complete node accurately.
    for cpu_link in "${node_dir}"/cpu[0-9]*; do
      [[ -e $cpu_link ]] || continue
      cpu=${cpu_link##*cpu}
      if cpu_is_online "$cpu"; then
        online+=("$cpu")
      else
        offline+=("$cpu")
      fi
    done
    mapfile -t online < <(printf '%s\n' "${online[@]}" | sort -n)
    mapfile -t offline < <(printf '%s\n' "${offline[@]}" | sort -n)
    printf 'node%s memory: %s\n' "$node" "$(sed -n 's/.*MemTotal:[[:space:]]*//p' "${node_dir}/meminfo")"
    printf 'node%s online CPUs: %s\n' "$node" "${online[*]:-(none)}"
    printf 'node%s offline CPUs: %s\n' "$node" "${offline[*]:-(none)}"
    online=()
    offline=()
  done
}

restore_cpus() {
  [[ $EUID -eq 0 ]] || { echo "restore requires root" >&2; exit 1; }
  if [[ ! -f $STATE_FILE ]]; then
    echo "No recorded CPUs to restore."
    return
  fi
  local cpu
  while read -r cpu; do
    [[ $cpu =~ ^[0-9]+$ ]] || continue
    if [[ -w ${SYS_CPU}/cpu${cpu}/online ]]; then
      printf '1' > "${SYS_CPU}/cpu${cpu}/online"
    fi
  done < "$STATE_FILE"
  rm -f "$STATE_FILE"
  rmdir "$STATE_DIR" 2>/dev/null || true
  echo "Restored the CPUs recorded by this experiment."
}

offline_node() {
  local node=$1
  [[ $EUID -eq 0 ]] || { echo "offline requires root" >&2; exit 1; }
  [[ $node =~ ^[0-9]+$ && -d ${SYS_NODE}/node${node} ]] || {
    echo "NUMA node ${node} does not exist" >&2
    exit 1
  }
  [[ ! -e ${SYS_NODE}/node${node}/cpu0 ]] || {
    echo "Refusing to offline node ${node}: it contains protected CPU 0" >&2
    exit 1
  }
  [[ ! -e $STATE_FILE ]] || {
    echo "A saved offline operation already exists." >&2
    echo "Restore it before starting a new experiment:" >&2
    echo "  sudo $0 restore" >&2
    exit 1
  }
  local other_online=0 node_dir cpu
  for node_dir in "${SYS_NODE}"/node[0-9]*; do
    [[ $node_dir != "${SYS_NODE}/node${node}" ]] || continue
    while read -r cpu; do
      if cpu_is_online "$cpu"; then
        other_online=1
        break 2
      fi
    done < <(expand_cpu_list "$(<"${node_dir}/cpulist")")
  done
  ((other_online == 1)) || {
    echo "Refusing to remove the only online NUMA node" >&2
    exit 1
  }
  mkdir -p "$STATE_DIR"
  : > "$STATE_FILE"
  chmod 600 "$STATE_FILE"
  local changed=()
  trap 'echo "CPU offlining failed; restoring changed CPUs" >&2; restore_cpus' ERR
  trap 'echo "CPU offlining interrupted; restoring changed CPUs" >&2; restore_cpus; exit 130' INT TERM HUP
  while read -r cpu; do
    [[ $cpu != 0 ]] || continue
    if cpu_is_online "$cpu"; then
      [[ -w ${SYS_CPU}/cpu${cpu}/online ]] || {
        echo "CPU ${cpu} cannot be hot-unplugged" >&2
        false
      }
      printf '%s\n' "$cpu" >> "$STATE_FILE"
      printf '0' > "${SYS_CPU}/cpu${cpu}/online"
      changed+=("$cpu")
    fi
  done < <(expand_cpu_list "$(<"${SYS_NODE}/node${node}/cpulist")")
  trap - ERR INT TERM HUP
  echo "Offlined NUMA node ${node} CPUs: ${changed[*]}"
  echo "NUMA node ${node} memory remains online."
}

case ${1:-} in
  offline)
    [[ $# -eq 2 ]] || { usage; exit 1; }
    offline_node "$2"
    ;;
  restore)
    [[ $# -eq 1 ]] || { usage; exit 1; }
    restore_cpus
    ;;
  status)
    [[ $# -le 2 ]] || { usage; exit 1; }
    show_status "${2:-}"
    ;;
  *)
    usage
    exit 1
    ;;
esac
