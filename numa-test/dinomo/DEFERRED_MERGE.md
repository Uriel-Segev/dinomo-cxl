# Deferred merge with one NUMA KVS worker

The NUMA server no longer requires one index merge for every user write.
It publishes each record before acknowledgement and serves recent values from
local logs until worker-controlled merge updates P-CLHT. Merge and reclamation
still execute synchronously; there is no new background thread or overlapping
reader/writer execution.

## Write, read, and release flow

1. `DinomoKVStore::put/update` calls the original `Dinomo::put` to construct
   and copy the operation record into the shared pool.
2. `Dinomo::publish` publishes the active log's written boundary after record
   writes complete. This does not change the hash index or release log leases.
3. The wrapper counts the pending write and checks merge triggers. If no
   trigger fires, it returns to the handler, which acknowledges the request.
4. A GET checks active staging first, then retained log copies in newest-block
   order, then the shared index. Within each NUMA log block it now selects the
   LAST matching committed record with the expected key length. This fixes
   stale first-match results after repeated updates, including after rollover.
5. At a write threshold or timer, the worker calls `Dinomo::merge(true)`. The
   manager indexes committed records in log order. Compute retires staging,
   copies, caches, spare grants, and its shared log head, then sends Release.
6. Existing ownership checks recycle only unleased, zero-index-reference logs.
   Pending state is reset only after synchronous merge/release succeeds.

The index can lag an acknowledged update, but the worker's local log view must
return that update. An indexed old value remains protected by its index
reference while the newer record is protected by its compute lease. No log is
released merely because its record has been acknowledged.

The worker pauses request processing while merging. A write that fires a
trigger waits for that merge before its acknowledgement. Other writes can be
acknowledged without a full merge. Metadata requests retain their synchronous
manager-IPC behavior. Network batching remains disabled: record publication
and deferred index merge are different from buffering unflushed writes.

## Policy and counters

`conf/dinomo-numa.yml` defaults to:

```yaml
numa:
  merge-write-limit: 16
  merge-interval-ms: 20
```

The timer is measured from the FIRST pending write. `maybe_merge()` runs in the
worker event loop (including idle polling) and after writes. These are
worker-service thresholds, not hard real-time deadlines; a long operation can
delay servicing the timer. Normal SIGINT/SIGTERM shutdown drains remaining
pending writes before reporting counters and cleaning up.

- Set interval to zero for threshold-only merge.
- Set write limit to zero for timer-only merge.
- Set write limit to one and interval to zero for merge-before-ack behavior.
- Both zero is invalid and is rejected.

Keep the pending window small enough for the pool and configured fresh-block
limit: leased logs cannot be reclaimed before merge/release. An oversized
window or growing live dataset can still exhaust the pool and fails explicitly.
The tested 16-write threshold fits the 32-key, 64-block-cap stress workload.

The `NUMA merge` summary counts published writes, threshold/timer/shutdown
merges, successful staging/copy GETs, successful shared-index GETs, and pending
writes. Missing-key GETs are excluded from the successful-read counters.
`NUMA merge request` timestamps use the host monotonic clock; the idle probe
checks that a merge begins between its idle-start and idle-end timestamps.
The `NUMA GC` counters retain the meanings in
[LOG_RECLAMATION.md](LOG_RECLAMATION.md).

## Run the tests

From the repository root:

```bash
# Deterministic threshold-only checks plus 16 MiB pool stress; all CPUs online.
MEMORY_NODE=0 ./numa-test/dinomo/run_deferred_test.sh --no-offline

# Same workload with all pool-node CPUs offline; restores CPU state afterward.
./numa-test/dinomo/run_deferred_test.sh

# Timer-only merge, including 100 ms without client requests.
MEMORY_NODE=0 NUM_KEYS=32 MERGE_WRITES=0 MERGE_MS=20 IDLE_MS=100 \
  ./numa-test/dinomo/run_network_test.sh --no-offline

# Compatibility control: every write merges before acknowledgement.
MEMORY_NODE=0 NUM_KEYS=32 MERGE_WRITES=1 MERGE_MS=0 \
  ./numa-test/dinomo/run_network_test.sh --no-offline
```

The deferred runner disables the timer and uses a 16-write threshold. Its first
eight writes repeatedly update one key, force two rollovers with large helper
records, and read the latest value in both active and copied logs BEFORE the
first merge. It then checks reads across hundreds of threshold boundaries,
binary/variable-size values, cold keys, missing keys, metadata, bounded reuse,
pool placement, shutdown drain, manager reaping, and pool deletion. The client
never requests merge or clears worker staging.

## Validation on c8220

| Test | Evidence directory | Result |
|---|---|---|
| Focused threshold visibility | `results/server-startup-6ar_jbyw` | 104 writes, 6 threshold merges, 1 shutdown merge, 97 staged/copy reads |
| Local 16 MiB stress | `results/server-startup-1o6z81bk` | Passed |
| Remote memory-only 16 MiB stress | `results/server-startup-a258z4ip` | Passed; all 20 node 1 logical CPUs offline during test, restored afterward |
| Timer-only / idle probe | `results/server-startup-y3cck4e5` | 105 writes, 12 timer merges, a merge timestamp within the client-idle interval |
| Merge-before-ack control | `results/server-startup-5y608hw_` | 104 writes, 104 threshold merges, zero staged reads |
| Original 1,000-key standalone milestone | `results/milestone-9DGwKdil` | Passed with reclamation disabled |

Both large stress runs processed 8,296 user writes with 518 threshold merges
and one shutdown drain. They checked 8,297 staged/copy reads and 2,107 index
reads. They wrote 20,963,328 application update bytes and granted 33,611,776
logical log bytes through a 16 MiB pool, using 36 fresh log objects and 8,170
reused grants. At shutdown there were 32 live records in 20 blocks, 16 free
blocks, zero leased blocks, and zero pending writes. Placement checks matched
256/256 sampled pages at startup and shutdown. Evidence is machine-local and
ignored by Git; results were obtained on the working tree recorded by the
runner, not an automatically created commit.

These results establish visibility and safe reuse under worker-controlled
deferred merge. They do not establish a performance improvement, durability,
recovery, concurrent maintenance, or multiple-worker correctness. The tmpfs
pool remains volatile. Future background merge requires reader protection and
a revised ownership/publication protocol; it cannot simply run these methods
on another thread.
