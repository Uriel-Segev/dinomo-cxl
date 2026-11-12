#!/usr/bin/env python3
"""Exercise NUMA lifecycle and optional client correctness; CPU hotplug is external."""
import argparse
import json
import os
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
    parser.add_argument("--workers", type=int, default=1)
    parser.add_argument("--worker-cpus", help="Comma-separated CPU for each compute worker")
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
    parser.add_argument("--merge-writes", type=int, default=16)
    parser.add_argument("--merge-ms", type=int, default=20)
    parser.add_argument("--idle-ms", type=int, default=0)
    parser.add_argument("--require-deferred", action="store_true")
    parser.add_argument("--concurrent", action="store_true")
    parser.add_argument("--manager-cpu", type=int)
    parser.add_argument("--merge-start-delay-ms", type=int, default=0)
    parser.add_argument("--merge-lock-delay-ms", type=int, default=0)
    parser.add_argument("--reader-delay-ms", type=int, default=0)
    parser.add_argument("--require-overlap", action="store_true")
    parser.add_argument("--require-backpressure", action="store_true")
    args = parser.parse_args()
    worker_cpus = [int(cpu) for cpu in args.worker_cpus.split(",")] if args.worker_cpus else [args.host_cpu] * args.workers
    if not 1 <= args.workers <= 64 or len(worker_cpus) != args.workers:
        parser.error("Use 1..64 workers and one CPU per worker")
    if args.workers > 1 and not args.concurrent:
        parser.error("Multiple workers require --concurrent")
    if args.workers > 1 and (args.require_deferred or args.idle_ms or args.expect_exhaustion):
        parser.error("These deterministic single-worker probes require --workers 1")
    if args.expect_exhaustion and not (args.client_check and args.no_reclaim and args.gc_rounds and args.log_block_limit == 0):
        parser.error("Expected exhaustion requires a GC workload, --no-reclaim, and no block limit")
    if not 16 <= args.pool_mb <= 4096 or args.log_block_limit < 0 or not 0 <= args.gc_rounds <= 4096:
        parser.error("Invalid pool size, block limit, or GC round count")
    if args.merge_writes < 0 or args.merge_ms < 0 or not (args.merge_writes or args.merge_ms):
        parser.error("A merge trigger must be enabled")
    if args.require_deferred and (args.merge_writes < 16 or args.merge_ms != 0 or args.keys < 4):
        parser.error("Deterministic deferred checks require >=16 writes, timer disabled, >=4 keys")
    if args.idle_ms and (args.merge_writes != 0 or args.merge_ms <= 0 or args.idle_ms <= args.merge_ms):
        parser.error("Idle probe requires timer-only merge and an idle interval longer than the timer")
    if args.concurrent and (args.no_reclaim or not 1 <= args.merge_writes <= 16 or args.idle_ms):
        parser.error("Concurrent mode requires reclamation and a 1..16 write limit")
    if args.require_overlap and not (args.concurrent and args.merge_lock_delay_ms > 0):
        parser.error("Overlap evidence requires concurrent mode and a positive merge-lock test delay")
    if args.require_backpressure and not args.concurrent:
        parser.error("Backpressure evidence requires concurrent mode")
    if any(not 0 <= value <= 1000 for value in (args.merge_start_delay_ms, args.merge_lock_delay_ms, args.reader_delay_ms)):
        parser.error("Test delays must be 0..1000 ms")
    manager_cpu = args.host_cpu if args.manager_cpu is None else args.manager_cpu
    if not any((node / f"cpu{manager_cpu}").exists() for node in Path("/sys/devices/system/node").glob("node[0-9]*") if (node / f"cpu{args.host_cpu}").exists()):
        parser.error("Manager CPU must belong to the host CPU's NUMA node")
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
    config = config.replace("  memory: 1", f"  memory: {args.workers}", 1)
    config += "\n  worker-cpus: [" + ", ".join(map(str, worker_cpus)) + "]\n"
    config = config.replace("host-cpu: 2", f"host-cpu: {args.host_cpu}")
    config = config.replace("memory-node: 1", f"memory-node: {args.memory_node}")
    config = config.replace("storage-cap: 256", f"storage-cap: {args.pool_mb}")
    config = config.replace("log-block-limit: 0", f"log-block-limit: {args.log_block_limit}")
    if args.no_reclaim: config = config.replace("reclaim-logs: true", "reclaim-logs: false")
    config = config.replace("merge-write-limit: 16", f"merge-write-limit: {args.merge_writes}")
    config = config.replace("merge-interval-ms: 20", f"merge-interval-ms: {args.merge_ms}")
    config = config.replace("manager-cpu: 2", f"manager-cpu: {manager_cpu}")
    if args.concurrent: config = config.replace("concurrent-merge: false", "concurrent-merge: true")
    config = config.replace("merge-start-delay-ms: 0", f"merge-start-delay-ms: {args.merge_start_delay_ms}")
    config = config.replace("merge-lock-delay-ms: 0", f"merge-lock-delay-ms: {args.merge_lock_delay_ms}")
    config = config.replace("reader-delay-ms: 0", f"reader-delay-ms: {args.reader_delay_ms}")
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
        invalid_config.write_text(config.replace(f"  memory: {args.workers}", "  memory: 0", 1))
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
            for worker in range(args.workers):
                wait_for(server, evidence / "server.log", f"NUMA server ready: worker={worker};")
            if route.poll() is not None:
                raise RuntimeError("Routing process failed")
            children = Path(f"/proc/{server.pid}/task/{server.pid}/children").read_text().split()
            if len(children) != 1:
                raise RuntimeError(f"Expected one manager child, found {children}")
            server_affinity = sorted(os.sched_getaffinity(server.pid))
            manager_affinity = sorted(os.sched_getaffinity(int(children[0])))
            if server_affinity != [worker_cpus[0]] or manager_affinity != [manager_cpu]:
                raise RuntimeError("Unexpected server/manager CPU affinity")
            placements = re.findall(r"NUMA worker placement: worker=(\d+) tid=(\d+) cpu=(\d+)",
                                    (evidence / "server.log").read_text())
            worker_threads = {}
            for worker, tid, cpu in placements:
                worker = int(worker)
                affinity = sorted(os.sched_getaffinity(int(tid)))
                if int(cpu) != worker_cpus[worker] or affinity != [worker_cpus[worker]]:
                    raise RuntimeError("Unexpected compute worker affinity")
                worker_threads[worker] = {"tid": int(tid), "cpus": affinity}
            if len(worker_threads) != args.workers:
                raise RuntimeError("Missing worker CPU placement evidence")
            (evidence / "processes.json").write_text(json.dumps({
                "server": server.pid, "manager": int(children[0]), "router": route.pid,
                "server_cpus": server_affinity, "manager_cpus": manager_affinity,
                "workers": worker_threads}, indent=2))
            if args.client_check:
                clients = []
                for client_id in range(args.workers):
                    client_directory = evidence / f"client-{client_id}"
                    client_directory.mkdir()
                    log_path = evidence / ("client.log" if client_id == 0 else f"client-{client_id}.log")
                    with log_path.open("w") as client_output:
                        client = subprocess.Popen(
                            ["taskset", "-c", str(args.host_cpu), str(client_binary), str(args.keys),
                             str(args.gc_rounds), str(args.idle_ms), str(args.workers), str(client_id)],
                            cwd=client_directory, stdout=client_output, stderr=client_output)
                    processes.append(client)
                    clients.append((client, log_path))
                deadline = time.monotonic() + 180
                while any(client.poll() is None for client, _ in clients) and time.monotonic() < deadline:
                    if server.poll() is not None:
                        if not args.expect_exhaustion:
                            raise RuntimeError("Server exited during workload: " + (evidence / "server.log").read_text()[-4000:])
                        for client, _ in clients:
                            if client.poll() is None: client.terminate()
                            client.wait(timeout=15)
                        break
                    time.sleep(0.05)
                for client, log_path in clients:
                    if client.poll() is None:
                        raise RuntimeError("Client exceeded workload deadline")
                    if client.returncode != 0 and not args.expect_exhaustion:
                        raise RuntimeError("Client correctness failed: " + log_path.read_text())
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
            merge_matches = re.findall(r"NUMA merge: published_writes=(\d+) threshold_merges=(\d+) timer_merges=(\d+) shutdown_merges=(\d+) staging_gets=(\d+) index_gets=(\d+) pending_writes=(\d+) worker=(\d+)", server_text)
            if len(merge_matches) != args.workers or {int(row[7]) for row in merge_matches} != set(range(args.workers)):
                raise RuntimeError("Missing merge/visibility evidence")
            writes, thresholds, timers, shutdowns, staged, indexed, pending = (
                sum(int(row[column]) for row in merge_matches) for column in range(7))
            if args.workers > 1 and any(int(row[0]) == 0 or int(row[6]) != 0 for row in merge_matches):
                raise RuntimeError("Every compute worker must publish writes and drain")
            if pending or not writes:
                raise RuntimeError("Pending writes or missing publication evidence")
            if (args.require_deferred or args.idle_ms or args.gc_rounds) and not indexed:
                raise RuntimeError("Missing index-read evidence")
            if args.require_deferred and (not staged or not thresholds or timers or thresholds >= writes or (writes % args.merge_writes and not shutdowns)):
                raise RuntimeError("Deferred reads/threshold/shutdown merge checks failed")
            if not args.concurrent and args.merge_writes == 1 and args.merge_ms == 0 and (thresholds != writes or timers or shutdowns or staged):
                raise RuntimeError("Merge-before-ack control did not merge each write")
            if args.concurrent:
                concurrent = re.search(r"NUMA concurrent: started=(\d+) completed=(\d+) writes_during_merge=(\d+) staged_reads_during_merge=(\d+) read_locks=(\d+) reader_waits=(\d+) writer_waits=(\d+) ipc_backpressure=(\d+)", server_text)
                if not concurrent:
                    raise RuntimeError("Missing concurrent-merge evidence")
                started, completed, overlap_writes, overlap_reads, locks, reader_waits, writer_waits, backpressure = map(int, concurrent.groups())
                if not started or completed != started or not locks:
                    raise RuntimeError("Merge epochs did not drain or index readers were unprotected")
                if args.require_overlap and (not overlap_writes or not overlap_reads):
                    raise RuntimeError("No write/staging-read progress while manager held the index write lock")
                if args.reader_delay_ms and not writer_waits:
                    raise RuntimeError("Pinned reader did not force manager to wait")
                if args.require_backpressure and not backpressure:
                    raise RuntimeError("Allocation/control backpressure was not exercised")
            if args.idle_ms and not timers:
                raise RuntimeError("Idle timer did not merge pending writes")
            if args.idle_ms:
                client_text = (evidence / "client.log").read_text()
                begin = re.search(r"IDLE_BEGIN: monotonic_ns=(\d+)", client_text)
                end = re.search(r"IDLE_END: monotonic_ns=(\d+)", client_text)
                events = re.findall(r"NUMA merge request: monotonic_ns=(\d+)", server_text)
                if not begin or not end or not any(int(begin.group(1)) < int(event) < int(end.group(1)) for event in events):
                    raise RuntimeError("No merge started while the client was idle")
            if args.gc_rounds:
                gc = re.search(r"NUMA GC: enabled=1 fresh_blocks=(\d+) reused_blocks=(\d+) reclaimed_blocks=(\d+) live_blocks=(\d+) free_blocks=(\d+) leased_blocks=(\d+) live_records=(\d+) logical_log_bytes=(\d+)", server_text)
                if not gc:
                    raise RuntimeError("Missing reclamation evidence")
                fresh, reused, reclaimed, live, free, leased, records, logical_bytes = map(int, gc.groups())
                if not reused or not reclaimed or leased or records != args.keys * args.workers or fresh != live + free:
                    raise RuntimeError("Reclamation ownership/count checks failed")
                if args.log_block_limit and fresh > args.log_block_limit:
                    raise RuntimeError("Physical log count exceeded the configured bound")
                update_bytes = 0
                for _, log_path in clients:
                    workload = re.search(r"GC_WORKLOAD: update_bytes=(\d+)", log_path.read_text())
                    if not workload:
                        raise RuntimeError(f"Missing workload byte count: {log_path}")
                    update_bytes += int(workload.group(1))
                if logical_bytes <= args.pool_mb * 1024 * 1024 or update_bytes <= args.pool_mb * 1024 * 1024:
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
