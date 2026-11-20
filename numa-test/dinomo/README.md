# DINOMO NUMA experiment: setup, implementation, tests, and benchmarks

This is the starting guide for the NUMA work in this repository. It covers the
small memory experiments, the DINOMO implementation milestones, correctness
and comparison tests, and the host-native benchmark workflow. Commands run
from the **repository root** unless a command explicitly changes directory.

## What is implemented

DINOMO can run on one Linux host with its existing network client, router,
compute engine, operation logs, and P-CLHT index. A NUMA backend replaces the
RDMA storage path with a shared-memory pool and a separate manager process.
No VM or Soft-RoCE device is needed for this workflow.

| Component | Current behavior |
|---|---|
| Network path | Existing `KvsClient` → DINOMO router → KVS compute worker |
| Compute | One or multiple worker threads in one KVS process, with private staging and fixed key ownership |
| Pool | Private, volatile, tmpfs-backed PMDK pool placed on a selected NUMA memory node |
| Data access | Checked address-to-offset translation and copies between the compute mapping and shared pool; different mapping addresses are supported |
| Manager | Separate process owning allocation, merge, index updates, metadata IPC, and log reuse |
| Index | Existing P-CLHT implementation; concurrent mode protects index lookup through value copying with a process-shared reader lock |
| Visibility | Writes publish before acknowledgement; the owning worker reads the latest unmerged value from active staging or retained log copies |
| Merge | Write-threshold/timer triggers; synchronous deferred mode or opt-in concurrent sealed-log epochs |
| Reclamation | Reuse only after a block has zero index references and its compute lease has been explicitly released |
| Shutdown | Drain pending writes/epochs, release grants, stop the manager, and remove the private pool |
| Benchmarking | LOAD, READ, UPDATE, VERIFY; synchronized clients; combined latency histograms; JSON/CSV reports and cleanup evidence |

Concurrent mode lets the manager merge a sealed epoch while workers continue
using private staging. The manager still handles commands serially, and index
reads and allocation/control requests can wait. Each worker can have one
outstanding sealed epoch. A cold/live record keeps its block allocated; there
is no compaction of partially live blocks.

The supported configuration keeps membership and worker count fixed, uses
canonical positive decimal integer user keys, and disables caches, batching,
elasticity, and replicated copies. Multiple workers require concurrent merge.
The implementation accepts up to 64 workers, but the exercised configurations
are 1, 2, and 4 workers. There is no dynamic reassignment, worker failover,
restart recovery, or durability guarantee. Remote NUMA is an experimental
memory-placement model, not actual CXL hardware or CXL timing.

## 1. Prepare a host

Use an x86-64 Linux host. Two memory-bearing NUMA nodes are needed for a
local/remote comparison; one node is enough for local correctness checks.
Inspect topology and tmpfs capacity first:

```bash
lscpu -e=CPU,NODE,SOCKET,CORE,ONLINE
numactl --hardware
bash numa-test/numa_cpu_control.sh status
df -h /dev/shm
```

Every CPU/node ID in this guide is an **example**. Replace them for your host.
The benchmark examples assume distinct physical cores on compute node 0:
workers `2,6,8,9`, manager `4`, router `0`, and clients `1,3`; pool node `0` is
local and node `1` is remote. Check SMT sibling relationships using the CORE
and SOCKET columns. The benchmark launcher rejects shared cores by default.
Leave CPUs online for ordinary tests and benchmarks.

Install the build dependencies on Ubuntu:

```bash
sudo apt-get update
sudo apt-get install -y build-essential cmake git python3 pkg-config \
  autoconf automake libtool wget unzip protobuf-compiler libprotobuf-dev \
  libibverbs-dev librdmacm-dev libtbb-dev libjemalloc-dev libzmq3-dev \
  libboost-all-dev libyaml-cpp-dev libspdlog-dev libpmemobj-dev libpmem-dev \
  libnuma-dev libmemcached-dev libpapi-dev libssl-dev numactl pciutils
```

These are the existing build dependencies; verbs libraries are needed to
compile shared DINOMO sources even though NUMA runs do not open RDMA devices.
The NUMA C++ targets use C++17. First-time CMake configuration downloads pinned
dependencies and needs network access. Rebuild on a new machine rather than
copying binaries or a CMake cache. Linux NUMA placement syscalls must be allowed;
a restricted container may prevent placement checks or local socket creation.

## 2. Build all NUMA components

```bash
# Small memory microbenchmarks.
make -C numa-test -j4

# Standalone DINOMO compute and reclamation tests.
make -C numa-test/dinomo -j4
make -C numa-test/dinomo build/dinomo-numa-gc-check -j4

# Network server, router, correctness client, and benchmark client.
make -C src/kvs/libbloom -j4
cmake -S . -B build/numa -DCMAKE_BUILD_TYPE=Release -DBUILD_NUMA_SERVER=ON
cmake --build build/numa --target \
  dinomo-kvs-numa dinomo-route dinomo-numa-client-check dinomo-numa-bench -j4
```

`conf/dinomo-numa.yml` is the one-worker correctness baseline with synchronous
deferred merge and reclamation. `conf/dinomo-numa-bench.json` is the separate
benchmark template with quiet diagnostics. The Python runners generate private
per-run configurations; do not edit the baseline for each experiment.

## 3. Small memory experiments

These measure the memory subsystem independently of DINOMO. They do not
measure end-to-end GET/UPDATE latency. See the [memory experiment guide](../README.md)
for placement policy, environment options, and result interpretation.

| Runner | What it measures |
|---|---|
| `numa-test/run_experiment.sh` | Dependent pointer-chase latency, local versus remote, before and after pool-node CPU offlining |
| `numa-test/run_memory_test.sh read-bandwidth` | Single-worker sequential read bandwidth |
| `numa-test/run_memory_test.sh write-bandwidth` | Single-worker sequential write bandwidth |
| `numa-test/run_memory_test.sh concurrent-read` | Aggregate random reads from multiple compute cores |
| `numa-test/run_memory_test.sh atomic` | Random sequentially consistent 64-bit atomic fetch-add |
| `numa-test/run_memory_test.sh mixed` | Concurrent 60% read / 30% write / 10% atomic workload |

```bash
HOST_CPU=2 HOST_NODE=0 MEMORY_NODE=1 \
  bash numa-test/run_experiment.sh
HOST_NODE=0 MEMORY_NODE=1 SIZE_MB=256 DURATION=3 REPETITIONS=3 THREADS=8 \
  bash numa-test/run_memory_test.sh all
bash numa-test/show_results.sh
bash numa-test/show_memory_results.sh
```

These runners use sudo to offline pool-node CPUs and restore them afterward.
Use a working set larger than the host's last-level cache for memory-latency
comparisons. Results go under `numa-test/results/`. `run_all_tests.sh` runs the
memory suites; it does **not** run all DINOMO correctness and benchmark tests.

## 4. DINOMO correctness tests, from smallest to largest

Run network suites **one at a time**, with existing DINOMO services stopped and
loopback service ports free. They share service ports. Each runner creates its
own pool and saves evidence under `numa-test/dinomo/results/`.

### Standalone compute and core reclamation

```bash
# Direct compute API: insert/read/update/read, missing keys, rollover,
# repeated allocation batches, and sampled memory placement.
HOST_CPU=2 HOST_NODE=0 MEMORY_NODE=0 \
  bash numa-test/dinomo/run_milestone.sh --no-offline

# Same compute test against a remote pool, leaving CPUs online.
HOST_CPU=2 HOST_NODE=0 MEMORY_NODE=1 \
  bash numa-test/dinomo/run_milestone.sh --no-offline

# Mixed-live blocks, cold/colliding keys, and safe address reuse.
HOST_CPU=2 MEMORY_NODE=0 bash numa-test/dinomo/run_gc_core_test.sh
```

The standalone milestone defaults to reclamation disabled and explicit merge
boundaries. It exercises the real compute/P-CLHT code without network services.
The core GC test adds the zero-reference/unleased reuse checks.

### Network startup and single-worker visibility

```bash
# Startup, placement, and lifecycle only.
python3 numa-test/dinomo/test_server_startup.py \
  --host-cpu 2 --manager-cpu 4 --memory-node 0

# Add network value checks and deterministic deferred-merge visibility.
python3 numa-test/dinomo/test_server_startup.py \
  --host-cpu 2 --manager-cpu 4 --memory-node 0 --client-check --keys 64 \
  --merge-writes 16 --merge-ms 0 --require-deferred

# Reclamation stress in a 16 MiB pool.
MEMORY_NODE=0 MANAGER_CPU=4 \
  bash numa-test/dinomo/run_gc_test.sh --no-offline

# Deferred merge plus reclamation stress; timer disabled for determinism.
MEMORY_NODE=0 MANAGER_CPU=4 \
  bash numa-test/dinomo/run_deferred_test.sh --no-offline
```

The correctness client checks immediate and later values, repeated updates,
variable-size/binary values, missing keys, metadata, and cold keys. The deferred
probe checks newest-value reads before merge across active logs and rollover.
Stress checks require update bytes/log grants beyond pool capacity, bounded
fresh allocation, actual reuse, and zero remaining leases/pending writes.

### Concurrent merge, contention, and failure handling

```bash
# Ordinary concurrent operation, with no injected delays.
MEMORY_NODE=0 MANAGER_CPU=4 CONCURRENT_MERGE=1 \
  bash numa-test/dinomo/run_network_test.sh --no-offline

# Stress overlap/reuse; deliberately injects a 5 ms writer-lock delay.
MEMORY_NODE=0 MANAGER_CPU=4 \
  bash numa-test/dinomo/run_concurrent_test.sh --no-offline

# Force reader/writer contention and verify overlap.
python3 numa-test/dinomo/test_server_startup.py \
  --host-cpu 2 --manager-cpu 4 --memory-node 0 --client-check --keys 32 \
  --merge-writes 16 --merge-ms 0 --require-deferred --concurrent \
  --merge-start-delay-ms 20 --merge-lock-delay-ms 20 --reader-delay-ms 50 \
  --require-overlap

# Allocation-credit/control backpressure.
MEMORY_NODE=0 MANAGER_CPU=4 MERGE_LOCK_DELAY_MS=50 REQUIRE_BACKPRESSURE=1 \
  bash numa-test/dinomo/run_concurrent_test.sh --no-offline

# Interrupt an active epoch; kill the owned manager during a reader wait.
python3 numa-test/dinomo/test_concurrent_failure.py \
  --host-cpu 2 --manager-cpu 4 --memory-node 0
```

Injected delays make contention and overlap observable. Keep all three delay
hooks at zero for ordinary operation and performance measurements. Failure
checks establish bounded failure and cleanup, not recovery of stored data.

### Fixed-owner multiple workers

```bash
# Two-worker small-pool stress, without delay hooks.
python3 numa-test/dinomo/test_server_startup.py \
  --workers 2 --worker-cpus 2,6 --host-cpu 2 --manager-cpu 4 \
  --memory-node 0 --concurrent --client-check --keys 32 --gc-rounds 256 \
  --pool-mb 16 --log-block-limit 96 --merge-ms 0

# Four-worker local stress.
python3 numa-test/dinomo/test_server_startup.py \
  --workers 4 --worker-cpus 2,6,8,9 --host-cpu 2 --manager-cpu 4 \
  --memory-node 0 --concurrent --client-check --keys 32 --gc-rounds 128 \
  --pool-mb 16 --log-block-limit 192 --merge-ms 0

# Multiworker interruption and manager-death checks.
python3 numa-test/dinomo/test_concurrent_failure.py \
  --workers 2 --worker-cpus 2,6 --host-cpu 2 --manager-cpu 4 --memory-node 0
```

Repeat with `--memory-node 1` to test remote placement while keeping CPUs
online. The correctness runner starts one independent client keyspace per
worker and checks affinity, all-worker readiness, publication, epoch drain,
record counts, placement, and cleanup.

## 5. Comparison and negative controls

These are the existing comparison tests (there is no separate differential-test
runner). Keep workload and placement matched while changing the named option.

| Comparison | How to run | Expected evidence |
|---|---|---|
| Local versus remote pool | Repeat a Python test with `--memory-node 0` and `1`, or a shell test with `MEMORY_NODE=0/1 --no-offline` | Values remain correct; sampled pages are on the requested node |
| Reclamation enabled versus disabled | Normal GC stress versus exhaustion command below | Reuse sustains updates; disabled reuse exhausts PMDK and cleans up |
| Merge-before-ack versus deferred | `MERGE_WRITES=1 MERGE_MS=0` versus deferred runner | Both return correct values; deferred path also exercises unmerged reads |
| Timer-only versus threshold-only | Timer command below versus deferred runner | Idle timer merge versus deterministic threshold merge |
| Synchronous versus concurrent | Deferred runner versus concurrent runner | Correct values and safe reuse in both; concurrent epochs and overlap checked separately |
| Timing enabled versus disabled | Benchmark default versus `--no-stall-timing` | Matched timing-overhead control; disabled run omits stall timing results |
| CPUs online versus memory-only pool | Shell runner with versus without `--no-offline` | Correct placement and restoration of changed CPU state |

```bash
# Negative control: real PMDK exhaustion, without an artificial block cap.
MEMORY_NODE=0 RECLAIM_LOGS=0 LOG_BLOCK_LIMIT=0 EXPECT_EXHAUSTION=1 \
  bash numa-test/dinomo/run_gc_test.sh --no-offline

# Compatibility control: synchronous merge before each write acknowledgement.
MEMORY_NODE=0 NUM_KEYS=32 MERGE_WRITES=1 MERGE_MS=0 \
  bash numa-test/dinomo/run_network_test.sh --no-offline

# Timer-only merge, including a client-idle interval.
MEMORY_NODE=0 NUM_KEYS=32 MERGE_WRITES=0 MERGE_MS=20 IDLE_MS=100 \
  bash numa-test/dinomo/run_network_test.sh --no-offline
```

The exhaustion control records `EXPECTED_EXHAUSTION`, not a successful workload
PASS. At least one merge trigger must remain enabled in ordinary configurations.

For an explicit memory-only experiment, use a remote shell test **without**
`--no-offline`, for example:

```bash
HOST_CPU=2 HOST_NODE=0 MEMORY_NODE=1 MANAGER_CPU=4 \
  bash numa-test/dinomo/run_deferred_test.sh
```

This offlines pool-node CPUs using sudo and restores those changed by the run
on exit/interruption. Use a pool node separate from compute; the CPU-control
script protects the node containing CPU 0. After SIGKILL or a lost session,
check status and restore if necessary:

```bash
bash numa-test/numa_cpu_control.sh status
sudo bash numa-test/numa_cpu_control.sh restore
```

## 6. Benchmark checks and measurements

First verify accounting, client behavior, and launcher lifecycle sequentially:

```bash
python3 numa-test/dinomo/test_benchmark_results.py
python3 numa-test/dinomo/test_benchmark_client.py \
  --worker-cpus 2 --manager-cpu 4 --client-cpu 6 --memory-node 0
python3 numa-test/dinomo/test_benchmark_launcher.py \
  --worker-cpu 2 --manager-cpu 4 --router-cpu 0 --client-cpus 1,3
```

These cover weighted histogram quantiles, drain-tail retention, result identity
and accounting, client values/errors/barriers, occupied ports, synchronous
fallback with timing disabled, interruption, manager death, and cleanup.

Run the short 12-case workflow matrix:

```bash
python3 numa-test/dinomo/run_benchmark.py \
  --worker-cpus 2,6,8,9 --worker-counts 1,2,4 \
  --manager-cpu 4 --router-cpu 0 --client-cpus 1,3 \
  --memory-nodes 0,1 --keys 1000 --value-size 64 \
  --pool-mb 64 --log-block-bytes 4096 --outstanding 32 \
  --warmup-s 1 --duration-s 2 --repeats 1
```

The matrix measures READ and UPDATE separately with a fresh deployment and
LOAD for each case. It verifies placement and affinity, warms up, synchronizes
clients, measures, drains, verifies the full keyspace, and checks shutdown and
cleanup. Every CPU stays online. The benchmark launcher requires workers,
manager, router, and clients to use distinct online CPUs on the same compute
node; workers use a prefix of `--worker-cpus` for each worker count.

For longer measurements, use the command in [BENCHMARKING.md](BENCHMARKING.md):
start with `--keys 10000 --pool-mb 512 --log-block-bytes 16384 --warmup-s 5
--duration-s 30 --repeats 3`, keeping the other placement/workload options
matched. Confirm `/dev/shm` capacity first. Vary client count and outstanding
requests to check client saturation. Repeat with `--no-stall-timing` for an
overhead control. A synchronous benchmark requires `--worker-counts 1
--synchronous`. Dataset size alone does not determine pool capacity; leave
space for live records, partially live blocks, index growth, and grants.

Throughput counts successful responses observed inside the scheduled window.
Median/p99 are calculated from merged client histograms for **all requests
issued in that window**, including drain completions. Percentiles are not
averaged across clients or repeats. Backend allocation/merge/reader/writer
wait times cover the whole server lifetime, including LOAD, warmup, VERIFY,
and shutdown; categories can overlap and are not exclusive measured-phase
stalls. See [BENCHMARK_CLIENT.md](BENCHMARK_CLIENT.md) for exact definitions.

## 7. Results, validation status, and moving hosts

| Evidence | Location/content |
|---|---|
| Memory microbenchmarks | `numa-test/results/`: CSV and summaries; use the display scripts |
| Standalone/network correctness | `numa-test/dinomo/results/`: per-run logs, topology/configuration, and PASS/fault/exhaustion evidence as appropriate |
| Benchmark matrix | `benchmark-*/summary.csv` and `summary.json`; one row per configuration/workload/repeat |
| Individual benchmark case | `report.json`, phase/client results and histograms, configuration, process records, `cleanup.json`, PASS/FAIL |
| Benchmark provenance | Root manifest, source/binary hashes, Git state/patch, source snapshots, topology, and available build metadata |

Implementation milestones have recorded standalone, network, reclamation,
deferred, concurrent, and multiworker correctness results. Their detailed
documents retain the historical evidence IDs and host-specific counts.
The latest validation of the benchmark working tree passed all four build
targets across the build checks, nine accounting tests, client integration,
launcher failure/cleanup checks, and the 12-case 1/2/4-worker local/remote
READ/UPDATE smoke matrix. The matrix evidence is
`results/benchmark-bws7uyab/`; launcher evidence is
`results/launcher-check-cgnw77tu/`; isolated client evidence is
`results/benchmark-client-iq5cm3tg/`. These short runs validate the workflow. A subsequent longer evaluation
completed 36 repeated baseline measurements and 10 client-concurrency/timing
controls, all passing. See [BENCHMARK_EVALUATION.md](BENCHMARK_EVALUATION.md)
for the results, evidence directories, and limits. Four-client UPDATE runs
exceeded the two-client baseline substantially, so a matched scaling matrix
with more client concurrency and measured-phase profiling remains next.

Result directories are ignored by Git and machine-local. Preserve selected
logs/results separately before leaving a host. Commit/push source and docs,
record the commit and working-tree state, rebuild on the next host, and rerun
correctness checks before measuring. Pools are volatile and removed by the
runners; every fresh deployment must load data again.

The older `numa-test/run_dinomo_test.sh` and
`vm-configs/c6525-25g/` scripts use the separate five-VM/Soft-RoCE workflow.
They are not the host-native NUMA benchmark launcher.

## Implementation and detailed documentation map

| File or guide | Purpose |
|---|---|
| `include/kvs/numa_backend.hpp`, `src/kvs/numa_backend.cpp` | Shared mapping, manager IPC, allocation, ownership/reuse, epochs, locks, placement, and counters |
| `include/kvs/dinomo_compute.hpp` | NUMA compute integration, publication, staging visibility, merge/release |
| `src/kvs/server.cpp` | NUMA worker startup, configuration, and lifecycle |
| `src/benchmark/numa_client_check.cpp` | Network correctness workload |
| `src/benchmark/numa_benchmark.cpp` | Host-native bounded benchmark client |
| `numa-test/dinomo/run_benchmark.py`, `benchmark_results.py` | Deployment/matrix orchestration and result validation/aggregation |
| [Memory experiments](../README.md) | Low-level latency/bandwidth/atomic tests and CPU control |
| [Log reclamation](LOG_RECLAMATION.md) | Index references, leases, release handshake, reuse counters, exhaustion control |
| [Deferred merge](DEFERRED_MERGE.md) | Latest-value reads, threshold/timer policy, rollover probes |
| [Concurrent merge](CONCURRENT_MERGE.md) | Original single-worker epoch protocol, reader protection, backpressure, fault tests |
| [Multiple workers](MULTIWORKER.md) | Current fixed-owner extension, constraints, stress/failure evidence |
| [Benchmark client](BENCHMARK_CLIENT.md) | Client contract, histogram population, and timing definitions |
| [Benchmark workflow](BENCHMARKING.md) | Full matrix setup, resource ownership, reports, interpretation |
| [Longer benchmark evaluation](BENCHMARK_EVALUATION.md) | Repeated 1/2/4-worker results, client-concurrency/timing controls, and next experiments |
| [Network integration audit](NETWORK_INTEGRATION_AUDIT.md) | Historical audit and integration findings |

Earlier milestone guides describe their scope at the time; use the current
implementation overview above and MULTIWORKER.md for the cumulative feature
boundary. Next work is repeated matched benchmark evaluation, followed by
separately scoped improvements such as finer index locking, allocation
scheduling, compaction, dynamic ownership, replication, and recovery.
