#!/usr/bin/env python3
"""Smoke-test the NUMA benchmark client; these short runs are not benchmarks."""
import argparse
import json
from pathlib import Path
import re
import signal
import subprocess
import tempfile
import time

from test_server_startup import wait_for


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build-dir", default="build/numa")
    parser.add_argument("--worker-cpus", default="2")
    parser.add_argument("--manager-cpu", type=int, default=4)
    parser.add_argument("--client-cpu", type=int, default=6)
    parser.add_argument("--memory-node", type=int, default=0)
    parser.add_argument("--synchronous", action="store_true")
    args = parser.parse_args()
    cpus = [int(cpu) for cpu in args.worker_cpus.split(",")]
    if args.synchronous and len(cpus) != 1:
        parser.error("Synchronous mode requires one worker")
    root = Path(__file__).resolve().parents[2]
    build = (root / args.build_dir).resolve()
    bench = build / "target/benchmark/dinomo-numa-bench"
    server_bin = build / "target/kvs/dinomo-kvs-numa"
    route_bin = build / "target/kvs/dinomo-route"
    for binary in (bench, server_bin, route_bin):
        if not binary.is_file():
            parser.error(f"Build target first: {binary}")
    results = root / "numa-test/dinomo/results"
    results.mkdir(exist_ok=True)
    evidence = Path(tempfile.mkdtemp(prefix="benchmark-client-", dir=results))
    pool = Path(tempfile.mkdtemp(prefix="dinomo-bench-check-", dir="/dev/shm"))
    processes = []
    manager = None
    def interrupted(signum, frame):
        raise KeyboardInterrupt(f"Received signal {signum}")
    previous_handlers = {sig: signal.signal(sig, interrupted)
                         for sig in (signal.SIGTERM, signal.SIGHUP)}
    print(f"Evidence: {evidence}", flush=True)
    (evidence / "commit.txt").write_text(subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True))
    (evidence / "git-status.txt").write_text(subprocess.check_output(["git", "status", "--short"], cwd=root, text=True))
    (evidence / "topology.txt").write_text(subprocess.check_output(["numactl", "--hardware"], text=True))
    config = (root / "conf/dinomo-numa.yml").read_text()
    replacements = {
        "  memory: 1": f"  memory: {len(cpus)}",
        "host-cpu: 2": f"host-cpu: {cpus[0]}",
        "manager-cpu: 2": f"manager-cpu: {args.manager_cpu}",
        "memory-node: 1": f"memory-node: {args.memory_node}",
        "storage-cap: 256": "storage-cap: 64",
        "pool-directory: /dev/shm": f"pool-directory: {pool}",
        "concurrent-merge: false": f"concurrent-merge: {str(not args.synchronous).lower()}",
    }
    for old, new in replacements.items():
        config = config.replace(old, new, 1)
    config += f"\n  worker-cpus: {json.dumps(cpus)}\n  measure-stalls: true\n"
    conf = evidence / "server.yml"
    conf.write_text(config)
    route_dir = evidence / "routing"
    (route_dir / "conf").mkdir(parents=True)
    (route_dir / "conf/dinomo-config.yml").write_text(config)

    def launch(command, directory, log):
        directory.mkdir(parents=True, exist_ok=True)
        with log.open("w") as output:
            process = subprocess.Popen(command, cwd=directory, stdout=output, stderr=output)
        processes.append(process)
        return process

    def phase(mode, tag, keys=33, warmup=1, barrier=True, expected_error=None):
        directory = evidence / tag
        directory.mkdir()
        clients = []
        for client_id in range(2):
            client_dir = directory / str(client_id)
            client_dir.mkdir()
            # JSON is valid YAML and avoids an extra Python YAML dependency.
            settings = {"threads": {"memory": len(cpus)}, "benchmark": {
                "mode": mode, "keys": keys, "value-size": 64, "clients": 2,
                "client-id": client_id, "outstanding": 8, "duration-s": 1,
                "timeout-s": 3, "warmup-s": warmup, "seed": 42 + client_id,
                "ready-file": str(client_dir / "ready"), "go-file": str(directory / "go"),
                "result-file": str(client_dir / "result.json")}}
            path = client_dir / "config.yml"
            path.write_text(json.dumps(settings))
            process = launch(["taskset", "-c", str(args.client_cpu), str(bench), str(path)],
                             client_dir, client_dir / "client.log")
            clients.append((process, client_dir))
        if mode != "LOAD" and barrier and not expected_error:
            deadline = time.monotonic() + 15
            while not all((directory / str(i) / "ready").exists() for i in range(2)):
                if any(p.poll() is not None for p, _ in clients) or time.monotonic() >= deadline:
                    raise RuntimeError(f"Clients failed before barrier: {directory}")
                if server.poll() is not None:
                    raise RuntimeError("Server failed during warmup")
                time.sleep(.02)
            temp = directory / "go.tmp"
            temp.write_text(str(time.monotonic_ns() + 500_000_000))
            temp.rename(directory / "go")
        for process, client_dir in clients:
            code = process.wait(timeout=20)
            if expected_error:
                if code == 0 or expected_error not in (client_dir / "client.log").read_text():
                    raise RuntimeError(f"Expected client error {expected_error}: {client_dir}")
                if (client_dir / "result.json").exists():
                    raise RuntimeError("Failed client published a result")
                continue
            if code:
                raise RuntimeError(f"Client failed: {client_dir}")
            data = json.loads((client_dir / "result.json").read_text())
            if data["status"] != "PASS":
                raise RuntimeError("Missing client PASS")
            if mode != "LOAD":
                if not data["completed"] or data["issued"] != data["completed"] + data["drain_completed"]:
                    raise RuntimeError("Invalid measurement/drain counts")
                if sum(count for _, count in data["latency_histogram_us"]) != data["issued"]:
                    raise RuntimeError("Latency histogram does not match issued/drained requests")

    try:
        router = launch(["taskset", "-c", str(args.manager_cpu), str(route_bin)], route_dir, evidence / "routing.log")
        server = launch([str(server_bin), str(conf)], evidence, evidence / "server.log")
        for worker in range(len(cpus)):
            wait_for(server, evidence / "server.log", f"NUMA server ready: worker={worker};")
        children = Path(f"/proc/{server.pid}/task/{server.pid}/children").read_text().split()
        if len(children) != 1:
            raise RuntimeError("Expected one manager")
        manager = int(children[0])
        # Missing keys must fail rather than contribute successful completions.
        phase("READ", "missing-keys", expected_error="Unknown response, missing key, or request error")
        phase("LOAD", "load")
        phase("READ", "read")
        phase("UPDATE", "update")
        phase("READ", "read-after-update")
        phase("READ", "barrier-timeout", warmup=0, barrier=False,
              expected_error="Start barrier deadline exceeded")
        server.terminate()
        if server.wait(timeout=15) != 0:
            raise RuntimeError("Server failed shutdown")
        text = (evidence / "server.log").read_text()
        timing = re.search(r"NUMA stalls: allocation_rpc_ns=(\d+) merge_wait_ns=(\d+) reader_wait_ns=(\d+) writer_wait_ns=(\d+)", text)
        if not timing or int(timing[1]) <= 0 or int(timing[2]) <= 0:
            raise RuntimeError("Missing allocation/merge timing")
        if "leased_blocks=0" not in text or len(re.findall(r"pending_writes=0 worker=", text)) != len(cpus):
            raise RuntimeError("Worker logs did not drain")
        if Path(f"/proc/{manager}").exists() or list(pool.iterdir()):
            raise RuntimeError("Manager or pool survived shutdown")
        if router.poll() is not None:
            raise RuntimeError("Router exited unexpectedly")
        (evidence / "PASS").write_text("LOAD/READ/UPDATE, histogram/drain accounting, missing keys, barrier timeout, timing and cleanup passed.\n")
        print("PASS: NUMA benchmark client smoke checks", flush=True)
    finally:
        for process in reversed(processes):
            if process.poll() is None:
                process.send_signal(signal.SIGTERM)
                try:
                    process.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
        if not list(pool.iterdir()):
            pool.rmdir()
        for sig, handler in previous_handlers.items():
            signal.signal(sig, handler)


if __name__ == "__main__":
    main()
