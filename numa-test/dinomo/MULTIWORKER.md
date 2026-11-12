# Fixed-owner NUMA compute workers

The NUMA server can launch 1..64 compute threads against one shared pool and
one manager. Multiple workers require `numa.concurrent-merge: true`, which
provides the process-shared index read/write lock. This is an experimental
extension of the single-worker baseline, not a throughput claim.

## Ownership and visibility

DINOMO's existing routing and local hash ring assign each user key to one
compute worker. Keep the worker count and membership fixed for the run, with
replication, batching, and caches disabled. User keys must be canonical positive
decimal integers, matching the existing integer-key compute engine. The owner serves acknowledged,
unmerged writes from its private staging and retained copies. Other workers
must not serve that key's pending data. Dynamic resharding, worker restart,
cross-worker writes to the same key, and failover are not implemented.
The manager rejects a key whose indexed owner changes.

Each compute thread binds its worker ID before constructing its Dinomo store.
It owns a private control connection, epoch sequence, allocation-grant lists,
pending completion state, staging-buffer slice, and published log-head slot.
The manager polls worker connections in round-robin order and processes one
command at a time. A delayed merge therefore still delays other workers'
allocation and metadata commands, although private staging work can continue.
Only one sealed epoch may remain outstanding per worker.

The manager maintains per-worker granted blocks and merged epochs. Commands
and replies carry a worker ID; connection identity, epoch identity, and exact
release address lists are checked. Each physical block has one lease owner.
Release checks that owner's published chain while the owner waits for its
reply. Other workers cannot obtain the block until it has zero index
references and its owner has released its lease. Index reads from all workers
hold the existing read lock through copying the value, so index replacement
and block reuse cannot invalidate an in-progress read. The global free list
allows a released, obsolete block to be allocated to a different worker.

Startup forks one manager before starting compute/ZeroMQ threads. Shutdown
joins every compute worker after its drain, collects final manager statistics,
and only then stops the manager and unmaps the pool. A worker exception requests
peer shutdown and is reported as a server failure; this is cleanup, not recovery.

## Configuration

Keep the default single-worker configuration for baseline runs. For two workers,
change these fields in a copy of `conf/dinomo-numa.yml`:

```yaml
threads:
  memory: 2
  storage: 0
  routing: 1
  benchmark: 1
numa:
  concurrent-merge: true
  worker-cpus: [2, 6]
  manager-cpu: 4
```

Preserve all other configuration fields. CPU IDs above are examples; choose
online CPUs on the compute NUMA node for the host. If `worker-cpus` is omitted,
all compute workers use `host-cpu`; use distinct CPUs for scaling measurements.
Test hooks should be zero for ordinary runs. More workers require more live and
preallocated blocks; the single-worker pool/block limits may be too small.

## Validation

Build the existing NUMA targets, then run from the repository root:

```bash
python3 numa-test/dinomo/test_server_startup.py \
  --workers 2 --worker-cpus 2,6 --host-cpu 2 --manager-cpu 4 \
  --memory-node 0 --concurrent --client-check --keys 32

# Simultaneous independent client keyspaces; aggregate updates exceed the pool.
python3 numa-test/dinomo/test_server_startup.py \
  --workers 2 --worker-cpus 2,6 --host-cpu 2 --manager-cpu 4 \
  --memory-node 0 --concurrent --client-check --keys 32 --gc-rounds 256 \
  --pool-mb 16 --log-block-limit 96
```

The runner launches one client per worker, with distinct client ports, user
keyspaces, and metadata keys. Each uses routing rather than directly selecting
a server worker. It checks all workers become ready, publish writes, and drain;
all clients check immediate/later reads, repeated updates, binary values, and
metadata. GC checks use the aggregate live key count and application bytes.
Use `--memory-node 1` for a remote placement control without changing CPU online
state. CPU-offline validation remains a separate, explicitly controlled run.

## Recorded results on c8220

| Check | Result | Evidence directory under `results/` |
|---|---|---|
| Two workers, local 16 MiB pool, no delay hooks | 8,400 writes, 524 completed async epochs, 64 current records, zero leases; 74 fresh blocks and 8,150 reused grants | `server-startup-nn7bbtsk` |
| Two workers, remote node 1 pool, no delay hooks | Same write/epoch/record totals and zero leases; 256/256 sampled pages on node 1 at startup/shutdown; CPU affinity verified | `server-startup-kfod1ju9` |
| Four workers, local 16 MiB pool, no delay hooks, acknowledged shutdown | 8,608 writes, 536 completed async epochs, 128 current records, zero leases; 139 fresh blocks and 8,117 reused grants | `server-startup-cw5zoxdb` |
| Two workers, injected reader/merge delays | Passed; 3 reader waits, 4 writer waits, writes and staging reads progressed while manager held the writer lock | `server-startup-9mntmbcf` |
| Two workers, interrupt during active epoch | Both workers drained; owned manager/router and pool removed | `server-startup-4rt3hen0/FAULT_PASS` |
| Two workers, manager killed during a reader wait | Five-second lock bound failed explicitly; owned processes and pool removed | `server-startup-a7bsznib/FAULT_PASS` |
| Single-worker deferred network regression | Immediate/later visibility, threshold merge and shutdown passed | `server-startup-7y12qnbw` |
| Original standalone reclamation regression | Mixed-live/cold/colliding keys passed; 19 fresh blocks, 8,175 reused grants, zero leases | `gc-core-HFqkgQpU` |

The two-worker GC clients each updated 10,477,568 application bytes; the
four-worker GC clients each updated 5,234,688 bytes. Aggregate application
updates exceeded the 16 MiB pool in each stress run. These checks do not
establish throughput, latency, or scaling improvement. The remote extension
checks left node 1 CPUs online; the earlier single-worker memory-only evidence
is separate. Only two- and four-worker configurations have been exercised;
the configurable upper bound of 64 is not a validation claim. Evidence is
machine-local and ignored by Git.

Run multiworker failure checks with:

```bash
python3 numa-test/dinomo/test_concurrent_failure.py \
  --workers 2 --worker-cpus 2,6 --host-cpu 2 --manager-cpu 4 --memory-node 0
```
