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

The next step is integrating this backend's initialization and lifecycle into
dinomo-kvs and the storage manager, then exercising the same operations through
the existing network client.
