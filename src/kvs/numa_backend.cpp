#include "kvs/numa_backend.hpp"
#include "kvs/ib_config.h"
#include "kvs/setup_ib.h"
#include <algorithm>
#include <atomic>
#include <cerrno>
#include <csignal>
#include <cstdio>
#include <cstring>
#include <map>
#include <poll.h>
#include <pthread.h>
#include <fcntl.h>
#include <linux/mempolicy.h>
#include <sched.h>
#include <stdexcept>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <unistd.h>
#include <time.h>

ConfigInfo config_info{};
IBRes ib_res{};
clht_t *farIdx = nullptr;
#ifndef DINOMO_NUMA_SERVER
uint64_t VALUE_SIZE = 64, SHORTCUT_SIZE = 16;
uint64_t MAX_LOG_BLOCK_LEN = 4096, MAX_PREALLOC_NUM = 2;
uint64_t LOG_BLOCK_HEADER_LEN = sizeof(log_block);
#endif
tbb::concurrent_queue<uint64_t> *reserved_alloc_queue = nullptr;
std::list<bloomFilter *> *filterList = nullptr;
constexpr unsigned unlimited_log_cache = 10000000; // NO_LIMIT_LOG_LENGTH in compute
#ifndef DINOMO_NUMA_SERVER
unsigned kLogCacheLen = unlimited_log_cache;
#else
extern unsigned kLogCacheLen;
#endif
FILE *log_fp = stderr;

namespace {
enum Command : uint64_t { Allocate = 1, Merge = 2, Quit = 3, PutMetadata = 4, GetMetadata = 5, Release = 6, Stats = 7, AsyncMerge = 8, ReleaseEpoch = 9 };
constexpr size_t metadata_capacity = 64 * 1024;
struct Message {
    uint64_t command = 0, count = 0, base = 0, root = 0, ok = 1;
    uint64_t addresses[64]{};
    uint64_t key_size = 0, value_size = 0, found = 0;
    char data[metadata_capacity]{};
    dinomo_numa::LogStats logs;
    uint64_t epoch = 0, worker = 0;
};
constexpr size_t max_workers = 64;
size_t worker_count = 1;
std::vector<int> worker_controls;
thread_local size_t worker_id = 0;
thread_local int control = -1;
pid_t manager = -1;
char *mapping = nullptr;
size_t mapping_size = 0;
uint64_t remote_base = 0;
std::atomic<uint64_t> reads{0}, writes{0}, allocations{0};
std::atomic<uint64_t> metadata_reads{0}, metadata_writes{0};
bool reclaim_enabled = false;
thread_local dinomo_numa::LogStats latest_log_stats;
dinomo_numa::ConcurrentOptions concurrent_options;
struct SharedControl {
    pthread_rwlock_t index_lock;
    std::atomic<uint64_t> merging{0}, writer_active{0}, read_locks{0}, reader_waits{0}, writer_waits{0};
    std::atomic<uint64_t> writes_during_merge{0}, staged_reads_during_merge{0};
};
static_assert(std::atomic<uint64_t>::is_always_lock_free, "Shared counters must be lock-free");
SharedControl *shared_control = nullptr;
bool index_lock_initialized = false;
thread_local bool async_pending = false, async_complete = false;
thread_local uint64_t async_epoch = 0;
std::atomic<uint64_t> async_started{0}, async_completed{0}, ipc_backpressure{0};
thread_local std::vector<uint64_t> current_grants, sealed_grants;
ibv_mr local_mr{};
ibv_qp *local_qps[max_workers]{};
ibv_cq *local_cqs[max_workers]{};
uint64_t remote_roots[max_workers]{};
uint32_t remote_keys[max_workers]{};

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

void pause_ms(uint32_t milliseconds)
{
    timespec remaining{milliseconds / 1000, static_cast<long>(milliseconds % 1000) * 1000000};
    while (nanosleep(&remaining, &remaining) != 0 && errno == EINTR) {}
}

timespec lock_deadline()
{
    timespec deadline{};
    require(clock_gettime(CLOCK_REALTIME, &deadline) == 0, "Read lock clock");
    deadline.tv_sec += 5;
    return deadline;
}

class IndexWriteGuard {
    bool locked = false;
public:
    IndexWriteGuard() {
        if (!shared_control) return;
        int result = pthread_rwlock_trywrlock(&shared_control->index_lock);
        if (result == EBUSY) {
            ++shared_control->writer_waits;
            auto deadline = lock_deadline();
            result = pthread_rwlock_timedwrlock(&shared_control->index_lock, &deadline);
        }
        require(result == 0, "Acquire index write lock (5s bound)");
        locked = true;
    }
    ~IndexWriteGuard() { if (locked) pthread_rwlock_unlock(&shared_control->index_lock); }
};

void receive_merge_reply()
{
    Message reply;
    exchange_bytes(control, &reply, sizeof(reply), false);
    require(reply.ok == 1 && reply.command == AsyncMerge && reply.epoch == async_epoch && reply.worker == worker_id,
            "Concurrent merge failed or reply mismatched");
    latest_log_stats = reply.logs;
    async_pending = false;
    async_complete = true;
    ++async_completed;
}

Message request(Message message)
{
    message.worker = worker_id;
    if (async_pending) {
        ++ipc_backpressure;
        receive_merge_reply();
    }
    const auto command = message.command;
    exchange_bytes(control, &message, sizeof(message), true);
    exchange_bytes(control, &message, sizeof(message), false);
    require(message.ok == 1 && message.command == command && message.worker == worker_id, "NUMA manager rejected or mismatched request");
    latest_log_stats = message.logs;
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

void serve(const std::vector<int> &fds, const std::string &path, size_t bytes, int cpu, int node,
           bool reclaim, size_t block_limit)
{
    int fd = fds.front();
    try {
        dinomo_numa::pin_cpu(concurrent_options.manager_cpu >= 0 ? concurrent_options.manager_cpu : cpu);
        memory_policy(node);
        require(setenv("DINOMO_NUMA_POOL_PATH", path.c_str(), 1) == 0, "setenv");
        farIdx = clht_create(1024, 1, worker_count, bytes);
        require(farIdx != nullptr, "Create PMDK pool");
        // Prefaulted tmpfs pool pages retain their remote placement; manager
        // bookkeeping allocated afterward follows the host CPU locally.
        require(syscall(SYS_set_mempolicy, MPOL_DEFAULT, nullptr, 0) == 0,
                "Restore manager allocation policy");
        clht_gc_thread_init(farIdx, 0);
        Message hello;
        hello.base = reinterpret_cast<uint64_t>(pop);
        hello.root = reinterpret_cast<uint64_t>(farIdx);
        for (int connection : fds) exchange_bytes(connection, &hello, sizeof(hello), true);

        // All PMDK allocator calls stay on this single manager thread.
        // The compute process only transfers bytes to allocated log blocks.
        struct WorkerState {
            std::vector<uint64_t> logs, merged_epoch;
            uint64_t last_epoch = 0;
        };
        std::vector<WorkerState> workers(worker_count);
        struct BlockState { uint64_t live = 0; bool leased = true, available = false; size_t owner = 0; };
        struct Reference { uint64_t record, block; size_t owner; };
        std::map<uint64_t, BlockState> blocks;
        std::map<uint64_t, Reference> references;
        std::vector<uint64_t> available;
        dinomo_numa::LogStats stats;

        // Volatile metadata, like the original storage metadata store. This
        // allocation follows the host-local policy restored after pool creation.
        std::map<std::string, std::string> metadata;
        std::vector<pollfd> descriptors;
        for (int connection : fds) descriptors.push_back({connection, POLLIN, 0});
        size_t next_worker = 0;
        for (;;) {
            int ready;
            do { ready = poll(descriptors.data(), descriptors.size(), -1); }
            while (ready < 0 && errno == EINTR);
            require(ready > 0, "Poll worker commands");
            size_t selected_worker = next_worker;
            for (size_t n = 0; n < worker_count; ++n) {
                selected_worker = (next_worker + n) % worker_count;
                if (descriptors[selected_worker].revents) break;
            }
            next_worker = (selected_worker + 1) % worker_count;
            fd = fds[selected_worker];
            auto &logs = workers[selected_worker].logs;
            auto &merged_epoch = workers[selected_worker].merged_epoch;
            auto &last_epoch = workers[selected_worker].last_epoch;
            Message message;
            exchange_bytes(fd, &message, sizeof(message), false);
            require(message.worker == selected_worker, "Worker connection identity mismatch");
            if (message.command == Quit) {
                require(selected_worker == 0, "Only lifecycle owner may stop manager");
                exchange_bytes(fd, &message, sizeof(message), true);
                break;
            }
            const bool asynchronous = message.command == AsyncMerge;
            if (asynchronous) {
                require(shared_control && merged_epoch.empty() && message.epoch > last_epoch,
                        "Invalid concurrent merge epoch");
                shared_control->merging.store(1);
                pause_ms(concurrent_options.start_delay_ms);
            }
            {
            IndexWriteGuard index_writer;
            if (asynchronous) {
                shared_control->writer_active.store(1);
                fprintf(stderr, "NUMA async index lock: epoch=%lu\n", message.epoch);
                pause_ms(concurrent_options.merge_delay_ms);
            }
            if (message.command == Allocate) {
                require(message.count > 0 && message.count <= 64,
                        "Invalid allocation batch");
                for (size_t i = 0; i < message.count; ++i) {
                    PMEMoid oid{pool_uuid, 0};
                    if (reclaim && !available.empty()) {
                        oid.off = available.back();
                        available.pop_back();
                        auto &state = blocks.at(oid.off);
                        require(state.available && !state.leased && state.live == 0,
                                "Attempt to reuse a referenced or leased log");
                        state.available = false;
                        state.leased = true;
                        ++stats.reused_blocks;
                    } else {
                        require(block_limit == 0 || blocks.size() < block_limit,
                                "NUMA fresh log block limit reached");
                        require(pmemobj_zalloc(pop, &oid,
                                sizeof(log_block) + MAX_LOG_BLOCK_LEN, 0) == 0,
                                "Allocate PMDK log block");
                        blocks.emplace(oid.off, BlockState{});
                        ++stats.fresh_blocks;
                    }
                    blocks.at(oid.off).owner = selected_worker;
                    auto *block = static_cast<log_block *>(pmemobj_direct(oid));
                    // No index reference, staging reference, spare allocation,
                    // or log-chain reference may survive reuse. The manager is
                    // the sole allocator and resets under the index write lock.
                    memset(block->buffer, 0, MAX_LOG_BLOCK_LEN);
                    new (&block->merged_offset) std::atomic<uint32_t>(0);
                    new (&block->offset) std::atomic<uint32_t>(0);
                    new (&block->valid_counter) std::atomic<uint64_t>(0);
                    new (&block->local_invalid_counter) std::atomic<uint64_t>(0);
                    new (&block->global_invalid_counter) std::atomic<uint64_t>(0);
                    new (&block->next) std::atomic<uint64_t>(0);
                    message.addresses[i] = reinterpret_cast<uint64_t>(block);
                    logs.push_back(oid.off);
                }
            } else if (message.command == Merge || asynchronous) {
                require(asynchronous || merged_epoch.empty(), "Synchronous merge before epoch retirement");
                std::vector<uint64_t> selected = logs;
                if (asynchronous) {
                    require(message.count > 0 && message.count <= 64, "Invalid sealed batch size");
                    selected.clear();
                    for (size_t i = 0; i < message.count; ++i) {
                        require(message.addresses[i] >= reinterpret_cast<uint64_t>(pop), "Invalid sealed address");
                        uint64_t offset = message.addresses[i] - reinterpret_cast<uint64_t>(pop);
                        require(std::find(logs.begin(), logs.end(), offset) != logs.end() &&
                                std::find(selected.begin(), selected.end(), offset) == selected.end(),
                                "Unowned or duplicate sealed log");
                        selected.push_back(offset);
                    }
                    merged_epoch = selected;
                    last_epoch = message.epoch;
                }
                // Allocation order is log order within this worker.
                for (uint64_t offset : selected) {
                    require(blocks.at(offset).leased && !blocks.at(offset).available &&
                            blocks.at(offset).owner == selected_worker,
                            "Merge encountered an unleased log");
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
                        auto previous = references.find(record->key);
                        require(previous == references.end() || previous->second.owner == selected_worker,
                                "Key changed compute ownership");
                        uint64_t old = clht_update(farIdx, record->key, record_offset);
                        if (previous != references.end()) {
                            require(old == previous->second.record && old != 0,
                                    "Index/log ownership mismatch");
                            auto &owner = blocks.at(previous->second.block);
                            require(owner.live > 0, "Log reference count underflow");
                            --owner.live;
                        } else {
                            require(old == 0, "Untracked index reference");
                            require(clht_put(farIdx, record->key, record_offset) != 0,
                                    "CLHT insert failed");
                        }
                        ++blocks.at(offset).live;
                        references[record->key] = {record_offset, offset, selected_worker};
                        position += sizeof(oplogs) + record->val_len;
                    }
                    block->merged_offset.store(position);
                }
            } else if (message.command == Release || message.command == ReleaseEpoch) {
                require(reclaim, "Log release requires reclamation mode");
                auto *head = static_cast<uint64_t *>(pmemobj_direct(
                    PMEMoid{pool_uuid, farIdx->log_table_addr + selected_worker * sizeof(uint64_t)}));
                std::vector<uint64_t> retired = logs;
                if (message.command == ReleaseEpoch) {
                    require(message.epoch == last_epoch && message.count == merged_epoch.size() &&
                            !merged_epoch.empty(), "Invalid epoch release");
                    retired = merged_epoch;
                    for (size_t i = 0; i < retired.size(); ++i)
                        require(message.addresses[i] == reinterpret_cast<uint64_t>(pop) + retired[i],
                                "Epoch release addresses mismatch");
                    // Compute is blocked on this request; the new active chain
                    // is stable and must not refer to a retired batch.
                    uint64_t cursor = *head;
                    size_t visited = 0;
                    while (cursor) {
                        require(++visited <= blocks.size() && blocks.count(cursor) &&
                                blocks.at(cursor).owner == selected_worker && blocks.at(cursor).leased &&
                                std::find(retired.begin(), retired.end(), cursor) == retired.end(),
                                "Published chain references retired epoch");
                        cursor = static_cast<log_block *>(pmemobj_direct(PMEMoid{pool_uuid, cursor}))->next.load();
                    }
                } else {
                    require(merged_epoch.empty() && *head == 0, "Compute still publishes a log chain or epoch");
                }
                // Release is a quiescent point: this compute worker has
                // cleared all local references and is blocked on this reply.
                for (uint64_t offset : retired) {
                    auto *block = static_cast<log_block *>(pmemobj_direct(PMEMoid{pool_uuid, offset}));
                    require(blocks.at(offset).leased && blocks.at(offset).owner == selected_worker, "Release of unowned log");
                    require(block->merged_offset.load() == block->offset.load(),
                            "Cannot release an unmerged log");
                    blocks.at(offset).leased = false;
                    block->next.store(0);
                }
                for (uint64_t offset : retired)
                    logs.erase(std::find(logs.begin(), logs.end(), offset));
                if (message.command == ReleaseEpoch) merged_epoch.clear();
                for (auto &entry : blocks) {
                    auto &state = entry.second;
                    if (state.live == 0 && !state.leased && !state.available) {
                        state.available = true;
                        available.push_back(entry.first);
                        ++stats.reclaimed_blocks;
                    }
                }
            } else if (message.command == Stats) {
                // Reply below includes the manager's current ownership counts.
            } else {
                if (message.command != PutMetadata && message.command != GetMetadata)
                    throw std::runtime_error("Unsupported NUMA control command");
                require(message.key_size > 0 && message.key_size <= metadata_capacity &&
                        message.value_size <= metadata_capacity - message.key_size,
                        "Metadata request exceeds IPC capacity");
                std::string key(message.data, message.key_size);
                if (message.command == PutMetadata) {
                    metadata[key] = std::string(message.data + message.key_size, message.value_size);
                } else {
                    auto entry = metadata.find(key);
                    message.found = entry != metadata.end();
                    message.value_size = message.found ? entry->second.size() : 0;
                    if (message.found)
                        memcpy(message.data, entry->second.data(), message.value_size);
                }
            }
            if (asynchronous) shared_control->writer_active.store(0);
            } // IndexWriteGuard: no index mutation/reset overlaps a protected GET.
            if (asynchronous) shared_control->merging.store(0);
            stats.live_blocks = stats.leased_blocks = stats.live_records = 0;
            stats.free_blocks = available.size();
            for (const auto &entry : blocks) {
                stats.live_blocks += entry.second.live != 0;
                stats.leased_blocks += entry.second.leased;
                stats.live_records += entry.second.live;
            }
            require(stats.live_records == references.size(), "Index reference accounting mismatch");
            message.logs = stats;
            exchange_bytes(fd, &message, sizeof(message), true);
        }
        pmemobj_close(pop);
        for (int connection : fds) close(connection);
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

void start(const std::string &path, size_t bytes, int cpu, int memory_node,
           bool reclaim_logs, size_t block_limit, const ConcurrentOptions &concurrent, size_t workers)
{
    require(manager == -1, "NUMA backend already started");
    require(workers > 0 && workers <= max_workers, "NUMA supports 1..64 workers");
    require(workers == 1 || concurrent.enabled, "Multiple workers require protected concurrent mode");
    worker_count = workers;
    require(!concurrent.enabled || reclaim_logs, "Concurrent merge requires reclamation");
    require(!concurrent.enabled || kLogCacheLen == unlimited_log_cache,
            "Concurrent merge requires log-cache-len=10000000 (no premature copy pruning)");
    require(concurrent.start_delay_ms <= 1000 && concurrent.merge_delay_ms <= 1000 &&
            concurrent.read_delay_ms <= 1000, "Test delays must be <= 1000 ms");
    concurrent_options = concurrent;
    reclaim_enabled = reclaim_logs;
    pin_cpu(cpu);
    if (concurrent.enabled) {
        void *page = mmap(nullptr, sizeof(SharedControl), PROT_READ | PROT_WRITE,
                          MAP_SHARED | MAP_ANONYMOUS, -1, 0);
        require(page != MAP_FAILED, "Map process-shared index control");
        shared_control = new (page) SharedControl;
        pthread_rwlockattr_t attributes;
        require(pthread_rwlockattr_init(&attributes) == 0, "Initialize index lock attributes");
        require(pthread_rwlockattr_setpshared(&attributes, PTHREAD_PROCESS_SHARED) == 0 &&
                pthread_rwlockattr_setkind_np(&attributes, PTHREAD_RWLOCK_PREFER_WRITER_NONRECURSIVE_NP) == 0 &&
                pthread_rwlock_init(&shared_control->index_lock, &attributes) == 0,
                "Initialize process-shared index lock");
        index_lock_initialized = true;
        pthread_rwlockattr_destroy(&attributes);
    }
    std::vector<int> manager_controls;
    timeval timeout{30, 0};
    for (size_t i = 0; i < worker_count; ++i) {
        int sockets[2];
        require(socketpair(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0, sockets) == 0, "socketpair");
        worker_controls.push_back(sockets[0]);
        manager_controls.push_back(sockets[1]);
        for (int fd : sockets) {
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
        }
    }
    manager = fork();
    require(manager >= 0, "fork storage manager");
    if (manager == 0) {
        signal(SIGINT, SIG_DFL);
        signal(SIGTERM, SIG_DFL);
        for (int fd : worker_controls) close(fd);
        serve(manager_controls, path, bytes, cpu, memory_node, reclaim_logs, block_limit);
    }
    for (int fd : manager_controls) close(fd);
    control = worker_controls[0];
    Message hello;
    for (int fd : worker_controls) {
        exchange_bytes(fd, &hello, sizeof(hello), false);
        require(hello.ok == 1, "Storage manager startup");
    }
    remote_base = hello.base;
    int file = open(path.c_str(), O_RDWR | O_CLOEXEC);
    require(file >= 0, "Open shared PMDK pool");
    mapping_size = bytes;
    mapping = static_cast<char *>(mmap(nullptr, bytes, PROT_READ | PROT_WRITE,
                                      MAP_SHARED, file, 0));
    close(file);
    require(mapping != MAP_FAILED, "Map shared pool");
    (void)madvise(mapping, bytes, MADV_NOHUGEPAGE);

    config_info.threads_per_memory = worker_count;
    config_info.threads_per_storage = 1;
    config_info.num_initial_storage_nodes = 1;
    config_info.msg_size = 64 * 1024;
    config_info.rank = 0;
    ib_res.num_qps = worker_count;
    ib_res.qp = local_qps;
    ib_res.cq = local_cqs;
    ib_res.mr_buf = &local_mr;
    ib_res.mr_pool = &local_mr;
    ib_res.ib_buf_size = config_info.msg_size * worker_count;
    ib_res.ib_buf = static_cast<char *>(calloc(1, ib_res.ib_buf_size));
    ib_res.ib_pool_size = (sizeof(log_block) + MAX_LOG_BLOCK_LEN) * worker_count;
    ib_res.ib_pool = static_cast<char *>(calloc(1, ib_res.ib_pool_size));
    require(ib_res.ib_buf && ib_res.ib_pool, "Allocate local staging buffers");
    std::fill(remote_roots, remote_roots + worker_count, hello.root);
    ib_res.raddr_pool = remote_roots;
    ib_res.rkey_pool = remote_keys;
    fprintf(stdout, "NUMA backend: compute_cpu=%d manager_cpu=%d memory_node=%d\n"
                    "storage_base=0x%lx compute_mapping=%p root_offset=0x%lx\n",
            cpu, concurrent.manager_cpu >= 0 ? concurrent.manager_cpu : cpu, memory_node,
            remote_base, static_cast<void *>(mapping),
            hello.root - remote_base);
    verify_placement(memory_node);
}

void bind_worker(size_t id)
{
    require(id < worker_count && id < worker_controls.size(), "Invalid NUMA worker ID");
    worker_id = id;
    control = worker_controls[id];
}

void allocate_logs(uint64_t *addresses, size_t count)
{
    require(count > 0 && count <= 64, "Allocation batch must be between 1 and 64");
    Message message;
    message.command = Allocate;
    message.count = count;
    message = request(message);
    require(count <= 64, "Allocation batch too large");
    std::copy(message.addresses, message.addresses + count, addresses);
    if (concurrent_options.enabled)
        current_grants.insert(current_grants.end(), addresses, addresses + count);
    allocations += count;
}

bool concurrent_enabled() { return concurrent_options.enabled; }

std::vector<uint64_t> seal_grants()
{
    require(concurrent_enabled() && !async_pending && !async_complete &&
            !current_grants.empty() && current_grants.size() <= 64, "Cannot seal merge batch");
    std::vector<uint64_t> result;
    result.swap(current_grants);
    return result;
}

void begin_merge(const std::vector<uint64_t> &addresses)
{
    require(concurrent_enabled() && !async_pending && !async_complete &&
            !addresses.empty() && addresses.size() <= 64, "Concurrent batch already pending or invalid");
    sealed_grants = addresses;
    Message message;
    message.command = AsyncMerge;
    message.worker = worker_id;
    message.epoch = ++async_epoch;
    message.count = addresses.size();
    std::copy(addresses.begin(), addresses.end(), message.addresses);
    std::atomic_thread_fence(std::memory_order_seq_cst);
    exchange_bytes(control, &message, sizeof(message), true);
    async_pending = true;
    ++async_started;
}

bool poll_merge(bool wait)
{
    if (async_pending) {
        pollfd descriptor{control, POLLIN, 0};
        int ready;
        do { ready = poll(&descriptor, 1, wait ? 30000 : 0); } while (ready < 0 && errno == EINTR);
        require(ready >= 0, "Poll concurrent merge reply");
        if (!ready && !wait) return false;
        require(ready > 0, "Concurrent merge exceeded reply deadline");
        receive_merge_reply();
    }
    return async_complete;
}

const std::vector<uint64_t> &merging_logs() { return sealed_grants; }

void release_merged_logs()
{
    require(async_complete && !async_pending, "Concurrent merge is not complete");
    Message message;
    message.command = ReleaseEpoch;
    message.epoch = async_epoch;
    message.count = sealed_grants.size();
    std::copy(sealed_grants.begin(), sealed_grants.end(), message.addresses);
    std::atomic_thread_fence(std::memory_order_seq_cst);
    (void)request(message);
    sealed_grants.clear();
    async_complete = false;
}

void note_write() {
    if (shared_control && shared_control->writer_active.load()) ++shared_control->writes_during_merge;
}
void note_staged_read() {
    if (shared_control && shared_control->writer_active.load()) ++shared_control->staged_reads_during_merge;
}

IndexReadGuard::IndexReadGuard()
{
    if (!shared_control) return;
    int result = pthread_rwlock_tryrdlock(&shared_control->index_lock);
    if (result == EBUSY) {
        ++shared_control->reader_waits;
        fprintf(stderr, "NUMA index reader wait\n");
        auto deadline = lock_deadline();
        result = pthread_rwlock_timedrdlock(&shared_control->index_lock, &deadline);
    }
    require(result == 0, "Acquire index read lock (5s bound)");
    locked = true;
    ++shared_control->read_locks;
}
IndexReadGuard::~IndexReadGuard() {
    if (locked) pthread_rwlock_unlock(&shared_control->index_lock);
}
void reader_pause() { if (shared_control) pause_ms(concurrent_options.read_delay_ms); }

void merge_logs()
{
    std::atomic_thread_fence(std::memory_order_seq_cst);
#ifdef DINOMO_NUMA_SERVER
    timespec instant{};
    require(clock_gettime(CLOCK_MONOTONIC, &instant) == 0, "Read merge clock");
    fprintf(stdout, "NUMA merge request: monotonic_ns=%lld\n",
            static_cast<long long>(instant.tv_sec) * 1000000000LL + instant.tv_nsec);
#endif
    Message message;
    message.command = Merge;
    (void)request(message);
    std::atomic_thread_fence(std::memory_order_seq_cst);
}

bool reclamation_enabled() { return reclaim_enabled; }

void release_logs()
{
    require(reclaim_enabled, "Reclamation is disabled");
    std::atomic_thread_fence(std::memory_order_seq_cst);
    Message message;
    message.command = Release;
    (void)request(message);
    current_grants.clear();
}

LogStats log_stats()
{
    Message message;
    message.command = Stats;
    return request(message).logs;
}

void put_metadata(const char *key, size_t key_size, const void *value, size_t value_size)
{
    require(key && key_size > 0 && key_size <= metadata_capacity &&
            value_size <= metadata_capacity - key_size && (value || value_size == 0),
            "Invalid NUMA metadata write");
    Message message;
    message.command = PutMetadata;
    message.key_size = key_size;
    message.value_size = value_size;
    memcpy(message.data, key, key_size);
    if (value_size) memcpy(message.data + key_size, value, value_size);
    (void)request(message);
    ++metadata_writes;
}

std::pair<bool, std::string> get_metadata(const char *key, size_t key_size)
{
    require(key && key_size > 0 && key_size <= metadata_capacity, "Invalid NUMA metadata key");
    Message message;
    message.command = GetMetadata;
    message.key_size = key_size;
    memcpy(message.data, key, key_size);
    message = request(message);
    require(message.value_size <= metadata_capacity, "Invalid NUMA metadata reply");
    ++metadata_reads;
    return {message.found != 0, std::string(message.data, message.value_size)};
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
    // Called only after all compute workers have joined.
    if (mapping && mapping != MAP_FAILED && !worker_controls.empty()) {
        bind_worker(0);
        try { latest_log_stats = log_stats(); } catch (const std::exception &) {}
    }
    if (shared_control)
        fprintf(stdout, "NUMA concurrent: started=%lu completed=%lu writes_during_merge=%lu staged_reads_during_merge=%lu read_locks=%lu reader_waits=%lu writer_waits=%lu ipc_backpressure=%lu\n",
            async_started.load(), async_completed.load(), shared_control->writes_during_merge.load(),
            shared_control->staged_reads_during_merge.load(), shared_control->read_locks.load(),
            shared_control->reader_waits.load(), shared_control->writer_waits.load(), ipc_backpressure.load());
    if (mapping && mapping != MAP_FAILED)
        fprintf(stdout, "NUMA counters: shared_reads=%lu shared_writes=%lu allocated_logs=%lu metadata_gets=%lu metadata_puts=%lu\n",
                reads.load(), writes.load(), allocations.load(), metadata_reads.load(), metadata_writes.load());
    if (mapping && mapping != MAP_FAILED)
        fprintf(stdout, "NUMA GC: enabled=%d fresh_blocks=%lu reused_blocks=%lu reclaimed_blocks=%lu live_blocks=%lu free_blocks=%lu leased_blocks=%lu live_records=%lu logical_log_bytes=%lu\n",
                reclaim_enabled, latest_log_stats.fresh_blocks, latest_log_stats.reused_blocks,
                latest_log_stats.reclaimed_blocks, latest_log_stats.live_blocks,
                latest_log_stats.free_blocks, latest_log_stats.leased_blocks,
                latest_log_stats.live_records, allocations.load() * (sizeof(log_block) + MAX_LOG_BLOCK_LEN));
    bool manager_ok = true;
    if (control >= 0) {
        Message quit;
        quit.command = Quit;
        // Wait for Quit acknowledgement before closing peer connections: a
        // peer HUP must not race the manager's round-robin command selection.
        try { (void)request(quit); }
        catch (const std::exception &) { manager_ok = false; }
        control = -1;
    }
    for (int fd : worker_controls) close(fd);
    worker_controls.clear();
    if (manager > 0) {
        int status = 0;
        pid_t reaped = 0;
        // Cleanup must finish even if the manager is stuck in a request.
        for (int attempt = 0; attempt < 100; ++attempt) {
            reaped = waitpid(manager, &status, WNOHANG);
            if (reaped == manager || (reaped < 0 && errno != EINTR)) break;
            timespec pause{0, 50 * 1000 * 1000};
            nanosleep(&pause, nullptr);
        }
        bool forced = reaped == 0 || (reaped < 0 && errno == EINTR);
        if (forced) {
            kill(manager, SIGKILL);
            do { reaped = waitpid(manager, &status, 0); }
            while (reaped < 0 && errno == EINTR);
        }
        manager = -1;
        manager_ok = manager_ok && !forced && reaped > 0 && WIFEXITED(status) && WEXITSTATUS(status) == 0;
    }
    if (mapping && mapping != MAP_FAILED)
        munmap(mapping, mapping_size);
    mapping = nullptr;
    free(ib_res.ib_buf);
    free(ib_res.ib_pool);
    ib_res.ib_buf = ib_res.ib_pool = nullptr;
    if (shared_control) {
        if (index_lock_initialized) pthread_rwlock_destroy(&shared_control->index_lock);
        index_lock_initialized = false;
        munmap(shared_control, sizeof(SharedControl));
        shared_control = nullptr;
    }
    require(manager_ok, "NUMA manager failed");
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
#ifdef DINOMO_NUMA_SERVER
int post_cas_signaled_blocking_profile(uint32_t, uint32_t, uint64_t,
        ibv_qp *, char *, uint64_t, uint32_t, ibv_cq *, uint64_t, uint64_t,
        uint64_t *, uint64_t *)
{
    throw std::runtime_error("CAS/replication is unsupported by the NUMA server");
}
int post_fetch_add_signaled_blocking_profile(uint32_t, uint32_t, uint64_t,
        ibv_qp *, char *, uint64_t, uint32_t, ibv_cq *, uint64_t,
        uint64_t *, uint64_t *)
{
    throw std::runtime_error("Fetch-add/replication is unsupported by the NUMA server");
}
#endif
}
