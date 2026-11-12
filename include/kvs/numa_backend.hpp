#ifndef DINOMO_NUMA_BACKEND_HPP
#define DINOMO_NUMA_BACKEND_HPP

#include <cstddef>
#include <cstdint>
#include <string>
#include <utility>
#include <vector>

// Experimental fixed-owner worker backend. Pool references remain storage-process
// addresses for compatibility; every transfer translates them to checked
// offsets in the compute process shared mapping.
namespace dinomo_numa {
void pin_cpu(int cpu);
struct LogStats {
    uint64_t fresh_blocks = 0, reused_blocks = 0, reclaimed_blocks = 0;
    uint64_t live_blocks = 0, free_blocks = 0, leased_blocks = 0, live_records = 0;
};
struct ConcurrentOptions {
    bool enabled = false;
    int manager_cpu = -1;
    uint32_t start_delay_ms = 0, merge_delay_ms = 0, read_delay_ms = 0;
};
void start(const std::string &path, std::size_t bytes, int cpu, int memory_node,
           bool reclaim_logs = false, std::size_t block_limit = 0,
           const ConcurrentOptions &concurrent = {}, std::size_t workers = 1);
// Bind each compute thread before using its buffers, grants, or manager channel.
void bind_worker(std::size_t id);
bool concurrent_enabled();
std::vector<uint64_t> seal_grants();
void begin_merge(const std::vector<uint64_t> &addresses);
bool poll_merge(bool wait = false);
const std::vector<uint64_t> &merging_logs();
void release_merged_logs();
void note_write();
void note_staged_read();
void reader_pause();
class IndexReadGuard {
    bool locked = false;
public:
    IndexReadGuard();
    ~IndexReadGuard();
    IndexReadGuard(const IndexReadGuard &) = delete;
    IndexReadGuard &operator=(const IndexReadGuard &) = delete;
};
void allocate_logs(uint64_t *addresses, std::size_t count);
void merge_logs();
bool reclamation_enabled();
// Only after caches, staging, log addresses, and the shared mapping slot are cleared.
void release_logs();
LogStats log_stats();
void put_metadata(const char *key, std::size_t key_size, const void *value, std::size_t value_size);
std::pair<bool, std::string> get_metadata(const char *key, std::size_t key_size);
void verify_placement(int expected_node);
void stop();
uint64_t read_count();
uint64_t write_count();
uint64_t allocation_count();
}
#endif
