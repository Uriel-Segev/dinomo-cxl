#include "trace_replay.hpp"
#include <deque>
#include <iostream>

void check(bool condition, const char *message) {
    if (!condition) throw std::runtime_error(message);
}

struct TestClock {
    using duration = std::chrono::milliseconds;
    using time_point = std::chrono::time_point<TestClock, duration>;
    static time_point time;
    static time_point now() { return time; }
};
TestClock::time_point TestClock::time;

struct FakeClient {
    struct Request { std::string id; bool read; unsigned key; double issued_s; };
    std::deque<Request> pending;
    std::vector<Request> issued;
    unsigned step_ms = 250, delay_ms = 500;
    bool never_complete = false, fail = false;
    size_t peak = 0;
    std::string issue(bool read, unsigned key) {
        Request request{std::to_string(issued.size()), read, key,
            std::chrono::duration<double>(TestClock::now().time_since_epoch()).count()};
        issued.push_back(request);
        pending.push_back(request);
        peak = std::max(peak, pending.size());
        return request.id;
    }
    std::vector<dinomo_trace::Response> receive() {
        TestClock::time += std::chrono::milliseconds(step_ms);
        std::vector<dinomo_trace::Response> result;
        while (!never_complete && !pending.empty() &&
               std::chrono::duration<double>(TestClock::now().time_since_epoch()).count() >=
               pending.front().issued_s + delay_ms / 1000.0) {
            result.push_back({pending.front().id, !fail});
            pending.pop_front();
        }
        return result;
    }
    bool pending_done() { return pending.empty(); }
};

void write(const std::string &path, const std::string &text) {
    std::ofstream output(path);
    output << text;
}

int main(int argc, char **argv) {
    try {
        check(argc == 2, "usage: trace_test OUTPUT_DIRECTORY");
        const std::string root = argv[1];
        const std::string header = "phase,duration_s,read_ratio,hot_start,hot_count,hot_probability\n";
        const std::string csv = root + "/test.csv";
        write(csv, "# comment\n" + header + "reads,1,1,1,10,1\nupdates,1,0,91,10,1\n");
        const auto phases = dinomo_trace::load(csv, 100);
        check(phases.size() == 2 && phases.back().end_s == 2, "phase duration");
        check(dinomo_trace::phase_at(phases, .999) == 0 &&
              dinomo_trace::phase_at(phases, 1) == 1 &&
              dinomo_trace::phase_at(phases, 2) == 2, "phase boundary selection");
        dinomo_trace::Sampler a(42), b(42);
        for (unsigned i = 0; i < 10000; ++i) {
            const auto key = a.key(phases[0], 100);
            check(key >= 1 && key <= 10 && key == b.key(phases[0], 100), "hot range and reproducibility");
            check(a.read(phases[0]) && b.read(phases[0]), "read-only sampling");
            check(!a.read(phases[1]) && !b.read(phases[1]), "update-only sampling");
        }
        auto mixed = phases[0]; mixed.hot_probability = .9; mixed.read_ratio = .95;
        dinomo_trace::Sampler mix(7);
        unsigned hot = 0, reads = 0;
        for (unsigned i = 0; i < 100000; ++i) {
            const unsigned key = mix.key(mixed, 100);
            check(key >= 1 && key <= 100, "full keyspace bounds");
            hot += key <= 10;
            reads += mix.read(mixed);
        }
        // 90% hot selection plus the 10% uniform tail gives 91% total hot access.
        check(hot > 90000 && hot < 92000 && reads > 94000 && reads < 96000, "mixed distributions");
        mixed.hot_probability = 0;
        unsigned low = 0;
        for (unsigned i = 0; i < 10000; ++i) low += mix.key(mixed, 100) <= 50;
        check(low > 4700 && low < 5300, "uniform baseline");
        for (const auto &invalid : std::vector<std::string>{
                "bad,0,1,1,10,1\n", "bad,1,nan,1,10,1\n", "bad,1,1,95,10,1\n",
                "bad,1,1,0,10,1\n", "bad,1,1,1,10,1.1\n", "bad,1,1,1,10,1,\n",
                "bad,1,1,1,10,1\nbad,1,1,1,10,1\n", "bad,1x,1,1,10,1\n",
                "bad,4294967296,1,1,10,1\n", "bad name,1,1,1,10,1\n", ""}) {
            write(root + "/invalid.csv", header + invalid);
            bool rejected = false;
            try { dinomo_trace::load(root + "/invalid.csv", 100); }
            catch (const std::exception &) { rejected = true; }
            check(rejected, "invalid CSV rejection");
        }
        write(root + "/invalid.csv", "wrong_header\n");
        bool rejected = false;
        try { dinomo_trace::load(root + "/invalid.csv", 100); }
        catch (const std::exception &) { rejected = true; }
        check(rejected, "header rejection");
        std::vector<double> values{9, 1, 5};
        check(dinomo_trace::quantile(values, .5) == 5 && dinomo_trace::quantile(values, 1) == 9,
              "latency quantiles");

        for (const std::string scenario : {"pass", "timeout", "error", "delayed", "empty"}) {
            TestClock::time = TestClock::time_point{};
            FakeClient client;
            client.never_complete = scenario == "timeout";
            client.fail = scenario == "error";
            if (scenario == "delayed") client.step_ms = 3500;
            if (scenario == "empty") client.delay_ms = 2500;
            std::ofstream log(root + "/" + scenario + ".log");
            auto emit = [&](const std::string &json) { log << "TRACE_RECORD " << json << '\n'; };
            unsigned reports = 0;
            auto report = [&](double throughput, double avg, double min, double max, double median, double tail,
                              const dinomo_trace::KeyLatencies &keys) {
                double sum = 0;
                uint64_t count = 0;
                for (const auto &entry : keys) {
                    check(entry.first >= 1 && entry.first <= 100 && entry.second.second > 0, "feedback key identity");
                    sum += entry.second.first;
                    count += entry.second.second;
                }
                check(count > 0 && std::abs(sum / count - avg) < 1e-6, "per-key feedback latency conservation");
                check(throughput > 0 && min <= median && median <= tail && tail <= max, "monitor feedback metrics");
                ++reports;
            };
            const bool pass = dinomo_trace::replay<FakeClient, decltype(emit), decltype(report), TestClock>(
                client, phases, 100, 1, 2, 42, 2, emit, report);
            check(pass == (scenario != "timeout" && scenario != "error"), "replay status");
            check(client.peak <= 2, "outstanding limit");
            check(reports > 0 || scenario != "pass", "monitoring feedback retained");
            for (const auto &request : client.issued) {
                check(request.issued_s < 2, "no issue after deadline");
                check(request.read == (request.issued_s < 1), "operation changes at phase boundary");
                check(request.read ? request.key <= 10 : request.key >= 91, "hotspot moves at boundary");
            }
        }
        std::cout << "Trace parser, sampling, phase replay, batching, and drain tests passed\n";
        return 0;
    } catch (const std::exception &e) {
        std::cerr << e.what() << '\n';
        return 1;
    }
}
