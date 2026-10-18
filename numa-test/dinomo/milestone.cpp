#include "kvs/dinomo_compute.hpp"
#include <sys/stat.h>
#include <unistd.h>
#include <cstdlib>
#include <iostream>
#include <stdexcept>
#include <string>

// Disable both value and shortcut caches, and release the values handed to
// insert/update. Every post-merge successful GET must traverse the shared CLHT.
class NoCache {
public:
    NoCache(uint64_t, uint64_t, uint64_t, double) {}
    bool find(uint64_t, char *&, size_t &, uint64_t &,
              std::function<char *(char *, size_t, uint64_t)>) { return false; }
    void insert(uint64_t, char *value, size_t, uint64_t) { free(value); }
    void update(uint64_t key, char *value, size_t length, uint64_t offset)
    { insert(key, value, length, offset); }
    void remove(uint64_t) {}
    void clear() {}
};

static void expect_value(Dinomo<NoCache> &store, uint64_t key,
                         const std::string &expected)
{
    uint64_t before = dinomo_numa::read_count();
    auto actual = store.get(key, sizeof(key));
    if (!actual.first || actual.second != expected.size() ||
        std::string(actual.first, actual.second) != expected)
        throw std::runtime_error("Value mismatch for key " + std::to_string(key));
    if (dinomo_numa::read_count() <= before)
        throw std::runtime_error("GET did not read the shared pool");
}

int main(int argc, char **argv)
{
    if (argc != 5) {
        std::cerr << "Usage: " << argv[0]
                  << " NEW_POOL_PATH HOST_CPU MEMORY_NODE NUM_KEYS\n";
        return 2;
    }
    const std::string path = argv[1];
    int cpu = std::stoi(argv[2]);
    int node = std::stoi(argv[3]);
    uint64_t keys = std::stoull(argv[4]);
    if (keys == 0 || keys > 10000) {
        std::cerr << "NUM_KEYS must be between 1 and 10000\n";
        return 2;
    }
    try {
        dinomo_numa::start(path, 256UL * 1024 * 1024, cpu, node);
        Dinomo<NoCache> store(1024 * 1024, 0, false);
        for (uint64_t key = 1; key <= keys; ++key) {
            std::string value(64, static_cast<char>('a' + key % 26));
            store.put(key, sizeof(key), value.data(), value.size(), false);
        }
        store.merge(true);
        for (uint64_t key = 1; key <= keys; ++key)
            expect_value(store, key, std::string(64, static_cast<char>('a' + key % 26)));
        auto absent = store.get(keys + 1, sizeof(uint64_t));
        if (absent.first || absent.second)
            throw std::runtime_error("Missing key unexpectedly found");

        for (uint64_t key = 1; key <= keys; ++key) {
            std::string value(80, static_cast<char>('A' + key % 26));
            store.put(key, sizeof(key), value.data(), value.size(), true);
        }
        store.merge(true);
        for (uint64_t key = 1; key <= keys; ++key)
            expect_value(store, key, std::string(80, static_cast<char>('A' + key % 26)));
        dinomo_numa::verify_placement(node);
        if (keys >= 1000 && dinomo_numa::allocation_count() <= MAX_PREALLOC_NUM)
            throw std::runtime_error("Test did not force allocation-batch rollover");
        std::cout << "PASS: existing Dinomo::put/get/merge, original PMDK CLHT, "
                  << keys << " inserts + reads + updates + reads, missing key, "
                  << "log rollover and repeated allocation\n"
                  << "shared_reads=" << dinomo_numa::read_count()
                  << " shared_writes=" << dinomo_numa::write_count()
                  << " allocated_logs=" << dinomo_numa::allocation_count() << "\n";
        dinomo_numa::stop();
        return 0;
    } catch (const std::exception &error) {
        std::cerr << "FAIL: " << error.what() << "\n";
        try { dinomo_numa::stop(); }
        catch (const std::exception &cleanup) {
            std::cerr << "Cleanup: " << cleanup.what() << "\n";
        }
        return 1;
    }
}
