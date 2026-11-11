#!/usr/bin/env python3
"""Exercise NUMA lifecycle and optional client correctness; CPU hotplug is external."""
import argparse
import re
from pathlib import Path
import signal
import subprocess
import tempfile
import time


def wait_for(process, log, marker, seconds=30):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if marker in log.read_text(errors="replace"):
            return
        if process.poll() is not None:
            raise RuntimeError(f"Process exited ({process.returncode}): {log.read_text()}")
        time.sleep(0.05)
    raise RuntimeError(f"Timed out waiting for {marker}: {log.read_text()}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build-dir", default="build/numa")
    parser.add_argument("--host-cpu", type=int, default=2)
    parser.add_argument("--memory-node", type=int, default=0)
    parser.add_argument("--client-check", action="store_true", help="Run existing-client network correctness checks")
    parser.add_argument("--keys", type=int, default=256)
    parser.add_argument("--require-offline", action="store_true")
    parser.add_argument("--gc-rounds", type=int, default=0)
    parser.add_argument("--pool-mb", type=int, default=256)
    parser.add_argument("--log-block-limit", type=int, default=0)
    parser.add_argument("--no-reclaim", action="store_true")
    parser.add_argument("--expect-exhaustion", action="store_true")
    args = parser.parse_args()
    if args.expect_exhaustion and not (args.client_check and args.no_reclaim and args.gc_rounds and args.log_block_limit == 0):
        parser.error("Expected exhaustion requires a GC workload, --no-reclaim, and no block limit")
    if not 16 <= args.pool_mb <= 4096 or args.log_block_limit < 0 or not 0 <= args.gc_rounds <= 4096:
        parser.error("Invalid pool size, block limit, or GC round count")
    root = Path(__file__).resolve().parents[2]
    build = (root / args.build_dir).resolve()
    server_binary = build / "target/kvs/dinomo-kvs-numa"
    route_binary = build / "target/kvs/dinomo-route"
    client_binary = build / "target/benchmark/dinomo-numa-client-check"
    binaries = [server_binary, route_binary]
    if args.client_check: binaries.append(client_binary)
    for binary in binaries:
        if not binary.is_file():
            parser.error(f"Build the target first: {binary}")
    results = Path(__file__).resolve().parent / "results"
    results.mkdir(exist_ok=True)
    evidence = Path(tempfile.mkdtemp(prefix="server-startup-", dir=results))
    (evidence / "conf").mkdir()
    if args.require_offline and Path(
            f"/sys/devices/system/node/node{args.memory_node}/cpulist").read_text().strip():
        raise RuntimeError("Pool node still has online CPUs")
    (evidence / "topology.txt").write_text(subprocess.check_output(
        ["bash", str(root / "numa-test/numa_cpu_control.sh"), "status"], text=True))
    config = (root / "conf/dinomo-numa.yml").read_text()
    config = config.replace("host-cpu: 2", f"host-cpu: {args.host_cpu}")
    config = config.replace("memory-node: 1", f"memory-node: {args.memory_node}")
    config = config.replace("storage-cap: 256", f"storage-cap: {args.pool_mb}")
    config = config.replace("log-block-limit: 0", f"log-block-limit: {args.log_block_limit}")
    if args.no_reclaim: config = config.replace("reclaim-logs: true", "reclaim-logs: false")
    # Keep private pool directories under an owned evidence subdirectory, so
    # cleanup can be verified without inspecting another user's resources.
    pool_root = Path(tempfile.mkdtemp(prefix="dinomo-startup-", dir="/dev/shm"))
    config = config.replace("pool-directory: /dev/shm", f"pool-directory: {pool_root}")
    config_path = evidence / "conf/dinomo-config.yml"
    config_path.write_text(config)
    route_directory = evidence / "routing"
    (route_directory / "conf").mkdir(parents=True)
    (route_directory / "conf/dinomo-config.yml").write_text(config)
    (evidence / "commit.txt").write_text(subprocess.check_output(
        ["git", "rev-parse", "HEAD"], cwd=root, text=True))
    (evidence / "git-status.txt").write_text(subprocess.check_output(
        ["git", "status", "--short"], cwd=root, text=True))
    processes = []
    stopping = [False]
    def interrupted(signum, frame):
        if not stopping[0]:
            stopping[0] = True
            raise KeyboardInterrupt(f"Received signal {signum}")
    previous_handlers = {sig: signal.signal(sig, interrupted)
                         for sig in (signal.SIGTERM, signal.SIGHUP)}
    try:
        invalid_config = evidence / "invalid.yml"
        invalid_config.write_text(config.replace("memory: 1", "memory: 2", 1))
        with (evidence / "invalid-config.log").open("w") as output:
            invalid = subprocess.run([str(server_binary), str(invalid_config)],
                                     cwd=evidence, stdout=output, stderr=output, timeout=10)
        if invalid.returncode == 0 or "NUMA server requires" not in (
                evidence / "invalid-config.log").read_text():
            raise RuntimeError("Invalid worker-count configuration was not rejected")
        if list(pool_root.iterdir()):
            raise RuntimeError("Invalid configuration created a pool")
        # With no routing process, startup must fail and clean the manager/pool.
        with (evidence / "missing-seed.log").open("w") as output:
            failed = subprocess.Popen([str(server_binary), str(config_path)],
                                      cwd=evidence, stdout=output, stderr=output)
            processes.append(failed)
            code = failed.wait(timeout=45)
        if code == 0 or "routing seed did not return membership" not in (
                evidence / "missing-seed.log").read_text():
            raise RuntimeError("Missing-seed test did not reach the expected failure")
        if list(pool_root.iterdir()):
            raise RuntimeError("Missing-seed test left a pool behind")

        with (evidence / "routing.log").open("w") as route_output, (
                evidence / "server.log").open("w") as server_output:
            route = subprocess.Popen(["taskset", "-c", str(args.host_cpu), str(route_binary)],
                                     cwd=route_directory, stdout=route_output, stderr=route_output)
            processes.append(route)
            server = subprocess.Popen([str(server_binary), str(config_path)],
                                      cwd=evidence, stdout=server_output, stderr=server_output)
            processes.append(server)
            wait_for(server, evidence / "server.log", "NUMA server ready:")
            if route.poll() is not None:
                raise RuntimeError("Routing process failed")
            children = Path(f"/proc/{server.pid}/task/{server.pid}/children").read_text().split()
            if len(children) != 1:
                raise RuntimeError(f"Expected one manager child, found {children}")
            if args.client_check:
                client_directory = evidence / "client"
                client_directory.mkdir()
                with (evidence / "client.log").open("w") as client_output:
                    client = subprocess.Popen(
                        ["taskset", "-c", str(args.host_cpu), str(client_binary), str(args.keys), str(args.gc_rounds)],
                        cwd=client_directory, stdout=client_output, stderr=client_output)
                    processes.append(client)
                    deadline = time.monotonic() + 180
                    while client.poll() is None and time.monotonic() < deadline:
                        if server.poll() is not None:
                            if not args.expect_exhaustion:
                                raise RuntimeError("Server exited during workload: " + (evidence / "server.log").read_text()[-4000:])
                            client.terminate()
                            client.wait(timeout=15)
                            break
                        time.sleep(0.05)
                    if client.poll() is None:
                        raise RuntimeError("Client exceeded workload deadline")
                    if client.returncode != 0 and not args.expect_exhaustion:
                        raise RuntimeError("Client correctness failed: " + (evidence / "client.log").read_text())
            if args.expect_exhaustion:
                if client.returncode == 0 or server.wait(timeout=15) == 0 or "Allocate PMDK log block" not in (evidence / "server.log").read_text():
                    raise RuntimeError("No-reclamation control did not exhaust the PMDK pool as expected")
            else:
                server.send_signal(signal.SIGTERM)
                if server.wait(timeout=15) != 0:
                    raise RuntimeError("Server did not shut down successfully")
            if any(Path(f"/proc/{pid}").exists() for pid in children):
                raise RuntimeError("Manager survived server shutdown")
        if list(pool_root.iterdir()):
            raise RuntimeError("Server shutdown left a pool behind")
        if args.client_check and not args.expect_exhaustion:
            server_text = (evidence / "server.log").read_text()
            counters = re.search(r"NUMA counters: shared_reads=(\d+) shared_writes=(\d+) allocated_logs=(\d+) metadata_gets=(\d+) metadata_puts=(\d+)", server_text)
            if not counters or any(int(value) == 0 for value in counters.groups()):
                raise RuntimeError("Expected shared-pool, allocation, and metadata operations")
            if args.keys >= 10 and int(counters.group(3)) <= 2:
                raise RuntimeError("Workload did not exercise repeated allocation batches")
            if args.gc_rounds:
                gc = re.search(r"NUMA GC: enabled=1 fresh_blocks=(\d+) reused_blocks=(\d+) reclaimed_blocks=(\d+) live_blocks=(\d+) free_blocks=(\d+) leased_blocks=(\d+) live_records=(\d+) logical_log_bytes=(\d+)", server_text)
                if not gc:
                    raise RuntimeError("Missing reclamation evidence")
                fresh, reused, reclaimed, live, free, leased, records, logical_bytes = map(int, gc.groups())
                if not reused or not reclaimed or leased or records != args.keys or fresh != live + free:
                    raise RuntimeError("Reclamation ownership/count checks failed")
                if args.log_block_limit and fresh > args.log_block_limit:
                    raise RuntimeError("Physical log count exceeded the configured bound")
                workload = re.search(r"GC_WORKLOAD: update_bytes=(\d+)", (evidence / "client.log").read_text())
                if logical_bytes <= args.pool_mb * 1024 * 1024 or not workload or int(workload.group(1)) <= args.pool_mb * 1024 * 1024:
                    raise RuntimeError("Workload did not exceed pool capacity")
            if args.require_offline and Path(
                    f"/sys/devices/system/node/node{args.memory_node}/cpulist").read_text().strip():
                raise RuntimeError("Pool CPUs came online during the workload")
        (evidence / "PASS").write_text("Config rejection, startup, missing seed, SIGTERM, manager and pool cleanup passed.\n")
        if args.expect_exhaustion:
            (evidence / "EXPECTED_EXHAUSTION").write_text("No-reclamation control exhausted PMDK; manager/pool cleanup passed.\n")
            (evidence / "PASS").unlink()
            print("PASS: no-reclamation control exhausted the PMDK pool and cleaned up")
        elif args.client_check:
            (evidence / "PASS").write_text("Network client correctness, metadata, allocation, placement, and lifecycle passed.\n")
            print("PASS: network client correctness, metadata, placement and lifecycle")
        else:
            print("PASS: startup and lifecycle only; client operations not tested")
    finally:
        for process in reversed(processes):
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
        if not list(pool_root.iterdir()):
            pool_root.rmdir()
        for sig, handler in previous_handlers.items():
            signal.signal(sig, handler)
        print(f"Evidence: {evidence}")


if __name__ == "__main__":
    main()
