# Synchronous single-worker log reclamation

This milestone recycles obsolete log blocks while preserving synchronous
single-worker merge/release and the existing DINOMO compute/P-CLHT code.
The server now also supports acknowledgements before merge; see
[DEFERRED_MERGE.md](DEFERRED_MERGE.md). Pending records remain leased until a
complete merge and release, so the ownership rule below is unchanged.
This baseline does not add background merge,
multiple workers, compaction, deletion, replication, or crash recovery.
The later [concurrent mode](CONCURRENT_MERGE.md) adds reader protection and
epoch-specific release while preserving the zero-reference, unleased reuse rule.

## Ownership rule

The manager distinguishes two kinds of references:

1. Index references: the current CLHT entry for each key names one record in a
   log block. Manager-local ownership tracks the record offset and owning block
   per key, plus a live-record count per block. When merge replaces a CLHT entry,
   its returned old offset must match this ownership record before the old
   block's count is decremented. The new block's count is incremented.
2. Compute leases: an allocation grant may still be held by active staging,
   a copied log, a cache/shortcut, an unused preallocation slot, or a published
   log-chain head. A successful merge alone does not end these leases.

`BlockState::live` in manager-local memory is the reclamation authority; the
original log header's valid/invalid counters retain their existing meanings.
Metadata remains a separate volatile manager-local store.

A block is reusable only when its index-reference count is zero AND compute
has explicitly released its lease. Blocks with even one cold/live record
remain allocated. No partially live block is compacted in this milestone.

## Release handshake

For a reclamation-enabled `Dinomo::merge(true)`:

1. Compute publishes the current log boundary and requests synchronous merge.
2. The manager applies committed records through original CLHT functions and
   updates ownership counts. It does not reuse any leased block.
3. Compute retires active staging and copied logs, clears caches and indirect
   pointers, discards all spare preallocated addresses, and clears its shared
   log mapping slot.
4. Compute sends a synchronous Release command and waits. The manager checks
   that the mapping slot is zero and all granted logs are fully merged.
5. The manager clears retired chain links, ends the grants, and queues every
   unleased zero-reference block for reuse. The pending-log list is cleared.
6. A later Allocate first consumes that queue. It checks the ownership state,
   resets the block header and payload, and grants the address again. Only when
   the queue is empty does it allocate another PMDK object.

An unbatched merge with cache retirement is required; unsafe merge modes fail
explicitly. The standalone baseline defaults to reclamation disabled, while
the NUMA network configuration enables it.

The synchronous single-worker contract is essential: a previous GET has
finished copying its result before another write can merge/release, and there
is no simultaneous index reader during merge. CLHT GET refreshes the active
table from the root; compute does not retain old table snapshots between
operations. This protocol cannot be reused for concurrent workers or
background merge without reader protection and a new ownership protocol. The
later concurrent mode supplies those for one compute worker: it can release a
completed epoch while a newer shared log head remains active.

## Memory bounds and counters

Recycled blocks remain allocated PMDK objects in the pool; this returns space
to the manager's reusable inventory, not to the OS or PMDK free allocator.
Manager maps grow with distinct live keys and the physical block high-water
mark, not with the number of updates. A growing live dataset can still fill the
pool. Continuous merge, partially-live compaction, and index-table reclamation
are separate work.

The `NUMA GC` summary reports:

| Counter | Meaning |
|---|---|
| fresh_blocks | Number of PMDK log objects allocated; physical high-water mark |
| reused_blocks | Allocation grants satisfied by existing reusable objects |
| reclaimed_blocks | Events returning a zero-reference, unleased block to the queue; includes unused spare grants |
| live_blocks / live_records | Blocks/records referenced by current index entries |
| free_blocks | Objects queued for reuse |
| leased_blocks | Objects still granted to compute |
| logical_log_bytes | Sum of block sizes across all allocation grants, including reused grants |

`allocated_logs` in the earlier NUMA summary continues to count grants, not
fresh PMDK objects. `numa.log-block-limit` can cap fresh log objects for tests;
zero means no extra cap beyond available pool capacity. Setting
`numa.reclaim-logs` false disables reuse for the exhaustion control.

## Reproduce

From the repository root:

```bash
# Core test: partially live blocks, cold keys, colliding keys, and address reuse.
./numa-test/dinomo/run_gc_core_test.sh

# Network stress: local 16 MiB pool; all CPUs remain online.
MEMORY_NODE=0 ./numa-test/dinomo/run_gc_test.sh --no-offline

# Same stress: node 1 memory-only pool; CPU state restored afterward.
./numa-test/dinomo/run_gc_test.sh

# Negative control: the same workload must exhaust PMDK without reclamation.
MEMORY_NODE=0 RECLAIM_LOGS=0 LOG_BLOCK_LIMIT=0 EXPECT_EXHAUSTION=1 \
  ./numa-test/dinomo/run_gc_test.sh --no-offline
```

The network stress defaults to 32 keys, 16 of them hot, 512 update rounds,
4 KiB blocks, a 16 MiB pool, and a maximum of 64 fresh log blocks. Hot values
vary in size, contain binary bytes, and carry generation identifiers. Each
acknowledged write is followed by a client GET. Cold keys and all current
values are rechecked across many reuse cycles. Initial keys collide in CLHT's
initial table. No client command manually merges logs or clears staging.

The runner requires both cumulative application update bytes and logical log
grants to exceed the pool's entire capacity, checks a nonzero reuse count,
checks the fresh-object bound, requires no outstanding leases, and verifies
index-reference counts and physical placement. The negative control expects
actual `pmemobj_zalloc` failure with no artificial block cap, then verifies
manager/pool cleanup. It records `EXPECTED_EXHAUSTION`, not a workload PASS.

## Validated on c8220

These are the saved merge-before-ack reclamation baseline runs. Current
deferred-merge tests and counters are documented in DEFERRED_MERGE.md; the
client now also includes a pre-merge rollover probe.

| Test | Result | Local evidence directory |
|---|---|---|
| Core mixed-live test | 19 fresh objects, 8,175 reused grants, 32 live records; 33,890,384 logical bytes in 16 MiB | `results/gc-core-rUm6hgim` |
| Local network stress | Passed | `results/server-startup-6rspna0h` |
| Remote memory-only network stress | Passed; all 20 node 1 logical CPUs offline, restored afterward | `results/server-startup-m3d61vcu` |
| Reuse-disabled control | Expected PMDK pool exhaustion; cleanup passed | `results/server-startup-0bianf6p` |
| Original standalone milestone, reuse disabled | 1,000-key correctness and rollover passed | `results/milestone-MIJyARJe` |

Both network stress runs wrote 20,963,328 application update bytes, granted
67,895,296 logical log bytes, and used only 34 fresh log objects with 16,542
reused grants. At shutdown, 32 blocks held 32 current records, two blocks were
free, and none were leased. Placement checks passed for 256/256 sampled pages
at startup and shutdown. Evidence is machine-local and ignored by Git; retain
it separately when moving hosts. These are correctness and space-reuse results,
not performance or persistence claims.
