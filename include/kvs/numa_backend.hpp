#ifndef DINOMO_NUMA_BACKEND_HPP
#define DINOMO_NUMA_BACKEND_HPP

#include <cstddef>
#include <cstdint>
#include <string>
#include <utility>

// Experimental one-worker backend. Pool references remain storage-process
// addresses for compatibility; every transfer translates them to checked
// offsets in the compute process shared mapping.
namespace dinomo_numa {
void pin_cpu(int cpu);
void start(const std::string &path, std::size_t bytes, int cpu, int memory_node);
void allocate_logs(uint64_t *addresses, std::size_t count);
void merge_logs();
void put_metadata(const char *key, std::size_t key_size, const void *value, std::size_t value_size);
std::pair<bool, std::string> get_metadata(const char *key, std::size_t key_size);
void verify_placement(int expected_node);
void stop();
uint64_t read_count();
uint64_t write_count();
uint64_t allocation_count();
}
#endif
