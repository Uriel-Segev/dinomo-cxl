#ifndef DINOMO_TRACE_WORKLOAD_HPP
#define DINOMO_TRACE_WORKLOAD_HPP

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <fstream>
#include <limits>
#include <random>
#include <sstream>
#include <stdexcept>
#include <string>
#include <unordered_set>
#include <vector>

namespace dinomo_trace {

inline std::string trim(const std::string &s) {
    const auto first = s.find_first_not_of(" \t\r\n");
    return first == std::string::npos ? "" :
        s.substr(first, s.find_last_not_of(" \t\r\n") - first + 1);
}

inline std::vector<std::string> fields(const std::string &line) {
    std::vector<std::string> result;
    std::stringstream input(line);
    std::string field;
    while (std::getline(input, field, ',')) result.push_back(trim(field));
    if (!line.empty() && line.back() == ',') result.push_back("");
    return result;
}

inline unsigned integer(const std::string &s, const std::string &name,
                        bool allow_zero = false) {
    if (s.empty() || s.find_first_not_of("0123456789") != std::string::npos)
        throw std::runtime_error(name + " must be a decimal integer");
    const auto value = std::stoull(s);
    if ((!allow_zero && value == 0) || value > std::numeric_limits<unsigned>::max())
        throw std::runtime_error(name + " is out of range");
    return static_cast<unsigned>(value);
}

inline double probability(const std::string &s, const std::string &name) {
    size_t consumed = 0;
    const double value = std::stod(s, &consumed);
    if (consumed != s.size() || !std::isfinite(value) || value < 0 || value > 1)
        throw std::runtime_error(name + " must be finite and between 0 and 1");
    return value;
}

struct Phase {
    std::string name;
    unsigned duration_s;
    double read_ratio;
    unsigned hot_start;
    unsigned hot_count;
    double hot_probability;
    uint64_t start_s;
    uint64_t end_s;
};

inline std::vector<Phase> load(const std::string &path, unsigned num_keys) {
    if (num_keys == 0) throw std::runtime_error("num_keys must be positive");
    std::ifstream input(path);
    if (!input) throw std::runtime_error("cannot open trace file: " + path);
    std::vector<Phase> phases;
    std::unordered_set<std::string> names;
    std::string line;
    unsigned line_number = 0;
    bool header = false;
    uint64_t duration = 0;
    while (std::getline(input, line)) {
        ++line_number;
        line = trim(line);
        if (line.empty() || line[0] == '#') continue;
        const auto row = fields(line);
        if (!header) {
            if (row != fields("phase,duration_s,read_ratio,hot_start,hot_count,hot_probability"))
                throw std::runtime_error("invalid trace CSV header");
            header = true;
            continue;
        }
        try {
            if (row.size() != 6) throw std::runtime_error("expected six CSV fields");
            if (row[0].empty() || row[0].find_first_not_of(
                        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-") != std::string::npos)
                throw std::runtime_error("phase names must contain only letters, digits, _ or -");
            if (!names.insert(row[0]).second) throw std::runtime_error("duplicate phase name");
            Phase p{row[0], integer(row[1], "duration_s"), probability(row[2], "read_ratio"),
                integer(row[3], "hot_start"), integer(row[4], "hot_count"),
                probability(row[5], "hot_probability"), duration, 0};
            if (p.hot_start > num_keys || p.hot_count > num_keys - p.hot_start + 1)
                throw std::runtime_error("hot region exceeds the loaded keyspace");
            duration += p.duration_s;
            // Bound runtime so timeout arithmetic and chrono conversion stay safe.
            if (duration > std::numeric_limits<unsigned>::max())
                throw std::runtime_error("total trace duration is too large");
            p.end_s = duration;
            phases.push_back(p);
        } catch (const std::exception &e) {
            throw std::runtime_error("trace line " + std::to_string(line_number) + ": " + e.what());
        }
    }
    if (!input.eof()) throw std::runtime_error("error reading trace file");
    if (phases.empty()) throw std::runtime_error("trace must contain at least one phase");
    return phases;
}

inline size_t phase_at(const std::vector<Phase> &phases, double elapsed_s) {
    size_t i = 0;
    while (i < phases.size() && elapsed_s >= phases[i].end_s) ++i;
    return i;  // size() means issuance has ended.
}

class Sampler {
    std::mt19937 random_;
    double unit() { return random_() / 4294967296.0; }
    unsigned index(unsigned count) {
        // Rejection sampling avoids modulo bias and is stable across C++ libraries.
        const uint64_t limit = (uint64_t(1) << 32) / count * count;
        uint32_t value;
        do { value = random_(); } while (value >= limit);
        return value % count;
    }
 public:
    explicit Sampler(unsigned seed) : random_(seed) {}
    unsigned key(const Phase &p, unsigned num_keys) {
        return unit() < p.hot_probability ? p.hot_start + index(p.hot_count) : 1 + index(num_keys);
    }
    bool read(const Phase &p) { return unit() < p.read_ratio; }
};

}  // namespace dinomo_trace
#endif
