"""Validate NUMA benchmark evidence and merge completion-weighted histograms."""
from collections import Counter
import json
import re


def integer(value, name, minimum=0):
    if type(value) is not int or value < minimum:
        raise ValueError(f"Invalid {name}: {value!r}")
    return value


def aggregate_clients(paths, mode, keys, value_size, duration, outstanding, start_ns=0):
    histogram = Counter()
    issued = completed = drained = verified = 0
    lateness = []
    max_pending = []
    for client_id, path in enumerate(paths):
        data = json.loads(path.read_text())
        expected = {"schema_version": 1, "status": "PASS", "mode": mode,
                    "client_id": client_id, "clients": len(paths), "keys": keys,
                    "value_size": value_size, "duration_s": duration, "outstanding": outstanding}
        if any(data.get(k) != v for k, v in expected.items()):
            raise ValueError(f"Client result identity/configuration mismatch: {path}")
        n = integer(data.get("completed"), "completed")
        i = integer(data.get("issued"), "issued")
        d = integer(data.get("drain_completed"), "drain_completed")
        v = integer(data.get("verified_keys"), "verified_keys")
        bins = Counter()
        for bucket, count in data["latency_histogram_us"]:
            bucket = integer(bucket, "latency bucket")
            bins[bucket] += integer(count, "bucket count", 1)
        if sum(bins.values()) != i or i != n + d:
            raise ValueError(f"Client completion/histogram accounting mismatch: {path}")
        measured = mode in ("READ", "UPDATE")
        if measured:
            if data.get("latency_population") != "issued_in_window_including_drain":
                raise ValueError(f"Unknown latency population: {path}")
            end_ns = start_ns + duration * 1_000_000_000
            if not start_ns or data.get("start_monotonic_ns") != start_ns or data.get("end_monotonic_ns") != end_ns:
                raise ValueError(f"Client measurement windows differ: {path}")
            actual = integer(data.get("observed_start_monotonic_ns"), "observed start", start_ns)
            if actual >= end_ns or not n:
                raise ValueError(f"Client missed measurement window: {path}")
            lateness.append((actual - start_ns) / 1000)
        elif v != 1 + (keys - 1 - client_id) // len(paths) or i or bins:
            raise ValueError(f"Incomplete LOAD/VERIFY partition: {path}")
        pending = integer(data.get("max_outstanding_observed"), "max outstanding", 1)
        if pending > outstanding:
            raise ValueError(f"Client exceeded outstanding limit: {path}")
        max_pending.append(pending)
        histogram.update(bins)
        issued += i
        completed += n
        drained += d
        verified += v
    if not paths:
        raise ValueError("No client results")

    def percentile(percent):
        rank = (issued * percent + 99) // 100
        cumulative = 0
        for bucket, count in sorted(histogram.items()):
            cumulative += count
            if cumulative >= rank:
                return bucket
        raise ValueError("Empty measured histogram")

    result = {"status": "PASS", "mode": mode, "clients": len(paths), "issued": issued,
              "completed": completed, "drain_completed": drained, "verified_keys": verified,
              "max_outstanding_observed_by_client": max_pending}
    if mode in ("READ", "UPDATE"):
        result.update({"duration_s": duration, "throughput_ops_s": completed / duration,
                       "latency_population": "issued_in_window_including_drain", "latency_samples": issued,
                       "p50_latency_us": percentile(50), "p99_latency_us": percentile(99),
                       "max_start_lateness_us": max(lateness),
                       "start_monotonic_ns": start_ns,
                       "end_monotonic_ns": start_ns + duration * 1_000_000_000,
                       "latency_histogram_us": sorted(histogram.items())})
    return result


def server_diagnostics(text, workers, keys, memory_node, timed, concurrent, min_published_writes=0):
    def counters(label):
        rows = re.findall(r"^" + re.escape(label) + r": (.+)$", text, re.MULTILINE)
        if len(rows) != 1:
            raise ValueError(f"Missing/duplicate {label} summary")
        return {k: int(v) for k, v in re.findall(r"([a-z_]+)=(\d+)", rows[0])}

    merge = [{k: int(v) for k, v in re.findall(r"([a-z_]+)=(\d+)", row)}
             for row in re.findall(r"^NUMA merge: (.+)$", text, re.MULTILINE)]
    if len(merge) != workers or {m.get("worker") for m in merge} != set(range(workers)):
        raise ValueError("Missing worker drain summaries")
    if any(m.get("pending_writes") != 0 for m in merge):
        raise ValueError("Worker has pending writes")
    if sum(m.get("published_writes", 0) for m in merge) < min_published_writes:
        raise ValueError("Missing server-side write publication evidence")
    gc = counters("NUMA GC")
    if gc.get("enabled") != 1 or gc.get("leased_blocks") != 0 or gc.get("live_records") != keys:
        raise ValueError("GC lease/live-record accounting failed")
    placements = re.findall(r"Shared pool placement: (\d+)/(\d+) pages on node (\d+)", text)
    if len(placements) != 2 or any(int(a) != int(b) or int(a) == 0 or int(n) != memory_node for a, b, n in placements):
        raise ValueError("Startup/shutdown pool placement checks failed")
    if any(marker in text for marker in ("[DBG put]", "NUMA async index lock:", "NUMA merge request:", "NUMA index reader wait")):
        raise ValueError("Per-operation diagnostics were enabled during benchmark")
    result = {"scope": "server_lifetime_including_load_warmup_verify_shutdown",
              "timing_categories_overlap": True, "gc": gc, "workers": merge,
              "pool_operations": counters("NUMA counters")}
    if not result["pool_operations"].get("shared_reads") or not result["pool_operations"].get("shared_writes"):
        raise ValueError("Missing shared-pool operation evidence")
    if concurrent:
        c = counters("NUMA concurrent")
        if c.get("started") != c.get("completed"):
            raise ValueError("Async epochs did not drain")
        result["concurrent"] = c
    if timed:
        result["stalls_ns"] = counters("NUMA stalls")
        if set(result["stalls_ns"]) != {"allocation_rpc_ns", "merge_wait_ns", "reader_wait_ns", "writer_wait_ns"}:
            raise ValueError("Incomplete timing summary")
    return result
