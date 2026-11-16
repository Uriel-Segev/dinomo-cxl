# NUMA benchmark client integration

`dinomo-numa-bench` is a host-native client using the existing `KvsClient`
network API. It is built only with `BUILD_NUMA_SERVER=ON`. The original
`dinomo-bench`, trigger executable, and five-VM Soft-RoCE scripts are unchanged.
The host-native benchmark launcher and aggregate result reporting remain to
be implemented; the smoke test below validates the client, not performance.

## Build and verify

From the repository root, after installing the dependencies in README.md:

```bash
make -C src/kvs/libbloom -j4
cmake -S . -B build/numa -DCMAKE_BUILD_TYPE=Release -DBUILD_NUMA_SERVER=ON
cmake --build build/numa --target dinomo-numa-bench dinomo-kvs-numa dinomo-route dinomo-numa-client-check -j4
python3 numa-test/dinomo/test_benchmark_client.py \
  --worker-cpus 2 --manager-cpu 4 --client-cpu 6 --memory-node 0
```

Choose CPU/node IDs from the host topology. Repeat with `--worker-cpus 2,8`
for two workers, `--memory-node 1` for remote memory, or `--synchronous` for
the single-worker synchronous fallback. These tests leave every CPU online.
Loopback DINOMO ports must be free. Evidence is saved in ignored
`results/benchmark-client-*` directories.

The test launches an owned router/server/private pool and two clients. It checks
an uneven 33-key LOAD partition, reads, updates, later reads, response identity
and errors, histogram and drain counts, missing-key rejection, start-barrier
timeouts, timing summaries, worker drain, and manager/pool cleanup. Its clients
share one CPU and run for one second: the output is correctness evidence only.

## Client contract

The executable takes one YAML configuration path. In addition to
`threads.memory`, its `benchmark` mapping contains:

| Field | Meaning |
|---|---|
| mode | LOAD, READ, or UPDATE |
| keys / value-size | Positive integer key count and application bytes per value (maximum 3000) |
| clients / client-id | 1..64 clients and a zero-based ID; clients cannot exceed keys |
| outstanding | Maximum requests in flight per client |
| duration-s / warmup-s | Positive measured duration and nonnegative warmup duration |
| timeout-s | Positive request, drain, and barrier timeout |
| seed | Nonnegative deterministic sampling seed; use a distinct seed per client |
| ready-file / go-file | Per-client readiness path and common start-file path for measured modes |
| result-file | Per-client JSON result path |

LOAD inserts the client's strided partition of keys 1..keys, then reads it back
and validates every value. Complete all clients' LOAD phases before starting
READ or UPDATE. Measured modes warm up and drain before creating readiness
files. A launcher must atomically publish a future Linux monotonic timestamp
in nanoseconds in the start file, after every client is ready. Each phase needs
fresh directories and barrier/result paths. See `test_benchmark_client.py` for
a concrete configuration and synchronization example.

READ/UPDATE sample the complete loaded keyspace uniformly. Values are identical
`a` bytes, matching the legacy synthetic workload; this tests response/value
integrity, not generation ordering between competing updates. The earlier
correctness client tests generation visibility separately.

The measured window ends at the shared scheduled deadline. Throughput uses
successful responses observed within that window; later responses are counted
only as drain completions. All issued requests must complete successfully.
Latency spans API issue to response observation using a monotonic clock,
including routing, transport and server waits. The JSON histogram rounds each
latency upward to a whole microsecond and includes only measured completions.
Merge histograms across clients to calculate combined median/p99 values;
averaging per-client percentiles is incorrect. Histogram work and value checks
consume client CPU, so client concurrency and placement need measurement.

## Optional backend timing

Set `numa.measure-stalls: true` in the server configuration to emit cumulative
`NUMA stalls` counters at shutdown. The default is false. With timing enabled,
per-contention reader messages are suppressed to avoid logging each wait.

- `allocation_rpc_ns`: elapsed allocation-call time, including IPC, manager
  scheduling, and any pending-merge reply consumed before allocation.
- `merge_wait_ns`: synchronous merge calls and time consuming asynchronous
  merge replies, including blocking completion polls. This is compute-side
  waiting, not manager merge execution time.
- `reader_wait_ns` / `writer_wait_ns`: time inside contended lock acquisition;
  writer time is recorded in the manager's shared control mapping.

Counters cover the server lifetime, including LOAD, warmup, and shutdown.
They sum time across workers and can exceed wall time. Allocation time can
overlap merge-wait time; do not add the categories as exclusive stalls. These
optional clock/counter operations add overhead and should be recorded in any
comparison. Synchronous mode reports zero index-lock waits.

Use the existing deterministic contention test to verify nonzero timed waits:

```bash
python3 numa-test/dinomo/test_server_startup.py \
  --host-cpu 2 --manager-cpu 4 --memory-node 0 --client-check --keys 32 \
  --merge-writes 16 --merge-ms 0 --require-deferred --concurrent \
  --merge-start-delay-ms 20 --merge-lock-delay-ms 20 --reader-delay-ms 50 \
  --require-overlap --measure-stalls
```

## Recorded verification

The new benchmark, NUMA server, correctness client, router, and original
`dinomo-bench` and `dinomo-kvs` targets compiled and linked with GCC 11.4,
CMake 3.22.1, and Protobuf 3.12.4. The RDMA server's compiler definitions were
checked to exclude the NUMA macros. This verifies builds, not a running
Soft-RoCE deployment. Nine invalid benchmark configurations were rejected.

| Check | Result | Evidence under `results/` |
|---|---|---|
| Single-worker local concurrent client smoke | Passed | `benchmark-client-13lh3hp8` |
| Two-worker remote concurrent client smoke | Passed; sampled pool pages on node 1 | `benchmark-client-j8b6wsqn` |
| Single-worker local synchronous client smoke | Passed, including timing summary | `benchmark-client-6vhjouwp` |
| Existing standalone 1,000-key local milestone | Passed | `milestone-sGT7zjoP` |
| Existing core reclamation regression | Passed; 19 fresh blocks, 8,175 reused grants, zero leases | `gc-core-B4R2BGG7` |
| Existing two-worker local 16 MiB stress | Passed; 8,400 writes, 524 completed epochs, zero leases | `server-startup-ns9jh5wj` |
| Existing injected-contention test with timing enabled | Passed; one reader wait and one writer wait, both with positive elapsed times | `server-startup-5smy76z6` |

All runs kept CPUs online. The evidence is machine-local and ignored by Git.
No throughput or scaling claim follows from these verification runs. Existing
allocation/merge diagnostic logging still needs attention before performance
measurements, alongside the pending launcher and aggregate report.
