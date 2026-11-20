#!/usr/bin/env python3
"""Run isolated host-native NUMA LOAD -> READ/UPDATE experiments and save reports."""
import argparse
import csv
import fcntl
import hashlib
import itertools
import json
import os
from pathlib import Path
import re
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time

from benchmark_results import aggregate_clients, server_diagnostics

ROOT = Path(__file__).resolve().parents[2]


def numbers(text):
    try:
        values = [int(x) for x in text.split(",")]
    except ValueError as error:
        raise argparse.ArgumentTypeError("Expected comma-separated integers") from error
    if not values or min(values) < 0 or len(set(values)) != len(values):
        raise argparse.ArgumentTypeError("Use distinct nonnegative integers")
    return values


def write_json(path, data):
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(data, indent=2) + "\n")
    temporary.replace(path)


def cpu_node(cpu):
    nodes = list(Path(f"/sys/devices/system/cpu/cpu{cpu}").glob("node[0-9]*"))
    if len(nodes) != 1:
        raise ValueError(f"Cannot determine NUMA node for CPU {cpu}")
    return int(nodes[0].name[4:])


def validate(args):
    if not args.worker_counts:
        args.worker_counts = [len(args.worker_cpus)]
    if not all(1 <= n <= min(64, len(args.worker_cpus)) for n in args.worker_counts):
        raise ValueError("Worker counts must be 1..64 and fit --worker-cpus")
    if len(args.client_cpus) > 64 or args.keys < max(len(args.client_cpus), max(args.worker_counts)):
        raise ValueError("Use 1..64 clients and at least as many keys as clients/workers")
    if args.synchronous and args.worker_counts != [1]:
        raise ValueError("--synchronous requires exactly one worker")
    for name in ("keys", "outstanding", "duration_s", "timeout_s", "phase_timeout_s", "repeats"):
        if getattr(args, name) <= 0:
            raise ValueError(f"--{name.replace('_', '-')} must be positive")
    if any(getattr(args, name) > 2**32 - 1 for name in
           ("keys", "outstanding", "duration_s", "timeout_s", "warmup_s", "merge_ms")):
        raise ValueError("Client numeric arguments must fit unsigned 32-bit integers")
    if len(set(args.modes)) != len(args.modes):
        raise ValueError("Use each measured mode once; use --repeats for repetitions")
    if not 1 <= args.value_size <= 3000 or not 16 <= args.pool_mb <= 4096:
        raise ValueError("Use value sizes 1..3000 bytes and pools 16..4096 MiB")
    if not 4096 <= args.log_block_bytes <= 65536 or args.log_block_bytes % 64:
        raise ValueError("Log block bytes must be a multiple of 64 in 4096..65536")
    if not 1 <= args.merge_writes <= 16 or args.merge_ms < 0 or args.warmup_s < 0:
        raise ValueError("Use merge writes 1..16 and nonnegative timer/warmup")
    if not 0 <= args.seed <= 2**32 - len(args.client_cpus):
        raise ValueError("Seed plus client ID must fit an unsigned 32-bit integer")
    roles = args.worker_cpus[:max(args.worker_counts)] + [args.manager_cpu, args.router_cpu] + args.client_cpus
    if len(set(roles)) != len(roles):
        raise ValueError("Workers, manager, router, and clients require distinct CPUs")
    allowed = os.sched_getaffinity(0)
    if any(cpu not in allowed for cpu in roles):
        raise ValueError(f"Requested CPU is offline or outside allowed affinity {sorted(allowed)}")
    node = cpu_node(roles[0])
    if any(cpu_node(cpu) != node for cpu in roles):
        raise ValueError("All compute, manager, router, and client CPUs must be on one NUMA node")
    cores = []
    for cpu in roles:
        topology = Path(f"/sys/devices/system/cpu/cpu{cpu}/topology")
        cores.append(((topology / "physical_package_id").read_text().strip(),
                      (topology / "core_id").read_text().strip()))
    if len(set(cores)) != len(cores) and not args.allow_shared_cores:
        raise ValueError("Requested CPUs share physical cores; choose separate cores or use --allow-shared-cores")
    for memory in args.memory_nodes:
        path = Path(f"/sys/devices/system/node/node{memory}/meminfo")
        if not path.exists() or not re.search(r"MemTotal:\s+[1-9]\d*", path.read_text()):
            raise ValueError(f"Node {memory} does not have memory")
    if shutil.disk_usage("/dev/shm").free < (args.pool_mb + 16) * 1024**2:
        raise ValueError("Insufficient free /dev/shm space for the requested pool")
    return node


def check_ports(workers, clients):
    ports = {base + i for base in range(6000, 7000, 100) for i in range(workers)}
    ports.update((7000, 7100, 7200, 7300, 8200))
    ports.update(7900 + i for i in range(workers))
    ports.update(base + i for base in (8300, 8400) for i in range(clients))
    for port in sorted(ports):
        with socket.socket() as probe:
            probe.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            try:
                probe.bind(("0.0.0.0", port))
            except OSError as error:
                raise RuntimeError(f"DINOMO port {port} is in use; stop the other deployment first") from error


class Deployment:
    """Own only this run's process groups and private pool directory."""
    def __init__(self, directory):
        self.directory = directory
        self.processes = []
        self.pool = None
        self.server = self.router = None

    def launch(self, name, command, cwd):
        cwd.mkdir(parents=True, exist_ok=True)
        with (cwd / f"{name}.log").open("w") as output:
            p = subprocess.Popen([str(x) for x in command], cwd=cwd, stdout=output,
                                 stderr=output, start_new_session=True)
        self.processes.append((name, p))
        with (self.directory / "commands.jsonl").open("a") as output:
            output.write(json.dumps({"name": name, "pid": p.pid, "cwd": str(cwd),
                                     "command": [str(x) for x in command]}) + "\n")
        return p

    def healthy(self):
        for name, p in (("server", self.server), ("router", self.router)):
            if p is not None and p.poll() is not None:
                raise RuntimeError(f"{name} exited unexpectedly ({p.returncode}); see {self.directory}")

    def wait(self, predicate, timeout, description, clients=()):
        deadline = time.monotonic() + timeout
        while True:
            self.healthy()
            if any(p.poll() not in (None, 0) for p in clients):
                raise RuntimeError(f"Client failed during {description}; see {self.directory}")
            if predicate():
                return
            if time.monotonic() >= deadline:
                raise RuntimeError(f"Timed out waiting for {description}; see {self.directory}")
            time.sleep(.02)

    def close(self):
        # Children inherit each owned leader's process group. Kill the group on
        # forced cleanup so an orphan manager cannot survive a failed server.
        errors = []
        for name, p in reversed(self.processes):
            try:
                os.killpg(p.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                p.wait(timeout=15 if name == "server" else 3)
            except subprocess.TimeoutExpired:
                pass
            try:
                os.killpg(p.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            try:
                p.wait(timeout=5)
            except subprocess.TimeoutExpired:
                errors.append(f"Could not reap {name} pid={p.pid}")
        if not errors and self.pool is not None:
            # This path was freshly created by this instance under /dev/shm.
            shutil.rmtree(self.pool)
        write_json(self.directory / "cleanup.json", {"status": "FAIL" if errors else "PASS", "errors": errors})
        if errors:
            raise RuntimeError("; ".join(errors))


def affinities(server, worker_cpus, manager_cpu, server_log):
    children = Path(f"/proc/{server.pid}/task/{server.pid}/children").read_text().split()
    if len(children) != 1:
        raise RuntimeError(f"Expected one manager, got {children}")
    manager = int(children[0])
    if sorted(os.sched_getaffinity(manager)) != [manager_cpu]:
        raise RuntimeError("Manager affinity mismatch")
    workers = {}
    for worker, tid, cpu in re.findall(r"NUMA worker placement: worker=(\d+) tid=(\d+) cpu=(\d+)", server_log):
        worker, tid, cpu = int(worker), int(tid), int(cpu)
        if worker >= len(worker_cpus) or cpu != worker_cpus[worker] or sorted(os.sched_getaffinity(tid)) != [cpu]:
            raise RuntimeError("Compute worker affinity mismatch")
        workers[worker] = {"tid": tid, "cpu": cpu}
    if len(workers) != len(worker_cpus):
        raise RuntimeError("Missing worker affinity evidence")
    return {"server": server.pid, "manager": manager, "workers": workers, "manager_cpu": manager_cpu}


def phase(deployment, args, binary, mode, workers, directory):
    directory.mkdir()
    clients = []
    paths = []
    for client_id, cpu in enumerate(args.client_cpus):
        cwd = directory / f"client-{client_id}"
        cwd.mkdir()
        config = {"threads": {"memory": workers}, "benchmark": {
            "mode": mode, "keys": args.keys, "value-size": args.value_size,
            "clients": len(args.client_cpus), "client-id": client_id,
            "outstanding": args.outstanding, "duration-s": args.duration_s,
            "timeout-s": args.timeout_s, "warmup-s": args.warmup_s,
            "seed": args.seed + client_id, "ready-file": str(cwd / "ready"),
            "go-file": str(directory / "go"), "result-file": str(cwd / "result.json")}}
        write_json(cwd / "config.json", config)
        p = deployment.launch("client", ["taskset", "-c", cpu, binary, cwd / "config.json"], cwd)
        clients.append(p)
        paths.append(cwd / "result.json")
    start_ns = 0
    if mode in ("READ", "UPDATE"):
        deployment.wait(lambda: all((p.parent / "ready").exists() for p in paths),
                        args.warmup_s + args.timeout_s + 10, f"{mode} readiness", clients)
        if any(p.poll() is not None for p in clients):
            raise RuntimeError("Measured client exited before start barrier")
        for p, cpu in zip(clients, args.client_cpus):
            if sorted(os.sched_getaffinity(p.pid)) != [cpu]:
                raise RuntimeError("Client affinity mismatch")
        start_ns = time.monotonic_ns() + 1_000_000_000
        go = directory / "go.tmp"
        go.write_text(str(start_ns))
        go.replace(directory / "go")
    limit = args.duration_s + args.timeout_s + 10 if start_ns else args.phase_timeout_s
    deployment.wait(lambda: all(p.poll() is not None for p in clients), limit, f"{mode} completion", clients)
    result = aggregate_clients(paths, mode, args.keys, args.value_size, args.duration_s,
                               args.outstanding, start_ns)
    if any(json.loads(path.read_text()).get("cpu") != cpu for path, cpu in zip(paths, args.client_cpus)):
        raise RuntimeError("Client CPU placement mismatch")
    write_json(directory / "summary.json", result)
    return result


def experiment(args, binaries, template, directory, workers, memory, repeat, mode, host_node):
    directory.mkdir()
    deployment = Deployment(directory)
    identity = {"workers": workers, "memory_node": memory, "placement": "local" if memory == host_node else "remote",
                "repeat": repeat, "mode": mode, "evidence": str(directory)}
    result = dict(identity, status="FAIL")
    try:
        check_ports(workers, len(args.client_cpus))
        deployment.pool = Path(tempfile.mkdtemp(prefix="dinomo-benchmark-", dir="/dev/shm"))
        config = json.loads(json.dumps(template))
        config["threads"]["memory"] = workers
        config["threads"]["benchmark"] = len(args.client_cpus)
        config["capacities"]["storage-cap"] = args.pool_mb
        config["kvs_config"]["value-size"] = args.value_size
        config["numa"].update({"host-cpu": args.worker_cpus[0], "worker-cpus": args.worker_cpus[:workers],
                               "manager-cpu": args.manager_cpu, "memory-node": memory,
                               "pool-directory": str(deployment.pool), "log-block-bytes": args.log_block_bytes,
                               "merge-write-limit": args.merge_writes, "merge-interval-ms": args.merge_ms,
                               "concurrent-merge": not args.synchronous, "measure-stalls": not args.no_stall_timing})
        write_json(directory / "server.json", config)
        routing = directory / "routing"
        (routing / "conf").mkdir(parents=True)
        write_json(routing / "conf/dinomo-config.yml", config)
        deployment.router = deployment.launch("router", ["taskset", "-c", args.router_cpu, binaries["router"]], routing)
        deployment.server = deployment.launch("server", [binaries["server"], directory / "server.json"], directory)
        log = directory / "server.log"
        deployment.wait(lambda: all(f"NUMA server ready: worker={worker};" in log.read_text(errors="replace")
                                    for worker in range(workers)), 45, "worker startup")
        pids = affinities(deployment.server, args.worker_cpus[:workers], args.manager_cpu, log.read_text())
        if sorted(os.sched_getaffinity(deployment.router.pid)) != [args.router_cpu]:
            raise RuntimeError("Router affinity mismatch")
        pids.update({"router": deployment.router.pid, "router_cpu": args.router_cpu, "client_cpus": args.client_cpus})
        write_json(directory / "processes.json", pids)
        phase(deployment, args, binaries["client"], "LOAD", workers, directory / "load")
        measured = phase(deployment, args, binaries["client"], mode, workers, directory / "measure")
        phase(deployment, args, binaries["client"], "VERIFY", workers, directory / "verify")
        deployment.healthy()
        deployment.server.terminate()
        if deployment.server.wait(timeout=30) != 0:
            raise RuntimeError("Server failed normal shutdown")
        if Path(f"/proc/{pids['manager']}").exists() or list(deployment.pool.iterdir()):
            raise RuntimeError("Manager or pool survived normal shutdown")
        diagnostics = server_diagnostics(log.read_text(), workers, args.keys, memory,
                                         not args.no_stall_timing, not args.synchronous,
                                         args.keys + (measured["issued"] if mode == "UPDATE" else 0))
        result.update({"status": "PASS", "measurement": measured, "diagnostics": diagnostics})
    except BaseException as error:
        result["error"] = f"{type(error).__name__}: {error}"
        raise
    finally:
        try:
            deployment.close()
        except BaseException as error:
            result.update(status="FAIL", error=f"Cleanup failed: {error}")
            raise
        finally:
            if result["status"] != "PASS":
                result.pop("measurement", None)
            write_json(directory / "report.json", result)
            (directory / result["status"]).write_text(result.get("error", "All client, placement, drain, and cleanup checks passed") + "\n")
    return result


def save_summary(directory, results, status):
    compact = json.loads(json.dumps(results))
    for row in compact:
        row.get("measurement", {}).pop("latency_histogram_us", None)
    write_json(directory / "summary.json", {"schema_version": 1, "status": status, "runs": compact})
    columns = ["status", "workers", "memory_node", "placement", "repeat", "mode", "throughput_ops_s",
               "p50_latency_us", "p99_latency_us", "completed", "drain_completed", "max_start_lateness_us",
               "allocation_rpc_ns", "merge_wait_ns", "reader_wait_ns", "writer_wait_ns", "diagnostics_scope", "evidence"]
    with (directory / "summary.csv").open("w", newline="") as output:
        writer = csv.DictWriter(output, fieldnames=columns)
        writer.writeheader()
        for result in compact:
            row = {k: v for k, v in result.items() if k in columns}
            row.update({k: v for k, v in result.get("measurement", {}).items() if k in columns})
            row.update(result.get("diagnostics", {}).get("stalls_ns", {}))
            row["diagnostics_scope"] = result.get("diagnostics", {}).get("scope", "")
            writer.writerow(row)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build-dir", default="build/numa")
    parser.add_argument("--worker-cpus", type=numbers, required=True, help="Ordered compute CPU list; each count uses a prefix")
    parser.add_argument("--worker-counts", type=numbers, help="E.g. 1,2,4; default all listed worker CPUs")
    parser.add_argument("--manager-cpu", type=int, required=True)
    parser.add_argument("--router-cpu", type=int, required=True)
    parser.add_argument("--client-cpus", type=numbers, required=True, help="One independent client process per CPU")
    parser.add_argument("--memory-nodes", type=numbers, required=True)
    parser.add_argument("--modes", nargs="+", choices=("READ", "UPDATE"), default=["READ", "UPDATE"])
    parser.add_argument("--keys", type=int, default=10000)
    parser.add_argument("--value-size", type=int, default=64)
    parser.add_argument("--pool-mb", type=int, default=512)
    parser.add_argument("--log-block-bytes", type=int, default=16384)
    parser.add_argument("--outstanding", type=int, default=32)
    parser.add_argument("--duration-s", type=int, default=30)
    parser.add_argument("--warmup-s", type=int, default=5)
    parser.add_argument("--timeout-s", type=int, default=30)
    parser.add_argument("--phase-timeout-s", type=int, default=300, help="Bound for each full LOAD/VERIFY phase")
    parser.add_argument("--repeats", type=int, default=1)
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--merge-writes", type=int, default=16)
    parser.add_argument("--merge-ms", type=int, default=20)
    parser.add_argument("--no-stall-timing", action="store_true")
    parser.add_argument("--synchronous", action="store_true")
    parser.add_argument("--allow-shared-cores", action="store_true", help="Explicitly permit SMT siblings (logical CPUs must remain distinct)")
    parser.add_argument("--results-dir", type=Path, default=ROOT / "numa-test/dinomo/results")
    args = parser.parse_args()
    try:
        host_node = validate(args)
    except ValueError as error:
        parser.error(str(error))
    build = (ROOT / args.build_dir).resolve()
    binaries = {"server": build / "target/kvs/dinomo-kvs-numa", "router": build / "target/kvs/dinomo-route",
                "client": build / "target/benchmark/dinomo-numa-bench"}
    for binary in binaries.values():
        if not os.access(binary, os.X_OK):
            parser.error(f"Build target first: {binary}")
    args.results_dir = args.results_dir.resolve()
    args.results_dir.mkdir(parents=True, exist_ok=True)
    directory = Path(tempfile.mkdtemp(prefix="benchmark-", dir=args.results_dir))
    print(f"Evidence: {directory}", flush=True)
    results = []
    previous = {}
    def interrupted(signum, frame):
        # Keep a second signal from interrupting cleanup of owned resources.
        for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            signal.signal(sig, signal.SIG_IGN)
        raise KeyboardInterrupt(f"Received signal {signum}")
    lock = None
    try:
        for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            previous[sig] = signal.signal(sig, interrupted)
        lock = open(f"/tmp/dinomo-numa-benchmark-{os.getuid()}.lock", "a")
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise RuntimeError("Another NUMA benchmark launcher is active") from error
        manifest = vars(args).copy()
        manifest.update({"schema_version": 1, "host_node": host_node, "cpu_online_state_changed": False,
                         "binary_sha256": {k: hashlib.sha256(p.read_bytes()).hexdigest() for k, p in binaries.items()},
                         "commands": {k: str(p) for k, p in binaries.items()},
                         "python_version": sys.version, "started_unix_ns": time.time_ns()})
        manifest["results_dir"] = str(args.results_dir)
        sources = ["src/benchmark/numa_benchmark.cpp", "src/benchmark/CMakeLists.txt",
                   "src/kvs/server.cpp", "src/kvs/numa_backend.cpp", "include/kvs/dinomo_compute.hpp",
                   "include/kvs/numa_backend.hpp", "conf/dinomo-numa-bench.json",
                   "numa-test/dinomo/run_benchmark.py", "numa-test/dinomo/benchmark_results.py"]
        manifest["source_sha256"] = {}
        for name in sources:
            source = ROOT / name
            destination = directory / "source" / name
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, destination)
            manifest["source_sha256"][name] = hashlib.sha256(source.read_bytes()).hexdigest()
        write_json(directory / "manifest.json", manifest)
        for filename, command in (("commit.txt", ["git", "rev-parse", "HEAD"]),
                                  ("git-status.txt", ["git", "status", "--short"]),
                                  ("working-tree.patch", ["git", "diff", "HEAD"]),
                                  ("topology.txt", ["numactl", "--hardware"]),
                                  ("cpus.txt", ["lscpu", "-e=CPU,NODE,SOCKET,CORE,ONLINE"]),
                                  ("uname.txt", ["uname", "-a"])):
            (directory / filename).write_text(subprocess.check_output(command, cwd=ROOT, text=True))
        if (build / "CMakeCache.txt").exists():
            shutil.copyfile(build / "CMakeCache.txt", directory / "CMakeCache.txt")
        if (build / "compile_commands.json").exists():
            shutil.copyfile(build / "compile_commands.json", directory / "compile_commands.json")
        template = json.loads((ROOT / "conf/dinomo-numa-bench.json").read_text())
        for workers, memory, repeat, mode in itertools.product(args.worker_counts, args.memory_nodes,
                                                               range(1, args.repeats + 1), args.modes):
            run_dir = directory / f"w{workers}-node{memory}-r{repeat}-{mode.lower()}"
            print(f"Running workers={workers} pool_node={memory} repeat={repeat} {mode}", flush=True)
            try:
                result = experiment(args, binaries, template, run_dir, workers, memory, repeat, mode, host_node)
            except BaseException:
                if (run_dir / "report.json").exists():
                    results.append(json.loads((run_dir / "report.json").read_text()))
                raise
            results.append(result)
            save_summary(directory, results, "RUNNING")
            measured = result["measurement"]
            print(f"PASS: {measured['throughput_ops_s']:.1f} ops/s; median={measured['p50_latency_us']} us; p99={measured['p99_latency_us']} us", flush=True)
        save_summary(directory, results, "PASS")
        (directory / "PASS").write_text("All configured runs and cleanup passed.\n")
        print(f"Results: {directory / 'summary.csv'}", flush=True)
        return 0
    except BaseException as error:
        save_summary(directory, results, "FAIL")
        (directory / "FAIL").write_text(f"{type(error).__name__}: {error}\n")
        print(f"FAIL: {error}\nEvidence: {directory}", file=sys.stderr, flush=True)
        return 130 if isinstance(error, KeyboardInterrupt) else 1
    finally:
        if lock is not None:
            lock.close()
        for sig, handler in previous.items():
            signal.signal(sig, handler)


if __name__ == "__main__":
    sys.exit(main())
