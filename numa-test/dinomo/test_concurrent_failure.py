#!/usr/bin/env python3
"""Fault checks for owned concurrent-test processes; never offlines CPUs."""
import argparse
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import time


def exercise(root, args, mode):
    results = root / "numa-test/dinomo/results"
    results.mkdir(exist_ok=True)
    previous = set(results.glob("server-startup-*"))
    output_path = results / f"concurrent-{mode}-{time.time_ns()}.log"
    command = ["python3", str(root / "numa-test/dinomo/test_server_startup.py"),
               "--build-dir", args.build_dir, "--host-cpu", str(args.host_cpu),
               "--manager-cpu", str(args.manager_cpu), "--memory-node", str(args.memory_node),
               "--client-check", "--keys", "32", "--merge-writes", "16", "--merge-ms", "0",
               "--concurrent", "--merge-lock-delay-ms", "1000" if mode == "manager-death" else "100"]
    command += ["--workers", str(args.workers)]
    if args.worker_cpus: command += ["--worker-cpus", args.worker_cpus]
    with output_path.open("w") as output:
        process = subprocess.Popen(command, cwd=root, stdout=output, stderr=output)
        evidence = None
        try:
            deadline = time.monotonic() + 60
            while time.monotonic() < deadline:
                if process.poll() is not None:
                    raise RuntimeError("Test exited before injection: " + output_path.read_text())
                for candidate in set(results.glob("server-startup-*")) - previous:
                    if not (candidate / "processes.json").exists(): continue
                    log = (candidate / "server.log").read_text(errors="replace")
                    marker = "NUMA index reader wait" if mode == "manager-death" else "NUMA async index lock:"
                    if marker in log: evidence = candidate
                if evidence: break
                time.sleep(0.01)
            if not evidence: raise RuntimeError("Did not reach the intended race window")
            pids = json.loads((evidence / "processes.json").read_text())
            if mode == "manager-death":
                # Only kill the still-owned manager recorded by this run.
                status = Path(f"/proc/{pids['manager']}/status").read_text()
                if int(re.search(r"PPid:\s+(\d+)", status).group(1)) != pids["server"]:
                    raise RuntimeError("Manager ownership changed before injection")
                os.kill(pids["manager"], signal.SIGKILL)
            else:
                process.send_signal(signal.SIGTERM)
            code = process.wait(timeout=30)
            if code == 0: raise RuntimeError("Interrupted/failed workload unexpectedly passed")
            if any(Path(f"/proc/{pids[name]}").exists() for name in ("server", "manager", "router")):
                raise RuntimeError("An owned process survived cleanup")
            config = (evidence / "conf/dinomo-config.yml").read_text()
            pool_root = Path(re.search(r"pool-directory: (.+)", config).group(1))
            if pool_root.exists(): raise RuntimeError("Pool survived failure cleanup")
            log = (evidence / "server.log").read_text()
            if mode == "manager-death":
                if "Acquire index read lock (5s bound)" not in log:
                    raise RuntimeError("Reader lock watchdog was not exercised")
            else:
                summary = re.search(r"NUMA concurrent: started=(\d+) completed=(\d+)", log)
                if not summary or summary.group(1) != summary.group(2) or log.count("pending_writes=0") != args.workers:
                    raise RuntimeError("Interrupted shutdown did not drain the active epoch")
            (evidence / "FAULT_PASS").write_text(f"{mode}: bounded exit, manager/router cleanup, pool removal passed.\n")
            print(f"PASS: {mode}; evidence: {evidence}")
        finally:
            if process.poll() is None:
                process.terminate()
                process.wait(timeout=30)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build-dir", default="build/numa")
    parser.add_argument("--workers", type=int, default=1)
    parser.add_argument("--worker-cpus")
    parser.add_argument("--host-cpu", type=int, default=2)
    parser.add_argument("--manager-cpu", type=int, default=4)
    parser.add_argument("--memory-node", type=int, default=0)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    for mode in ("interrupt", "manager-death"):
        exercise(root, args, mode)


if __name__ == "__main__":
    main()
