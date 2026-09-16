# DINOMO on CloudLab — c6525-25g

Five KVM virtual machines on one CloudLab host, connected over Soft-RoCE (software RDMA
over a virtual Linux bridge). All scripts are run from your local machine and SSH into the
host, which then SSHes into VMs.

| VM | Process | Mgmt IP | RDMA IP |
|----|---------|---------|---------|
| dinomo-storage | dinomo-storage | 192.168.122.25 | 10.0.0.1 |
| dinomo-kvs | dinomo-kvs | 192.168.122.150 | 10.0.0.2 |
| dinomo-route | dinomo-route | 192.168.122.99 | — |
| dinomo-monitor | dinomo-monitor | 192.168.122.114 | — |
| dinomo-bench | dinomo-bench | 192.168.122.167 | — |

The benchmark guest uses `bench0` as its internal hostname because DINOMO derives
the benchmark node ID from the numeric suffix.

---

## Usage

**Fresh CloudLab node:**
```bash
vi vm-configs/c6525-25g/config.sh   # set CLOUDLAB_HOST
bash vm-configs/c6525-25g/setup_vms.sh   # ~20 min, run once
bash vm-configs/c6525-25g/start.sh
bash vm-configs/c6525-25g/test.sh
```

**Subsequent runs (VMs already exist):**
```bash
bash vm-configs/c6525-25g/start.sh
bash vm-configs/c6525-25g/test.sh
```

---

## `config.sh`

The only file you need to edit. All scripts source it.

| Variable | Change when? | Notes |
|----------|-------------|-------|
| `CLOUDLAB_HOST` | Every new experiment | Hostname from the CloudLab experiment page |
| `SSH_USER` | Your account differs | CloudLab username — case sensitive |
| `SSH_KEY` | Your key path differs | Must match the key registered on CloudLab |
| `NODE_TYPE` | Different hardware | Only `c6525-25g` supported currently |
| `VM_*` IPs | Never | Fixed to the private virtual networks we create |
| `DINOMO_REPO` | When you have a fork | URL cloned by `setup_vms.sh` on fresh nodes |
| `DINOMO_BRANCH` | When using a non-default branch | Branch checked out and updated by `setup_vms.sh` |
| `HOST_DATA_DEVICE` | Different disk layout | Empty secondary disk used for VM images; `/dev/sdb` on a fresh c6525-25g node |
| `BENCH_NUM_KEYS` | Tuning | How many keys to LOAD and operate on |
| `BENCH_DURATION` | Tuning | Seconds per RUN workload |
| `BENCH_OUTSTANDING` | Tuning | In-flight requests — higher = more throughput up to a point |
| `BENCH_REPORT_PERIOD` | Tuning | Seconds between epoch output lines |

**Node-type-specific (set automatically from `NODE_TYPE`):**

- `VM_RDMA_IFACE="enp2s0"` — the NIC inside storage/kvs VMs connected to the RDMA bridge. Soft-RoCE attaches to this. Name is deterministic from the PCI slot of the second virtio NIC.
- `HOST_DATA_DIR="/mnt/data"` — where VM disk images live. Must be on the large secondary disk, not the root filesystem.

---

## Scripts

### `setup_vms.sh` — run once on a fresh node

Four phases, ~20 minutes total:

1. **Host prep** — safely formats the empty `HOST_DATA_DEVICE` when needed, mounts it at `/mnt/data`, installs KVM/libvirt/rdma-core, creates the `br-rdma` Linux bridge at `10.0.0.0/24`, and registers it as a libvirt network so VMs can attach to it.
2. **Disk images** — downloads Ubuntu 20.04 cloud image (~600 MB), creates five 20 GB qcow2 overlay disks backed by it (copy-on-write, start near-empty).
3. **VM creation** — `virt-install` + cloud-init: sets hostname, injects SSH key, configures static IPs, installs packages. Storage and kvs get two NICs (management + RDMA bridge); others get one. Waits for cloud-init to finish on each VM.
4. **Build** — clones the configured repository branch on all five VMs in parallel, removes `-mavx2` from CMakeLists.txt, verifies the PMDK TLS crash fix, builds using each VM's CPU count, and deploys the VM configuration as `conf/dinomo-config.yml`.

Idempotent — re-running skips steps already done.

---

### `start.sh` — start all components

1. Kills leftover processes on all VMs, deletes `/dev/shm/pool`.
2. Loads `rdma_rxe` on storage and kvs VMs, attaches `rxe0` to `VM_RDMA_IFACE`. **Not persistent across VM reboots — must run every time.**
3. Starts `dinomo-storage`, polls `/tmp/dinomo-storage.log` for `"start to listen"` before proceeding. This line means storage has opened its TCP socket for the Queue Pair handshake — kvs must not connect before this appears.
4. Starts `dinomo-kvs`, waits 3 seconds for it to initiate the RDMA connection.
5. Starts route, monitor, bench in parallel.
6. Polls `/tmp/dinomo-kvs.log` for `"raddr_pool="` — this line is printed by each of the four kvs worker threads after completing the RDMA handshake. Four lines = all threads ready.

---

### `stop.sh` — kill everything

`pkill -9` all `dinomo-*` processes on all VMs and deletes `/dev/shm/pool`.

---

### `test.sh` — benchmark test suite

Requires DINOMO already running. Runs in sequence:

1. **LOAD** — inserts `BENCH_NUM_KEYS` keys. Waits for `"Loading data took"` in `log_0.txt`.
2. **WRITE** — `RUN:0:...` (100% writes, UPDATE mode, `BENCH_DURATION` seconds).
3. **READ** — `RUN:100:...` (100% reads).
4. **MIXED** — `RUN:50:...` (50% reads, 50% writes).

Each run snapshots the bench log line count first and reads only new lines for results, so outputs from different runs don't overlap.

Results appear in `~/projects/DINOMO/log_0.txt` on the bench VM.

> **Trigger workaround:** `dinomo-bench-trigger` loops after stdin closes and can
> send empty commands. The scripts keep stdin open long enough to deliver the
> requested command, then stop only the trigger helper; `dinomo-bench` continues
> running independently.

### `run_ycsb.sh` — reset-isolated YCSB-style suite

Runs the workload mixes supported by DINOMO's native benchmark command:

- **A** — 50% reads, 50% updates
- **B** — 95% reads, 5% updates
- **C** — 100% reads

Before every workload and repetition, the script runs `start.sh` to recreate the
PMDK pool and processes, then loads a fresh keyspace. Results and component logs
are saved under `results/ycsb/<UTC timestamp>/`, with aggregate metrics in
`summary.csv`. D–F are omitted because the native harness does not implement the
required insert-latest, scan, and read-modify-write operations.

```bash
# One run each of A, B, and C with settings from config.sh
bash vm-configs/c6525-25g/run_ycsb.sh

# Three 60-second repetitions of A and C
YCSB_REPETITIONS=3 YCSB_DURATION=60 \
  bash vm-configs/c6525-25g/run_ycsb.sh A C
```

Optional environment overrides are `YCSB_NUM_KEYS`, `YCSB_VALUE_SIZE`,
`YCSB_DURATION`, `YCSB_REPORT_PERIOD`, `YCSB_OUTSTANDING`, `YCSB_ZIPF`,
`YCSB_REPETITIONS`, `YCSB_LOAD_TIMEOUT`, `YCSB_RUN_TIMEOUT`, and
`YCSB_RESULTS_ROOT`. The default `YCSB_ZIPF=0` selects the uniform distribution
used by the tested setup.

---

### `run_trace.sh` — dynamic workload

Loads keys once, then changes read/update mix and popular keys over CSV phases
while DINOMO retains its cache state. The example runs for 240 seconds over one
million keys. Rebuild and deploy the benchmark with TRACE support first; see
[TRACE.md](TRACE.md) for build instructions, CSV format, and results.

```bash
bash vm-configs/c6525-25g/run_trace.sh --check
bash vm-configs/c6525-25g/run_trace.sh
```

Each repetition calls `start.sh` and recreates the PMDK pool. Local tests:
`bash vm-configs/c6525-25g/test_trace.sh`.

---

### `07_trigger_bench.sh` — single workload

```bash
bash vm-configs/c6525-25g/07_trigger_bench.sh [LOAD|WRITE|READ|MIXED]
```

Sends one command to `dinomo-bench-trigger`. Use for manual runs. Results go to `log_0.txt` on the bench VM.

---

### `00_cleanup.sh` / `01_setup_rdma.sh` through `06_run_bench.sh`

Lower-level scripts that `start.sh` wraps. Run individually to restart one component without the full sequence. **Ordering matters:** storage must be ready before kvs, and Soft-RoCE must be set up before either.

### `check_logs.sh`

Tails the last 5 lines of every process log across all VMs.

---

## Troubleshooting

**kvs stuck at STEP3** — routing node unreachable. Check `dinomo-route` is running and that `seed_ip` in `conf/dinomo-vm-config.yml` is `192.168.122.99` (route VM), not storage.

**`raddr_pool=` count stays below 4** — one or more kvs threads failed the RDMA handshake. Check `/tmp/dinomo-kvs.log` for RTR errors. Verify `rdma link show` shows `rxe0 state ACTIVE` on both VMs.

**Storage crashes ~40s in** — PMDK TLS fix not applied. Check `/tmp/dinomo-storage.log` for `"Pre-allocated 32 spare log blocks"`. If missing, re-run `setup_vms.sh`.

**`IBV_WC_REM_ACCESS_ERR` after storage restart** — `remote_start_addr` is stale. Confirm `raddr_pool=` and `remote_start_addr=` match in `/tmp/dinomo-kvs.log`. This should not happen if the `clht_lb_res.c` fix is applied.

**bench-trigger segfaults immediately** — stdin closed before ZMQ delivered the message. Always use the `(echo 'CMD'; sleep N) | bench-trigger` pattern for manual invocations.
