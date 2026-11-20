# Host-native NUMA benchmarks

`run_benchmark.py` runs DINOMO routing, the NUMA KVS workers and manager, and
independent `KvsClient` processes on one host. It keeps the original Soft-RoCE
targets and five-VM launchers available. No VM, RDMA device, sudo, or CPU
offlining is needed for this workflow. Linux NUMA placement operations and
loopback service ports must be available.

See [the longer evaluation](BENCHMARK_EVALUATION.md) for completed repeated
measurements and client-concurrency/timing controls.

## Build

Install the dependencies listed in README.md, then run from the repository root:

```bash
make -C src/kvs/libbloom -j4
cmake -S . -B build/numa -DCMAKE_BUILD_TYPE=Release -DBUILD_NUMA_SERVER=ON
cmake --build build/numa --target dinomo-numa-bench dinomo-kvs-numa dinomo-route -j4
```

The launcher uses the dedicated `conf/dinomo-numa-bench.json` template. JSON is
valid YAML for the existing C++ configuration loader. It saves per-run copies;
the correctness baseline `conf/dinomo-numa.yml` is not edited.

## Run a matched matrix

Inspect `lscpu -e=CPU,NODE,SOCKET,CORE,ONLINE` and `numactl --hardware` first.
Replace every CPU and memory-node ID below with values for your machine:

```bash
python3 numa-test/dinomo/run_benchmark.py \
  --worker-cpus 2,6,8,9 --worker-counts 1,2,4 \
  --manager-cpu 4 --router-cpu 0 --client-cpus 1,3 \
  --memory-nodes 0,1 --keys 10000 --value-size 64 \
  --pool-mb 512 --log-block-bytes 16384 \
  --outstanding 32 --warmup-s 5 --duration-s 30 --repeats 3
```

Each worker count uses a prefix of `--worker-cpus`. One client process runs on
each listed client CPU. All workers, manager, router, and clients must use
distinct online CPUs on the same compute NUMA node. SMT siblings are rejected
unless `--allow-shared-cores` is explicitly supplied. The manager and router
also have dedicated CPUs. A single-node host can run only a local comparison.
Every CPU stays online, including CPUs on a remote pool node.

By default the launcher measures READ and UPDATE separately. Use
`--modes READ` or `--modes UPDATE` to select one. For each worker count, pool
node, repeat, and workload it:

1. Creates a private pool and fresh router/server processes with delay hooks
   disabled, caches/batching/replication disabled, and diagnostic quiet mode on.
2. Checks worker and manager CPU affinity and waits for all workers to be ready.
3. Runs partitioned LOAD clients, which read back every inserted value.
4. Starts fresh clients, warms up, drains pending warmup requests, and publishes
   one future monotonic start timestamp after all clients are ready.
5. Measures the selected workload with a bounded outstanding window per client,
   drains all requests, then runs a full-keyspace VERIFY phase.
6. Shuts down the server, requires zero pending writes/leases and matching
   async epoch counts, checks placement at startup/shutdown, and removes all
   owned processes and the private pool before the next experiment.

The pool is volatile and each workload loads its own data. The initial default
is concurrent merge, with a 16-write threshold and a 20 ms timer. A synchronous
comparison is available with `--worker-counts 1 --synchronous`.

## Results and interpretation

The launcher prints its evidence directory under `numa-test/dinomo/results/`.

- `summary.csv` and `summary.json` contain one row per workload/configuration/
  repeat, including throughput, combined median/p99 latency, and lifetime wait
  counters. Repeats remain separate; percentiles are never averaged.
- Each `w*-node*-r*-*` directory contains `report.json`, phase summaries, client
  result histograms/configs/logs, generated service configuration, process/CPU
  records, `cleanup.json`, and a PASS or FAIL marker.
- The root manifest records settings, source and binary hashes, topology,
  commit/working-tree status, a patch, relevant source snapshots, and available
  CMake cache/compiler commands. Keep these ignored results separately when
  moving to another host. Build before running; the launcher does not rebuild.

Throughput is the total successful completions observed in the shared timed
window divided by its scheduled duration. Drain completions are recorded
separately and do not inflate throughput. Latencies span API issue to response
observation, including routing, transport, server waits and client polling.
Their population includes **all requests issued in the timed window**, even
those completed during drain, so slow requests at the boundary are retained.
Latency bins round upward to whole microseconds. Combined percentiles use the
nearest-rank convention on the merged histograms. `max_start_lateness_us`
records client scheduling delay relative to the common start.

Backend `allocation_rpc_ns`, `merge_wait_ns`, `reader_wait_ns`, and
`writer_wait_ns` cover the **whole server lifetime**, including LOAD, warmup,
VERIFY, and shutdown. They are not isolated measured-phase timings. Allocation
time can include merge waits, and sums across workers can exceed wall time;
do not add these categories as exclusive stalls. Existing contention counts,
pool access counts and block reuse statistics are retained in `report.json`.
See [BENCHMARK_CLIENT.md](BENCHMARK_CLIENT.md) for precise counter definitions.
Timing adds overhead; use `--no-stall-timing` for a matched timing-disabled
control. Quiet mode stays enabled independently of timing.

The default pool/log settings are independent of the correctness stress
settings. Pool sizing must allow live values, partially live log blocks,
index growth, and active/sealed allocation grants. Value bytes alone are not
a pool-capacity estimate; allocation failure fails the run explicitly.
`--phase-timeout-s` bounds each entire LOAD/VERIFY phase; `--timeout-s` bounds
requests, drains and barrier waits. Increase the phase bound for large loads.

Check client saturation by varying the number of client CPUs and outstanding
requests. Preserve dataset, value size, workers, client placement/concurrency,
pool/log size, merge settings, and timing settings between local/remote pairs.
Use repeated longer runs and inspect scheduling effects before making a
scaling claim. Matrix order is deterministic; account for order effects when
designing an experiment. NUMA access does not establish actual CXL timings,
recovery, replication, or durability.

## Resource ownership and failures

The launcher rejects occupied service ports before starting a deployment and
never stops an existing DINOMO instance. A per-user lock prevents simultaneous
launchers from competing for the same ports. SIGINT/SIGTERM, client deadlines,
server failures, or manager failures mark the experiment FAIL and clean up its
owned process groups and private pool. Previously completed rows remain in the
summary, with overall status FAIL if the matrix did not finish. A failed run
does not publish successful performance metrics for its incomplete workload.

## Verification

```bash
# Pure result-accounting checks, including weighted quantiles and drain tails.
python3 numa-test/dinomo/test_benchmark_results.py

# End-to-end client value and error checks (choose CPU IDs for the host).
python3 numa-test/dinomo/test_benchmark_client.py \
  --worker-cpus 2 --manager-cpu 4 --client-cpu 6 --memory-node 0

# Occupied ports, synchronous/no-timing fallback, SIGTERM, manager death, cleanup.
python3 numa-test/dinomo/test_benchmark_launcher.py \
  --worker-cpu 2 --manager-cpu 4 --router-cpu 0 --client-cpus 1,3
```

A short matrix check uses the command above with `--keys 1000 --pool-mb 64
--log-block-bytes 4096 --warmup-s 1 --duration-s 2 --repeats 1`. This checks all
12 READ/UPDATE configurations, including four workers with a remote pool.
It is a workflow smoke test, not evidence for a performance improvement.
