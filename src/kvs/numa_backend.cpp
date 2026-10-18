#include "kvs/numa_backend.hpp"
#include "kvs/ib_config.h"
#include "kvs/setup_ib.h"
#include <algorithm>
#include <atomic>
#include <cerrno>
#include <cstdio>
#include <cstring>
#include <fcntl.h>
#include <linux/mempolicy.h>
#include <sched.h>
#include <stdexcept>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <unistd.h>

ConfigInfo config_info{};
IBRes ib_res{};
clht_t *farIdx = nullptr;
uint64_t VALUE_SIZE = 64, SHORTCUT_SIZE = 16;
uint64_t MAX_LOG_BLOCK_LEN = 4096, MAX_PREALLOC_NUM = 2;
uint64_t LOG_BLOCK_HEADER_LEN = sizeof(log_block);
tbb::concurrent_queue<uint64_t> *reserved_alloc_queue = nullptr;
std::list<bloomFilter *> *filterList = nullptr;
unsigned kLogCacheLen = 10000000;
FILE *log_fp = stderr;

namespace {
enum Command : uint64_t { Allocate = 1, Merge = 2, Quit = 3 };
struct Message {
    uint64_t command = 0, count = 0, base = 0, root = 0, ok = 1;
    uint64_t addresses[64]{};
};
int control = -1;
pid_t manager = -1;
char *mapping = nullptr;
size_t mapping_size = 0;
uint64_t remote_base = 0;
uint64_t reads = 0, writes = 0, allocations = 0;
ibv_mr local_mr{};
ibv_qp *local_qps[1]{};
ibv_cq *local_cqs[1]{};
uint64_t remote_roots[1]{};
uint32_t remote_keys[1]{};

void require(bool condition, const std::string &message)
{
    if (!condition)
        throw std::runtime_error(message + ": " + std::strerror(errno));
}

void exchange_bytes(int fd, void *data, size_t size, bool sending)
{
    char *bytes = static_cast<char *>(data);
    while (size) {
        ssize_t done = sending ? send(fd, bytes, size, MSG_NOSIGNAL) :
                                 recv(fd, bytes, size, 0);
        if (done < 0 && errno == EINTR)
            continue;
        require(done > 0, "NUMA manager IPC failed");
        bytes += done;
        size -= static_cast<size_t>(done);
    }
}

Message request(Message message)
{
    exchange_bytes(control, &message, sizeof(message), true);
    exchange_bytes(control, &message, sizeof(message), false);
    require(message.ok == 1, "NUMA manager rejected request");
    return message;
}

void memory_policy(int node)
{
    require(node >= 0 && node < 1024, "Invalid memory node");
    unsigned long mask[1024 / (8 * sizeof(unsigned long))]{};
    mask[node / (8 * sizeof(unsigned long))] |=
        1UL << (node % (8 * sizeof(unsigned long)));
    require(syscall(SYS_set_mempolicy, MPOL_BIND, mask, 1024) == 0,
            "set_mempolicy");
}

void *translate(uint64_t address, size_t length)
{
    require(mapping && address >= remote_base, "Invalid NUMA pool address");
    uint64_t offset = address - remote_base;
    require(offset <= mapping_size && length <= mapping_size - offset,
            "NUMA transfer outside shared pool");
    return mapping + offset;
}

void serve(int fd, const std::string &path, size_t bytes, int cpu, int node)
{
    try {
        dinomo_numa::pin_cpu(cpu);
        memory_policy(node);
        require(setenv("DINOMO_NUMA_POOL_PATH", path.c_str(), 1) == 0, "setenv");
        farIdx = clht_create(1024, 1, 1, bytes);
        require(farIdx != nullptr, "Create PMDK pool");
        // Prefaulted tmpfs pool pages retain their remote placement; manager
        // bookkeeping allocated afterward follows the host CPU locally.
        require(syscall(SYS_set_mempolicy, MPOL_DEFAULT, nullptr, 0) == 0,
                "Restore manager allocation policy");
        clht_gc_thread_init(farIdx, 0);
        Message hello;
        hello.base = reinterpret_cast<uint64_t>(pop);
        hello.root = reinterpret_cast<uint64_t>(farIdx);
        exchange_bytes(fd, &hello, sizeof(hello), true);

        // All PMDK allocator calls stay on this single manager thread.
        // The compute process only transfers bytes to allocated log blocks.
        std::vector<uint64_t> logs;
        for (;;) {
            Message message;
            exchange_bytes(fd, &message, sizeof(message), false);
            if (message.command == Quit)
                break;
            if (message.command == Allocate) {
                require(message.count > 0 && message.count <= 64,
                        "Invalid allocation batch");
                for (size_t i = 0; i < message.count; ++i) {
                    PMEMoid oid;
                    require(pmemobj_zalloc(pop, &oid,
                            sizeof(log_block) + MAX_LOG_BLOCK_LEN, 0) == 0,
                            "Allocate PMDK log block");
                    auto *block = static_cast<log_block *>(pmemobj_direct(oid));
                    new (&block->merged_offset) std::atomic<uint32_t>(0);
                    new (&block->offset) std::atomic<uint32_t>(0);
                    new (&block->valid_counter) std::atomic<uint64_t>(0);
                    new (&block->local_invalid_counter) std::atomic<uint64_t>(0);
                    new (&block->global_invalid_counter) std::atomic<uint64_t>(0);
                    new (&block->next) std::atomic<uint64_t>(0);
                    message.addresses[i] = reinterpret_cast<uint64_t>(block);
                    logs.push_back(oid.off);
                }
            } else if (message.command == Merge) {
                // Allocation order is log order for this one-worker milestone.
                for (uint64_t offset : logs) {
                    auto *block = static_cast<log_block *>(
                        pmemobj_direct(PMEMoid{pool_uuid, offset}));
                    uint32_t position = block->merged_offset.load();
                    uint32_t end = block->offset.load();
                    require(end <= MAX_LOG_BLOCK_LEN, "Invalid log boundary");
                    while (position < end) {
                        auto *record = reinterpret_cast<oplogs *>(
                            block->buffer + position);
                        require(end - position >= sizeof(oplogs) &&
                                record->val_len <= end - position - sizeof(oplogs) &&
                                record->commit == 1, "Invalid committed log record");
                        require(record->op_type == OP_INSERT ||
                                record->op_type == OP_UPDATE,
                                "Unsupported operation in NUMA milestone");
                        uint64_t record_offset = pmemobj_oid(record).off;
                        uint64_t old = clht_update(farIdx, record->key, record_offset);
                        if (!old)
                            require(clht_put(farIdx, record->key, record_offset) != 0,
                                    "CLHT insert failed");
                        position += sizeof(oplogs) + record->val_len;
                    }
                    block->merged_offset.store(position);
                }
            } else {
                throw std::runtime_error("Unsupported NUMA control command");
            }
            exchange_bytes(fd, &message, sizeof(message), true);
        }
        pmemobj_close(pop);
        close(fd);
        _exit(0);
    } catch (const std::exception &error) {
        fprintf(stderr, "NUMA storage manager: %s\n", error.what());
        Message failure;
        failure.ok = 0;
        (void)send(fd, &failure, sizeof(failure), MSG_NOSIGNAL);
        _exit(1);
    }
}
}

namespace dinomo_numa {
void pin_cpu(int cpu)
{
    require(cpu >= 0 && cpu < CPU_SETSIZE, "Invalid host CPU");
    cpu_set_t affinity;
    CPU_ZERO(&affinity);
    CPU_SET(cpu, &affinity);
    require(sched_setaffinity(0, sizeof(affinity), &affinity) == 0,
            "Pin process to host CPU");
}

void start(const std::string &path, size_t bytes, int cpu, int memory_node)
{
    require(manager == -1, "NUMA backend already started");
    pin_cpu(cpu);
    int sockets[2];
    require(socketpair(AF_UNIX, SOCK_STREAM, 0, sockets) == 0, "socketpair");
    // Bound startup and control waits if the manager fails.
    timeval timeout{30, 0};
    for (int fd : sockets) {
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
    }
    manager = fork();
    require(manager >= 0, "fork storage manager");
    if (manager == 0) {
        close(sockets[0]);
        serve(sockets[1], path, bytes, cpu, memory_node);
    }
    close(sockets[1]);
    control = sockets[0];
    Message hello;
    exchange_bytes(control, &hello, sizeof(hello), false);
    require(hello.ok == 1, "Storage manager startup");
    remote_base = hello.base;
    int file = open(path.c_str(), O_RDWR | O_CLOEXEC);
    require(file >= 0, "Open shared PMDK pool");
    mapping_size = bytes;
    mapping = static_cast<char *>(mmap(nullptr, bytes, PROT_READ | PROT_WRITE,
                                      MAP_SHARED, file, 0));
    close(file);
    require(mapping != MAP_FAILED, "Map shared pool");
    (void)madvise(mapping, bytes, MADV_NOHUGEPAGE);

    config_info.threads_per_memory = 1;
    config_info.threads_per_storage = 1;
    config_info.num_initial_storage_nodes = 1;
    config_info.msg_size = 64 * 1024;
    config_info.rank = 0;
    ib_res.num_qps = 1;
    ib_res.qp = local_qps;
    ib_res.cq = local_cqs;
    ib_res.mr_buf = &local_mr;
    ib_res.mr_pool = &local_mr;
    ib_res.ib_buf_size = config_info.msg_size;
    ib_res.ib_buf = static_cast<char *>(calloc(1, ib_res.ib_buf_size));
    ib_res.ib_pool_size = sizeof(log_block) + MAX_LOG_BLOCK_LEN;
    ib_res.ib_pool = static_cast<char *>(calloc(1, ib_res.ib_pool_size));
    require(ib_res.ib_buf && ib_res.ib_pool, "Allocate local staging buffers");
    remote_roots[0] = hello.root;
    ib_res.raddr_pool = remote_roots;
    ib_res.rkey_pool = remote_keys;
    fprintf(stdout, "NUMA backend: compute_cpu=%d manager_cpu=%d memory_node=%d\n"
                    "storage_base=0x%lx compute_mapping=%p root_offset=0x%lx\n",
            cpu, cpu, memory_node, remote_base, static_cast<void *>(mapping),
            hello.root - remote_base);
    verify_placement(memory_node);
}

void allocate_logs(uint64_t *addresses, size_t count)
{
    Message message;
    message.command = Allocate;
    message.count = count;
    message = request(message);
    require(count <= 64, "Allocation batch too large");
    std::copy(message.addresses, message.addresses + count, addresses);
    allocations += count;
}

void merge_logs()
{
    std::atomic_thread_fence(std::memory_order_seq_cst);
    Message message;
    message.command = Merge;
    (void)request(message);
    std::atomic_thread_fence(std::memory_order_seq_cst);
}

void verify_placement(int expected_node)
{
    void *pages[256];
    int status[256];
    size_t page_size = static_cast<size_t>(sysconf(_SC_PAGESIZE));
    size_t count = std::min<size_t>(256, mapping_size / page_size);
    for (size_t i = 0; i < count; ++i) {
        size_t offset = ((i * (mapping_size / page_size)) / count) * page_size;
        pages[i] = mapping + offset;
        // Fault this process mapping before querying physical page placement.
        (void)*static_cast<volatile char *>(pages[i]);
    }
    require(syscall(SYS_move_pages, 0, count, pages, nullptr, status, 0) == 0,
            "Query shared pool placement");
    size_t matching = 0;
    for (size_t i = 0; i < count; ++i)
        matching += status[i] == expected_node;
    fprintf(stdout, "Shared pool placement: %zu/%zu pages on node %d\n",
            matching, count, expected_node);
    require(matching == count, "Shared pool placement mismatch");
}

uint64_t read_count() { return reads; }
uint64_t write_count() { return writes; }
uint64_t allocation_count() { return allocations; }

void stop()
{
    if (control >= 0) {
        Message quit;
        quit.command = Quit;
        (void)send(control, &quit, sizeof(quit), MSG_NOSIGNAL);
        close(control);
        control = -1;
    }
    if (manager > 0) {
        int status = 0;
        waitpid(manager, &status, 0);
        manager = -1;
        require(WIFEXITED(status) && WEXITSTATUS(status) == 0,
                "NUMA manager failed");
    }
    if (mapping && mapping != MAP_FAILED)
        munmap(mapping, mapping_size);
    mapping = nullptr;
    free(ib_res.ib_buf);
    free(ib_res.ib_pool);
    ib_res.ib_buf = ib_res.ib_pool = nullptr;
}
}

// The milestone target links these implementations instead of ib.cpp.
// No verbs device, memory registration, queue pair, or RDMA packet is used.
extern "C" {
int post_read_signaled_blocking_profile(uint32_t size, uint32_t, uint64_t,
        ibv_qp *, char *buffer, uint64_t address, uint32_t, ibv_cq *,
        uint64_t *counter, uint64_t *payload)
{
    memcpy(buffer, translate(address, size), size);
    ++*counter;
    *payload += size;
    ++reads;
    return 0;
}
int post_write_signaled_blocking_profile(uint32_t size, uint32_t, uint64_t,
        ibv_qp *, char *buffer, uint64_t address, uint32_t, ibv_cq *,
        uint64_t *counter, uint64_t *payload)
{
    memcpy(translate(address, size), buffer, size);
    ++*counter;
    *payload += size;
    ++writes;
    return 0;
}
int post_recv_profile(uint32_t, uint32_t, uint64_t, ibv_qp *, char *,
        uint64_t *, uint64_t *)
{
    // Allocation and merge use synchronous Unix IPC in this build.
    return 0;
}
int post_send_imm_profile(uint32_t, uint32_t, uint64_t, uint32_t,
        ibv_qp *, char *, uint64_t *, uint64_t *)
{
    throw std::runtime_error("Unsupported SEND path in one-worker NUMA milestone");
}
}
