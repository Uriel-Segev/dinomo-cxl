# Longer NUMA benchmark evaluation

Status: **46 measurements passed**, including 36 baseline cases and 10
follow-up measurements. All case-level validation and cleanup checks passed.
All five evidence manifests record identical benchmark/server/router binary
hashes and identical captured implementation-source hashes.

## Method

The baseline uses 1, 2, and 4 fixed-owner workers, local node 0 and remote node 1
pools, READ and UPDATE separately, and three fresh-deployment repeats per case
(36 runs). Each run loads and verifies 10,000 keys with 64-byte application
values, warms up for 5 seconds, measures for 30 seconds, drains, and verifies
the complete keyspace. Pool size is 512 MiB; log blocks are 16 KiB. Concurrent
merge uses a 16-write threshold and 20 ms timer with delay hooks disabled.
Two independent clients each allow 32 outstanding requests. Backend timing is
enabled; diagnostic quiet mode is enabled.

Host: dual-socket Intel Xeon E5-2660 v2, 10 physical cores per socket, SMT2.
Workers use CPUs 2,6,8,9 (a prefix per count), manager 4, router 0, clients 1,3.
All roles use distinct physical cores on node 0; every CPU remains online.
The launcher checks affinity and sampled pool placement at startup/shutdown.
Frequency, SMT sibling activity, and OS scheduling are not experimentally
controlled. Matrix order is deterministic, not randomized.

Baseline evidence: `results/benchmark-ahybpu1f/`. Each run preserves configuration,
source/binary hashes, Git state, histograms, phase summaries, and cleanup records.
The source tree includes uncommitted changes; use the recorded hashes and source
snapshots as the exact implementation identity, not just the commit ID.

Throughput counts successful responses observed in the scheduled window.
Latency includes every request issued in that window, including drain tails.
Report throughput median and range over repeats; retain each run's p50/p99
rather than averaging percentiles. Lifetime stall counters include LOAD,
warmup, VERIFY, and shutdown and can overlap.

The 640,000-byte application dataset is smaller than socket LLC capacity.
Selected-node placement does not imply every access reaches DRAM. This study
measures the current networked NUMA implementation and does not establish CXL
latency, persistence, or a large-working-set remote-memory penalty.

See [BENCHMARKING.md](BENCHMARKING.md) for reproduction options and
[BENCHMARK_CLIENT.md](BENCHMARK_CLIENT.md) for accounting definitions.

## Baseline results

Throughput is the median across three repeats, with minimum–maximum in
parentheses. Latency columns list the combined-client percentile for repeats
1/2/3, in milliseconds. No latency percentiles are averaged.

| Workers | Pool | Mode | Throughput ops/s: median (range) | p50 ms: r1 / r2 / r3 | p99 ms: r1 / r2 / r3 |
|---|---|---|---|---|---|
| 1 | local | READ | 8,107.1 (7,997.1–8,260.5) | 7.861 / 7.725 / 7.972 | 8.362 / 8.370 / 8.426 |
| 1 | local | UPDATE | 9,542.9 (9,275.1–9,710.4) | 6.573 / 6.676 / 6.861 | 6.896 / 7.022 / 7.256 |
| 1 | remote | READ | 7,969.7 (7,735.0–8,117.5) | 8.004 / 7.853 / 8.255 | 8.412 / 8.375 / 8.552 |
| 1 | remote | UPDATE | 9,698.5 (9,602.1–9,716.2) | 6.569 / 6.648 / 6.579 | 6.879 / 6.923 / 6.850 |
| 2 | local | READ | 14,595.0 (14,593.7–14,748.1) | 4.399 / 4.386 / 4.357 | 8.690 / 8.733 / 8.595 |
| 2 | local | UPDATE | 18,655.4 (18,594.6–18,829.2) | 3.386 / 3.454 / 3.458 | 6.779 / 6.907 / 6.865 |
| 2 | remote | READ | 14,668.7 (14,434.6–14,718.7) | 4.369 / 4.442 / 4.367 | 8.642 / 8.764 / 8.637 |
| 2 | remote | UPDATE | 18,549.0 (18,340.3–18,625.8) | 3.468 / 3.425 / 3.494 | 6.909 / 6.815 / 6.974 |
| 4 | local | READ | 25,734.9 (25,630.4–25,874.9) | 1.844 / 1.890 / 1.890 | 13.327 / 13.439 / 13.406 |
| 4 | local | UPDATE | 25,747.4 (25,368.3–25,780.8) | 1.921 / 1.926 / 1.953 | 12.599 / 12.462 / 12.576 |
| 4 | remote | READ | 25,506.4 (25,487.3–25,626.3) | 1.888 / 1.891 / 1.889 | 13.456 / 13.507 / 13.370 |
| 4 | remote | UPDATE | 25,777.1 (25,592.6–25,986.9) | 1.932 / 1.931 / 1.949 | 12.344 / 12.435 / 12.092 |

### Scaling and placement

| Workers | Local READ speedup vs 1 worker | Local UPDATE speedup vs 1 worker | Remote/local READ throughput | Remote/local UPDATE throughput |
|---|---|---|---|---|
| 1 | 1.00× | 1.00× | 0.983 | 1.016 |
| 2 | 1.80× | 1.95× | 1.005 | 0.994 |
| 4 | 3.17× | 2.70× | 0.991 | 1.001 |

All 36 workloads passed full-keyspace verification, sampled startup/shutdown
placement, affinity, zero-pending-write/lease and epoch-drain checks, and
cleanup. Maximum client start lateness was 83.156 µs; the largest drain
fraction was 0.0276% of issued requests. Drain latency samples remain
in the percentile population.

Four workers increase throughput, with sublinear scaling particularly for
UPDATE. READ p99 increases from roughly 8.4 ms to 13.4 ms locally; UPDATE p99
increases from roughly 7 ms to 12.5 ms. Local/remote throughput differences are
small and do not establish a memory-placement penalty for this dataset.
The fixed run order and uncontrolled scheduling/frequency limit causal claims.

## Reproduce the baseline

```bash
python3 numa-test/dinomo/run_benchmark.py \
  --worker-cpus 2,6,8,9 --worker-counts 1,2,4 \
  --manager-cpu 4 --router-cpu 0 --client-cpus 1,3 \
  --memory-nodes 0,1 --keys 10000 --value-size 64 \
  --pool-mb 512 --log-block-bytes 16384 --outstanding 32 \
  --warmup-s 5 --duration-s 30 --repeats 3
```

Replace every CPU/node ID for a different host. Build first using the commands
in [README.md](README.md), and run benchmark suites sequentially.

## Focused local four-worker controls

All other dataset/pool/merge settings match the baseline. These controls use
30-second measurements and 5-second warmup. Results are exploratory until
repeated; their time order also differs from the baseline.

| Configuration | READ ops/s | READ p50 / p99 ms | UPDATE ops/s | UPDATE p50 / p99 ms | Evidence |
|---|---|---|---|---|---|
| 2 clients × 128 outstanding; timing on | 26,965.5 | 9.047 / 22.172 | 27,749.1 | 9.150 / 18.450 | `results/benchmark-bt64j3v9/` |
| 4 clients × 32 outstanding; timing on | 28,294.2 | 1.728 / 16.579 | 34,875.2 | 1.514 / 13.509 | `results/benchmark-oowoq63j/` |
| 2 clients × 32 outstanding; timing off | 25,600.0 | 1.890 / 13.538 | 25,251.0 | 1.949 / 12.523 | `results/benchmark-7ewftt8x/` |

### Repeated four-client check

The initial four-client READ/UPDATE pair was repeated twice in
`results/benchmark-p91pn3ki/`, giving three independent deployments per mode
when combined with `results/benchmark-oowoq63j/`. The values below are in
chronological order: initial pair, then repeat 1 and repeat 2 of the follow-up.

| Mode | Throughput ops/s: median (range) | p50 ms, each run | p99 ms, each run | Throughput vs 2-client baseline median |
|---|---|---|---|---|
| READ | 28,252.0 (27,751.2–28,294.2) | 1.728 / 1.619 / 2.003 | 16.579 / 16.984 / 16.457 | +9.8% |
| UPDATE | 34,875.2 (34,551.3–35,065.1) | 1.514 / 1.633 / 2.077 | 13.509 / 13.561 / 12.993 | +35.5% |

To reproduce the controls, use the baseline command with `--worker-counts 4`
and `--memory-nodes 0`. For the larger-window check, use `--outstanding 128
--repeats 1` with the original two clients. For the four-client check, use
`--client-cpus 1,3,5,7 --outstanding 32 --repeats 3`. For the timing-disabled
check, keep two clients and 32 outstanding requests and add
`--no-stall-timing --repeats 1`. Do not combine control changes in one comparison.
The larger-window and timing-disabled checks each have only one run per mode.

## Backend diagnostics

The following are medians of accumulated elapsed seconds across three local
baseline repeats. Their scope is the **entire server lifetime**, not the
30-second measured phase. Worker totals can exceed wall time; allocation and
merge times overlap. Do not sum these columns or interpret them as fractions
of the measured duration.

| Workers | Mode | Allocation RPC s | Merge wait s | Reader lock wait s | Writer lock wait s |
|---|---|---|---|---|---|
| 1 | READ | 0.082957 | 0.014920 | 0.000077 | 0.000000 |
| 1 | UPDATE | 3.332051 | 0.405222 | 0.000161 | 0.000000 |
| 2 | READ | 0.083011 | 0.015810 | 0.000307 | 0.000259 |
| 2 | UPDATE | 6.495011 | 0.948998 | 0.000304 | 0.000251 |
| 4 | READ | 0.093697 | 0.013308 | 0.001299 | 0.000716 |
| 4 | UPDATE | 11.011074 | 1.186414 | 0.001120 | 0.000664 |

## Findings and next experiment

- **The longer workload is stable and correct under the tested settings.** All
  46 cases passed response/value checks, placement, drain, and cleanup. This is
  bounded experimental evidence, not support for untested worker counts or
  recovery/durability features.
- **Worker scaling is real at fixed client concurrency, but sublinear.** The
  local baseline reaches 3.17× READ and 2.70× UPDATE throughput at four workers
  relative to one worker. Four-worker p99 is higher than the one-worker result.
- **The two-client UPDATE baseline is client-concurrency limited.** Four clients
  increase median UPDATE throughput by about 35%, and READ by about 10%.
  Changing client count also doubles aggregate outstanding capacity, so this
  does not isolate client CPU cost from queue/window effects. No tested
  configuration is established as the server's maximum throughput.
- **A larger window alone has a latency cost.** Two clients with 128 outstanding
  requests each gain modest throughput while increasing median and p99 latency.
  This is a single-run observation, not a complete saturation curve.
- **No large timing penalty was observed in the single timing-disabled control.**
  It did not improve throughput over the timing-enabled baseline medians. A
  paired repeated study would be needed to estimate small timing overhead.
- **Local/remote performance is similar for this small dataset.** This cannot be
  generalized to a working set exceeding LLC or actual CXL hardware. The
  lifetime counters do not identify the measured-phase bottleneck; READ lock
  waits are small in these totals, so they alone do not explain the READ ceiling.

The next matched scaling matrix should use four clients at every worker count
and both memory placements, retaining three repeats and the same dataset and
merge policy. Follow with client/window sweeps until throughput plateaus, then
profile measured phases to distinguish client, request-handler, transport,
allocation/merge, and memory costs. Busy-poll CPU utilization alone cannot make
that distinction. For a memory-placement study, pilot a larger live working
set exceeding socket LLC, validate pool headroom, and interleave/randomize
local/remote order. Keep these as separate experiments so each comparison has
one clear question. Do not optimize the backend based solely on the small
local/remote difference or the original two-client ceiling.

Raw results are machine-local and ignored by Git. Preserve all five evidence
directories separately when moving hosts; this report preserves their summary,
not the raw histograms, configurations, or binaries.
