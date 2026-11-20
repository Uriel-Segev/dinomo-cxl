#!/usr/bin/env python3
"""Exercise launcher failures, cleanup, and synchronous/no-timing fallback."""
import argparse
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build-dir", default="build/numa")
    parser.add_argument("--worker-cpu", type=int, default=2)
    parser.add_argument("--manager-cpu", type=int, default=4)
    parser.add_argument("--router-cpu", type=int, default=0)
    parser.add_argument("--client-cpus", default="1,3")
    args = parser.parse_args()
    results = ROOT / "numa-test/dinomo/results"
    results.mkdir(exist_ok=True)
    evidence = Path(tempfile.mkdtemp(prefix="launcher-check-", dir=results))
    print(f"Evidence: {evidence}", flush=True)
    command = ["python3", str(ROOT / "numa-test/dinomo/run_benchmark.py"),
               "--build-dir", args.build_dir, "--worker-cpus", str(args.worker_cpu),
               "--manager-cpu", str(args.manager_cpu), "--router-cpu", str(args.router_cpu),
               "--client-cpus", args.client_cpus, "--memory-nodes", "0", "--keys", "33",
               "--pool-mb", "32", "--outstanding", "8", "--warmup-s", "0", "--timeout-s", "5"]

    def exercise(name, extra, expected_code, injection=None):
        case = evidence / name
        with (evidence / f"{name}.log").open("w") as output:
            process = subprocess.Popen(command + ["--results-dir", str(case)] + extra,
                                       cwd=ROOT, stdout=output, stderr=output)
        try:
            if injection:
                deadline = time.monotonic() + 30
                go = None
                while time.monotonic() < deadline:
                    matches = list(case.glob("benchmark-*/w*/measure/go"))
                    if matches:
                        go = matches[0]
                        break
                    if process.poll() is not None:
                        raise RuntimeError(f"{name} exited before injection")
                    time.sleep(.02)
                if go is None:
                    raise RuntimeError(f"{name} never reached the measured phase")
                start = int(go.read_text())
                while time.monotonic_ns() < start + 200_000_000:
                    time.sleep(.01)
                if injection == "interrupt":
                    process.send_signal(signal.SIGTERM)
                else:
                    pids = json.loads((go.parent.parent / "processes.json").read_text())
                    status = Path(f"/proc/{pids['manager']}/status").read_text()
                    ppid = next(line.split()[1] for line in status.splitlines() if line.startswith("PPid:"))
                    if int(ppid) != pids["server"]:
                        raise RuntimeError("Manager ownership changed before fault injection")
                    os.kill(pids["manager"], signal.SIGKILL)
            code = process.wait(timeout=45)
            if code != expected_code:
                raise RuntimeError(f"{name}: unexpected exit {code}; see {evidence / (name + '.log')}")
        finally:
            if process.poll() is None:
                process.terminate()
                process.wait(timeout=40)
        runs = list(case.glob("benchmark-*"))
        if len(runs) != 1:
            raise RuntimeError(f"{name}: missing evidence directory")
        run = runs[0]
        summary = json.loads((run / "summary.json").read_text())
        expected_status = "PASS" if expected_code == 0 else "FAIL"
        if summary["status"] != expected_status or not (run / expected_status).exists():
            raise RuntimeError(f"{name}: wrong summary status")
        if expected_code and (run / "PASS").exists():
            raise RuntimeError(f"{name}: failed workload published PASS")
        for cleanup in run.glob("w*/cleanup.json"):
            if json.loads(cleanup.read_text())["status"] != "PASS":
                raise RuntimeError(f"{name}: cleanup failed")
        for config in run.glob("w*/server.json"):
            pool = Path(json.loads(config.read_text())["numa"]["pool-directory"])
            if pool.exists():
                raise RuntimeError(f"{name}: private pool survived cleanup")
        for commands in run.glob("w*/commands.jsonl"):
            for line in commands.read_text().splitlines():
                pid = json.loads(line)["pid"]
                if Path(f"/proc/{pid}").exists():
                    raise RuntimeError(f"{name}: owned process {pid} survived cleanup")
        for path in run.glob("w*/processes.json"):
            manager = json.loads(path.read_text())["manager"]
            if Path(f"/proc/{manager}").exists():
                raise RuntimeError(f"{name}: manager survived cleanup")
        print(f"PASS: {name}", flush=True)
        return summary

    # A foreign listener must be left untouched, without starting a deployment.
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 6400))
        listener.listen()
        exercise("occupied-port", ["--duration-s", "1", "--modes", "READ"], 1)
        if listener.getsockname()[1] != 6400:
            raise RuntimeError("Foreign listener was changed")
    summary = exercise("synchronous-no-timing", ["--duration-s", "1", "--synchronous",
                                                "--no-stall-timing", "--modes", "READ", "UPDATE"], 0)
    if any("stalls_ns" in run["diagnostics"] for run in summary["runs"]):
        raise RuntimeError("Timing-disabled run emitted timing results")
    exercise("interrupt", ["--duration-s", "20", "--modes", "READ"], 130, "interrupt")
    exercise("manager-death", ["--duration-s", "20", "--modes", "UPDATE"], 1, "manager-death")
    (evidence / "PASS").write_text("Port isolation, fallback, timing disable, interruption, manager death and cleanup passed.\n")


if __name__ == "__main__":
    main()
