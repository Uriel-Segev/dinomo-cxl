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

## Milestone 2: one network KVS worker with a NUMA pool

The `dinomo-kvs-numa` target now serves the existing C++ `KvsClient` API
through DINOMO's request handler, LWW serializer, wrapper, and compute engine.
A host-native routing process provides membership discovery. Monitoring is
not required for this bounded test with reporting and policies disabled.
No VMs, Soft-RoCE device, or RDMA device operations are used.

The server runs one uncached, unbatched worker and a separate manager on the
selected host CPU. Both access the private tmpfs-backed PMDK pool placed on the
selected memory node. The existing RDMA target and standalone milestone remain
available.

### Build and dependencies

In addition to the standalone milestone dependencies, the full server/client
build needs CMake, Protobuf/compiler, jemalloc, Boost system/thread, and
ZeroMQ/cppzmq, spdlog, and yaml-cpp. CMake downloads pinned vendor sources, so
the first build requires network access.

~~~bash
cd ~/dinomo-cxl
make -C src/kvs/libbloom -j4
cmake -S . -B build/numa -DCMAKE_BUILD_TYPE=Release -DBUILD_NUMA_SERVER=ON
cmake --build build/numa --target dinomo-kvs-numa dinomo-numa-client-check dinomo-route -j4
~~~

### Run network correctness

The runner builds the targets, creates isolated configuration and logs, starts
routing/server/client on the host CPU, checks results and placement, and
removes its manager and temporary pool. By default it offlines the pool-node
CPUs and restores those it changed on exit, failure, or interruption.

~~~bash
cd ~/dinomo-cxl

# Local control: node 0 pool, all CPUs online.
MEMORY_NODE=0 ./numa-test/dinomo/run_network_test.sh --no-offline

# Target: node 1 pool, node 1 CPUs offline during the test.
./numa-test/dinomo/run_network_test.sh

# Confirm CPU restoration.
./numa-test/numa_cpu_control.sh status
~~~

Defaults are `HOST_CPU=2 HOST_NODE=0 MEMORY_NODE=1 NUM_KEYS=256`.
Adjust them to the machine's topology; `NUM_KEYS` supports 1..2000.
Use `--no-offline` for a remote pool with its CPUs online.
Run the script as the ordinary user; sudo is used for CPU hotplug.
SIGKILL or power loss cannot run cleanup traps; use the existing CPU restore
command if necessary.

The C++ client checks:
- Missing user and metadata keys.
- Metadata PUT, GET, and UPDATE, including binary values.
- Insert/read, update/read, and another update/read for every user key.
- Changing value lengths and embedded NUL bytes.
- Later reads of all keys after repeated allocation/merge cycles.

The client never sends merge commands or clears worker staging. The server
owns the visibility boundary. Startup tests also reject a multiworker
configuration and check missing-router failure, SIGTERM exit, manager reaping,
and private-pool removal. Evidence is saved under `results/server-startup-*`:
configuration, topology, commit ID/working-tree status, and client/server/router
logs. The final server log includes transfer, allocation, and metadata counters.

For startup/lifecycle checks without the client or CPU hotplug:

~~~bash
python3 numa-test/dinomo/test_server_startup.py --host-cpu 2 --memory-node 1
~~~

### Visibility and metadata contract

For this target, each user PUT/UPDATE writes a log record and synchronously
merges it into the original P-CLHT index before returning to the request
handler for acknowledgement. The NUMA merge retires local staging and clears
caches, so a following GET uses the shared index and sees the acknowledged
value. This avoids relying on the old staging scan's first-match behavior.
There is no background merge or concurrent worker access.

Metadata GET/PUT use bounded synchronous Unix-domain IPC to a volatile
string-key store in manager-local memory, like the original storage metadata
store. User records and the index reside in the selected shared pool.
Metadata keys plus values must fit the 64 KiB IPC payload. User values, including
their serialized LWW envelope, must fit one log block after its record header
(the configuration uses 4 KiB total log blocks). Oversized requests fail
explicitly. Missing results are handled before LWW deserialization.

Merge-before-ack retires a log for every write and the current allocator
requests fresh batches, so space use is intentionally inefficient. Logs are
not reclaimed. This is a bounded correctness configuration, not a sustained
workload or performance configuration. The standalone milestone still tests
capacity-driven log rollover separately.

### Validation on c8220

The 256-key network test passed for:
- A local node 0 pool with all CPUs online:
  `results/server-startup-2_jmpy_5`.
- A remote node 1 pool with all 20 node 1 logical CPUs offline:
  `results/server-startup-9n624dqy`.

Both runs verified 256/256 sampled pool pages on the requested node at startup
and shutdown. Each recorded 5,895 shared reads, 3,073 shared writes, 1,536
allocated log blocks, four metadata GETs, and two metadata PUTs.
The remote runner restored CPUs afterward. The standalone 1,000-key local
milestone also passed after the IPC changes. These ignored evidence directories
are machine-local and are not transferred by cloning.
SIGTERM interruption during remote startup also passed pool removal and CPU
restoration checks; evidence is in
`results/server-startup-4f8x20fj/INTERRUPTION_PASS`.

The initial source audit and implementation notes are in
[NETWORK_INTEGRATION_AUDIT.md](NETWORK_INTEGRATION_AUDIT.md).

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
