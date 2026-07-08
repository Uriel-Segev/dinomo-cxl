#ifndef IB_H_
#define IB_H_

#include <inttypes.h>
#include <sys/types.h>
#include <endian.h>
#include <byteswap.h>
#include <infiniband/verbs.h>
#include <arpa/inet.h>

#ifdef __cplusplus
extern "C" {
#endif

/* CHANGED from IBV_MTU_4096: Soft-RoCE (software RDMA over Converged Ethernet) running
 * over a virtual Linux bridge only supports a Maximum Transmission Unit of up to 1024 bytes.
 * The original code used 4096 bytes which causes the Queue Pair transition to Ready-To-Receive
 * state to fail silently when running on Soft-RoCE. */
#define IB_MTU              IBV_MTU_1024
#define IB_PORT             1
#define IB_SL               0
#define IB_WR_ID_STOP       0xE000000000000000
#define NUM_WARMING_UP_OPS  500000
#define TOT_NUM_OPS         10000000
#define SIG_INTERVAL        1000

#if __BYTE_ORDER == __LITTLE_ENDIAN
static inline uint64_t htonll(uint64_t x) {return bswap_64(x);}
static inline uint64_t ntohll(uint64_t x) {return bswap_64(x);}
#elif __BYTE_ORDER == __BIG_ENDIAN
static inline uint64_t htonll(uint64_t x) {return x;}
static inline uint64_t ntohll(uint64_t x) {return x;}
#else
#error __BYTE_ORDER is neither __LITTLE_ENDIAN nor __BIG_ENDIAN
#endif

struct QPInfo {
    uint16_t lid;
    uint32_t qp_num;
    uint32_t rank;
    uint32_t rkey_pool;
    uint64_t raddr_pool;
    uint32_t rkey_buf;
    uint64_t raddr_buf;
    /* ADDED: 16-byte Global Identifier field for RDMA over Converged Ethernet (RoCE) and
     * Soft-RoCE. The original code only used the Local Identifier (lid) to route packets,
     * which is sufficient for physical InfiniBand hardware. RoCE and Soft-RoCE require a
     * Global Identifier to route packets over Ethernet — without it all RDMA packets are
     * silently dropped. This field is exchanged between storage and kvs during the
     * Queue Pair handshake so each side knows the other's Global Identifier. */
    uint8_t  gid[16];
} __attribute__ ((packed));

enum MsgType {
    MSG_CTL_START = 100,
    MSG_CTL_STOP,
    MSG_REGULAR,
    MSG_CTL_COMMIT,
};

/* CHANGED: added remote_gid parameter. The original signature was:
 *   modify_qp_to_rts(qp, target_qp_num, target_lid)
 * The remote Global Identifier must now be passed in so the Queue Pair transition to
 * Ready-To-Send state can configure global routing (required for RoCE and Soft-RoCE).
 * All callers in setup_ib.cpp and dinomo_storage.cpp were updated to match. */
int modify_qp_to_rts(struct ibv_qp *qp, uint32_t target_qp_num, uint16_t target_lid, union ibv_gid *remote_gid);

int poll_cq(struct ibv_cq *cq);

int post_write_signaled_blocking(uint32_t req_size, uint32_t lkey, uint64_t wr_id, 
        struct ibv_qp *qp, char *buf, uint64_t raddr, uint32_t rkey, struct ibv_cq *cq);

int post_write_signaled_blocking_profile(uint32_t req_size, uint32_t lkey, uint64_t wr_id, 
        struct ibv_qp *qp, char *buf, uint64_t raddr, uint32_t rkey, struct ibv_cq *cq,
        uint64_t *rdma_write_counter, uint64_t *rdma_write_payload);

int post_write_signaled_nonblocking(uint32_t req_size, uint32_t lkey, uint64_t wr_id, 
        struct ibv_qp *qp, char *buf, uint64_t raddr, uint32_t rkey);

int post_write_unsignaled(uint32_t req_size, uint32_t lkey, uint64_t wr_id,
        struct ibv_qp *qp, char *buf, uint64_t raddr, uint32_t rkey);

int post_cas_signaled_blocking(uint32_t req_size, uint32_t lkey, uint64_t wr_id,
        struct ibv_qp *qp, char *buf, uint64_t raddr, uint32_t rkey, struct ibv_cq *cq,
        uint64_t expected, uint64_t value);

int post_cas_signaled_blocking_profile(uint32_t req_size, uint32_t lkey, uint64_t wr_id,
        struct ibv_qp *qp, char *buf, uint64_t raddr, uint32_t rkey, struct ibv_cq *cq,
        uint64_t expected, uint64_t value, uint64_t *rdma_cas_counter, uint64_t *rdma_cas_payload);

int post_cas_signaled_nonblocking(uint32_t req_size, uint32_t lkey, uint64_t wr_id,
        struct ibv_qp *qp, char *buf, uint64_t raddr, uint32_t rkey, struct ibv_cq *cq,
        uint64_t expected, uint64_t value);

int post_fetch_add_signaled_blocking(uint32_t req_size, uint32_t lkey, uint64_t wr_id,
struct ibv_qp *qp, char *buf, uint64_t raddr, uint32_t rkey, struct ibv_cq *cq, uint64_t value);

int post_fetch_add_signaled_blocking_profile(uint32_t req_size, uint32_t lkey, uint64_t wr_id,
struct ibv_qp *qp, char *buf, uint64_t raddr, uint32_t rkey, struct ibv_cq *cq, uint64_t value,
uint64_t *rdma_faa_counter, uint64_t *rdma_faa_payload);

int post_fetch_add_signaled_nonblocking(uint32_t req_size, uint32_t lkey, uint64_t wr_id,
struct ibv_qp *qp, char *buf, uint64_t raddr, uint32_t rkey, struct ibv_cq *cq, uint64_t value);

int post_read_signaled_blocking(uint32_t req_size, uint32_t lkey, uint64_t wr_id,
        struct ibv_qp *qp, char *buf, uint64_t raddr, uint32_t rkey, struct ibv_cq *cq);

int post_read_signaled_blocking_profile(uint32_t req_size, uint32_t lkey, uint64_t wr_id,
        struct ibv_qp *qp, char *buf, uint64_t raddr, uint32_t rkey, struct ibv_cq *cq,
        uint64_t *rdma_read_counter, uint64_t *rdma_read_payload);

int post_read_signaled_nonblocking(uint32_t req_size, uint32_t lkey, uint64_t wr_id,
        struct ibv_qp *qp, char *buf, uint64_t raddr, uint32_t rkey);

int post_read_unsignaled(uint32_t req_size, uint32_t lkey, uint64_t wr_id,
        struct ibv_qp *qp, char *buf, uint64_t raddr, uint32_t rkey);

int post_send(uint32_t req_size, uint32_t lkey, uint64_t wr_id, struct ibv_qp *qp, char *buf);

int post_send_imm(uint32_t req_size, uint32_t lkey, uint64_t wr_id, uint32_t imm_data, struct ibv_qp *qp, char *buf);

int post_send_imm_profile(uint32_t req_size, uint32_t lkey, uint64_t wr_id, uint32_t imm_data, 
        struct ibv_qp *qp, char *buf, uint64_t *rdma_send_counter, uint64_t *rdma_send_payload);

int post_send_poll(uint32_t req_size, uint32_t lkey, uint64_t wr_id, struct ibv_qp *qp, char *buf, struct ibv_cq *cq);

int post_send_imm_poll(uint32_t req_size, uint32_t lkey, uint64_t wr_id, uint32_t imm_data, struct ibv_qp *qp, char *buf, struct ibv_cq *cq);

int post_recv(uint32_t req_size, uint32_t lkey, uint64_t wr_id, struct ibv_qp *qp, char *buf);

int post_recv_profile(uint32_t req_size, uint32_t lkey, uint64_t wr_id, struct ibv_qp *qp, char *buf,
        uint64_t *rdma_recv_counter, uint64_t *rdma_recv_payload);

int post_srq_recv(uint32_t req_size, uint32_t lkey, uint64_t wr_id, struct ibv_srq *srq, char *buf);

#ifdef __cplusplus
}
#endif
#endif // ib.h
