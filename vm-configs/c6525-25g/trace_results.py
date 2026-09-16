#!/usr/bin/env python3
"""Extract native TRACE_RECORD JSON from a benchmark log; validate count totals."""
import argparse
import csv
import json
from pathlib import Path


def export(log, output):
    output.mkdir(parents=True, exist_ok=True)
    records = []
    for line in log.read_text().splitlines():
        if "TRACE_ERROR:" in line:
            raise ValueError(line)
        if "TRACE_RECORD " in line:
            records.append(json.loads(line.split("TRACE_RECORD ", 1)[1]))
    summaries = [r for r in records if r["record_type"] == "trace_summary"]
    if len(summaries) != 1:
        raise ValueError("expected one trace summary; rebuild and deploy the TRACE benchmark")
    summary = summaries[0]
    intervals = [r for r in records if r["record_type"] == "client_interval"]
    if not intervals:
        raise ValueError("missing client intervals")
    issued = sum(r["read_issued"] + r["update_issued"] for r in intervals)
    completed = sum(r["read_completed"] + r["update_completed"] for r in intervals)
    if issued != summary["issued"] or completed != summary["completed"]:
        raise ValueError("interval/summary counts disagree")
    if issued != completed + summary["drain_completed"] + summary["unresolved"]:
        raise ValueError("issued/completed/drain/unresolved counts disagree")
    previous_end = 0.0
    for index, row in enumerate(intervals, 1):
        if row["interval"] != index or abs(row["start_elapsed_s"] - previous_end) > 1e-6:
            raise ValueError("interval continuity failed")
        if row["duration_s"] < 0:
            raise ValueError("negative interval duration")
        for op in ("read", "update"):
            if row[f"{op}_latency_samples"] != row[f"{op}_completed"] - row[f"{op}_failed"]:
                raise ValueError("latency/completion count mismatch")
        previous_end = row["elapsed_s"]
    if abs(previous_end - summary["measurement_duration_s"]) > 1e-6:
        raise ValueError("measurement endpoint missing")
    (output / "trace.jsonl").write_text("".join(json.dumps(r) + "\n" for r in records))
    (output / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    for name, rows in (("intervals", intervals), ("phases", [r for r in records if r["record_type"] in ("phase_start", "phase_end")])):
        with (output / f"{name}.csv").open("w", newline="") as stream:
            writer = csv.DictWriter(stream, fieldnames=list(rows[0]) if rows else ["record_type"])
            writer.writeheader()
            writer.writerows(rows)
    if summary["status"] != "PASS" or completed == 0:
        raise ValueError("trace failed or had no measured completions; see summary.json")
    print(f"PASS: {summary['throughput_ops_s']:.2f} ops/s, {completed} measured completions")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("log", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    try:
        export(args.log, args.output)
    except (ValueError, KeyError, OSError) as error:
        parser.exit(1, f"ERROR: {error}\n")
