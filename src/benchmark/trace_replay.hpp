#ifndef DINOMO_TRACE_REPLAY_HPP
#define DINOMO_TRACE_REPLAY_HPP

#include "trace_workload.hpp"
#include <chrono>
#include <iomanip>
#include <unordered_map>

namespace dinomo_trace {

struct Response { std::string id; bool success; };
using KeyLatencies = std::unordered_map<unsigned, std::pair<double, uint64_t>>;
struct Stats {
    uint64_t issued = 0, completed = 0, failed = 0;
    std::vector<double> latency_us;
};

inline double quantile(std::vector<double> &values, double q) {
    if (values.empty()) return 0;
    const size_t index = static_cast<size_t>((values.size() - 1) * q);
    std::nth_element(values.begin(), values.begin() + index, values.end());
    return values[index];
}

inline void json_stats(std::ostream &out, const char *name, Stats &s) {
    out << ",\"" << name << "_issued\":" << s.issued
        << ",\"" << name << "_completed\":" << s.completed
        << ",\"" << name << "_failed\":" << s.failed
        << ",\"" << name << "_latency_samples\":" << s.latency_us.size();
    for (const auto &q : std::vector<std::pair<const char *, double>>{{"p50", .50}, {"p95", .95}, {"p99", .99}}) {
        out << ",\"" << name << "_" << q.first << "_latency_us\":";
        if (s.latency_us.empty()) out << "null";
        else out << quantile(s.latency_us, q.second);
    }
}

// Client adapter: issue(read, key) -> request ID; receive() -> terminal responses;
// pending_done() -> native client state. Emit retains JSON records, report sends
// existing monitor feedback. Clock injection makes deadline/drain tests deterministic.
template <class Client, class Emit, class Report, class Clock = std::chrono::steady_clock>
bool replay(Client &client, const std::vector<Phase> &phases, unsigned num_keys,
            unsigned report_period, unsigned max_outstanding, unsigned seed,
            unsigned drain_timeout_s, Emit emit, Report report) {
    if (phases.empty() || !num_keys || !report_period || !max_outstanding || !drain_timeout_s)
        throw std::runtime_error("trace parameters must be positive");
    if (!client.pending_done()) throw std::runtime_error("client has pending requests before TRACE");
    using Point = typename Clock::time_point;
    struct Pending { Point issued; bool read; unsigned key; };
    std::unordered_map<std::string, Pending> pending;
    Sampler sampler(seed);
    Stats reads, updates;
    KeyLatencies key_latencies;
    uint64_t total_issued = 0, total_completed = 0, total_failed = 0, drain_completed = 0;
    uint64_t unknown_responses = 0;
    const auto start = Clock::now();
    const auto deadline = start + std::chrono::seconds(phases.back().end_s);
    auto interval_start = start;
    size_t phase = 0;
    unsigned interval = 1;
    auto seconds = [&](Point t) { return std::chrono::duration<double>(t - start).count(); };
    auto record = [&](const char *type, Point t) {
        std::ostringstream out;
        out << std::setprecision(12) << "{\"schema_version\":1,\"record_type\":\"" << type
            << "\",\"elapsed_s\":" << seconds(t);
        return out.str();
    };
    auto boundary = [&](const char *type, size_t i, Point t) {
        const auto scheduled = start + std::chrono::seconds(
            std::string(type) == "phase_start" ? phases[i].start_s : phases[i].end_s);
        emit(record(type, scheduled) + ",\"observed_elapsed_s\":" + std::to_string(seconds(t)) +
            ",\"phase\":\"" + phases[i].name +
            "\",\"scheduled_start_s\":" + std::to_string(phases[i].start_s) +
            ",\"scheduled_end_s\":" + std::to_string(phases[i].end_s) + "}");
    };
    auto flush = [&](Point end, bool final_partial) {
        const double duration = std::chrono::duration<double>(end - interval_start).count();
        const uint64_t completed = reads.completed + updates.completed;
        std::ostringstream out;
        out << record("client_interval", end) << std::setprecision(12)
            << ",\"interval\":" << interval++ << ",\"phase\":\"" << phases[phase].name
            << "\",\"start_elapsed_s\":" << seconds(interval_start)
            << ",\"duration_s\":" << duration << ",\"final_partial\":" << (final_partial ? "true" : "false")
            << ",\"throughput_ops_s\":" << (duration > 0 ? completed / duration : 0)
            << ",\"outstanding\":" << pending.size();
        json_stats(out, "read", reads);
        json_stats(out, "update", updates);
        out << "}";
        emit(out.str());
        std::vector<double> latency = reads.latency_us;
        latency.insert(latency.end(), updates.latency_us.begin(), updates.latency_us.end());
        if (!latency.empty() && duration > 0) {
            double sum = 0;
            for (double value : latency) sum += value;
            report(completed / duration, sum / latency.size(), quantile(latency, 0),
                   quantile(latency, 1), quantile(latency, .5), quantile(latency, .99), key_latencies);
        }
        reads = Stats{};
        updates = Stats{};
        key_latencies.clear();
        interval_start = end;
    };
    boundary("phase_start", phase, start);
    while (true) {
        auto now = Clock::now();
        if (now >= deadline) break;
        // Split intervals at every phase boundary, including phases skipped by a
        // delayed poll. Outstanding requests remain live across transitions.
        while (now >= start + std::chrono::seconds(phases[phase].end_s)) {
            flush(start + std::chrono::seconds(phases[phase].end_s), true);
            boundary("phase_end", phase, now);
            ++phase;
            boundary("phase_start", phase, now);
        }
        if (std::chrono::duration<double>(now - interval_start).count() >= report_period)
            flush(now, false);
        if (pending.size() < max_outstanding) {
            const auto key = sampler.key(phases[phase], num_keys);
            const bool read = sampler.read(phases[phase]);
            // Check again after reporting/sampling; never issue at/after deadline.
            now = Clock::now();
            if (now >= deadline) break;
            if (now >= start + std::chrono::seconds(phases[phase].end_s)) continue;
            const std::string id = client.issue(read, key);
            if (id.empty() || !pending.emplace(id, Pending{now, read, key}).second)
                throw std::runtime_error("client returned an empty or duplicate request ID");
            ++(read ? reads : updates).issued;
            ++total_issued;
        }
        for (const auto &response : client.receive()) {
            const auto end = Clock::now();
            const auto found = pending.find(response.id);
            if (found == pending.end()) { ++unknown_responses; continue; }
            if (end >= deadline) {
                ++drain_completed;
                if (!response.success) ++total_failed;
            } else {
                // Attribute intervals to completion time and operations to issue
                // identity, including responses from an earlier phase.
                while (end >= start + std::chrono::seconds(phases[phase].end_s)) {
                    flush(start + std::chrono::seconds(phases[phase].end_s), true);
                    boundary("phase_end", phase, end);
                    ++phase;
                    boundary("phase_start", phase, end);
                }
                Stats &s = found->second.read ? reads : updates;
                ++s.completed;
                ++total_completed;
                if (!response.success) { ++s.failed; ++total_failed; }
                else {
                    const double latency = std::chrono::duration<double, std::micro>(end - found->second.issued).count();
                    s.latency_us.push_back(latency);
                    auto &key_latency = key_latencies[found->second.key];
                    key_latency.first += latency;
                    ++key_latency.second;
                }
            }
            pending.erase(found);
        }
    }
    const auto measurement_end = Clock::now();
    // Finish phases even if the client stalled across multiple boundaries.
    while (phase + 1 < phases.size()) {
        flush(start + std::chrono::seconds(phases[phase].end_s), true);
        boundary("phase_end", phase, measurement_end);
        ++phase;
        boundary("phase_start", phase, measurement_end);
    }
    flush(deadline, true);
    boundary("phase_end", phase, measurement_end);
    const auto outstanding_at_deadline = pending.size() + drain_completed;
    emit(record("measurement_end", deadline) + ",\"observed_elapsed_s\":" +
         std::to_string(seconds(measurement_end)) + ",\"scheduled_end_s\":" +
         std::to_string(phases.back().end_s) + ",\"outstanding_at_deadline\":" +
         std::to_string(outstanding_at_deadline) + "}");
    emit(record("drain_start", deadline) + ",\"observed_elapsed_s\":" +
         std::to_string(seconds(measurement_end)) + "}");
    const auto drain_deadline = measurement_end + std::chrono::seconds(drain_timeout_s);
    while ((!pending.empty() || !client.pending_done()) && Clock::now() < drain_deadline) {
        for (const auto &response : client.receive()) {
            const auto found = pending.find(response.id);
            if (found == pending.end()) { ++unknown_responses; continue; }
            ++drain_completed;
            if (!response.success) ++total_failed;
            pending.erase(found);
        }
    }
    const auto end = Clock::now();
    const bool drained = pending.empty() && client.pending_done();
    emit(record("drain_end", end) + ",\"unresolved\":" + std::to_string(pending.size()) +
         ",\"drain_timeout\":" + (drained ? "false" : "true") + "}");
    std::ostringstream summary;
    summary << record("trace_summary", end) << ",\"measurement_duration_s\":" << phases.back().end_s
            << ",\"issued\":" << total_issued << ",\"completed\":" << total_completed
            << ",\"failed_including_drain\":" << total_failed
            << ",\"drain_completed\":" << drain_completed << ",\"unresolved\":" << pending.size()
            << ",\"unknown_responses\":" << unknown_responses
            << ",\"throughput_ops_s\":" << double(total_completed) / phases.back().end_s
            << ",\"status\":\"" << (drained && !total_failed && !unknown_responses ? "PASS" : "FAIL") << "\"}";
    emit(summary.str());
    return drained && !total_failed && !unknown_responses;
}

}  // namespace dinomo_trace
#endif
