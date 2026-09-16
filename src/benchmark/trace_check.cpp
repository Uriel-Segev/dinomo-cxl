#include "trace_workload.hpp"
#include <iostream>

// Standalone validator uses exactly the same parser as the benchmark. It has no
// DINOMO dependencies and can also be compiled directly with g++ -std=c++11.
int main(int argc, char **argv) {
    try {
        if (argc != 3) throw std::runtime_error("usage: dinomo-trace-check CSV NUM_KEYS");
        const auto phases = dinomo_trace::load(argv[1], dinomo_trace::integer(argv[2], "num_keys"));
        std::cout << phases.back().end_s << '\n';
        return 0;
    } catch (const std::exception &e) {
        std::cerr << "ERROR: " << e.what() << '\n';
        return 1;
    }
}
