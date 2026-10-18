# NUMA memory-pool latency experiment

For the first functional DINOMO shared-memory implementation, see
[dinomo/README.md](dinomo/README.md). Its runner tests the existing DINOMO
compute methods and PMDK CLHT against a node 1 pool with node 1 CPUs offline.

This experiment models the planned single-server DINOMO layout:

- Linux NUMA node 0 is the compute/host node. Its CPUs stay online.
- Linux NUMA node 1 is the disaggregated memory pool. Its CPUs are hot-unplugged,
  but its memory stays online.
- A dependent pointer-chase runs on one node 0 CPU against memory allocated on
  node 0 (local) and node 1 (remote). Dependency between loads prevents memory
  parallelism from hiding access latency.

On dinomo-c6420, node 0 contains the even-numbered logical CPUs and node 1
contains the odd-numbered logical CPUs. Each node has approximately 190 GiB of
memory. Linux uses zero-based node names, so these correspond to the first and
second physical NUMA nodes.

## Run the complete experiment

~~~bash
cd ~/dinomo-cxl/numa-test
make
./numa_cpu_control.sh status
./run_experiment.sh
~~~

The runner measures both placements with all CPUs online, offlines node 1's
CPUs, repeats the measurements, and restores those CPUs on normal exit or an
interrupt. It uses sudo only for CPU hotplug operations. CSV data and a short
summary are written under results/.

Defaults can be overridden without editing scripts:

~~~bash
SIZE_MB=512 PASSES=5 REPETITIONS=7 HOST_CPU=2 ./run_experiment.sh
~~~

The working set should be larger than the 22 MiB last-level cache local to a
socket. The default 256 MiB is sufficient on this machine. Transparent huge
pages are disabled for the mapping so repeated runs use the same 4 KiB page
policy.

To leave node 1 as a memory-only node after measuring:

~~~bash
./run_experiment.sh --keep-offline
~~~

Restore it later with:

~~~bash
sudo ./numa_cpu_control.sh restore
~~~

A reboot also brings hot-unplugged CPUs back online. If the runner is killed
with SIGKILL or the machine loses power, its exit trap cannot run; use the
restore command after reconnecting.

## Read the result

The summary reports mean nanoseconds per dependent load and the remote/local
ratio. For example, remote/local=1.45x means accessing node 1 memory from the
node 0 CPU took 45 percent longer than accessing node 0 memory.

List the result files with the newest first:

~~~bash
ls -lt results/
~~~

Display the newest raw CSV as a clean table:

~~~bash
./show_results.sh
~~~

Display a particular run:

~~~bash
./show_results.sh results/latency-20261018T042042Z.csv
~~~

The table shows every repetition, followed by aggregate local and remote
latencies, their ranges, the remote/local ratio, and the percentage of extra
latency for remote memory. The PLACEMENT column should show 256/256, confirming
that every sampled page was on the requested memory node.

To inspect the original CSV directly, use less with horizontal scrolling and
press q when finished:

~~~bash
less -S results/latency-20261018T042042Z.csv
~~~

The C benchmark calls the Linux mbind syscall before touching its mapping and
samples pages with move_pages to verify they landed on the requested node. It
does not require numactl or libnuma.

CPU hotplug is separate from memory placement. Offlining node 1's CPUs should
not itself make remote access faster; it creates the desired memory-only pool.
The local-versus-remote rows quantify the NUMA latency that a shared-memory
DINOMO transport would see.

## Additional memory tests

The extended tests turn node 1 into a memory-only node, compare local node 0
memory with remote node 1 memory, and restore node 1's CPUs afterward. Run each
test separately:

~~~bash
./run_memory_test.sh read-bandwidth
./run_memory_test.sh write-bandwidth
./run_memory_test.sh concurrent-read
./run_memory_test.sh atomic
./run_memory_test.sh mixed
~~~

The tests measure:

| Test | Measurement |
|---|---|
| read-bandwidth | Single-worker sequential read bandwidth |
| write-bandwidth | Single-worker sequential write bandwidth |
| concurrent-read | Aggregate random-read performance from multiple node 0 CPU cores |
| atomic | Random sequentially consistent 64-bit atomic fetch-add operations |
| mixed | Concurrent workload containing 60% reads, 30% writes, and 10% atomic operations |

Run all five memory tests together:

~~~bash
./run_memory_test.sh all
~~~

Display the newest extended result in a table:

~~~bash
./show_memory_results.sh
~~~

Or select a particular result:

~~~bash
./show_memory_results.sh results/memory-suite-all-TIMESTAMP.csv
~~~

The bandwidth rows are compared using GiB/s; higher is better. Concurrent,
atomic, and mixed rows are compared using average nanoseconds per operation;
lower is better. The logical_gib_s field counts eight useful bytes per
operation and does not include cache-coherence or memory-controller traffic.

Defaults can be changed through environment variables:

~~~bash
SIZE_MB=512 DURATION=5 REPETITIONS=5 THREADS=8 \
  ./run_memory_test.sh all
~~~

THREADS controls concurrent-read and mixed tests. Atomic operations use one
thread by default so the result is interpretable as operation cost. Use
ATOMIC_THREADS=8 to measure concurrent atomic throughput and contention.

## DINOMO operation latency

DINOMO's native benchmark already measures throughput plus average, minimum,
maximum, median, and p99 GET/UPDATE latency. With the configured DINOMO
deployment running, execute:

~~~bash
./run_dinomo_test.sh
~~~

This performs LOAD followed by write-only, read-only, and 50/50 mixed
workloads. It saves both the raw log and a parsed CSV under results/.
Currently it tests whichever transport is selected by the DINOMO deployment in
vm-configs/c6525-25g/config.sh. After DINOMO is changed to use the NUMA memory
pool, the same test will report the new end-to-end operation latency.

Run the original latency experiment and every extended memory test in sequence:

~~~bash
./run_all_tests.sh
~~~

Include the end-to-end DINOMO test when DINOMO is already running:

~~~bash
./run_all_tests.sh --include-dinomo
~~~
