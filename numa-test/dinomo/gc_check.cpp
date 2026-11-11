#include "kvs/dinomo_compute.hpp"
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>

class NoCache {
public:
    NoCache(uint64_t, uint64_t, uint64_t, double) {}
    bool find(uint64_t, char *&, size_t &, uint64_t &,
              std::function<char *(char *, size_t, uint64_t)>) { return false; }
    void insert(uint64_t, char *value, size_t, uint64_t) { free(value); }
    void update(uint64_t k, char *v, size_t n, uint64_t o) { insert(k, v, n, o); }
    void remove(uint64_t) {}
    void clear() {}
};

static void expect_value(Dinomo<NoCache> &store, unsigned key, const std::string &expected)
{
    auto before = dinomo_numa::read_count();
    auto result = store.get(1 + 1024UL * key, sizeof(uint64_t));
    if (!result.first || std::string(result.first, result.second) != expected ||
        dinomo_numa::read_count() == before)
        throw std::runtime_error("Shared-index value mismatch: " + std::to_string(key));
}

int main(int argc, char **argv)
{
    if (argc != 4) {
        std::cerr << "Usage: gc-check NEW_POOL_PATH HOST_CPU MEMORY_NODE\n";
        return 2;
    }
    try {
        const size_t bytes = 16UL * 1024 * 1024;
        dinomo_numa::start(argv[1], bytes, std::stoi(argv[2]), std::stoi(argv[3]), true, 24);
        Dinomo<NoCache> store(1024, 0, false);
        std::vector<std::string> expected(32);
        // All initial records share one log block, and the keys collide in the
        // initial CLHT table. Half remain cold while hot records are replaced.
        for (unsigned key = 0; key < expected.size(); ++key) {
            expected[key] = std::string(64, 'a' + key % 26);
            store.put(1 + 1024UL * key, sizeof(uint64_t), expected[key].data(), expected[key].size(), false);
        }
        store.merge(true);
        auto initial = dinomo_numa::log_stats();
        if (initial.live_blocks != 1 || initial.live_records != 32 || initial.leased_blocks != 0)
            throw std::runtime_error("Initial mixed-live block ownership was not established");
        bool rejected = false;
        try { store.merge(false); }
        catch (const std::runtime_error &) { rejected = true; }
        if (!rejected) throw std::runtime_error("Unsafe merge without cache retirement was accepted");
        for (unsigned round = 0; round < 256; ++round) {
            for (unsigned key = 16; key < expected.size(); ++key) {
                expected[key] = std::string(512 + (round % 3) * 1024, 'A' + key % 26);
                expected[key].replace(0, 12, std::to_string(round) + ":" + std::to_string(key));
                expected[key][20] = '\0';
                store.put(1 + 1024UL * key, sizeof(uint64_t), expected[key].data(), expected[key].size(), true);
                store.merge(true);
                expect_value(store, key, expected[key]);
            }
            for (unsigned key = 0; key < expected.size(); ++key) expect_value(store, key, expected[key]);
        }
        auto stats = dinomo_numa::log_stats();
        if (!stats.reused_blocks || stats.fresh_blocks > 24 || stats.leased_blocks ||
            stats.live_records != 32 || stats.live_blocks != 17 ||
            dinomo_numa::allocation_count() * (sizeof(log_block) + MAX_LOG_BLOCK_LEN) <= bytes)
            throw std::runtime_error("Reclamation did not bound physical logs beyond pool-sized allocation demand");
        dinomo_numa::verify_placement(std::stoi(argv[3]));
        std::cout << "PASS: mixed-live logs, cold keys, colliding keys, repeated address reuse, shared reads, bounded logs\n";
        dinomo_numa::stop();
        return 0;
    } catch (const std::exception &error) {
        std::cerr << "FAIL: " << error.what() << '\n';
        try { dinomo_numa::stop(); } catch (const std::exception &) {}
        return 1;
    }
}
