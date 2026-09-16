# Dynamic trace workload

This is a synthetic, phase-based workload using DINOMO's native GET and UPDATE
requests. Each repetition resets the cluster and loads the keyspace once. All
phases then execute in one benchmark loop, retaining server/cache state and
outstanding requests across phase changes. There are no inserts or deletes.

## Build and run

Deploy this checkout's changed files to the benchmark VM, including
`common/include/client/kvs_client.hpp`, `src/benchmark/benchmark.cpp`,
`src/benchmark/trigger.cpp`, `src/benchmark/CMakeLists.txt`, and the new
`src/benchmark/trace_*.hpp` and `trace_check.cpp` files. Rebuild on that VM:

```bash
cd ~/projects/DINOMO
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build --target dinomo-bench dinomo-bench-trigger dinomo-trace-check -j4
```

Use the default build with `SINGLE_OUTSTANDING` disabled. No KVS or storage
protocol changes are needed. Existing YCSB commands still work. The trigger also
now exits cleanly at EOF rather than sending empty commands.

From your local checkout, validate the trace without contacting the VMs:

```bash
bash vm-configs/c6525-25g/run_trace.sh --check
```

Then run it:

```bash
bash vm-configs/c6525-25g/run_trace.sh
# Three independent repetitions, each with one load and all CSV phases:
TRACE_REPETITIONS=3 bash vm-configs/c6525-25g/run_trace.sh
```

Like `run_ycsb.sh`, an actual run calls `start.sh`, stops DINOMO processes,
and recreates the PMDK pool. The runner validates all CSV rows and checks for
TRACE support in the deployed benchmark before the first reset. It activates
only benchmark thread 0. Local requirements are Python 3 and a C++11 compiler
(`g++`, or set `CXX` to another compiler executable). The standalone validator
uses exactly the same CSV parser as the benchmark.
The deployed capability can be checked without starting a client using
`./build/target/benchmark/dinomo-bench --supports-trace`.

## CSV format

The included `traces/moving_hotspot.csv` has five phases:

| Phase | Seconds | Reads | Hot keys | Hot selection probability |
| --- | ---: | ---: | --- | ---: |
| baseline | 30 | 95% | unused | 0% |
| hotspot_A | 60 | 95% | 1–10,000 | 90% |
| hotspot_B | 60 | 95% | 500,001–510,000 | 90% |
| write_heavy | 30 | 50% | 500,001–510,000 | 90% |
| recovery | 60 | 95% | unused | 0% |

```csv
phase,duration_s,read_ratio,hot_start,hot_count,hot_probability
baseline,30,0.95,1,100000,0
hotspot,60,0.95,1,10000,0.9
```

For every request, choose the hot region with `hot_probability`, otherwise choose
uniformly from the **entire** loaded keyspace, including the hot region. Both
reads and updates use that distribution. Thus a 1% hot region with 90% hot
selection receives about 90.1% of all requests. With probability zero, access is
uniform across the entire keyspace; the hot fields still must be valid.

Durations and key fields must be positive unsigned 32-bit decimal integers.
For the automated runner, key count and value size must also fit the existing
LOAD command's signed 32-bit range.
Ratios must be finite and in [0, 1]. Hot ranges must lie within keys
`1..TRACE_NUM_KEYS`. Phase names must be unique and use letters, digits, `_`, or
`-`. Blank lines, `#` comment lines, surrounding whitespace and CRLF endings
are accepted. Quoted fields are unnecessary and unsupported.

Use your own file as the first positional argument:

```bash
TRACE_NUM_KEYS=1000000 bash vm-configs/c6525-25g/run_trace.sh path/to/trace.csv
```

Defaults: one million keys, configured value size (64 bytes), configured report
period (5 seconds), configured outstanding limit (64), seed 42, one repetition,
300-second load timeout, and 30-second drain timeout. Overrides:
`TRACE_NUM_KEYS`, `TRACE_VALUE_SIZE`, `TRACE_REPORT_PERIOD`, `TRACE_OUTSTANDING`,
`TRACE_SEED`, `TRACE_REPETITIONS`, `TRACE_LOAD_TIMEOUT`, `TRACE_DRAIN_TIMEOUT`,
`TRACE_RUN_TIMEOUT`, and `TRACE_RESULTS_ROOT`.

The sampler produces a reproducible sequence for a given seed and identical
phase/request choices. This is a concurrency-limited workload: request counts
and exact issue times depend on DINOMO performance, so the seed does not produce
an identical timestamped trace across runs. No Zipf sampler is used.

## Native command

For an already running cluster with keys loaded, put the CSV on the benchmark
VM and send this through `dinomo-bench-trigger 1`:

```text
TRACE:/tmp/moving_hotspot.csv:1000000:64:5:64:42:30
```

Arguments: CSV path, loaded key count, value bytes, report seconds, outstanding
limit, seed, optional drain timeout seconds (default 30). The path must not
contain `:`. The benchmark parses the entire file before issuing requests. It
assumes the declared keys have actually been loaded; missing keys make the run
fail. Invalid commands produce `TRACE_ERROR`; completed runs produce
`TRACE_DONE status=PASS` or `FAIL`.

## Results and interpretation

Results live under `results/trace/<run_id>/`. The root retains the exact uploaded
CSV, its hash, and parameters. Each repetition retains deployed benchmark,
trigger, configuration and trace hashes; raw benchmark/KVS logs; RDMA and cache
CSVs; system snapshots; and host telemetry. Additional trace outputs:

- `trace.jsonl`: versioned phase, interval, measurement, drain and summary records.
- `intervals.csv`: read/update issued, completed and failed counts, successful
  latency sample counts and p50/p95/p99, throughput, and outstanding requests.
- `phases.csv`: scheduled phase boundaries and when the client observed them.
- `summary.json`: measurement throughput and counts, drain completions, failures,
  unresolved requests, unexpected responses, and PASS/FAIL.

Timing uses a monotonic clock. Intervals split at phase boundaries and include a
final partial record. Completions are attributed to their completion interval,
even if issued in a previous phase; operation type and latency come from the
original request ID and issue timestamp. Latency includes client-side routing
and retry time. Only successful completions contribute latency samples; empty
latency populations are null. Throughput counts terminal completions, with
failures counted separately. Existing monitoring feedback, including average
per-key latency, continues through the native feedback protocol.
Percentiles select sample index `floor((sample_count - 1) * quantile)`.

At the scheduled final deadline, issuance stops. Responses observed at or after
that deadline count separately as drain completions. Measurement throughput is
measured completions divided by the CSV's total duration. Drain has a bounded
timeout; failures, unresolved requests, or unexpected responses make the run
fail. Late boundary observation is retained explicitly. A blocking native client
call cannot be preempted by this loop; the outer runner also has a timeout.

Plot interval throughput and latency against `elapsed_s` and mark phase
boundaries to see hotspot and write-mix effects. RDMA/cache records retain the
existing server reporting window limitations described in `YCSB.md`. A combined
cache hit ratio does not measure the fraction avoiding remote access.

This implements trace replay and client interval reporting, not the entire
proposed `MEASUREMENT_DESIGN.md` contract: acknowledged server snapshots,
cross-machine clock alignment, mergeable histograms and whole-run latency
percentiles remain separate work. Do not average interval percentiles and label
them whole-run percentiles.

## Local verification

For performance runs, the KVS request handler's per-request `[DBG urh]` stderr
prints have been removed. Copy `src/kvs/user_request_handler.cpp` to the KVS VM
and rebuild `dinomo-kvs` there to apply this change. The host-side collector now
uses `ssh -n` to retain every worker row in its input snapshot; update
`benchmark_helpers.sh` on the host before rerunning. No benchmark rebuild is
needed just for these two fixes.

```bash
bash vm-configs/c6525-25g/test_trace.sh
```

The tests run without VMs, using the actual parser/sampler/replay code and a
simulated asynchronous client/clock. They check distributions, seed consistency,
invalid inputs, phase changes, request limits, completion batches, deadlines,
drain timeout and failed responses, JSON export, interval continuity and count
conservation. A real VM smoke run is still required after rebuilding DINOMO.
