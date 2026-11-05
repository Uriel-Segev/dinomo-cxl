#!/bin/bash

#run one trace at several kvs cache sizes, each given as a percentage of the dataset
#dataset size = what the cache counts: number of keys x value-size from the config (1006 B)
#each percentage gets its own folder: results/cache_sweep/<sweep-id>/pct-<P>_cap-<N>MB/
#run with --help to see the flags

#stop at the first error, or unset variables, and on failures inside pipes (same as run_trace.sh)
set -Eeuo pipefail

#folder that this script is in (vm-configs/c6525-25g)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

#repo root, two folders up
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"


# ------------------------------------------------------------
# Defaults: used for any flag that is not given
# ------------------------------------------------------------

#workload size: number of keys
NUM_KEYS=1000000

#one specific percentage; empty means "do the sweep"
PERCENT=""

#percentages to sweep when --percent is not given
PERCENTS="1 2 4 8 16"

#trace to run
TRACE_CSV="${SCRIPT_DIR}/traces/moving_hotspot.csv"

# ------------------------------------------------------------
# Usage text: printed by --help and when a flag is wrong
# ------------------------------------------------------------
usage() {
  cat << 'EOF'
Usage: bash run_cache_sweep.sh [--keys N] [--percent P | --percents "P1 P2 ..."] [--trace FILE]
  --keys N             number of keys in the workload (default 1000000)
  --percent P          run only this cache size, as % of the dataset (e.g. 4)
  --percents "P1 P2"   percentages to sweep when --percent is not given (default "1 2 4 8 16")
  --trace FILE         trace CSV to run (default traces/moving_hotspot.csv)
  --help               show this text
EOF
}


# ------------------------------------------------------------
# Read the flags
# ------------------------------------------------------------

#each pass handles the first remaining argument ($1); its value is the next one ($2)
while [[ $# -gt 0 ]]; do
    #--help needs no value: print usage and stop
    if [[ "$1" == "--help" ]]; then
        usage
        exit 0
    fi

    #every other flag needs a value after it
    if [[ $# -lt 2 ]]; then
        echo "ERROR: $1 needs a value"
        usage
        exit 1
    fi

    #store the value in the matching string
    case "$1" in
        --keys)     NUM_KEYS="$2" ;;
        --percent)  PERCENT="$2" ;;
        --percents) PERCENTS="$2" ;;
        --trace)    TRACE_CSV="$2" ;;

        #anything else is a typo or a flag that doesn't exist
        *)
            echo "ERROR: unkown flag '$1'"
            usage
            exit 1
            ;;
    esac

    #remove the flag and its value, so the next flag becomes $1
    shift 2
done

#if one percentage was given, the "sweep" is just that one
if [[ -n "${PERCENT}" ]]; then
    PERCENTS="${PERCENT}"
fi

# ------------------------------------------------------------
# Check the inputs and work out every cache size before starting
# ------------------------------------------------------------

#keys must be a positive whole number
if ! [[ "${NUM_KEYS}" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: --keys must be a positive whole number (got '${NUM_KEYS}')"
  exit 1
fi

#the trace file must exist
if [[ ! -f "${TRACE_CSV}" ]]; then
    echo "ERROR: trace file not found: ${TRACE_CSV}"
    exit 1
fi

#read value-size (the size the cache counts per value) from the repo's config
VALUE_SIZE=$(tr -d '\r' < "${SCRIPT_DIR}/conf/dinomo-vm-config.yml" \
    | awk '$1 == "value-size:" {print $2}')

#stop if it couldn't be found
if [[ -z "${VALUE_SIZE}" ]]; then
  echo "ERROR: could not read value-size from conf/dinomo-vm-config.yml"
  exit 1
fi

#turn a percentage into memory-cap in whole MB: keys * value-size * percent/100, in MB rounded
#(awk does the math because bash can't do decimals)
cap_for_percent() {
    awk -v k="${NUM_KEYS}" -v v="${VALUE_SIZE}" -v p="$1" \
        'BEGIN { printf "%d", k * v * p / 100 / 1048576 + 0.5 }'
}

#show the plan, and stop now if any percentage is bad
echo "Workload: ${NUM_KEYS} keys x ${VALUE_SIZE} B (as counted by the cache)"
for pct in ${PERCENTS}; do
    #percentage must be a number
    if ! [[ "${pct}" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    echo "ERROR: percentage must be a number (got '${pct}')"
    exit 1
    fi
    #work out its cache size
    cap=$(cap_for_percent "${pct}")
    #memory-cap is whole MB, so anything that rounds below 1 MB can't be run
    if [[ "${cap}" -lt 1 ]]; then
        echo "ERROR: ${pct}% of this workload is under 1 MB; use more keys or a bigger percentage"
        exit 1
    fi 
    echo "  ${pct}% -> memory-cap ${cap} MB"
done

# ------------------------------------------------------------
# Run the sweep
# ------------------------------------------------------------
#unique name for this sweep, from the current UTC date and time
SWEEP_ID="$(date -u +%Y%m%dT%H%M%SZ)"

#folder that holds every cache size's results for this sweep
SWEEP_DIR="${REPO_ROOT}/results/cache_sweep/${SWEEP_ID}"
#create it (-p: also creates missing parent folders, no error if it exists)
mkdir -p "${SWEEP_DIR}"

#run the trace once per percentage
for pct in ${PERCENTS}; do
    #cache size for this percentage
    cap=$(cap_for_percent "${pct}")
    #show which one is starting
    echo "=== cache sweep: ${pct}% of dataset = memory-cap ${cap} MB ==="
    #run run_trace.sh for this cache size. the three settings apply only to this run:
    #  MEMORY_CAP          -> start.sh sets memory-cap on the VMs
    #  TRACE_NUM_KEYS      -> run_trace.sh loads and uses this many keys
    #  TRACE_RESULTS_ROOT  -> results are saved under pct-<P>_cap-<N>MB/

    #the last line runs run_trace.sh with the trace CSV
    MEMORY_CAP="${cap}" \
    TRACE_NUM_KEYS="${NUM_KEYS}" \
    TRACE_RESULTS_ROOT="${SWEEP_DIR}/pct-${pct}_cap-${cap}MB" \
        bash "${SCRIPT_DIR}/run_trace.sh" "${TRACE_CSV}"
done

#show where everything was saved 
echo "Sweep results: ${SWEEP_DIR}"
