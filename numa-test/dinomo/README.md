# DINOMO NUMA milestone: one compute worker and a memory-only pool

Run from this directory:

~~~bash
make -j4
./run_milestone.sh
~~~

The runner temporarily offlines all CPUs on node 1, checks that its online CPU
list is empty, and runs a compute worker plus a storage manager on CPU 2 of
node 0. Both processes map a private 256 MiB PMDK pool backed by tmpfs.
The manager binds allocation to node 1 before creating/prefaulting the pool.
All 256 sampled pool pages must be on node 1 before and after the test.
CPU offlining requires sudo; the DINOMO processes run as the invoking user.
CPUs changed by the run are restored on exit or interruption.

The test invokes the existing Dinomo template in
include/kvs/dinomo_compute.hpp and the existing P-CLHT implementation.
It verifies 1,000 inserts, post-merge reads, updates with a different value
length, post-merge updated reads, a missing key, log rollover, and repeated
allocation batches. Caches are disabled and each successful post-merge GET
must increment the shared-pool read count.

Evidence is saved under results/milestone-XXXXXXXX/:

- topology.txt records CPU state, host CPU, pool node, and key count.
- test.log records mapping addresses, placement checks, transfer counts,
  allocation counts, and the final PASS or failure.

The temporary PMDK pool is deleted after the test. It is a volatile correctness
experiment; it provides no restart/recovery or power-loss durability guarantee.
The existing RDMA pool at /dev/shm/pool is not used.

## Dependencies

Ubuntu packages:

~~~bash
sudo apt-get install build-essential libpmemobj-dev libibverbs-dev libtbb-dev
~~~

Verbs headers/library are required because the existing DINOMO source includes
verbs types and inactive code paths. The milestone does not open an RDMA
device, register memory, create queue pairs, or post verbs operations.

## Local-memory control and debugging

Run the same backend with a node 0 pool, leaving CPUs online:

~~~bash
MEMORY_NODE=0 ./run_milestone.sh --no-offline
~~~

Run a remote pool with all CPUs still online:

~~~bash
./run_milestone.sh --no-offline
~~~

Change the host CPU and workload size:

~~~bash
HOST_CPU=4 NUM_KEYS=5000 ./run_milestone.sh
~~~

The supported key-count range is 1 through 10,000. The default 4 KiB log blocks
and allocation batches of two blocks intentionally force rollover at a small
test size; these are test settings rather than performance settings.

## Implementation boundary

The standalone Makefile defines DINOMO_NUMA_MILESTONE. Existing Soft-RoCE build
targets do not define it.

- numa_backend.cpp is linked instead of ib.cpp. Blocking read/write helpers
  translate storage addresses into checked offsets in the compute mapping and
  copy bytes directly. Pool references keep the existing DINOMO format.
- Allocation and explicit merge use synchronous Unix-domain IPC. PMDK allocation
  and CLHT index updates execute in the storage manager on node 0.
- The manager processes committed insert/update log records using the original
  clht_put/clht_update. It does not run the original background merge/GC loop.
- A NUMA-only post-merge cleanup retires active local staging so reads exercise
  the shared index and updates begin a new log.
- Different virtual addresses are supported by converting a storage address to
  an offset before accessing the shared mapping.

This milestone directly tests DINOMO's compute API. It does not yet start the
network KVS server, routing, monitoring, or benchmark client. It supports one
worker with explicit merge boundaries, insert/update/get, and synchronous
allocation. Replication, failure handling, metadata operations, background GC,
multiworker synchronization, and asynchronous completion paths need subsequent
integration. Unsupported SEND paths fail explicitly.

## Milestone 1: completed and validated

The first functional milestone is complete at the compute-API level. It uses
the existing DINOMO implementation rather than a replacement key-value store.

| Component | Implemented behavior |
|---|---|
| Compute | One existing Dinomo instance, caches disabled, running on node 0 |
| Storage manager | Separate process on node 0; owns PMDK allocation and explicit merge requests |
| Pool | Private shared tmpfs-backed PMDK mapping allocated on the selected memory node |
| Transfers | Blocking reads/writes copy through checked pool offsets; no RDMA device operations |
| Index | Original P-CLHT lookup, insertion, and update implementation |
| Control requests | Synchronous Unix-domain socket requests for allocation and merge |
| Placement | 256 sampled pages checked before and after the operation test |
| Lifecycle | Per-run pool creation/removal and restoration of CPUs changed by the runner |

On the original c6420 host, the validated remote configuration used CPU 2 on
node 0, all 32 logical CPUs on node 1 offline, and a 256 MiB pool on node 1.
The 1,000-key test passed insert/read/update/read and missing-key checks,
allocated 48 log blocks across repeated allocation requests, and verified
256/256 sampled pages on node 1. Compute and storage mapped the pool at
different virtual addresses. A node 0 pool control also passed.

These are correctness results. The tiny log blocks, disabled caches, explicit
merges, and synchronous IPC are not yet a configuration for performance claims.

## Resume on a fresh CloudLab machine

Clone the pushed branch and install the standalone milestone dependencies:

~~~bash
git clone --branch cloudlab-softroce https://github.com/Uriel-Segev/dinomo-cxl.git
cd dinomo-cxl
git log -1 --oneline
sudo apt-get update
sudo apt-get install -y build-essential libpmemobj-dev libibverbs-dev libtbb-dev
lscpu
bash numa-test/numa_cpu_control.sh status
df -h /dev/shm
cd numa-test/dinomo
make -j4
~~~

Select a host CPU that actually belongs to the chosen host node. The defaults
assume CPU 2 belongs to node 0 and node 1 is the pool node. NUMA CPU numbering
can differ on another server. The CPU-control script protects the node
containing CPU 0, so use another node as the memory-only pool.

The runner requires at least 256 MiB of free tmpfs capacity plus overhead. It
does not require KVM, VMs, a virtual bridge, or a Soft-RoCE device.

Reproduce these configurations in order, substituting appropriate node and CPU
IDs if necessary:

~~~bash
# Local pool control; all CPUs remain online.
HOST_CPU=2 HOST_NODE=0 MEMORY_NODE=0 ./run_milestone.sh --no-offline

# Remote pool control; all CPUs remain online.
HOST_CPU=2 HOST_NODE=0 MEMORY_NODE=1 ./run_milestone.sh --no-offline

# Target configuration: remote pool with its CPUs offline during the test.
HOST_CPU=2 HOST_NODE=0 MEMORY_NODE=1 ./run_milestone.sh

# Confirm CPU restoration afterward.
../numa_cpu_control.sh status
~~~

For each run, open the printed evidence directory and inspect topology.txt and
test.log. Require a final PASS, correct page placement, and, for the target
configuration, no online CPUs on the pool node in topology.txt. Preserve the
commit ID alongside the evidence. The runner removes its temporary pool and
restores CPUs after the run; the memory-only configuration is temporary.

If a previous run was interrupted and a saved CPU state remains, recover before
starting another experiment:

~~~bash
sudo ../numa_cpu_control.sh restore
../numa_cpu_control.sh status
~~~

Compiled binaries, installed packages, and ignored results directories are not
transferred by cloning. Copy results off the old machine if they are needed.
The five-VM configuration in vm-configs/c6525-25g/config.sh is separate and
contains host-specific SSH settings; it is not used by run_milestone.sh.

## Next milestone: requests through the network KVS server

The next acceptance target is one network-facing KVS worker serving an existing
DINOMO client, with storage management on node 0 and the shared pool on node 1.
Keep explicit merge boundaries and one worker until this path is correct.
The following steps are planned work, not capabilities of the current runner.

### 1. Audit startup and the complete request path

Trace server startup, one insert, one GET, one UPDATE, and the control requests
needed to join the cluster. Record every required transport operation before
wiring in the NUMA backend.

| File, relative to repository root | Work to inspect |
|---|---|
| src/kvs/server.cpp | ib_init startup, worker construction, and ib_finalize shutdown |
| src/kvs/user_request_handler.cpp | Client request dispatch and response handling |
| include/kvs/dinomo_compute.hpp | Data operations, allocation, merge, and metadata operations |
| src/kvs/numa_backend.cpp | Current pool mapping, address translation, manager IPC, and lifecycle |
| src/kvs/dinomo_storage.cpp | Original management requests, merge processing, and GC responsibilities |
| src/kvs/dpm.cpp | Original standalone storage startup |
| src/kvs/CMakeLists.txt | Server/storage sources and dependencies |
| conf/dinomo-local.yml | Existing configuration to assess for a host-native setup |

The current backend throws on unsupported SEND paths. Routing/monitoring
startup may invoke metadata operations even when the user workload only uses
GET/UPDATE. Implement or explicitly account for those required paths; do not
convert unsupported requests into successful no-ops.

Acceptance: a documented list of startup and request-path dependencies, with
each required helper classified as implemented or needing a NUMA equivalent.

### 2. Add explicit server backend selection and initialization

Add a dedicated NUMA server build/configuration that selects the shared-memory
implementation instead of linking ib.cpp. Retain the existing RDMA target.
Configure host CPU/node, pool node, pool size, and a private pool path without
hard-coding the previous CloudLab host or VM IP addresses.

The current start() function forks the manager. Call it before launching
threads, or change the manager to a separately launched process with an attach
protocol. Do not simply fork it from inside an already multithreaded server.
Replace the RDMA-only initialization and finalization paths for this target.
Give startup failures and normal shutdown a clear manager/pool cleanup path.

Acceptance: the NUMA server initializes without an RDMA device, starts exactly
one KVS worker, and shuts down without leaving a manager or temporary pool.

### 3. Bring up routing, monitoring, and a client on node 0

Create a separate host-native configuration and launcher for the NUMA setup.
Pin every component and any background helper to host-node CPUs. Keep ordinary
process buffers/caches local to node 0 and only shared storage structures in
the node 1 pool. Verify pool placement after startup and under workload.

Start only the components the audited request path requires. Use the existing
client API to insert a known key, read it, update it, and read the changed
value. Add bounded waits so a missing reply reports a failure rather than
hanging indefinitely.

Acceptance: a client outside the KVS process receives the expected values and
missing-key behavior while the pool node has no online CPUs.

### 4. Make log publication and merge behavior work across client requests

The current test calls merge explicitly between insert and read phases. Define
how the network server triggers merge and when an acknowledged update becomes
visible to a later GET. Test reads before and after merge, repeated updates to
the same key, variable value lengths, and allocation/log rollover.

Audit local staging lookups as well as shared-index lookups: a cache or staging
hit must not return an older value after an update. Preserve write-before-
publication ordering and request/response synchronization. Continue to reject
unsupported replication or asynchronous paths explicitly.

Acceptance: correctness holds for interleaved client requests, without the
test harness manually clearing staging or hiding stale values with phase order.

### 5. Save a repeatable network-level correctness test

Add a runner that builds the NUMA server target, starts its local components,
offlines the pool-node CPUs, checks placement, sends client operations, and
cleans up. Save topology, configuration, commit ID, and logs for each run.
Repeat with both a local pool and a remote memory-only pool.

Acceptance: a single command passes the same client-visible checks in both
placements and restores the machine on success, failure, or interruption.

## Later milestones, after network correctness

1. Add multiple workers with per-worker staging and IPC ownership. Define CPU
   atomic access, publication ordering, allocator ownership, and reclamation
   rules before allowing concurrent access to shared metadata. Stress repeated
   updates to the same keys and hash-bucket collisions.
2. Implement continuous merge and safe reclamation. The current manager merges
   on request and never reclaims allocated logs; sustained runs would exhaust
   the pool. Demonstrate a workload larger than available log capacity without
   stale reads or use-after-free.
3. Integrate the existing benchmark client and report actual end-to-end GET
   and UPDATE throughput plus median/p99 latency. The current run_dinomo_test.sh
   still invokes the five-VM harness and must be adapted to select the new
   host-native deployment before it can measure the NUMA server.
4. Compare Soft-RoCE, a local shared pool, and a remote shared pool using matched
   worker counts, cache settings, datasets, request mixes, and client placement.
   Record cache hits and bytes/operations reaching the pool so cache behavior
   does not conceal transport differences. Do not interpret microbenchmark
   ns/op as client GET/UPDATE latency.
5. Address replication, failure recovery, and persistence as separate features.
   The current tmpfs pool is volatile, and remote NUMA access alone does not
   establish actual CXL timing or persistent-memory durability semantics.
