# One-worker NUMA network integration audit

This records the initial static source audit and subsequent implementation.
The current network correctness status is summarized immediately below;
the detailed audit sections preserve findings from before integration.
The existing milestone remains the correctness baseline; its local and remote
controls have passed on the user's c8220 host.

An experimental fixed-owner multiworker extension is described in
[MULTIWORKER.md](MULTIWORKER.md). The historical single-worker acceptance
results below remain the baseline.

## Implementation progress after the audit

The opt-in `dinomo-kvs-numa` target now excludes the RDMA initialization sources,
uses target-specific NUMA definitions, and resolves the duplicate global
definitions described below. `conf/dinomo-numa.yml` supplies its configuration.
Initialization forks the manager before constructing ZeroMQ contexts; the
one-worker configuration is validated. The server has a signal-requested exit
path, a bounded routing-seed wait, private per-run pool ownership, and manager
cleanup with a bounded wait. `test_server_startup.py` exercises startup and
cleanup without offlining CPUs; `run_network_test.sh` owns optional CPU hotplug.

Metadata GET/PUT now use synchronous manager commands and a volatile
manager-local string-key store, like the original storage metadata store.
The NUMA compute methods bypass SEND and CQ polling for these commands.
Bounds checks limit the combined metadata key/value payload to 64 KiB.
Ordinary user records and the index remain in the selected shared pool.

The first integrated `DinomoKVStore` merged each write before acknowledgement.
The current server publishes each write, reads newest pending values, and
merges at a worker-controlled threshold or timer. Complete merge and compute
release still precede log reuse; normal shutdown drains pending writes.
See [DEFERRED_MERGE.md](DEFERRED_MERGE.md) for the validated current contract.
Missing results are checked before LWW deserialization.
The NUMA serializer stores exact binary LWW payloads without adding NUL
terminators. Empty-cache inserts release their copied values in this target.

The C++ `dinomo-numa-client-check` uses the existing `KvsClient` API and routing
discovery. It validates 256 inserts, two updates per key, immediate/later reads,
variable-length/binary values, missing keys, and metadata missing/PUT/GET/UPDATE.
It never issues merge commands or clears worker staging. Both the local node 0
control and remote node 1 memory-only test passed. The remote run verified all
20 pool-node logical CPUs offline and restored them on exit. Interruption
cleanup also passed: SIGTERM during startup removed the pool and restored CPU
state. Evidence:

- Local network: `results/server-startup-2_jmpy_5`.
- Remote memory-only network: `results/server-startup-9n624dqy`.
- Interrupted runner: `results/server-startup-4f8x20fj/INTERRUPTION_PASS`.
- Standalone regression: `results/milestone-Og9WU4qF`.

Those were pre-reclamation correctness results. On `numa-merge-gc`, the manager
now tracks index ownership and compute leases, with reuse only after an explicit
quiescent release. Local and remote memory-only stress tests passed beyond
16 MiB pool capacity while fresh log allocation remained at 34 blocks. The
reuse-disabled control exhausted PMDK as expected. See
[LOG_RECLAMATION.md](LOG_RECLAMATION.md) for the protocol and current evidence.
Continuous merge, multiworker synchronization, replication, recovery,
persistence, benchmark integration, and performance claims remain out of scope.

## Initial audit (historical findings before the implementation above)

## Target and initial restrictions

Run the existing client API against one network-facing KVS worker on node 0,
with a separate manager on node 0 and the shared pool on node 1. Routing and
any monitoring/client processes must also run on node 0. No VMs or Soft-RoCE
devices are required. First disable batching, value/shortcut caching,
elasticity, selective replication, and performance reporting. Set global memory
replication and local replication to one, with no storage-tier KVS workers.
The DPM pool is not a storage-tier KVS worker.

These restrictions must be validated at startup. Unsupported operations must
fail explicitly, rather than silently pretending to succeed.

## Startup and shutdown trace

1. `src/kvs/server.cpp:main` loads `conf/dinomo-config.yml`: worker counts,
   capacities (the code multiplies these by MiB), log settings, policies,
   replication, network settings, RDMA settings, and server addresses.
2. It calls `ib_init` before launching worker threads. A NUMA target needs a
   separate configuration/initialization path calling `dinomo_numa::start`.
   The backend forks its manager: this must happen before ZeroMQ contexts or
   other thread-producing libraries are initialized, not inside `run()`.
3. `run<DinomoECKVS>` constructs the ZeroMQ context and sockets, asks the routing
   seed for membership with a blocking join request, builds hash rings, and
   notifies routing and monitoring. Set `server.mgmt_ip` to the literal `NULL`
   to avoid the Kubernetes restart-count request. Bound the seed receive wait;
   the existing response-puller timeout does not bound that separate socket.
4. Worker construction creates `DinomoKVStore<EmptyCache>` and its LWW serializer.
   The underlying `Dinomo` constructor reads the shared root and initializes
   its mapping slot through the blocking transfer helpers. This part is covered
   by the compute milestone, though its test uses its own `NoCache` class.
5. The worker polls requests, membership/replication events, and timers in an
   unconditional `while (true)`. Periodic flush is not an index merge.
6. Normal finalization currently calls `ib_finalize` after worker execution,
   but the infinite loop provides no ordinary stop path. Add coordinated loop
   termination and call NUMA cleanup in normal execution context, not a signal
   handler. The runner must own pool-file deletion and CPU restoration.

Do not link the standalone backend into the existing server without resolving
symbol ownership: `VALUE_SIZE`, `SHORTCUT_SIZE`, `LOG_BLOCK_HEADER_LEN`,
`MAX_LOG_BLOCK_LEN`, `MAX_PREALLOC_NUM`, and `kLogCacheLen` are defined by both
`server.cpp` and `numa_backend.cpp`; `log_fp` is defined by both
`dinomo_compute.cpp` and `numa_backend.cpp`. Choose one definition per target.
The backend supplies `config_info` and `ib_res`, so it must also replace their
RDMA-side definitions. Keep the existing RDMA executable unchanged.

## Client request trace

`common/include/client/kvs_client.hpp` builds `KeyRequest`, resolves/caches a
worker address through routing, sends the request, and tracks its response.
The server dispatches the message to `user_request_handler.cpp`.

For ordinary user keys, responsibility is resolved through the hash rings and
replication map. With exactly one responsible worker:

| Request | Call chain after dispatch |
|---|---|
| PUT/INSERT | `process_put` -> `MemoryLWWSerializer::put` -> `DinomoKVStore::put` -> `Dinomo::put(..., false)` |
| UPDATE | `process_update` -> serializer `update` -> wrapper `update` -> `Dinomo::put(..., true)` |
| GET/READ | `process_get` -> serializer `get` -> wrapper `get` -> `Dinomo::get` |

The `process_*` adapters live in `src/kvs/utils.cpp`; the serializer is in
`include/kvs/server_utils.hpp`; the wrapper is in `include/kvs/base_kv_store.hpp`.
User key strings are converted with `stoul`; use known numeric keys for the
initial test. Values pass through LWW serialization, unlike raw milestone
values. Verify returned application values through the existing client API.

Metadata keys take an earlier branch in the request handler, invoking
`process_get_meta` / `process_put_meta` and then `Dinomo::getMeta` / `putMeta`.
These are string-key operations separate from the integer-key log path.
Routing's replication-factor resolution and monitoring's statistics requests
are reasons metadata traffic must be accounted for even in a simple workload.

## Transport/helper inventory

| Operation/helper | Current NUMA status | Network integration requirement |
|---|---|---|
| Backend initialization/finalization | `start` / `stop` exist | Replace `ib_init` / `ib_finalize`, define ownership and failure cleanup |
| Blocking profiled READ/WRITE | Checked offset translation + `memcpy` | Reuse for constructor, index lookup, and logs; retain bounds checks |
| `post_recv_profile` | Returns success without a receive | Valid only for paths fully replaced by synchronous IPC; not a general receive implementation |
| Log preallocation | NUMA branch calls synchronous `allocate_logs` | Reuse; validate batch size 1..64 before allocating arrays/using IPC |
| Explicit merge | NUMA branch calls `merge_logs` | Reuse after defining server-owned merge boundaries |
| Metadata GET/PUT | Calls unsupported SEND then completion handling | Add real manager metadata commands and NUMA compute branches, or prove a bounded restricted startup/workload cannot invoke them |
| Generic `post_send_imm_profile` | Throws | Keep rejecting requests that have no NUMA implementation |
| CQ polling / asynchronous completion | No NUMA completion mechanism | Supported paths must bypass verbs polling; do not fake completion success |
| Replicated GET/PUT/UPDATE; CAS/fetch-add paths | Not supported by the one-worker backend | Reject replication/multiworker configurations and related management transitions |
| Failover / indirect-pointer install/remove | RDMA SEND/completion paths | Explicitly reject until implemented |
| Delete | Manager merge accepts INSERT/UPDATE only | Exclude from initial client test and reject unsupported use |
| Flush/batching | Original memory-write code exists; unvalidated here | Disable batching initially; flush alone does not index records |
| Continuous merge and reclamation | Absent | Keep bounded test size; do not claim sustained-workload support |

The backend manager currently supports only Allocate, Merge, and Quit commands.
Its merge scans allocated logs synchronously and uses original CLHT functions;
it does not run `dinomo_storage.cpp`'s background maintenance implementation.

## Correctness gaps to resolve before network acceptance

### Visibility and repeated updates

`milestone.cpp` does inserts -> explicit merge -> reads -> updates -> explicit
merge -> reads. The NUMA `merge()` branch retires active staging after indexing.
The server does not currently invoke this boundary after every client write.

`check_from_staging_pool` scans forward and returns the first matching record.
Repeated same-key writes can therefore select an earlier staged value unless
publication/lookup behavior or server-owned merge boundaries prevent it. The
current test does not establish correctness for that interleaving. Either
establish a synchronous merge-before-ack policy for the first server target,
or implement latest-record staging semantics; test whichever contract is chosen.
Per-write merge is a correctness-first option, not a performance configuration.

### Missing-key serialization

The wrapper reports `KEY_DNE` for a zero-length backend result, but
`MemoryLWWSerializer::get` proceeds to construct a string from the returned
pointer and deserialize it. Handle the missing/error result before decoding;
do not rely on library-specific handling of a null pointer with zero length.
Apply the same reasoning to metadata and replicated adapters where relevant.

### Configuration and lifecycle

`conf/dinomo-local.yml` supplies useful loopback addresses, but lacks several
fields unconditionally read by the current server (including `kvs_config`,
`net_config`, RDMA settings and policy fields). It is not a ready-to-run NUMA
configuration. Create a dedicated complete host-native configuration and
launcher; do not reuse the five-VM IP settings. Inspect every component's
configuration reads and bind addresses before combining loopback services.

Add bounded launcher readiness/client waits, signal-driven server termination,
and cleanup for startup exceptions, IPC failure, and manager death. Current
backend IPC has 30-second socket timeouts, but `stop()` waits for the child
without a termination deadline. Do not assume a signal handler can safely
perform IPC or PMDK cleanup. Check placement after startup and workload;
placement verification samples 256 pages rather than every page in the pool.

## Ordered implementation and acceptance

1. Add a dedicated NUMA server build selecting the backend instead of RDMA
   sources; resolve duplicate globals, compile/link requirements, and unsupported
   template paths. Retain the standalone milestone and RDMA targets. The standalone
   Makefile uses C++17 while the top-level CMake defaults to C++11; account for
   language requirements explicitly for the new target.
2. Add complete NUMA configuration, one-worker validation, pre-thread manager
   initialization, and graceful/bounded teardown.
3. Implement metadata IPC and wire the required metadata paths, then bring up
   routing and any required monitoring with all processes on node 0.
4. Establish write visibility/merge policy and safe missing-key serialization.
5. Add an existing-client-API correctness runner with interleaved insert/read,
   repeated update/read, changing value lengths, missing keys, and rollover.
   The runner must not directly clear worker staging or manually merge phases
   to mask visibility problems.
6. Pass the same test for node 0 local storage and node 1 memory-only storage.
   Save commit ID, config, topology, placement results, client/server/manager
   logs, and successful resource/CPU cleanup. Include failure/interruption checks.

No performance claim is part of this acceptance target. The later opt-in
[concurrent milestone](CONCURRENT_MERGE.md) implements sealed-log manager merge,
protected index reads, and epoch-specific reclamation for one compute worker.
Multiworker ownership, durability, recovery, and actual CXL hardware evaluation
remain later milestones.
