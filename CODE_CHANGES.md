# Code Changes — DINOMO Soft-RoCE Port

All changes are relative to the original [utsaslab/DINOMO](https://github.com/utsaslab/DINOMO) repository.

**`ADDED`** — line did not exist in the original.
**`CHANGED`** — line existed but its value was modified. The comment states the original value.

---

## Why changes were needed

The original code routes RDMA packets using a **Local Identifier (LID)**, which works on physical InfiniBand. Soft-RoCE runs over Ethernet and requires a **Global Identifier (GID)** and a **Global Routing Header (GRH)** on every packet — without them Soft-RoCE silently drops all traffic. A second fix pre-allocates log blocks from the main thread to avoid a PMDK 1.8 crash when `server_manager_thread` calls `pmemobj_zalloc()` without initialized thread-local storage.

---

## `include/kvs/ib.h`

This header defines shared constants, the `QPInfo` struct that is exchanged over TCP between storage and kvs during startup, and the prototype for `modify_qp_to_rts()`. Three things changed.

**Maximum Transmission Unit constant.** Soft-RoCE running over a virtual Linux bridge cannot handle packets larger than 1024 bytes. The original value of 4096 causes the Queue Pair transition to Ready-To-Receive to fail silently — no error is returned but RDMA communication never works.

```c
// BEFORE
#define IB_MTU  IBV_MTU_4096

// AFTER — Soft-RoCE over a virtual bridge only supports up to 1024-byte MTU; 4096 causes the RTR transition to fail silently
/* CHANGED from IBV_MTU_4096 ... */
#define IB_MTU  IBV_MTU_1024
```

**QPInfo struct — added Global Identifier field.** `QPInfo` is the struct that storage and kvs serialize and send to each other over TCP at startup so each side knows the other's Queue Pair number, memory keys, and pool address. The original struct had no Global Identifier field, so there was no mechanism to tell the other side what address to route RDMA packets to on Soft-RoCE. Adding `gid[16]` piggybacks on the existing TCP handshake without any extra round trips.

```c
// BEFORE — QPInfo had no gid field; only a Local Identifier was exchanged during handshake
struct QPInfo {
    uint16_t lid;  uint32_t qp_num;  uint32_t rank;
    uint32_t rkey_pool;  uint64_t raddr_pool;
    uint32_t rkey_buf;   uint64_t raddr_buf;
} __attribute__ ((packed));

// AFTER — added gid[16] so each side can send its Global Identifier to the other over TCP
struct QPInfo {
    uint16_t lid;  uint32_t qp_num;  uint32_t rank;
    uint32_t rkey_pool;  uint64_t raddr_pool;
    uint32_t rkey_buf;   uint64_t raddr_buf;
    /* ADDED: 16-byte Global Identifier for RoCE and Soft-RoCE. Without this, each side
     * has no way to learn the other's Global Identifier and all RDMA packets are dropped. */
    uint8_t  gid[16];
} __attribute__ ((packed));
```

**modify_qp_to_rts() prototype.** The function that transitions a Queue Pair through INIT → Ready-To-Receive → Ready-To-Send now needs the remote side's Global Identifier so it can configure global routing in the address handle. Adding the parameter here propagates the requirement to all callers.

```c
// BEFORE
int modify_qp_to_rts(struct ibv_qp *qp, uint32_t target_qp_num, uint16_t target_lid);

// AFTER — remote_gid is now required to configure global routing in the Queue Pair address handle
/* CHANGED: added remote_gid parameter. All callers in setup_ib.cpp and dinomo_storage.cpp updated. */
int modify_qp_to_rts(struct ibv_qp *qp, uint32_t target_qp_num, uint16_t target_lid, union ibv_gid *remote_gid);
```

---

## `src/kvs/ib.cpp`

This file implements `modify_qp_to_rts()` and all RDMA post/poll operations. Three areas changed.

**New includes.** Two headers are needed to support the backtrace-on-failure diagnostics added below.

```c
// BEFORE — no backtrace headers
#include <unistd.h>

// AFTER
#include <unistd.h>
/* ADDED: provides backtrace() and backtrace_symbols() for call stack printing on RDMA failure. */
#include <execinfo.h>
/* ADDED: provides free() used to release memory from backtrace_symbols(). */
#include <stdlib.h>
```

**modify_qp_to_rts() — implementation.** This is the core change that makes RDMA work on Soft-RoCE. The Ready-To-Receive block in this function configures the address handle — the struct that controls how outgoing RDMA packets are addressed. The original set `is_global=0` and `dlid=target_lid`, which tells the hardware to route using the 16-bit Local Identifier. Soft-RoCE over Ethernet does not have Local Identifiers; every packet needs a 128-bit Global Identifier and a Global Routing Header instead.

```c
// BEFORE — signature took no remote_gid; RTR used Local Identifier routing only
int modify_qp_to_rts(struct ibv_qp *qp, uint32_t target_qp_num, uint16_t target_lid)
{
    // ...RTR block...
        qp_attr.ah_attr.is_global = 0;
        qp_attr.ah_attr.dlid      = target_lid;
        // (no grh fields)

// AFTER
/* CHANGED: added remote_gid parameter. Original: modify_qp_to_rts(qp, target_qp_num, target_lid) */
int modify_qp_to_rts(struct ibv_qp *qp, uint32_t target_qp_num, uint16_t target_lid, union ibv_gid *remote_gid)
{
    // ...RTR block...
        /* CHANGED from 0 to 1: enables the Global Routing Header; without this Soft-RoCE drops all packets. */
        qp_attr.ah_attr.is_global      = 1;
        /* CHANGED from target_lid to 0: Local Identifier is unused in RoCE/Soft-RoCE routing. */
        qp_attr.ah_attr.dlid           = 0;
        /* ADDED: destination Global Identifier — the remote side's RDMA network address. */
        qp_attr.ah_attr.grh.dgid       = *remote_gid;
        /* ADDED: source Global Identifier index 1 = IPv4-mapped entry (::ffff:10.0.0.x) for Soft-RoCE. */
        qp_attr.ah_attr.grh.sgid_index = 1;
        /* ADDED: hop limit 1 — all communication stays on the local virtual bridge. */
        qp_attr.ah_attr.grh.hop_limit  = 1;
        /* ADDED: debug print showing Queue Pair transition details at startup. */
        fprintf(stderr, "RTR: qpn=0x%x target_qpn=0x%x mtu=%d sgid_idx=1 dgid=...\n", ...);
```

**poll_cq() failure path.** `poll_cq()` is called after every RDMA operation to check whether it succeeded. When it failed, the original only printed the status string and returned -1 — no way to tell which operation failed or where in the call stack it was triggered. Two things were added: `opcode` in the print to distinguish WRITE/READ/SEND failures, and a full call stack via `backtrace()`.

```c
// BEFORE — poll_cq error print had no opcode; no backtrace
        fprintf(stderr, "%s: Failed status %s (%d) for wr_id %d\n", ...);
        return -1;

// AFTER
        /* CHANGED: added opcode=%d to distinguish RDMA Write, Read, and Send failures. */
        fprintf(stderr, "%s: Failed status %s (%d) for wr_id %d opcode=%d\n", ...);
        /* ADDED: print call stack so the failing operation can be found without a debugger. */
        void *bt[20]; int bts = backtrace(bt, 20);
        char **btsyms = backtrace_symbols(bt, bts);
        for (int i = 0; i < bts; i++) fprintf(stderr, "  bt[%d]: %s\n", i, btsyms[i]);
        free(btsyms);
        return -1;
```

---

## `src/kvs/setup_ib.cpp`

This file handles the Queue Pair setup and handshake for both the storage node (`connect_qp_server`) and the kvs node (`connect_qp_client`), and the one-time RDMA device initialization (`setup_ib`).

**connect_qp_server() and connect_qp_client() — Global Identifier query, copy into QPInfo, updated modify_qp_to_rts() call.** During the TCP handshake each side fills a `QPInfo` array and sends it to the other side. Before this change, neither side queried its own Global Identifier or included it in that array, so neither side had any way to configure global routing after the handshake. The fix adds `ibv_query_gid()` to get the local Global Identifier, copies it into each `QPInfo` entry, and updates the `modify_qp_to_rts()` call to pass the remote Global Identifier received from the other side. Both `connect_qp_server()` and `connect_qp_client()` are identical in structure so they are shown as one combined example.

```c
// BEFORE — no Global Identifier query; gid field not populated; modify_qp_to_rts took no gid

```c
// BEFORE — no Global Identifier query; gid field not populated; modify_qp_to_rts took no gid
    for (i = 0; i < ib_res.num_qps; i++) {
        local_qp_info[i].lid = ...; // ... other fields ...
        // (no gid)
    }
    ret = modify_qp_to_rts(ib_res.qp[...], remote_qp_info[...].qp_num, remote_qp_info[...].lid);

// AFTER
    /* ADDED: query the local Global Identifier at index 1 (IPv4-mapped entry for Soft-RoCE).
     * Original code did not query or exchange Global Identifiers at all. */
    union ibv_gid local_gid;
    int gid_ret = ibv_query_gid(ib_res.ctx, IB_PORT, 1, &local_gid);
    /* ADDED: print local Global Identifier at startup for verification. */
    fprintf(stderr, "SERVER connect_qp_server: gid_ret=%d gid=...\n", ...);
    for (i = 0; i < ib_res.num_qps; i++) {
        local_qp_info[i].lid = ...; // ... other fields ...
        /* ADDED: copy this node's Global Identifier into QPInfo so the other side receives it
         * over TCP and can configure global routing toward this node. */
        memcpy(local_qp_info[i].gid, local_gid.raw, 16);
    }
    /* CHANGED: added remote Global Identifier argument. Original: modify_qp_to_rts(..., qp_num, lid) */
    ret = modify_qp_to_rts(ib_res.qp[...], remote_qp_info[...].qp_num, remote_qp_info[...].lid,
            (union ibv_gid *)remote_qp_info[...].gid);
```

**setup_ib() — pool address diagnostic print.** After `ibv_reg_mr()` registers the PMDK pool as an RDMA memory region, the pool's base virtual address and remote key are now printed. This was the primary diagnostic used to verify the `clht_lb_res.c` fix: the base address printed here must match the `remote_start_addr` field read back from the hash table header on the kvs side.

```c
// BEFORE — no pool address print after ibv_reg_mr
    ib_res.mr_pool = ibv_reg_mr(ib_res.pd, ...);
    check(ib_res.mr_pool != NULL, "Failed to register PM pool");

// AFTER
    ib_res.mr_pool = ibv_reg_mr(ib_res.pd, ...);
    check(ib_res.mr_pool != NULL, "Failed to register PM pool");
    /* ADDED: print pool base, size, end, and remote key. Used during debugging to verify this
     * matched remote_start_addr read back from the hash table header. */
    fprintf(stderr, "SERVER mr_pool: base=0x%lx size=%zu end=0x%lx rkey=0x%x\n", ...);
```

---

## `src/kvs/sock.cpp`

This file serializes and deserializes `QPInfo` structs over a TCP socket. `sock_set_qp_info()` converts integer fields to network byte order and sends them; `sock_get_qp_info()` receives them and converts back to host byte order. The Global Identifier field needs to be copied in both directions, but since it is a raw 16-byte array (not an integer) it does not need byte-order conversion — just a plain `memcpy`.

**sock_set_qp_info() — copy Global Identifier into outgoing struct.**

```c
// BEFORE — sock_set_qp_info: gid not copied into outgoing struct
        tmp_qp_info[i].raddr_buf = htonll(qp_info[i].raddr_buf);
        // (end of loop body)

// AFTER
        tmp_qp_info[i].raddr_buf = htonll(qp_info[i].raddr_buf);
        /* ADDED: copy Global Identifier — raw byte array, no byte-order conversion needed. */
        memcpy(tmp_qp_info[i].gid, qp_info[i].gid, 16);
```

**sock_get_qp_info() — copy Global Identifier out of received struct.**

```c
// BEFORE — sock_get_qp_info: gid not copied out of received struct
        qp_info[i].raddr_buf = ntohll(tmp_qp_info[i].raddr_buf);
        // (end of loop body)

// AFTER
        qp_info[i].raddr_buf = ntohll(tmp_qp_info[i].raddr_buf);
        /* ADDED: copy Global Identifier — raw byte array, no byte-order conversion needed. */
        memcpy(qp_info[i].gid, tmp_qp_info[i].gid, 16);
```

---

## `src/kvs/Indexes/P-CLHT/src/clht_lb_res.c`

`remote_start_addr` is used by the kvs to compute RDMA write targets: `target = (ptr - remote_start_addr) + raddr_pool_base`. On storage restart the pool may map at a new virtual address. The original else branch (pool already existed) never updated `remote_start_addr`, leaving it stale from the previous run — causing every RDMA write to fail with `IBV_WC_REM_ACCESS_ERR`.

```c
// BEFORE — non-SHARED_NOTHING mode: else branch did not set remote_start_addr
    } else {
        w->resize_lock = LOCK_FREE;  w->gc_lock = LOCK_FREE;  w->status_lock = LOCK_FREE;
    }

// AFTER
    } else {
        /* ADDED: pool is being reopened, not created fresh. Original code left remote_start_addr
         * with a stale address from the previous run, causing IBV_WC_REM_ACCESS_ERR on every
         * RDMA write after a storage restart. */
        w->remote_start_addr = (uint64_t)pop;
        w->resize_lock = LOCK_FREE;  w->gc_lock = LOCK_FREE;  w->status_lock = LOCK_FREE;
    }
```

```c
// BEFORE — SHARED_NOTHING mode (per-peer table w[i]): same bug
        } else {
            w[i]->resize_lock = LOCK_FREE;  w[i]->gc_lock = LOCK_FREE;  w[i]->status_lock = LOCK_FREE;
        }

// AFTER
        } else {
            /* ADDED: same fix as above for the SHARED_NOTHING code path. w[i] is the per-peer
             * hash table wrapper. Same stale address bug, same IBV_WC_REM_ACCESS_ERR result. */
            w[i]->remote_start_addr = (uint64_t)pop;
            w[i]->resize_lock = LOCK_FREE;  w[i]->gc_lock = LOCK_FREE;  w[i]->status_lock = LOCK_FREE;
        }
```

---

## `src/kvs/dinomo_storage.cpp`

This file is the storage node process. Two areas changed.

**ib_connection_manager_thread() — Global Identifier query, copy into QPInfo, updated modify_qp_to_rts() call.** This thread runs on the storage node and handles each incoming kvs connection at runtime (as opposed to the initial `connect_qp_server()` call at startup). It has its own copy of the Queue Pair handshake logic and needed the same three changes as `setup_ib.cpp`: query the local Global Identifier, copy it into outgoing `QPInfo` entries, and pass the remote Global Identifier to `modify_qp_to_rts()`. The before/after is structurally identical to the `setup_ib.cpp` example above; the same ADDED/CHANGED comments appear in the source.

**run_server() — pre-allocate 32 spare log blocks before any threads start.** A log block is an 8 MB chunk in the PMDK pool that the kvs node writes into via RDMA. When a log block fills up, the kvs sends a message to storage requesting a new one. In the original code, `server_manager_thread` handled this by calling `pmemobj_zalloc()` on demand. Under PMDK 1.8, `pmemobj_zalloc()` internally calls `pmemobj_errormsg()` which reads from thread-local storage (TLS). `server_manager_thread` never calls `pmemobj_open()` or `pmemobj_create()`, so its TLS is never initialized. About 40 seconds into a benchmark run, when the pool's initially available blocks ran out, `server_manager_thread` called `pmemobj_zalloc()` for the first time, `pmemobj_errormsg()` dereferenced a NULL pointer at offset `0x1808`, and the storage process crashed. The fix is to call `pmemobj_zalloc()` 32 times here in `run_server()` (the main thread, where TLS is initialized) and push the results into `reserved_alloc_queue` before any worker threads start. `server_manager_thread` then calls `try_pop()` on the queue instead and never touches PMDK TLS.

```c
// BEFORE — run_server: no spare block pre-allocation; server_manager_thread called pmemobj_zalloc on demand
    reserved_alloc_queue = new tbb::concurrent_queue<uint64_t>;
    barrier_init(&barrier, num_threads);

// AFTER — pre-allocate 32 blocks before any thread starts
    reserved_alloc_queue = new tbb::concurrent_queue<uint64_t>;

    /* ADDED: pre-allocate spare log blocks here in the main thread before worker threads start.
     * The original code let server_manager_thread call pmemobj_zalloc() on demand. This crashed
     * ~40s into a benchmark run: PMDK 1.8 TLS is not initialized in server_manager_thread, so
     * pmemobj_errormsg() dereferences NULL+0x1808 and aborts. With 32 blocks pre-loaded here,
     * server_manager_thread uses try_pop() instead and never touches PMDK TLS directly. */
    {
        const int spare_blocks = 32;
        int n_ok = 0;
        for (int b = 0; b < spare_blocks; b++) {
            PMEMoid ret;
            if (pmemobj_zalloc(pop, &ret, sizeof(log_block) + MAX_LOG_BLOCK_LEN, 0)) {
                fprintf(stderr, "[storage] pmemobj_zalloc failed at spare block %d\n", b);
                break;
            }
            reserved_alloc_queue->push((uint64_t)pmemobj_direct(ret));
            n_ok++;
        }
        fprintf(stderr, "[storage] Pre-allocated %d spare log blocks (%lu MB each)\n",
                n_ok, (sizeof(log_block) + MAX_LOG_BLOCK_LEN) / (1024*1024));
    }

    barrier_init(&barrier, num_threads);
```

---

## `src/kvs/server.cpp`

This file is the kvs node main process. Three areas changed. None of these affect correctness — they are all diagnostic additions that made it possible to observe the startup sequence and identify crashes during development.

**execinfo.h include.** Needed for `backtrace()` and `backtrace_symbols()` used in the terminate handler below.

```c
// BEFORE — no execinfo header
#include "kvs/kvs_handlers.hpp"

// AFTER
/* ADDED: provides backtrace() and backtrace_symbols() for the terminate handler below. */
#include <execinfo.h>
#include "kvs/kvs_handlers.hpp"
```

**STEP1–STEP4 progress markers in run().** The `run()` function is the entry point for each of the four kvs worker threads. The original code had no output until spdlog was set up and messages were written to a log file — if a thread hung or crashed before that, there was nothing in the log. The four markers cover: thread entry (STEP1), spdlog created (STEP2), about to block on routing response (STEP3), and routing response received (STEP4). All four threads printing STEP4 is the signal that the kvs is ready to process requests.

```c
// BEFORE — run(): no progress markers; a hang was invisible in the log
    auto log = spdlog::basic_logger_mt(...);
    ...
    kZmqUtil->send_string("join", &addr_requester);
    string serialized_addresses = kZmqUtil->recv_string(&addr_requester);

// AFTER
    /* ADDED: STEP1 — printed on thread entry before spdlog is set up. */
    fprintf(stderr, "run<T>[tid=%u] STEP1: entered\n", thread_id);
    auto log = spdlog::basic_logger_mt(...);
    /* ADDED: STEP2 — confirms spdlog was created. */
    fprintf(stderr, "run<T>[tid=%u] STEP2: spdlog created\n", thread_id);
    ...
    kZmqUtil->send_string("join", &addr_requester);
    /* ADDED: STEP3 — printed before the blocking recv. STEP3 without STEP4 = routing node unreachable. */
    fprintf(stderr, "run<T>[tid=%u] STEP3: waiting for routing response\n", thread_id);
    string serialized_addresses = kZmqUtil->recv_string(&addr_requester);
    /* ADDED: STEP4 — printed after routing response. All 4 threads at STEP4 = kvs ready. */
    fprintf(stderr, "run<T>[tid=%u] STEP4: got routing response len=%zu\n", thread_id, serialized_addresses.size());
```

**std::set_terminate() handler in main().** `std::terminate()` is called by the C++ runtime when an exception propagates out of a thread without being caught — for example `std::bad_alloc` from a failed memory allocation. The original code had no handler, so the process would call `std::abort()` with no output. The handler installed here prints a full call stack to stderr before aborting, so the crash location is visible in the log.

```c
// BEFORE — main(): no terminate handler; uncaught exceptions exited silently
int main(int argc, char *argv[])
{

// AFTER
int main(int argc, char *argv[])
{
    /* ADDED: terminate handler that prints a backtrace on uncaught exceptions (e.g. std::bad_alloc).
     * Original code had none — the process would exit with no crash location information. */
    std::set_terminate([]() {
        void *bt[30]; int bts = backtrace(bt, 30);
        char **btsyms = backtrace_symbols(bt, bts);
        fprintf(stderr, "TERMINATE HANDLER (bad_alloc or uncaught exception):\n");
        for (int i = 0; i < bts; i++) fprintf(stderr, "  bt[%d]: %s\n", i, btsyms[i]);
        free(btsyms);
        abort();
    });
```

---

## `include/kvs/dinomo_compute.hpp`

This file implements the kvs-side data operations: GET, PUT, and `preallocate_log_blocks()`. All changes here are diagnostic prints — none affect correctness. They were added during debugging to make the RDMA addressing state and the log block allocation flow observable.

**raddr_pool / remote_start_addr print after reading hash table header.** At startup each kvs thread reads the hash table header from storage via RDMA. The header contains `remote_start_addr`, which must equal `raddr_pool` (the pool base address received during the handshake). If they differ, the `clht_lb_res.c` fix is not working and every RDMA write will go to the wrong address.

```c
// BEFORE — no print after reading hash table header via RDMA
    memcpy(h, ib_res.ib_buf + (config_info.msg_size * thread_id), sizeof(clht_t));

// AFTER
    memcpy(h, ib_res.ib_buf + (config_info.msg_size * thread_id), sizeof(clht_t));
    /* ADDED: raddr_pool and remote_start_addr must match. If they differ, remote_start_addr is
     * stale (pool reopened at a new address) and all RDMA writes will fail. This print was the
     * key diagnostic that confirmed the clht_lb_res.c fix was working. */
    fprintf(stderr, "DINOMO[tid=%d]: raddr_pool=0x%lx rkey_pool=0x%x "
            "remote_start_addr=0x%lx log_table_addr=0x%lx mapping_raddr=0x%lx\n", ...);
```

**preallocate_log_blocks() — diagnostic prints.** This function requests new log blocks from storage by posting an RDMA SEND and then blocking in a poll loop until storage replies with new block addresses. If this function hangs, the kvs stops making progress and the benchmark stalls with no output. The four prints cover: before the SEND, after the SEND is posted, each poll loop completion, and when the RECV from storage arrives.

```c
// BEFORE — preallocate_log_blocks(): no diagnostic prints; hangs were invisible
    ret = post_send_imm_profile(...);
    // poll loop...
        if (wc[j].opcode == IBV_WC_RECV) {
            memcpy(log_blocks_raddrs, buf_ptr, ...);

// AFTER
    /* ADDED: print before SEND so a hang is identifiable. */
    fprintf(stderr, "[DBG prealloc] thread=%ld posting SEND to storage (rank=%d)\n", ...);
    ret = post_send_imm_profile(...);
    /* ADDED: print after SEND is posted, before the blocking poll. */
    fprintf(stderr, "[DBG prealloc] thread=%ld SEND posted, polling for RECV...\n", ...);
    // poll loop...
        /* ADDED: print each work completion — shows opcode and status for diagnosis. */
        fprintf(stderr, "[DBG prealloc] thread=%ld poll wc[%lu] opcode=%d status=%d\n", ...);
        if (wc[j].opcode == IBV_WC_RECV) {
            /* ADDED: print when storage responds — confirms round-trip completed. */
            fprintf(stderr, "[DBG prealloc] thread=%ld got RECV from storage, copying log block addrs\n", ...);
            memcpy(log_blocks_raddrs, buf_ptr, ...);
```

**PUT call sites — log block allocation prints.** When a kvs thread has no current log block assigned (`non_replicated_alloc == 0`), it calls `preallocate_log_blocks()` to get one from storage. This is the first time a new thread writes anything — the three prints show which thread and key triggered it, confirm the blocking call returned, and print the RDMA address of the newly assigned block. This same pattern appears in two separate PUT code paths (non-SHARED_NOTHING and SHARED_NOTHING), so the same change was applied to both.

```c
// BEFORE — PUT else branch (new log block needed): no diagnostic prints (two call sites, same change)
    } else {
        preallocate_log_blocks(...);
        next_batch = pop_log_blocks_raddr();
        non_replicated_alloc = next_batch;

// AFTER
    } else {
        /* ADDED: print which thread and key triggered the allocation. */
        fprintf(stderr, "[DBG put] thread=%ld key=%lu non_replicated_alloc=0, calling preallocate_log_blocks\n", ...);
        preallocate_log_blocks(...);
        /* ADDED: print after blocking SEND/RECV completes. */
        fprintf(stderr, "[DBG put] thread=%ld key=%lu preallocate_log_blocks returned\n", ...);
        next_batch = pop_log_blocks_raddr();
        non_replicated_alloc = next_batch;
        /* ADDED: print the RDMA address of the newly allocated log block. */
        fprintf(stderr, "[DBG put] thread=%ld key=%lu next_batch=0x%lx\n", ...);
```

---

## `src/kvs/user_request_handler.cpp`

This file handles incoming client requests (PUT and GET). When a request arrives, the handler first calls `get_responsible_threads()` to look up which kvs thread owns the key on the consistent hash ring, then either processes it locally or forwards it. All changes here are diagnostic prints. During early debugging the kvs was receiving requests but producing no output — these prints revealed that `get_responsible_threads()` was returning `succeed=false` because the routing table had not yet been populated (the kvs had not finished the cluster join), and later that `process_put()` was being called correctly once that was resolved.

```c
// BEFORE — no diagnostic prints around routing and PUT
            ServerThreadList threads = kHashRingUtil->get_responsible_threads(...);
            if (succeed) {
                bool wt_in_threads = (...);
                if (!wt_in_threads) { ... } else {
                    unsigned ret = process_put(key, ...);
                    if (batching) {

// AFTER
            ServerThreadList threads = kHashRingUtil->get_responsible_threads(...);
            /* ADDED: succeed=0 means routing table not yet populated; size=0 means no thread owns
             * this key. Both indicate the kvs has not finished joining the cluster. */
            fprintf(stderr, "[DBG urh] key=%s get_responsible_threads succeed=%d threads.size=%zu\n", ...);
            if (succeed) {
                bool wt_in_threads = (...);
                /* ADDED: 0 means this thread is not responsible and will forward the request. */
                fprintf(stderr, "[DBG urh] key=%s wt_in_threads=%d\n", ...);
                if (!wt_in_threads) { ... } else {
                    /* ADDED: print before process_put so a hang inside it is identifiable. */
                    fprintf(stderr, "[DBG urh] key=%s calling process_put\n", ...);
                    unsigned ret = process_put(key, ...);
                    /* ADDED: non-zero return = log block write error. */
                    fprintf(stderr, "[DBG urh] key=%s process_put returned %u batching=%d\n", ...);
                    if (batching) {
```
