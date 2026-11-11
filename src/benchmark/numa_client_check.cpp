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
        const unsigned keys = argc == 2 ? std::stoul(argv[1]) : 256;
        if (argc > 2 || keys < 1 || keys > 2000)
            throw std::runtime_error("Usage: dinomo-numa-client-check [NUM_KEYS:1..2000]");
        kTierMetadata[Tier::MEMORY] = TierMetadata(Tier::MEMORY, 1, 1, 16 * 1024 * 1024);
        kTierMetadata[Tier::STORAGE] = TierMetadata(Tier::STORAGE, 0, 0, 256 * 1024 * 1024);
        KvsClient client({UserRoutingThread("127.0.0.1", 0)}, "127.0.0.1", 0, 2000, false);
        unsigned long long timestamp = 1;
        read(client, "99999999", "", true);
        const std::string meta = "ANNA_METADATA|numa-correctness";
        read(client, meta, "", true);
        write(client, meta, "metadata-v1", timestamp++, false);
        read(client, meta, "metadata-v1");
        const std::string binary_meta("metadata\0with-bytes", 19);
        write(client, meta, binary_meta, timestamp++, true);
        read(client, meta, binary_meta);

        // Every acknowledgement is followed by a GET through the existing
        // client API; the harness never sends merge or clears worker staging.
        for (unsigned key = 1; key <= keys; ++key) {
            const std::string name = std::to_string(key);
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
            read(client, std::to_string(key), std::string("latest\0binary", 13));
        read(client, "99999999", "", true);
        read(client, meta, binary_meta);
        std::cout << "PASS: existing KvsClient; " << keys
                  << " inserts, repeated updates, immediate and later reads, variable/binary values, missing keys, metadata GET/PUT/UPDATE\n";
        return 0;
    } catch (const std::exception &error) {
        std::cerr << "FAIL: " << error.what() << '\n';
        return 1;
    }
}
