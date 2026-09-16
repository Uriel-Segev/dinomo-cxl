#!/bin/bash
# Local tests need only a C++11 compiler and Python 3; no VMs or RDMA devices.
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
test_dir="$(mktemp -d /tmp/dinomo-trace-test.XXXXXXXX)"
trap 'rm -rf "${test_dir}"' EXIT
"${CXX:-g++}" -std=c++11 -Wall -Wextra -Werror -pedantic \
  "${REPO_ROOT}/src/benchmark/trace_test.cpp" -o "${test_dir}/test"
"${test_dir}/test" "${test_dir}"
python3 "${SCRIPT_DIR}/trace_results.py" "${test_dir}/pass.log" "${test_dir}/pass"
for scenario in timeout error delayed empty; do
  if python3 "${SCRIPT_DIR}/trace_results.py" "${test_dir}/${scenario}.log" "${test_dir}/${scenario}"; then
    echo "ERROR: exporter accepted ${scenario}" >&2; exit 1
  fi
  # Failed/empty runs must still retain readable records and a summary.
  test -s "${test_dir}/${scenario}/summary.json"
done
python3 - "${test_dir}" <<'PY'
import json
import sys
from pathlib import Path
root = Path(sys.argv[1])
records = [json.loads(line) for line in (root / 'pass/trace.jsonl').read_text().splitlines()]
summary = json.loads((root / 'pass/summary.json').read_text())
assert summary['issued'] == summary['completed'] + summary['drain_completed']
assert summary['drain_completed'] > 0
assert [r['elapsed_s'] for r in records if r['record_type'] == 'phase_start'] == [0, 1]
assert len([r for r in records if r['record_type'] == 'phase_end']) == 2
timeout = json.loads((root / 'timeout/summary.json').read_text())
assert timeout['unresolved'] == 2 and timeout['status'] == 'FAIL'
empty = [json.loads(line) for line in (root / 'empty/trace.jsonl').read_text().splitlines()]
assert all(r['read_p99_latency_us'] is None and r['update_p99_latency_us'] is None
           for r in empty if r['record_type'] == 'client_interval')
print('JSON export, interval conservation, phase markers, and empty latency checks passed')
PY
python3 - "${test_dir}" "${SCRIPT_DIR}/benchmark_helpers.sh" <<'PY'
import os
import subprocess
import sys
from pathlib import Path
root, helpers = Path(sys.argv[1]), sys.argv[2]
# Emulate both SSH hops locally, retaining the actual quoting and guest script.
mock = root / 'mock_ssh'
mock.write_text('''#!/usr/bin/env python3
import shlex, subprocess, sys
from pathlib import Path
guest = shlex.split(shlex.split(sys.argv[-1])[-1])
script = sys.stdin.read().replace('log="$HOME/projects/DINOMO/log_0.txt"',
    'log="' + str(Path(__file__).parent / 'guest.log') + '"')
sys.exit(subprocess.run(guest, input=script, text=True).returncode)
''')
mock.chmod(0o755)
command = '''source "$1"
SSH="$2"
CLOUDLAB_HOST=fake
SSH_USER=fake
VM_USER=fake
VM_BENCH=fake
wait_for_bench_log 1 "$3" 1 "${4:-}"
'''
(root / 'guest.log').write_text('Loading data took 1 seconds.\n')
subprocess.run(['bash', '-c', command, 'test', helpers, str(mock), 'Loading data took'], check=True)
(root / 'guest.log').write_text('TRACE_ERROR: bad CSV\nTRACE_DONE status=FAIL\n')
result = subprocess.run(['bash', '-c', command, 'test', helpers, str(mock), 'TRACE_DONE', 'TRACE_ERROR:'],
                        capture_output=True, text=True)
assert result.returncode != 0 and "benchmark reported 'TRACE_ERROR:'" in result.stderr
print('Shared SSH helper preserves spaced arguments and reports trace errors immediately')
# Mimic SSH's default stdin consumption. All snapshot rows must survive.
collector = root / 'mock_collector_ssh'
collector.write_text('''#!/usr/bin/env python3
import sys
if '-n' not in sys.argv:
    sys.stdin.read()
print(sys.argv[-1])
''')
collector.chmod(0o755)
snapshot = root / 'workers.csv'
snapshot.write_text(''.join(f'/tmp/log_{i}.txt,20\\n'.replace('\\n', '\n') for i in range(4)))
output = root / 'workers.log'
collect = '''source "$1"
SSH="$2"
CLOUDLAB_HOST=fake
SSH_USER=fake
VM_USER=fake
VM_KVS=fake
capture_kvs_log_segments "$3" "$4"
'''
subprocess.run(['bash', '-c', collect, 'test', helpers, str(collector), str(snapshot), str(output)], check=True)
assert len(output.read_text().splitlines()) == 4
assert all(f'log_{i}.txt' in output.read_text() for i in range(4))
print('KVS collector retains all four workers when SSH consumes stdin')
PY
bash -n "${SCRIPT_DIR}/run_trace.sh" "${SCRIPT_DIR}/run_ycsb.sh" "${SCRIPT_DIR}/benchmark_helpers.sh"
bash "${SCRIPT_DIR}/run_trace.sh" --check
if TRACE_NUM_KEYS=100 bash "${SCRIPT_DIR}/run_trace.sh" --check; then
  echo "ERROR: runner accepted an out-of-range hotspot" >&2; exit 1
fi
