#!/usr/bin/env python3
"""Regression checks for benchmark accounting; no services or NUMA setup needed."""
import json
from pathlib import Path
import tempfile
import unittest

from benchmark_results import aggregate_clients, server_diagnostics


class ResultsTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.paths = [Path(self.temp.name) / f"{i}.json" for i in range(2)]
        self.rows = [self.row(0, 99, [[10, 99]]), self.row(1, 1, [[1000, 1]])]
        self.write()

    def row(self, client, count, histogram):
        return {"schema_version": 1, "status": "PASS", "mode": "READ", "client_id": client,
                "clients": 2, "keys": 33, "value_size": 64, "duration_s": 10, "outstanding": 8,
                "issued": count, "completed": count, "drain_completed": 0, "verified_keys": 0,
                "latency_population": "issued_in_window_including_drain",
                "latency_histogram_us": histogram, "start_monotonic_ns": 1000000,
                "end_monotonic_ns": 10001000000, "observed_start_monotonic_ns": 1001000,
                "max_outstanding_observed": 8}

    def write(self):
        for path, row in zip(self.paths, self.rows):
            path.write_text(json.dumps(row))

    def aggregate(self):
        self.write()
        return aggregate_clients(self.paths, "READ", 33, 64, 10, 8, 1000000)

    def test_percentiles_weight_completions_and_exclude_drain(self):
        result = self.aggregate()
        self.assertEqual(result["throughput_ops_s"], 10)
        self.assertEqual(result["p50_latency_us"], 10)
        self.assertEqual(result["p99_latency_us"], 10)
        self.assertEqual(result["drain_completed"], 0)
        self.assertEqual(result["max_start_lateness_us"], 1)
        self.rows[0] = self.row(0, 98, [[10, 98]])
        self.rows[1] = self.row(1, 2, [[1000, 2]])
        self.assertEqual(self.aggregate()["p99_latency_us"], 1000)

    def test_drain_latencies_are_retained(self):
        self.rows[0].update(issued=101, drain_completed=2, latency_histogram_us=[[10, 99], [10000, 2]])
        result = self.aggregate()
        self.assertEqual(result["throughput_ops_s"], 10)
        self.assertEqual(result["p99_latency_us"], 10000)
        self.assertEqual(result["latency_samples"], 102)

    def test_reject_histogram_mismatch(self):
        self.rows[0]["latency_histogram_us"] = [[10, 98]]
        with self.assertRaisesRegex(ValueError, "accounting mismatch"):
            self.aggregate()

    def test_reject_duplicate_identity(self):
        self.rows[1]["client_id"] = 0
        with self.assertRaisesRegex(ValueError, "identity/configuration"):
            self.aggregate()

    def test_reject_different_windows(self):
        self.rows[1]["start_monotonic_ns"] += 1
        with self.assertRaisesRegex(ValueError, "windows differ"):
            self.aggregate()

    def test_reject_failed_or_undrained_client(self):
        for key, value in (("status", "FAIL"), ("issued", 1000)):
            with self.subTest(key=key):
                saved = self.rows[0][key]
                self.rows[0][key] = value
                with self.assertRaises(ValueError):
                    self.aggregate()
                self.rows[0][key] = saved

    def test_uneven_load_partition(self):
        for i, row in enumerate(self.rows):
            row.update(mode="LOAD", issued=0, completed=0, drain_completed=0,
                       latency_histogram_us=[], verified_keys=17-i)
        self.write()
        result = aggregate_clients(self.paths, "LOAD", 33, 64, 10, 8)
        self.assertEqual(result["verified_keys"], 33)
        self.rows[0]["verified_keys"] = 16
        self.write()
        with self.assertRaisesRegex(ValueError, "partition"):
            aggregate_clients(self.paths, "LOAD", 33, 64, 10, 8)


class DiagnosticsTest(unittest.TestCase):
    text = """Shared pool placement: 256/256 pages on node 1
NUMA merge: published_writes=33 pending_writes=0 worker=0
Shared pool placement: 256/256 pages on node 1
NUMA GC: enabled=1 fresh_blocks=10 reused_blocks=30 leased_blocks=0 live_records=33
NUMA counters: shared_reads=200 shared_writes=100 allocated_logs=40 metadata_gets=0 metadata_puts=0
NUMA stalls: allocation_rpc_ns=1000 merge_wait_ns=200 reader_wait_ns=3 writer_wait_ns=4
NUMA concurrent: started=10 completed=10 reader_waits=1 writer_waits=1
"""

    def test_valid_diagnostics_have_explicit_scope(self):
        result = server_diagnostics(self.text, 1, 33, 1, True, True)
        self.assertTrue(result["timing_categories_overlap"])
        self.assertIn("server_lifetime", result["scope"])

    def test_reject_bad_placement_leases_epochs_and_logging(self):
        cases = [self.text.replace("256/256", "255/256", 1),
                 self.text.replace("leased_blocks=0", "leased_blocks=1"),
                 self.text.replace("pending_writes=0", "pending_writes=1"),
                 self.text.replace("completed=10", "completed=9"),
                 self.text + "[DBG put] allocation\n"]
        for text in cases:
            with self.subTest(text=text), self.assertRaises(ValueError):
                server_diagnostics(text, 1, 33, 1, True, True)


if __name__ == "__main__":
    unittest.main()
