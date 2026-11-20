// Host-native LOAD -> READ/UPDATE driver. The legacy VM benchmark is unchanged.
#include "client/kvs_client.hpp"
#include "kvs_threads.hpp"
#include "trace_workload.hpp"
#include "yaml-cpp/yaml.h"
#include <chrono>
#include <fstream>
#include <iostream>
#include <map>
#include <sched.h>
#include <thread>
#include <unordered_map>

unsigned kDefaultLocalReplication = 1;
HashRingUtil hash_ring_util;
HashRingUtilInterface *kHashRingUtil = &hash_ring_util;
ZmqUtil zmq_util;
ZmqUtilInterface *kZmqUtil = &zmq_util;

using Clock = std::chrono::steady_clock;
struct Pending { Clock::time_point start; std::string key; bool read; };

int main(int argc, char **argv) {
    try {
        if (argc != 2) throw std::runtime_error("Usage: dinomo-numa-bench CONFIG.yml");
        const auto conf = YAML::LoadFile(argv[1]);
        const auto b = conf["benchmark"];
        const auto mode = b["mode"].as<std::string>();
        auto number = [&](const char *name, bool zero = false) {
            return dinomo_trace::integer(b[name].as<std::string>(), name, zero);
        };
        const unsigned keys = number("keys"), length = number("value-size");
        const unsigned clients = number("clients"), id = number("client-id", true);
        const unsigned outstanding = number("outstanding"), seconds = number("duration-s");
        const unsigned timeout = number("timeout-s"), warmup = number("warmup-s", true);
        const unsigned seed = number("seed", true);
        if ((mode != "LOAD" && mode != "VERIFY" && mode != "READ" && mode != "UPDATE") || id >= clients || clients > keys || length > 3000)
            throw std::runtime_error("Invalid mode, client partition, or value size (max 3000)");
        const unsigned workers = conf["threads"]["memory"].as<unsigned>();
        if (!workers || workers > 64 || clients > 64)
            throw std::runtime_error("Workers and clients must be in 1..64");
        kTierMetadata[Tier::MEMORY] = TierMetadata(Tier::MEMORY, workers, 1, 16 * 1024 * 1024);
        kTierMetadata[Tier::STORAGE] = TierMetadata(Tier::STORAGE, 0, 0, 256 * 1024 * 1024);
        KvsClient client({UserRoutingThread("127.0.0.1", 0)}, "127.0.0.1", id, 2000, false);
        const std::string expected(length, 'a');
        const auto value = serialize(static_cast<unsigned long long>(
            std::chrono::duration_cast<std::chrono::microseconds>(
                std::chrono::system_clock::now().time_since_epoch()).count()), expected);
        std::unordered_map<std::string, Pending> pending;
        // Exact merged quantiles to 1 us resolution, without per-operation files.
        std::map<uint64_t, uint64_t> histogram;
        uint64_t issued = 0, completed = 0, drained = 0;
        uint64_t start_ns = 0, end_ns = 0, observed_start_ns = 0, max_pending = 0;
        auto nanoseconds = [](Clock::time_point t) {
            return std::chrono::duration_cast<std::chrono::nanoseconds>(t.time_since_epoch()).count();
        };
        auto issue = [&](unsigned key, bool read, bool insert) {
            const auto name = std::to_string(key);
            const auto start = Clock::now();
            const auto rid = read ? client.get_async_with_id(name) :
                insert ? client.put_async(name, value, LatticeType::LWW) :
                         client.update_async(name, value, LatticeType::LWW);
            if (rid.empty() || !pending.emplace(rid, Pending{start, name, read}).second)
                throw std::runtime_error("Empty or duplicate request ID");
            max_pending = std::max<uint64_t>(max_pending, pending.size());
        };
        auto receive = [&](bool measure, Clock::time_point deadline) {
            for (const auto &response : client.receive_async()) {
                const auto now = Clock::now();
                const auto p = pending.find(response.response_id());
                if (p == pending.end() || response.error() != AnnaError::NO_ERROR ||
                    response.tuples_size() != 1 || response.tuples(0).error() != AnnaError::NO_ERROR ||
                    response.tuples(0).key() != p->second.key)
                    throw std::runtime_error("Unknown response, missing key, or request error");
                if (p->second.read && deserialize_lww(response.tuples(0).payload()).reveal().value != expected)
                    throw std::runtime_error("Read value mismatch");
                if (measure) {
                    if (now < deadline) {
                        ++completed;
                    } else ++drained;
                    // Retain late completions in the latency population so the
                    // end-of-window drain cannot censor the slowest requests.
                    const auto us = std::chrono::duration<double, std::micro>(now - p->second.start).count();
                    ++histogram[static_cast<uint64_t>(std::ceil(us))];
                }
                if (now - p->second.start > std::chrono::seconds(timeout))
                    throw std::runtime_error("Request exceeded timeout");
                pending.erase(p);
            }
            for (const auto &p : pending)
                if (Clock::now() - p.second.start > std::chrono::seconds(timeout))
                    throw std::runtime_error("Request deadline exceeded");
        };
        auto drain = [&](bool measure, Clock::time_point deadline) {
            const auto bound = Clock::now() + std::chrono::seconds(timeout);
            while (!pending.empty() || !client.check_all_pending_requests_done()) {
                if (Clock::now() >= bound) throw std::runtime_error("Drain deadline exceeded");
                receive(measure, deadline);
            }
        };
        // LOAD partitions cover 1..keys exactly, including uneven divisions.
        // Verify every loaded value through the network before reporting ready.
        if (mode == "LOAD" || mode == "VERIFY") {
            for (bool read : {false, true}) {
                if (mode == "VERIFY" && !read) continue;
                for (uint64_t key = id + 1; key <= keys; key += clients) {
                    while (pending.size() >= outstanding) receive(false, Clock::time_point::max());
                    issue(static_cast<unsigned>(key), read, !read);
                }
                drain(false, Clock::time_point::max());
            }
        } else {
            dinomo_trace::Sampler sampler(seed);
            dinomo_trace::Phase phase{mode, seconds, mode == "READ" ? 1.0 : 0.0, 1, keys, 0, 0, seconds};
            const auto warm_end = Clock::now() + std::chrono::seconds(warmup);
            while (Clock::now() < warm_end) {
                if (pending.size() < outstanding) issue(sampler.key(phase, keys), mode == "READ", false);
                receive(false, Clock::time_point::max());
            }
            drain(false, Clock::time_point::max());
            {
                std::ofstream ready(b["ready-file"].as<std::string>());
                ready << '\n';
                ready.close();
                if (!ready) throw std::runtime_error("Cannot write ready file");
            }
            const auto bound = Clock::now() + std::chrono::seconds(timeout);
            while (!start_ns) {
                std::ifstream go(b["go-file"].as<std::string>());
                go >> start_ns;
                if (Clock::now() >= bound) throw std::runtime_error("Start barrier deadline exceeded");
                std::this_thread::sleep_for(std::chrono::milliseconds(1));
            }
            const auto start = Clock::time_point(std::chrono::duration_cast<Clock::duration>(std::chrono::nanoseconds(start_ns)));
            if (Clock::now() > start) throw std::runtime_error("Missed synchronized start");
            std::this_thread::sleep_until(start);
            observed_start_ns = nanoseconds(Clock::now());
            max_pending = 0;
            const auto end = start + std::chrono::seconds(seconds);
            end_ns = nanoseconds(end);
            while (Clock::now() < end) {
                if (pending.size() < outstanding) {
                    const auto key = sampler.key(phase, keys);
                    if (Clock::now() >= end) break;
                    issue(key, mode == "READ", false);
                    ++issued;
                }
                receive(true, end);
            }
            drain(true, end);
            if (!completed || completed + drained != issued)
                throw std::runtime_error("No measured completions or inconsistent drain");
        }
        std::ofstream out(b["result-file"].as<std::string>());
        out << "{\"schema_version\":1,\"status\":\"PASS\",\"mode\":\"" << mode << "\",\"client_id\":" << id
            << ",\"keys\":" << keys << ",\"value_size\":" << length << ",\"clients\":" << clients
            << ",\"outstanding\":" << outstanding << ",\"seed\":" << seed
            << ",\"cpu\":" << sched_getcpu()
            << ",\"start_monotonic_ns\":" << start_ns << ",\"end_monotonic_ns\":" << end_ns
            << ",\"observed_start_monotonic_ns\":" << observed_start_ns
            << ",\"max_outstanding_observed\":" << max_pending
            << ",\"latency_population\":\"issued_in_window_including_drain\""
            << ",\"verified_keys\":" << ((mode == "LOAD" || mode == "VERIFY") ? 1 + (keys - 1 - id) / clients : 0)
            << ",\"issued\":" << issued << ",\"completed\":" << completed
            << ",\"drain_completed\":" << drained << ",\"duration_s\":" << seconds
            << ",\"latency_histogram_us\":[";
        bool first = true;
        for (const auto &bin : histogram) {
            if (!first) out << ',';
            first = false;
            out << '[' << bin.first << ',' << bin.second << ']';
        }
        out << "]}\n";
        out.close();
        if (!out) throw std::runtime_error("Cannot write benchmark result");
        std::cout << "PASS: " << mode << " client=" << id << std::endl;
        return 0;
    } catch (const std::exception &e) {
        std::cerr << "FAIL: " << e.what() << std::endl;
        return 1;
    }
}
