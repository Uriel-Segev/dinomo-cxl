# Concurrent sealed-log merge with one compute worker

Concurrent merge is an opt-in extension of the NUMA backend. One compute
worker can publish new writes and serve private staging/log-copy reads while
the separate manager indexes an immutable sealed batch. The synchronous
deferred mode remains the default and is still tested.

This is not lock-free index access: shared-index GETs can wait for a coarse
process-shared read/write lock. Allocation, metadata, a full pending window,
or exhausted allocation credits can also wait for the manager. The goal here
is correct overlap and bounded reuse, not a performance claim.

## Batch ownership and IPC

1. A threshold/timer calls `Dinomo::begin_async_merge`. Compute publishes the
   active extent, captures its allocation grants, copies the active log into
   retained local history, and stops appending to those blocks.
2. Compute clears the old active state, spare-address array, and shared log
   head. It obtains credits for the next epoch before submitting the old batch,
   so its next write need not immediately wait for allocation.
3. `begin_merge` sends an AsyncMerge command with an increasing epoch ID and
   an explicit ordered list of sealed addresses. It does not wait for merge
   completion. The manager processes only those blocks, never the new active
   block or its unused allocation grants.
4. Compute keeps old private copies until completion, with newer active/copy
   records searched first. The worker polls the completion socket between
   requests. Only one sealed batch can be in flight.
5. `finish_async_merge` retires copies belonging to that completed batch and
   clears caches. Newer copies and active staging stay intact.
6. ReleaseEpoch supplies the matching epoch and exact addresses. The manager
   verifies full merge, checks that the current published chain excludes those
   addresses, ends only those leases, and queues zero-index-reference blocks.
   It removes the retired batch from its pending-grant list.

Address reuse still requires BOTH zero live index references and no compute
lease. Epoch IDs and exact-list matching reject stale or mismatched completion
and release messages. The manager retains sole ownership of PMDK allocation,
index mutation, reference accounting, and block reset.

The control socket is serialized. If a new allocation or metadata request is
needed while a merge reply is pending, the backend first receives and validates
that reply before issuing another command. It preserves the completion state
until compute retires the old copies. This is explicit backpressure, not an
unbounded command queue. Epoch submission is capped at 64 grants; concurrent
mode requires a write threshold in 1..16 and unlimited automatic log-copy
retention (`log-cache-len: 10000000`). Explicit epoch retirement bounds copies
instead of the old pruning policy.

## Reader protection

The backend creates a shared anonymous control mapping BEFORE forking the
manager and before ZeroMQ creates threads. Its POSIX rwlock uses
`PTHREAD_PROCESS_SHARED` and writer preference.

- `IndexReadGuard` spans the entire shared-index GET: root/table traversal,
  record-address lookup, and copying the value into the worker's private buffer.
  It releases before serialization, which uses private bytes. No manager IPC
  occurs inside this read section.
- The manager takes the write lock for index mutation, resize, release,
  allocation/reset, and other control commands. A reader holding an old record
  reference must finish before the manager can replace that index entry or
  reset reusable storage.
- Private staging/copy reads bypass the index lock. Those copies are immutable
  from the manager's perspective and their corresponding pool blocks stay
  leased until compute explicitly retires them.
- Active append writes use new-epoch leased blocks, not the sealed batch.

This protects index snapshots as well as record lifetimes. Original P-CLHT is
still used, but its mutation is not assumed to be safe against an unprotected
multi-step shared-memory read. Caches, batching, replication, and multiple
compute workers remain disabled.

## Shutdown and failure

Normal shutdown waits for the in-flight epoch, retires its copies, and drains
the current active epoch synchronously. Even when no writes are pending, it
releases unused next-epoch credits before removing the pool. Tests require
started/completed epoch counts to match, zero pending writes, and zero leases.

Index lock acquisition has a nominal five-second deadline. A manager killed
while holding the lock causes a bounded read failure and aborts the experiment;
the rwlock is not a crash-recovery mechanism. Cleanup reaps owned processes and
removes the private pool. The NUMA server configures ZeroMQ nonblocking teardown
so undeliverable responses to a disconnected client cannot hold shutdown open.
No failover, recovery, restart durability, or power-loss durability is promised.

## Configuration and test hooks

`numa.concurrent-merge` defaults to false. Set it true to enable this protocol;
keep reclamation enabled. `numa.manager-cpu` selects a CPU on the host NUMA node.
The tests validate CPU affinity and save it with owned PIDs in `processes.json`.
On c8220, compute CPU 2 and manager CPU 4 both belong to node 0.

Three bounded hooks (0..1000 ms) widen races for tests and default to zero:

| Setting | Injection point |
|---|---|
| merge-start-delay-ms | After announcing an epoch, before acquiring the writer lock |
| merge-lock-delay-ms | While holding the index writer lock |
| reader-delay-ms | After index lookup, before copying the referenced value, while holding the reader lock |

`writes_during_merge` and `staged_reads_during_merge` count successful work while
the manager actually holds the index writer lock, not merely while a reply is
pending. `reader_waits` and `writer_waits` count contended lock acquisitions.
`ipc_backpressure` counts control requests that first had to consume an earlier
merge reply; it is not elapsed wait time. Counters depend on scheduling.

## Run

From the repository root, with CPU/node IDs adjusted for the machine:

```bash
# Ordinary operation: concurrent mode, normal timer, NO delay hooks.
MEMORY_NODE=0 CONCURRENT_MERGE=1 MANAGER_CPU=4 \
  ./numa-test/dinomo/run_network_test.sh --no-offline

# Small-pool overlap/reuse stress. This test deliberately holds the writer
# lock for 5 ms to make overlap observable; it is not a benchmark.
MEMORY_NODE=0 MANAGER_CPU=4 ./numa-test/dinomo/run_concurrent_test.sh --no-offline

# Same stress with node 1 CPUs offline; restores CPU state afterward.
MANAGER_CPU=4 ./numa-test/dinomo/run_concurrent_test.sh

# Force reader/writer contention and verify that a pinned reader delays merge.
python3 numa-test/dinomo/test_server_startup.py \
  --host-cpu 2 --manager-cpu 4 --memory-node 0 --client-check --keys 32 \
  --merge-writes 16 --merge-ms 0 --require-deferred --concurrent \
  --merge-start-delay-ms 20 --merge-lock-delay-ms 20 --reader-delay-ms 50 \
  --require-overlap

# Exhaust available credits while a merge is in progress, then resume safely.
MEMORY_NODE=0 MANAGER_CPU=4 MERGE_LOCK_DELAY_MS=50 REQUIRE_BACKPRESSURE=1 \
  ./numa-test/dinomo/run_concurrent_test.sh --no-offline

# Interrupt an active epoch; separately kill the owned manager while a reader
# waits. Both checks use private local pools and leave CPUs online.
python3 numa-test/dinomo/test_concurrent_failure.py \
  --host-cpu 2 --manager-cpu 4 --memory-node 0

# Synchronous fallback remains available.
MEMORY_NODE=0 ./numa-test/dinomo/run_deferred_test.sh --no-offline
```

## Validation on c8220

| Test | Evidence directory | Result |
|---|---|---|
| Local 16 MiB concurrent stress | `results/server-startup-baus9h5v` | Passed; CPU 2 compute, CPU 4 manager |
| Remote memory-only concurrent stress | `results/server-startup-p5qbz3fc` | Passed; all 20 node 1 logical CPUs offline, restored afterward |
| Pinned-reader overlap test | `results/server-startup-1ym5nepv` | 35 writes and 35 staging reads while writer-locked; one reader wait and one writer wait |
| Allocation/control backpressure | `results/server-startup-j3x6z42e` | 512 backpressure events; values, epoch drain, and reuse passed |
| Ordinary concurrent timer, no hooks | `results/server-startup-4h4jbe2i` | 104 writes, 11 completed timer epochs; no injected delays |
| Interrupt during active epoch | `results/server-startup-l0fkrry4/FAULT_PASS` | Epoch drained, processes reaped, pool removed |
| Manager killed while reader waits | `results/server-startup-lc9lhlbq/FAULT_PASS` | Five-second reader deadline failed explicitly; processes/pool cleaned up |
| Synchronous deferred regression | `results/server-startup-tz8_7zd3` | Passed |
| Original standalone, 1,000 keys | `results/milestone-u5zhPkmC` | Passed with concurrency/reclamation disabled |

Both large stress runs processed 8,296 writes, completed all 518 asynchronous
epochs plus a synchronous shutdown drain, and verified 20,963,328 application
update bytes through a 16 MiB pool. They used 38 fresh log objects with 8,168
reused grants. At shutdown there were 32 live records in 20 blocks, 18 free
blocks, zero leased blocks, and zero pending writes. Both verified placement
for 256/256 sampled pages at startup and shutdown. Each observed over 1,000
writes and staging reads during writer-locked windows. With the longer 50 ms
injection, high-water allocation was 40 objects and all 518 epochs completed.

The no-hook test validates ordinary behavior, but did not happen to observe
critical-section overlap at its client request rate. Delay hooks deliberately
make those windows measurable. These are correctness/space-reuse results, not
throughput or latency claims. Evidence directories are machine-local and ignored
by Git; no commit is created automatically. Multiple workers, finer-grained
index protection, replication, actual CXL hardware evaluation, and recovery
remain subsequent work.
