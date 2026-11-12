#include "client/kvs_client.hpp"
#include "kvs_threads.hpp"
#include <chrono>
#include <iostream>
#include <stdexcept>
#include <thread>

unsigned kDefaultLocalReplication = 1;
HashRingUtil hash_ring_util;
HashRingUtilInterface *kHashRingUtil = &hash_ring_util;
ZmqUtil zmq_util;
ZmqUtilInterface *kZmqUtil = &zmq_util;

static KeyResponse await(KvsClient &client, const std::string &id)
{
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(10);
    while (std::chrono::steady_clock::now() < deadline) {
        for (const auto &response : client.receive_async()) {
            if (response.response_id() != id || response.tuples_size() != 1)
                throw std::runtime_error("Unexpected client response identity or tuple count");
            if (response.error() != AnnaError::NO_ERROR)
                throw std::runtime_error("Client response error");
            return response;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    throw std::runtime_error("Client response deadline exceeded for " + id);
}

static void write(KvsClient &client, const std::string &key, const std::string &value,
                  unsigned long long timestamp, bool update)
{
    const auto payload = serialize(timestamp, value);
    const auto id = update ? client.update_async(key, payload, LatticeType::LWW) :
                             client.put_async(key, payload, LatticeType::LWW);
    const auto response = await(client, id);
    if (response.tuples(0).key() != key || response.tuples(0).error() != AnnaError::NO_ERROR)
        throw std::runtime_error("Write failed for " + key);
}

static void read(KvsClient &client, const std::string &key, const std::string &expected,
                 bool missing = false)
{
    const auto response = await(client, client.get_async_with_id(key));
    const auto &tuple = response.tuples(0);
    if (tuple.key() != key) throw std::runtime_error("Wrong response key");
    if (missing) {
        if (tuple.error() != AnnaError::KEY_DNE)
            throw std::runtime_error("Missing key was not reported: " + key);
    } else if (tuple.error() != AnnaError::NO_ERROR ||
               deserialize_lww(tuple.payload()).reveal().value != expected) {
        throw std::runtime_error("Read mismatch for " + key);
    }
}

int main(int argc, char **argv)
{
    try {
        const unsigned keys = argc >= 2 ? std::stoul(argv[1]) : 256;
        const unsigned rounds = argc >= 3 ? std::stoul(argv[2]) : 0;
        const unsigned idle_ms = argc >= 4 ? std::stoul(argv[3]) : 0;
        const unsigned workers = argc >= 5 ? std::stoul(argv[4]) : 1;
        const unsigned client_id = argc >= 6 ? std::stoul(argv[5]) : 0;
        if (argc > 6 || workers < 1 || workers > 64 || client_id >= workers || keys < 1 || keys > 2000 || rounds > 4096 || (rounds && keys % 2) || idle_ms > 10000)
            throw std::runtime_error("Usage: dinomo-numa-client-check [NUM_KEYS] [GC_ROUNDS] [IDLE_MS] [WORKERS] [CLIENT_ID]");
        auto key_name = [rounds, client_id](unsigned key) {
            // Collide in the initial CLHT table when stressing reclamation.
            return std::to_string(client_id * 10000000UL + (rounds ? 1 + 1024UL * (key - 1) : key));
        };
        kTierMetadata[Tier::MEMORY] = TierMetadata(Tier::MEMORY, workers, 1, 16 * 1024 * 1024);
        kTierMetadata[Tier::STORAGE] = TierMetadata(Tier::STORAGE, 0, 0, 256 * 1024 * 1024);
        KvsClient client({UserRoutingThread("127.0.0.1", 0)}, "127.0.0.1", client_id, 2000, false);
        unsigned long long timestamp = 1;
        read(client, "99999999", "", true);
        const std::string meta = "ANNA_METADATA|numa-correctness-" + std::to_string(client_id);
        read(client, meta, "", true);
        write(client, meta, "metadata-v1", timestamp++, false);
        read(client, meta, "metadata-v1");
        const std::string binary_meta("metadata\0with-bytes", 19);
        write(client, meta, binary_meta, timestamp++, true);
        read(client, meta, binary_meta);

        if (keys >= 4) {
            // Eight writes: with threshold >=16 and timer disabled, every read
            // here must precede the first merge. Force rollover twice to test
            // newest-record lookup within both active and retained log copies.
            write(client, key_name(1), "first", timestamp++, false);
            write(client, key_name(1), "second", timestamp++, true);
            write(client, key_name(1), "third", timestamp++, true);
            read(client, key_name(1), "third");
            write(client, key_name(2), std::string(3000, 'x'), timestamp++, false);
            write(client, key_name(3), std::string(3000, 'y'), timestamp++, false);
            read(client, key_name(1), "third");
            write(client, key_name(1), "fourth", timestamp++, true);
            write(client, key_name(1), "fifth", timestamp++, true);
            read(client, key_name(1), "fifth");
            write(client, key_name(4), std::string(3000, 'z'), timestamp++, false);
            read(client, key_name(1), "fifth");
        }

        // Every acknowledgement is followed by a GET through the existing
        // client API; the harness never sends merge or clears worker staging.
        for (unsigned key = 1; key <= keys; ++key) {
            const std::string name = key_name(key);
            const std::string first(64, 'a' + key % 26);
            const std::string second(257, 'A' + key % 26);
            const std::string third("latest\0binary", 13);
            write(client, name, first, timestamp++, false);
            read(client, name, first);
            write(client, name, second, timestamp++, true);
            read(client, name, second);
            write(client, name, third, timestamp++, true);
            read(client, name, third);
        }
        // Revisit earlier keys after many allocation batches and merge cycles.
        for (unsigned key = 1; key <= keys; ++key)
            read(client, key_name(key), std::string("latest\0binary", 13));
        if (rounds) {
            std::vector<std::string> values(keys + 1, std::string("latest\0binary", 13));
            uint64_t bytes = 0;
            for (unsigned round = 0; round < rounds; ++round) {
                for (unsigned key = keys / 2 + 1; key <= keys; ++key) {
                    values[key] = std::string(2048 + (round % 3) * 512, 'A' + key % 26);
                    const auto generation = std::to_string(round) + ":" + std::to_string(key);
                    values[key].replace(0, generation.size(), generation);
                    values[key][32] = '\0';
                    write(client, key_name(key), values[key], timestamp++, true);
                    bytes += values[key].size();
                    read(client, key_name(key), values[key]);
                }
                // Cold values must survive reuse of thousands of hot records.
                if (round % 8 == 0)
                    for (unsigned key = 1; key <= keys; ++key)
                        read(client, key_name(key), values[key]);
            }
            for (unsigned key = 1; key <= keys; ++key) read(client, key_name(key), values[key]);
            std::cout << "GC_WORKLOAD: update_bytes=" << bytes << " rounds=" << rounds
                      << " hot_keys=" << keys / 2 << '\n';
        }
        read(client, "99999999", "", true);
        read(client, meta, binary_meta);
        if (idle_ms) {
            // Drain earlier timer cycles before starting a fresh idle probe.
            std::this_thread::sleep_for(std::chrono::milliseconds(idle_ms));
            write(client, key_name(1), "timer-final", timestamp++, true);
            std::cout << "IDLE_BEGIN: monotonic_ns=" << std::chrono::duration_cast<std::chrono::nanoseconds>(
                std::chrono::steady_clock::now().time_since_epoch()).count() << std::endl;
            std::this_thread::sleep_for(std::chrono::milliseconds(idle_ms));
            std::cout << "IDLE_END: monotonic_ns=" << std::chrono::duration_cast<std::chrono::nanoseconds>(
                std::chrono::steady_clock::now().time_since_epoch()).count() << std::endl;
            read(client, key_name(1), "timer-final");
            std::cout << "IDLE_PROBE: wait_ms=" << idle_ms << '\n';
        }
        std::cout << "PASS: existing KvsClient; " << keys
                  << " inserts, repeated updates, immediate and later reads, variable/binary values, missing keys, metadata GET/PUT/UPDATE\n";
        return 0;
    } catch (const std::exception &error) {
        std::cerr << "FAIL: " << error.what() << '\n';
        return 1;
    }
}
