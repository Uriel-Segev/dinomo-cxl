#include <arpa/inet.h>
#include <unistd.h>
/* ADDED: execinfo.h provides backtrace() and backtrace_symbols() used below to print
 * a full call stack whenever an RDMA operation fails, making crash diagnosis easier. */
#include <execinfo.h>
/* ADDED: stdlib.h needed for free(), which is used to release the memory allocated
 * by backtrace_symbols() after printing the stack trace. */
#include <stdlib.h>

#include "kvs/ib.h"
#include "kvs/debug.h"

#ifdef DH_DEBUG
std::atomic<uint64_t> RDMA_READ_COUNTER;
std::atomic<uint64_t> RDMA_WRITE_COUNTER;
std::atomic<uint64_t> RDMA_SEND_COUNTER;
std::atomic<uint64_t> RDMA_CAS_COUNTER;

std::atomic<uint64_t> RDMA_READ_LATENCY;
std::atomic<uint64_t> RDMA_WRITE_LATENCY;
std::atomic<uint64_t> RDMA_SEND_LATENCY;
std::atomic<uint64_t> RDMA_CAS_LATENCY;

std::atomic<uint64_t> RDMA_READ_PAYLOAD;
std::atomic<uint64_t> RDMA_WRITE_PAYLOAD;
std::atomic<uint64_t> RDMA_SEND_PAYLOAD;
std::atomic<uint64_t> RDMA_CAS_PAYLOAD;
#endif

/* CHANGED: added remote_gid parameter. Original signature was:
 *   modify_qp_to_rts(qp, target_qp_num, target_lid)
 * The remote Global Identifier is now required to configure global routing in the
 * Queue Pair address handle, which is mandatory for RoCE and Soft-RoCE. */
int modify_qp_to_rts(struct ibv_qp *qp, uint32_t target_qp_num, uint16_t target_lid, union ibv_gid *remote_gid)
{
    int ret = 0;

    // change QP state to INIT
    {
        struct ibv_qp_attr qp_attr;
        memset(&qp_attr, 0, sizeof(ibv_qp_attr));
        qp_attr.qp_state = IBV_QPS_INIT;
        qp_attr.pkey_index = 0;
        qp_attr.port_num = IB_PORT;
        qp_attr.qp_access_flags = IBV_ACCESS_REMOTE_READ | IBV_ACCESS_REMOTE_WRITE | IBV_ACCESS_REMOTE_ATOMIC;

        ret = ibv_modify_qp (qp, &qp_attr, IBV_QP_STATE | IBV_QP_PKEY_INDEX |
                IBV_QP_PORT | IBV_QP_ACCESS_FLAGS);
        check(ret == 0, "Failed to modify qp to INIT");
    }

    // Change QP state to RTR
    {
        struct ibv_qp_attr qp_attr;
        memset(&qp_attr, 0, sizeof(ibv_qp_attr));
        qp_attr.qp_state               = IBV_QPS_RTR;
        qp_attr.path_mtu               = IB_MTU;
        qp_attr.rq_psn                 = 0;
        qp_attr.max_dest_rd_atomic     = 1;
        qp_attr.min_rnr_timer          = 12;
        qp_attr.ah_attr.port_num       = IB_PORT;
        qp_attr.ah_attr.sl             = IB_SL;
        qp_attr.ah_attr.src_path_bits  = 0;
        qp_attr.dest_qp_num            = target_qp_num;
        /* CHANGED: the original code set is_global=0 and routed using only the Local
         * Identifier (dlid = target_lid). That works on physical InfiniBand but not on
         * RoCE or Soft-RoCE, which run over Ethernet and require a Global Routing Header
         * in every packet. The following lines replace the original three lines:
         *   qp_attr.ah_attr.is_global = 0;
         *   qp_attr.ah_attr.dlid      = target_lid;
         *   (no grh fields were set)
         */

        /* CHANGED from 0 to 1: enables the Global Routing Header in every outgoing
         * RDMA packet. Without this, Soft-RoCE drops all packets silently. */
        qp_attr.ah_attr.is_global      = 1;
        /* CHANGED from target_lid to 0: the Local Identifier is not used for routing
         * in RoCE or Soft-RoCE — routing is done via the Global Identifier instead. */
        qp_attr.ah_attr.dlid           = 0;
        /* ADDED: destination Global Identifier — the remote side's address on the
         * RDMA network, equivalent to an IP address for InfiniBand/RoCE routing. */
        qp_attr.ah_attr.grh.dgid       = *remote_gid;
        /* ADDED: source Global Identifier index. Index 2 on this hardware RoCE device
         * corresponds to the IPv4-mapped Global Identifier (e.g. ::ffff:10.0.0.x),
         * which is the correct entry for the CloudLab Mellanox RoCE interface. */
        qp_attr.ah_attr.grh.sgid_index = 2;
        /* ADDED: hop limit (equivalent to IP Time-To-Live). Set to 1 since all
         * communication stays within the local virtual network — no routing needed. */
        qp_attr.ah_attr.grh.hop_limit  = 1;

        /* ADDED: debug print showing the Queue Pair transition details so we can verify
         * the correct Global Identifiers are being exchanged during startup. */
        fprintf(stderr, "RTR: qpn=0x%x target_qpn=0x%x mtu=%d sgid_idx=2 dgid=%02x%02x:%02x%02x:%02x%02x:%02x%02x:%02x%02x:%02x%02x:%02x%02x:%02x%02x\n",
                qp->qp_num, target_qp_num, qp_attr.path_mtu,
                remote_gid->raw[0], remote_gid->raw[1], remote_gid->raw[2], remote_gid->raw[3],
                remote_gid->raw[4], remote_gid->raw[5], remote_gid->raw[6], remote_gid->raw[7],
                remote_gid->raw[8], remote_gid->raw[9], remote_gid->raw[10], remote_gid->raw[11],
                remote_gid->raw[12], remote_gid->raw[13], remote_gid->raw[14], remote_gid->raw[15]);

        ret = ibv_modify_qp(qp, &qp_attr, IBV_QP_STATE | IBV_QP_AV | IBV_QP_PATH_MTU |
                IBV_QP_DEST_QPN | IBV_QP_RQ_PSN | IBV_QP_MAX_DEST_RD_ATOMIC |
                IBV_QP_MIN_RNR_TIMER);
        check(ret == 0, "Failed to change qp to RTR");
    }

    // Change QP state to RTS
    {
        struct ibv_qp_attr qp_attr;
        memset(&qp_attr, 0, sizeof(ibv_qp_attr));
        qp_attr.qp_state               = IBV_QPS_RTS;
        qp_attr.timeout                = 14;
        qp_attr.retry_cnt              = 7;
        qp_attr.rnr_retry              = 7;
        qp_attr.sq_psn                 = 0;
        qp_attr.max_rd_atomic          = 1;

        ret = ibv_modify_qp(qp, &qp_attr, IBV_QP_STATE | IBV_QP_TIMEOUT | IBV_QP_RETRY_CNT |
                IBV_QP_RNR_RETRY | IBV_QP_SQ_PSN | IBV_QP_MAX_QP_RD_ATOMIC);
        check(ret == 0, "Failed to modify qp to RTS");
    }

    return 0;

error:
    return -1;
}

int poll_cq(struct ibv_cq *cq)
{
    int num_comp;
    struct ibv_wc wc;
    memset(&wc, 0, sizeof(struct ibv_wc));

    do {
        num_comp = ibv_poll_cq(cq, 1, &wc);
    } while (num_comp == 0);

    if (num_comp < 0) {
        fprintf(stderr, "%s: ibv_poll_cq() failed\n", __func__);
        return -1;
    }

    if (wc.status != IBV_WC_SUCCESS) {
        /* CHANGED: original error print did not include opcode. Added opcode=%d so we
         * can distinguish between failed RDMA Write, Read, and Send completions. */
        fprintf(stderr, "%s: Failed status %s (%d) for wr_id %d opcode=%d\n", __func__,
                ibv_wc_status_str(wc.status), wc.status, (int)wc.wr_id, (int)wc.opcode);
        /* ADDED: print a full call stack when an RDMA completion fails. This was
         * essential for diagnosing which operation triggered the failure during debugging. */
        void *bt[20]; int bts = backtrace(bt, 20);
        /* ADDED: convert raw stack frame addresses to human-readable function names. */
        char **btsyms = backtrace_symbols(bt, bts);
        /* ADDED: print each stack frame to stderr. */
        for (int i = 0; i < bts; i++) fprintf(stderr, "  bt[%d]: %s\n", i, btsyms[i]);
        /* ADDED: free the memory allocated by backtrace_symbols(). */
        free(btsyms);
        return -1;
    }

    return 0;
}

int post_write_signaled_blocking(uint32_t req_size, uint32_t lkey, uint64_t wr_id,
        struct ibv_qp *qp, char *buf, uint64_t raddr, uint32_t rkey, struct ibv_cq *cq)
{
    int ret = 0;
    struct ibv_send_wr *bad_send_wr;

    struct ibv_sge list;
    list.addr = (uintptr_t) buf;
    list.length = req_size;
    list.lkey = lkey;

    struct ibv_send_wr send_wr;
    memset(&send_wr, 0, sizeof(struct ibv_send_wr));
    send_wr.wr_id = wr_id;
    send_wr.sg_list = &list;
    send_wr.num_sge = 1;
    send_wr.opcode = IBV_WR_RDMA_WRITE;
    send_wr.send_flags = IBV_SEND_SIGNALED;
    send_wr.wr.rdma.remote_addr = raddr;
    send_wr.wr.rdma.rkey = rkey;

    ret = ibv_post_send(qp, &send_wr, &bad_send_wr);
    if (ret != 0) {
        fprintf(stderr, "%s: ibv_post_send() failed %d\n", __func__, ret);
        return ret;
    }

    ret = poll_cq(cq);
    /* ADDED: debug print so that if an RDMA Write fails we can see exactly which remote
     * address and remote key were being targeted, and the size of the write. */
    if (ret != 0)
        fprintf(stderr, "RDMA WRITE failed: raddr=0x%lx rkey=0x%x size=%u\n", (unsigned long)raddr, rkey, req_size);

    return ret;
}

int post_write_signaled_blocking_profile(uint32_t req_size, uint32_t lkey, uint64_t wr_id,
        struct ibv_qp *qp, char *buf, uint64_t raddr, uint32_t rkey, struct ibv_cq *cq,
        uint64_t *rdma_write_counter, uint64_t *rdma_write_payload)
{
    (*rdma_write_counter)++;
    *rdma_write_payload = *rdma_write_payload + (uint64_t)req_size;

    int ret = 0;
    struct ibv_send_wr *bad_send_wr;

    struct ibv_sge list;
    list.addr = (uintptr_t) buf;
    list.length = req_size;
    list.lkey = lkey;

    struct ibv_send_wr send_wr;
    memset(&send_wr, 0, sizeof(struct ibv_send_wr));
    send_wr.wr_id = wr_id;
    send_wr.sg_list = &list;
    send_wr.num_sge = 1;
    send_wr.opcode = IBV_WR_RDMA_WRITE;
    send_wr.send_flags = IBV_SEND_SIGNALED;
    send_wr.wr.rdma.remote_addr = raddr;
    send_wr.wr.rdma.rkey = rkey;

    ret = ibv_post_send(qp, &send_wr, &bad_send_wr);
    if (ret != 0) {
        fprintf(stderr, "%s: ibv_post_send() failed %d\n", __func__, ret);
        return ret;
    }

    ret = poll_cq(cq);
    /* ADDED: debug print so that if a profiled RDMA Write fails we can see the remote
     * address, remote key, local key, size, and local buffer pointer for diagnosis. */
    if (ret != 0)
        fprintf(stderr, "RDMA WRITE_PROFILE failed: raddr=0x%lx rkey=0x%x lkey=0x%x size=%u buf=%p\n",
                (unsigned long)raddr, rkey, lkey, req_size, (void*)buf);

    return ret;
}

int post_write_signaled_nonblocking(uint32_t req_size, uint32_t lkey, uint64_t wr_id,
        struct ibv_qp *qp, char *buf, uint64_t raddr, uint32_t rkey)
{
    int ret = 0;
    struct ibv_send_wr *bad_send_wr;

    struct ibv_sge list;
    list.addr = (uintptr_t) buf;
    list.length = req_size;
    list.lkey = lkey;

    struct ibv_send_wr send_wr;
    memset(&send_wr, 0, sizeof(struct ibv_send_wr));
    send_wr.wr_id = wr_id;
    send_wr.sg_list = &list;
    send_wr.num_sge = 1;
    send_wr.opcode = IBV_WR_RDMA_WRITE;
    send_wr.send_flags = IBV_SEND_SIGNALED;
    send_wr.wr.rdma.remote_addr = raddr;
    send_wr.wr.rdma.rkey = rkey;

    ret = ibv_post_send(qp, &send_wr, &bad_send_wr);
    return ret;
}

int post_write_unsignaled(uint32_t req_size, uint32_t lkey, uint64_t wr_id,
        struct ibv_qp *qp, char *buf, uint64_t raddr, uint32_t rkey)
{
    int ret = 0;
    struct ibv_send_wr *bad_send_wr;

    struct ibv_sge list;
    list.addr = (uintptr_t) buf;
    list.length = req_size;
    list.lkey = lkey;

    struct ibv_send_wr send_wr;
    memset(&send_wr, 0, sizeof(struct ibv_send_wr));
    send_wr.wr_id = wr_id;
    send_wr.sg_list = &list;
    send_wr.num_sge = 1;
    send_wr.opcode = IBV_WR_RDMA_WRITE;
    send_wr.wr.rdma.remote_addr = raddr;
    send_wr.wr.rdma.rkey = rkey;

    ret = ibv_post_send(qp, &send_wr, &bad_send_wr);
    return ret;
}

int post_cas_signaled_blocking(uint32_t req_size, uint32_t lkey, uint64_t wr_id,
        struct ibv_qp *qp, char *buf, uint64_t raddr, uint32_t rkey, struct ibv_cq *cq,
        uint64_t expected, uint64_t value)
{
    int ret = 0;
    struct ibv_send_wr *bad_send_wr;

    struct ibv_sge list;
    list.addr = (uintptr_t) buf;
    list.length = req_size;
    list.lkey = lkey;

    struct ibv_send_wr send_wr;
    memset(&send_wr, 0, sizeof(struct ibv_send_wr));
    send_wr.wr_id = wr_id;
    send_wr.sg_list = &list;
    send_wr.num_sge = 1;
    send_wr.opcode = IBV_WR_ATOMIC_CMP_AND_SWP;
    send_wr.send_flags = IBV_SEND_SIGNALED;
    send_wr.wr.atomic.remote_addr = raddr;
    send_wr.wr.atomic.rkey = rkey;
    send_wr.wr.atomic.compare_add = expected;
    send_wr.wr.atomic.swap = value;

    ret = ibv_post_send(qp, &send_wr, &bad_send_wr);
    if (ret != 0) {
        fprintf(stderr, "%s: ibv_post_send() failed %d\n", __func__, ret);
        return ret;
    }

    ret = poll_cq(cq);

    return ret;
}

int post_cas_signaled_blocking_profile(uint32_t req_size, uint32_t lkey, uint64_t wr_id,
        struct ibv_qp *qp, char *buf, uint64_t raddr, uint32_t rkey, struct ibv_cq *cq,
        uint64_t expected, uint64_t value, uint64_t *rdma_cas_counter, uint64_t *rdma_cas_payload)
{
    (*rdma_cas_counter)++;
    *rdma_cas_payload = *rdma_cas_payload + (uint64_t)req_size + sizeof(uint32_t);
    int ret = 0;
    struct ibv_send_wr *bad_send_wr;

    struct ibv_sge list;
    list.addr = (uintptr_t) buf;
    list.length = req_size;
    list.lkey = lkey;

    struct ibv_send_wr send_wr;
    memset(&send_wr, 0, sizeof(struct ibv_send_wr));
    send_wr.wr_id = wr_id;
    send_wr.sg_list = &list;
    send_wr.num_sge = 1;
    send_wr.opcode = IBV_WR_ATOMIC_CMP_AND_SWP;
    send_wr.send_flags = IBV_SEND_SIGNALED;
    send_wr.wr.atomic.remote_addr = raddr;
    send_wr.wr.atomic.rkey = rkey;
    send_wr.wr.atomic.compare_add = expected;
    send_wr.wr.atomic.swap = value;

    ret = ibv_post_send(qp, &send_wr, &bad_send_wr);
    if (ret != 0) {
        fprintf(stderr, "%s: ibv_post_send() failed %d\n", __func__, ret);
        return ret;
    }

    ret = poll_cq(cq);

    return ret;
}

int post_cas_signaled_nonblocking(uint32_t req_size, uint32_t lkey, uint64_t wr_id,
        struct ibv_qp *qp, char *buf, uint64_t raddr, uint32_t rkey, struct ibv_cq *cq,
        uint64_t expected, uint64_t value)
{
    int ret = 0;
    struct ibv_send_wr *bad_send_wr;

    struct ibv_sge list;
    list.addr = (uintptr_t) buf;
    list.length = req_size;
    list.lkey = lkey;

    struct ibv_send_wr send_wr;
    memset(&send_wr, 0, sizeof(struct ibv_send_wr));
    send_wr.wr_id = wr_id;
    send_wr.sg_list = &list;
    send_wr.num_sge = 1;
    send_wr.opcode = IBV_WR_ATOMIC_CMP_AND_SWP;
    send_wr.send_flags = IBV_SEND_SIGNALED;
    send_wr.wr.atomic.remote_addr = raddr;
    send_wr.wr.atomic.rkey = rkey;
    send_wr.wr.atomic.compare_add = expected;
    send_wr.wr.atomic.swap = value;

    ret = ibv_post_send(qp, &send_wr, &bad_send_wr);
    return ret;
}

int post_fetch_add_signaled_blocking(uint32_t req_size, uint32_t lkey, uint64_t wr_id,
struct ibv_qp *qp, char *buf, uint64_t raddr, uint32_t rkey, struct ibv_cq *cq, uint64_t value)
{
    int ret = 0;
    struct ibv_send_wr *bad_send_wr;

    struct ibv_sge list;
    list.addr = (uintptr_t) buf;
    list.length = req_size;
    list.lkey = lkey;

    struct ibv_send_wr send_wr;
    memset(&send_wr, 0, sizeof(struct ibv_send_wr));
    send_wr.wr_id = wr_id;
    send_wr.sg_list = &list;
    send_wr.num_sge = 1;
    send_wr.opcode = IBV_WR_ATOMIC_FETCH_AND_ADD;
    send_wr.send_flags = IBV_SEND_SIGNALED;
    send_wr.wr.atomic.remote_addr = raddr;
    send_wr.wr.atomic.rkey = rkey;
    send_wr.wr.atomic.compare_add = value;

    ret = ibv_post_send(qp, &send_wr, &bad_send_wr);
    if (ret != 0) {
        fprintf(stderr, "%s: ibv_post_send() failed %d\n", __func__, ret);
        return ret;
    }

    ret = poll_cq(cq);
    return ret;
}

int post_fetch_add_signaled_blocking_profile(uint32_t req_size, uint32_t lkey, uint64_t wr_id,
struct ibv_qp *qp, char *buf, uint64_t raddr, uint32_t rkey, struct ibv_cq *cq, uint64_t value,
uint64_t *rdma_faa_counter, uint64_t *rdma_faa_payload)
{
    (*rdma_faa_counter)++;
    *rdma_faa_payload = *rdma_faa_payload + (uint64_t)req_size + sizeof(uint32_t);
    int ret = 0;
    struct ibv_send_wr *bad_send_wr;

    struct ibv_sge list;
    list.addr = (uintptr_t) buf;
    list.length = req_size;
    list.lkey = lkey;

    struct ibv_send_wr send_wr;
    memset(&send_wr, 0, sizeof(struct ibv_send_wr));
    send_wr.wr_id = wr_id;
    send_wr.sg_list = &list;
    send_wr.num_sge = 1;
    send_wr.opcode = IBV_WR_ATOMIC_FETCH_AND_ADD;
    send_wr.send_flags = IBV_SEND_SIGNALED;
    send_wr.wr.atomic.remote_addr = raddr;
    send_wr.wr.atomic.rkey = rkey;
    send_wr.wr.atomic.compare_add = value;

    ret = ibv_post_send(qp, &send_wr, &bad_send_wr);
    if (ret != 0) {
        fprintf(stderr, "%s: ibv_post_send() failed %d\n", __func__, ret);
        return ret;
    }

    ret = poll_cq(cq);
    return ret;
}

int post_fetch_add_signaled_nonblocking(uint32_t req_size, uint32_t lkey, uint64_t wr_id,
struct ibv_qp *qp, char *buf, uint64_t raddr, uint32_t rkey, struct ibv_cq *cq, uint64_t value)
{
    int ret = 0;
    struct ibv_send_wr *bad_send_wr;

    struct ibv_sge list;
    list.addr = (uintptr_t) buf;
    list.length = req_size;
    list.lkey = lkey;

    struct ibv_send_wr send_wr;
    memset(&send_wr, 0, sizeof(struct ibv_send_wr));
    send_wr.wr_id = wr_id;
    send_wr.sg_list = &list;
    send_wr.num_sge = 1;
    send_wr.opcode = IBV_WR_ATOMIC_FETCH_AND_ADD;
    send_wr.send_flags = IBV_SEND_SIGNALED;
    send_wr.wr.atomic.remote_addr = raddr;
    send_wr.wr.atomic.rkey = rkey;
    send_wr.wr.atomic.compare_add = value;

    ret = ibv_post_send(qp, &send_wr, &bad_send_wr);
    if (ret != 0) {
        fprintf(stderr, "%s: ibv_post_send() failed %d\n", __func__, ret);
        return ret;
    }
}

int post_read_signaled_blocking(uint32_t req_size, uint32_t lkey, uint64_t wr_id,
        struct ibv_qp *qp, char *buf, uint64_t raddr, uint32_t rkey, struct ibv_cq *cq)
{
    int ret = 0;
    struct ibv_send_wr *bad_send_wr;

    struct ibv_sge list;
    list.addr = (uintptr_t) buf;
    list.length = req_size;
    list.lkey = lkey;

    struct ibv_send_wr send_wr;
    memset(&send_wr, 0, sizeof(struct ibv_send_wr));
    send_wr.wr_id = wr_id;
    send_wr.sg_list = &list;
    send_wr.num_sge = 1;
    send_wr.opcode = IBV_WR_RDMA_READ;
    send_wr.send_flags = IBV_SEND_SIGNALED;
    send_wr.wr.rdma.remote_addr = raddr;
    send_wr.wr.rdma.rkey = rkey;

    ret = ibv_post_send(qp, &send_wr, &bad_send_wr);
    if (ret != 0) {
        fprintf(stderr, "%s: ibv_post_send() failed %d\n", __func__, ret);
        return ret;
    }

    ret = poll_cq(cq);
    /* ADDED: debug print so that if an RDMA Read fails we can see which remote
     * address and remote key were being read from, and the size of the read. */
    if (ret != 0)
        fprintf(stderr, "RDMA READ failed: raddr=0x%lx rkey=0x%x size=%u\n", (unsigned long)raddr, rkey, req_size);

    return ret;
}

int post_read_signaled_blocking_profile(uint32_t req_size, uint32_t lkey, uint64_t wr_id,
        struct ibv_qp *qp, char *buf, uint64_t raddr, uint32_t rkey, struct ibv_cq *cq,
        uint64_t *rdma_read_counter, uint64_t *rdma_read_payload)
{
    (*rdma_read_counter)++;
    *rdma_read_payload = *rdma_read_payload + (uint64_t)req_size;
    int ret = 0;
    struct ibv_send_wr *bad_send_wr;

    struct ibv_sge list;
    list.addr = (uintptr_t) buf;
    list.length = req_size;
    list.lkey = lkey;

    struct ibv_send_wr send_wr;
    memset(&send_wr, 0, sizeof(struct ibv_send_wr));
    send_wr.wr_id = wr_id;
    send_wr.sg_list = &list;
    send_wr.num_sge = 1;
    send_wr.opcode = IBV_WR_RDMA_READ;
    send_wr.send_flags = IBV_SEND_SIGNALED;
    send_wr.wr.rdma.remote_addr = raddr;
    send_wr.wr.rdma.rkey = rkey;

    ret = ibv_post_send(qp, &send_wr, &bad_send_wr);
    if (ret != 0) {
        fprintf(stderr, "%s: ibv_post_send() failed %d\n", __func__, ret);
        return ret;
    }

    ret = poll_cq(cq);

    return ret;
}

int post_read_signaled_nonblocking(uint32_t req_size, uint32_t lkey, uint64_t wr_id,
        struct ibv_qp *qp, char *buf, uint64_t raddr, uint32_t rkey)
{
    int ret = 0;
    struct ibv_send_wr *bad_send_wr;

    struct ibv_sge list;
    list.addr = (uintptr_t) buf;
    list.length = req_size;
    list.lkey = lkey;

    struct ibv_send_wr send_wr;
    memset(&send_wr, 0, sizeof(struct ibv_send_wr));
    send_wr.wr_id = wr_id;
    send_wr.sg_list = &list;
    send_wr.num_sge = 1;
    send_wr.opcode = IBV_WR_RDMA_READ;
    send_wr.send_flags = IBV_SEND_SIGNALED;
    send_wr.wr.rdma.remote_addr = raddr;
    send_wr.wr.rdma.rkey = rkey;

    ret = ibv_post_send(qp, &send_wr, &bad_send_wr);
    return ret;
}

int post_read_unsignaled(uint32_t req_size, uint32_t lkey, uint64_t wr_id,
        struct ibv_qp *qp, char *buf, uint64_t raddr, uint32_t rkey)
{
    int ret = 0;
    struct ibv_send_wr *bad_send_wr;

    struct ibv_sge list;
    list.addr = (uintptr_t) buf;
    list.length = req_size;
    list.lkey = lkey;

    struct ibv_send_wr send_wr;
    memset(&send_wr, 0, sizeof(struct ibv_send_wr));
    send_wr.wr_id = wr_id;
    send_wr.sg_list = &list;
    send_wr.num_sge = 1;
    send_wr.opcode = IBV_WR_RDMA_READ;
    send_wr.wr.rdma.remote_addr = raddr;
    send_wr.wr.rdma.rkey = rkey;

    ret = ibv_post_send(qp, &send_wr, &bad_send_wr);
    return ret;
}

int post_send(uint32_t req_size, uint32_t lkey, uint64_t wr_id,
        struct ibv_qp *qp, char *buf)
{
#ifdef DH_DEBUG
    RDMA_SEND_COUNTER.fetch_add(1);
    RDMA_SEND_PAYLOAD.fetch_add((uint64_t)req_size);
#endif
    int ret = 0;
    struct ibv_send_wr *bad_send_wr;

    struct ibv_sge list;
    list.addr = (uintptr_t) buf;
    list.length = req_size;
    list.lkey = lkey;

    struct ibv_send_wr send_wr;
    memset(&send_wr, 0, sizeof(struct ibv_send_wr));
    send_wr.wr_id = wr_id;
    send_wr.sg_list = &list;
    send_wr.num_sge = 1;
    send_wr.opcode = IBV_WR_SEND;
    //        send_wr.opcode = IBV_WR_SEND_WITH_IMM;
    send_wr.send_flags = IBV_SEND_SIGNALED;
    //        send_wr.imm_data = htonl(imm_data);

    ret = ibv_post_send(qp, &send_wr, &bad_send_wr);
    if (ret != 0) {
        fprintf(stderr, "%s: ibv_post_send() failed %d\n", __func__, ret);
        return ret;
    }

    return ret;
}

int post_send_imm(uint32_t req_size, uint32_t lkey, uint64_t wr_id,
        uint32_t imm_data, struct ibv_qp *qp, char *buf)
{
    int ret = 0;
    struct ibv_send_wr *bad_send_wr;

    struct ibv_sge list;
    list.addr = (uintptr_t) buf;
    list.length = req_size;
    list.lkey = lkey;

    struct ibv_send_wr send_wr;
    memset(&send_wr, 0, sizeof(struct ibv_send_wr));
    send_wr.wr_id = wr_id;
    send_wr.sg_list = &list;
    if (req_size != 0) send_wr.num_sge = 1;
    else send_wr.num_sge = 0;
    send_wr.opcode = IBV_WR_SEND_WITH_IMM;
    send_wr.send_flags = IBV_SEND_SIGNALED;
    send_wr.imm_data = htonl(imm_data);

    ret = ibv_post_send(qp, &send_wr, &bad_send_wr);
    if (ret != 0) {
        fprintf(stderr, "%s: ibv_post_send() failed %d\n", __func__, ret);
        return ret;
    }

    return ret;
}

int post_send_imm_profile(uint32_t req_size, uint32_t lkey, uint64_t wr_id,
        uint32_t imm_data, struct ibv_qp *qp, char *buf,
        uint64_t *rdma_send_counter, uint64_t *rdma_send_payload)
{
    (*rdma_send_counter)++;
    *rdma_send_payload = *rdma_send_payload + (uint64_t)req_size + sizeof(uint32_t);
    int ret = 0;
    struct ibv_send_wr *bad_send_wr;

    struct ibv_sge list;
    list.addr = (uintptr_t) buf;
    list.length = req_size;
    list.lkey = lkey;

    struct ibv_send_wr send_wr;
    memset(&send_wr, 0, sizeof(struct ibv_send_wr));
    send_wr.wr_id = wr_id;
    send_wr.sg_list = &list;
    if (req_size != 0) send_wr.num_sge = 1;
    else send_wr.num_sge = 0;
    send_wr.opcode = IBV_WR_SEND_WITH_IMM;
    send_wr.send_flags = IBV_SEND_SIGNALED;
    send_wr.imm_data = htonl(imm_data);

    ret = ibv_post_send(qp, &send_wr, &bad_send_wr);
    if (ret != 0) {
        fprintf(stderr, "%s: ibv_post_send() failed %d\n", __func__, ret);
        return ret;
    }

    return ret;
}

int post_send_poll(uint32_t req_size, uint32_t lkey, uint64_t wr_id,
        struct ibv_qp *qp, char *buf, struct ibv_cq *cq)
{
#ifdef DH_DEBUG
    RDMA_SEND_COUNTER.fetch_add(1);
    RDMA_SEND_PAYLOAD.fetch_add((uint64_t)req_size);
#endif
    int ret = 0;
    struct ibv_send_wr *bad_send_wr;

    struct ibv_sge list;
    list.addr = (uintptr_t) buf;
    list.length = req_size;
    list.lkey = lkey;

    struct ibv_send_wr send_wr;
    memset(&send_wr, 0, sizeof(struct ibv_send_wr));
    send_wr.wr_id = wr_id;
    send_wr.sg_list = &list;
    send_wr.num_sge = 1;
    send_wr.opcode = IBV_WR_SEND;
    //        send_wr.opcode = IBV_WR_SEND_WITH_IMM;
    send_wr.send_flags = IBV_SEND_SIGNALED;
    //        send_wr.imm_data = htonl(imm_data);

    ret = ibv_post_send(qp, &send_wr, &bad_send_wr);
    if (ret != 0) {
        fprintf(stderr, "%s: ibv_post_send() failed %d\n", __func__, ret);
        return ret;
    }

    ret = poll_cq(cq);

    return ret;
}

int post_send_imm_poll(uint32_t req_size, uint32_t lkey, uint64_t wr_id,
        uint32_t imm_data, struct ibv_qp *qp, char *buf, struct ibv_cq *cq)
{
#ifdef DH_DEBUG
    RDMA_SEND_COUNTER.fetch_add(1);
    RDMA_SEND_PAYLOAD.fetch_add((uint64_t)(req_size + sizeof(uint32_t)));
#endif
    int ret = 0;
    struct ibv_send_wr *bad_send_wr;

    struct ibv_sge list;
    list.addr = (uintptr_t) buf;
    list.length = req_size;
    list.lkey = lkey;

    struct ibv_send_wr send_wr;
    memset(&send_wr, 0, sizeof(struct ibv_send_wr));
    send_wr.wr_id = wr_id;
    send_wr.sg_list = &list;
    if (req_size != 0) send_wr.num_sge = 1;
    else send_wr.num_sge = 0;
    send_wr.opcode = IBV_WR_SEND_WITH_IMM;
    send_wr.send_flags = IBV_SEND_SIGNALED;
    send_wr.imm_data = htonl(imm_data);

    ret = ibv_post_send(qp, &send_wr, &bad_send_wr);
    if (ret != 0) {
        fprintf(stderr, "%s: ibv_post_send() failed %d\n", __func__, ret);
        return ret;
    }

    ret = poll_cq(cq);

    return ret;
}

int post_recv(uint32_t req_size, uint32_t lkey, uint64_t wr_id,
        struct ibv_qp *qp, char *buf) {
    int ret = 0;
    struct ibv_recv_wr *bad_recv_wr;

    struct ibv_sge list;
    list.addr = (uintptr_t) buf;
    list.length = req_size;
    list.lkey = lkey;

    struct ibv_recv_wr recv_wr;
    memset(&recv_wr, 0, sizeof(struct ibv_recv_wr));
    recv_wr.wr_id = wr_id;
    recv_wr.sg_list = &list;
    recv_wr.num_sge = 1;

    ret = ibv_post_recv(qp, &recv_wr, &bad_recv_wr);
    return ret;
}

int post_recv_profile(uint32_t req_size, uint32_t lkey, uint64_t wr_id,
        struct ibv_qp *qp, char *buf, uint64_t *rdma_recv_counter, uint64_t *rdma_recv_payload) {
    (*rdma_recv_counter)++;
    *rdma_recv_payload = *rdma_recv_payload + (uint64_t)req_size + sizeof(uint32_t);
    int ret = 0;
    struct ibv_recv_wr *bad_recv_wr;

    struct ibv_sge list;
    list.addr = (uintptr_t) buf;
    list.length = req_size;
    list.lkey = lkey;

    struct ibv_recv_wr recv_wr;
    memset(&recv_wr, 0, sizeof(struct ibv_recv_wr));
    recv_wr.wr_id = wr_id;
    recv_wr.sg_list = &list;
    recv_wr.num_sge = 1;

    ret = ibv_post_recv(qp, &recv_wr, &bad_recv_wr);
    return ret;
}

int post_srq_recv(uint32_t req_size, uint32_t lkey, uint64_t wr_id,
        struct ibv_srq *srq, char *buf)
{
    int ret = 0;
    struct ibv_recv_wr *bad_recv_wr;

    struct ibv_sge list;
    list.addr = (uintptr_t) buf;
    list.length = req_size;
    list.lkey = lkey;

    struct ibv_recv_wr recv_wr;
    memset(&recv_wr, 0, sizeof(struct ibv_recv_wr));
    recv_wr.wr_id = wr_id;
    recv_wr.sg_list = &list;
    recv_wr.num_sge = 1;

    ret = ibv_post_srq_recv(srq, &recv_wr, &bad_recv_wr);
    return ret;
}
