# Running the DINOMO YCSB-style suite

Run from the repository root after provisioning the VMs and checking `config.sh`:

```bash
YCSB_NUM_KEYS=1000 YCSB_DURATION=10 bash vm-configs/c6525-25g/run_ycsb.sh C
YCSB_REPETITIONS=3 YCSB_DURATION=60 YCSB_LOAD_TIMEOUT=300 bash vm-configs/c6525-25g/run_ycsb.sh A B C
```

Every repetition restarts the cluster and deletes the storage pool. Do not run
multiple suites against the same cluster simultaneously. No separate start step
is required. The script changes are local and work with the existing benchmark
fraction-based RUN protocol; no VM rebuild is needed for these uniform runs.

A is 50% reads / 50% updates, B is 95% reads / 5% updates, and C is reads only.
Only benchmark thread 0 is triggered. Defaults are 100,000 keys, 64-byte values,
64 outstanding requests, 30 seconds, and 5-second reports. YCSB_ZIPF must be 0;
the source allocation fix in benchmark.cpp is not automatically deployed to VMs.

Results are copied to `results/ycsb/<run-id>/` on the machine running the script:

- `parameters.txt`: requested parameters and local checkout commit.
- `summary.csv`: one row per completed or failed repetition.
- `workload-*/run-*/command.txt`: exact RUN command.
- `load.log`, `benchmark.log`, `start.log`: phase logs.
- `rdma.csv`: per-thread, per-report-interval RDMA operation and byte counters.
- `cache.csv`: per-thread, per-report-interval cache size, hit, and miss counters.
- `system/host-sar.txt`: one-second host memory and interface statistics during RUN.
- `system/host-{before,after}.txt`: host memory, interface, and RDMA snapshots.
- `system/kvs-{before,after}.txt`: KVS VM memory, interface, and RDMA snapshots.
- `kvs-workload.log`: KVS log records written during the RUN window.
- `logs/` or `failure-logs/`: captured VM logs (best effort).

```bash
column -s, -t results/ycsb/<run-id>/summary.csv
tar -czf ycsb-results.tar.gz -C results/ycsb <run-id>
```

PASS means LOAD and RUN completion were observed and nonzero throughput plus
latency metrics were parsed. It does not prove returned-value correctness or
recovery. Latencies are means of epoch percentiles, not whole-run percentiles;
throughput is an unweighted mean of reported epochs. There is no separate warmup.
The recorded commit describes the local checkout, not necessarily deployed VM
binaries. These are single-client Soft-RoCE VM measurements.

The RDMA columns in `summary.csv` sum the intervals present in `rdma.csv`.
Because KVS counters reset on the server reporting interval, the first captured
interval can contain operations from the end of LOAD, and a final partial
interval may not be published before RUN finishes. Use `rdma.csv` when examining
interval timing. The KVS binary must be rebuilt and deployed after adding these
counters.

The cache totals in `summary.csv` sum the intervals present in `cache.csv`.
`cache_hit_ratio` is the sum of value-cache, shortcut-cache, and local-log hits
divided by those hits plus cache misses. Cache counters have the same reporting
window caveat as RDMA counters. System collection is best effort, so a missing
telemetry command does not fail the database workload.
