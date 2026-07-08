# DINOMO Project Handoff

## 1. What This Is

DINOMO is a distributed key-value store that uses RDMA to allow kvs nodes to write directly into a storage node's persistent memory pool without involving the storage CPU on the data path. The original codebase targets Kubernetes with Docker containers. We stripped that away and run the raw binaries directly on CloudLab hardware.

---

## 2. Current Status

### c6525-25g (single CloudLab host, 5 KVM VMs, Soft-RoCE)

- **Host**: one c6525-25g node on Utah CloudLab (AMD EPYC, set `CLOUDLAB_HOST` in config.sh)
- **VMs**: 5 KVM VMs on one host connected over Soft-RoCE (software RDMA over a virtual Linux bridge)
- **Scripts**: `vm-configs/c6525-25g/` — see `README.md` there for full usage
- **Status**: fully working end-to-end (LOAD + RUN benchmarks run cleanly)

Quick start (VMs already exist):
```bash
bash vm-configs/c6525-25g/start.sh
bash vm-configs/c6525-25g/test.sh
```

Fresh node (run once, ~20 min):
```bash
vi vm-configs/c6525-25g/config.sh   # set CLOUDLAB_HOST
bash vm-configs/c6525-25g/setup_vms.sh
bash vm-configs/c6525-25g/start.sh
bash vm-configs/c6525-25g/test.sh
```

Benchmark results (write-only UPDATE, 100K keys, 64 outstanding, 30s):
- Peak throughput: ~18,800 ops/sec
- Median latency: ~4–5 ms (Soft-RoCE is ~4–5× higher latency than real IB hardware)

---

## 3. Repo Structure

```
vm-configs/
  c6525-25g/
    config.sh        — set CLOUDLAB_HOST here
    setup_vms.sh     — run once on a fresh node
    start.sh         — start all 5 processes in order
    stop.sh / 00_cleanup.sh — kill everything
    test.sh          — LOAD + 3 benchmark workloads
    07_trigger_bench.sh     — send a single workload command
    check_logs.sh    — tail last 5 lines of all logs
    README.md        — full documentation for this setup
    conf/            — YAML config files deployed to VMs

src/kvs/             — kvs and storage source
include/kvs/         — headers including dinomo_compute.hpp
src/kvs/Indexes/P-CLHT/src/clht_lb_res.c  — hash table, pool open/reopen

CODE_CHANGES.md      — before/after for every source change with explanation
```

---

## 4. Architecture

Five processes:

| Process | VM / Node | Role |
|---------|-----------|------|
| dinomo-storage | storage VM | PMDK pool owner; allocates log blocks on request |
| dinomo-kvs | kvs VM | 4 worker threads; RDMA-writes directly into storage pool |
| dinomo-route | route VM | consistent hash ring membership; kvs queries this at startup |
| dinomo-monitor | monitor VM | statistics collection |
| dinomo-bench | bench VM | benchmark client; sends LOAD and RUN commands to kvs via ZMQ |

Data path for a PUT:
```
bench → ZMQ → kvs worker thread → user_request_handler
  → get_responsible_threads() → process_put()
    → Dinomo::put()
      → if no log block: preallocate_log_blocks()
          → RDMA SEND to storage (request new block addresses)
          → poll CQ until storage replies via RDMA SEND
      → RDMA WRITE log entry into storage pool
      → RDMA WRITE to update CLHT hash table index
```

**Start order matters**: storage must open its TCP socket before kvs starts (kvs connects immediately at startup). Route and monitor must be up before kvs finishes joining the cluster. `start.sh` enforces this with log polling between steps.

---

## 5. Code Changes Made

All changes are documented with inline `ADDED`/`CHANGED` comments in the source, and explained with before/after blocks in `CODE_CHANGES.md`. Brief summary:

### Bug fixes (affect correctness)

**`clht_lb_res.c`** — `remote_start_addr` not updated on pool reopen. When the PMDK pool reopens at a new virtual address, `remote_start_addr` kept the old value, causing every RDMA write to hit the wrong address (`IBV_WC_REM_ACCESS_ERR`). Fixed in both the non-SHARED_NOTHING and SHARED_NOTHING branches.

**`dinomo_storage.cpp`** — PMDK TLS crash ~40s into a benchmark. `server_manager_thread` called `pmemobj_zalloc()` on demand, but PMDK 1.8 TLS is not initialized in that thread, so `pmemobj_errormsg()` dereferenced NULL+0x1808 and crashed. Fixed by pre-allocating 32 spare log blocks from the main thread before any worker threads start.

### Soft-RoCE port (required for VM setup)

**`ib.h`** — MTU lowered from `IBV_MTU_4096` to `IBV_MTU_1024` (virtual bridge can't handle 4096). `QPInfo` struct gained a `gid[16]` field. `modify_qp_to_rts()` prototype gained a `remote_gid` parameter.

**`ib.cpp`** — `modify_qp_to_rts()` implementation: changed `is_global=0` to `is_global=1`, set `grh.dgid` and `grh.sgid_index=1` (IPv4-mapped GID entry for Soft-RoCE). Without this every RDMA packet is silently dropped.

**`setup_ib.cpp`** — both `connect_qp_server()` and `connect_qp_client()`: added `ibv_query_gid()` call, copy GID into outgoing `QPInfo`, pass received GID to `modify_qp_to_rts()`.

**`sock.cpp`** — `sock_set_qp_info()` and `sock_get_qp_info()`: added `memcpy` of the 16-byte GID field (raw bytes, no byte-order conversion needed).

**`dinomo_storage.cpp`** — `ib_connection_manager_thread()`: same GID changes as `setup_ib.cpp`.

### Diagnostics (do not affect correctness)

**`server.cpp`** — STEP1–STEP4 `fprintf` prints in the kvs `run()` function to track thread startup; `std::set_terminate()` handler to print a backtrace on uncaught exceptions.

**`ib.cpp`** — `poll_cq()` failure path now prints opcode and a full call stack via `backtrace()`.

**`dinomo_compute.hpp`** — prints in `preallocate_log_blocks()` and at the two PUT call sites; `raddr_pool` / `remote_start_addr` comparison print after reading the hash table header.

**`user_request_handler.cpp`** — prints around `get_responsible_threads()`, `wt_in_threads`, and `process_put()`.

---

## 6. Key Config Variables (c6525-25g)

Edit `vm-configs/c6525-25g/config.sh`:

| Variable | What it controls |
|----------|-----------------|
| `CLOUDLAB_HOST` | Hostname from the CloudLab experiment page — change every new experiment |
| `SSH_USER` | CloudLab username (capital U for `Uriel`) |
| `BENCH_NUM_KEYS` | Keys to insert in LOAD and operate on in RUN |
| `BENCH_DURATION` | Seconds per RUN workload |
| `BENCH_OUTSTANDING` | In-flight requests per thread |

---

## 7. Troubleshooting

**kvs stuck at STEP3** — routing node unreachable. Verify `dinomo-route` is running and that `seed_ip` in `conf/dinomo-vm-config.yml` points to the route VM (192.168.122.99), not storage.

**`raddr_pool=` count below 4 in kvs log** — one or more threads failed the RDMA handshake. Check `rdma link show` on both VMs shows `rxe0 state ACTIVE`. Re-run `01_setup_rdma.sh` if not.

**Storage crashes ~40s in** — PMDK TLS fix not applied. Look for `"Pre-allocated 32 spare log blocks"` in `/tmp/dinomo-storage.log`. If missing, re-run `setup_vms.sh`.

**`IBV_WC_REM_ACCESS_ERR` after storage restart** — stale `remote_start_addr`. Confirm `raddr_pool=` and `remote_start_addr=` match in kvs log. This should not happen if the `clht_lb_res.c` fix is applied.

**bench-trigger segfaults** — stdin closed before ZMQ delivered the message. Always use `(echo 'CMD'; sleep N) | bench-trigger` pattern, never bare `echo CMD | bench-trigger`.

**Soft-RoCE not active after VM reboot** — `rdma_rxe` is not persistent across reboots. Re-run `01_setup_rdma.sh` or let `start.sh` handle it (it reloads rxe every time).
