#ifndef DINOMO_NUMA_BACKEND_HPP
#define DINOMO_NUMA_BACKEND_HPP

#include <cstddef>
#include <cstdint>
#include <string>

// Experimental one-worker backend. Pool references remain storage-process
// addresses for compatibility; every transfer translates them to checked
// offsets in the compute process shared mapping.
namespace dinomo_numa {
void pin_cpu(int cpu);
void start(const std::string &path, std::size_t bytes, int cpu, int memory_node);
void allocate_logs(uint64_t *addresses, std::size_t count);
void merge_logs();
void verify_placement(int expected_node);
void stop();
uint64_t read_count();
uint64_t write_count();
uint64_t allocation_count();
}
#endif
