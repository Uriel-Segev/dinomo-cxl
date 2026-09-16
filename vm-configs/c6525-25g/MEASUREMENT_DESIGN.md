# YCSB measurement and analysis contract

This is a proposed instrumentation contract, not a description of features
already implemented. The current runner and deployed binaries remain unchanged.

## What the existing results support

The latest saved full suite, `20260911T081941763567773Z-49724`, uses one million
keys, 64-byte values, one active benchmark thread, 64 outstanding requests,
uniform keys, and three 60-second repetitions of each workload.

Across repetitions, mean reported throughput is approximately 30,063 ops/s for
A, 45,605 for B, and 44,337 for C. These are averages of interval averages.
Reported latency summaries are averages of interval percentiles, not pooled
whole-run percentiles. A has lower throughput and higher median latency in this
suite. B's small throughput lead over C needs more repetitions before attributing
it to workload behavior.

All nine rows report a cache-hit ratio of one, but many hits are shortcut hits
and RDMA reads remain substantial. Separate local-value service from finding a
cached remote pointer. Never interpret this ratio as the fraction of operations
that avoid remote access.

## Record format

Use versioned JSON Lines, one JSON object per line, with a common envelope:

- `schema_version`, `run_id`, `workload`, `repetition`, `component`, `node`,
  `thread`, `record_type`, and a component-local `sequence`.
- `utc_unix_ns`: wall-clock timestamp encoded as an integer or decimal string.
- `monotonic_ns`: local monotonic timestamp; only subtract within one machine.
- `measurement_id`: identifies the measured phase independently of warmup.

Include units in field names. Preserve raw records; generate CSV tables from
them rather than treating formatted log text as the analysis interface.

## Unified client intervals

Emit a single `client_interval` object containing:

- Interval ID, UTC start/end, monotonic start/end, and actual duration in ns.
- Issued, completed, failed, timed-out, and outstanding requests, separately for
  reads and updates; distinguish logical requests from retry attempts.
- Throughput computed from completed logical operations and actual duration.
- Count, sum, minimum, maximum, and histograms of completion latency by operation.
- `final_partial` and the associated measurement boundary IDs.

Capture the endpoint once and use it for every field. Do not independently
increment the epoch while emitting throughput and latency. Empty intervals have
zero completions and null latency percentiles, not synthetic timeout latencies.
Tag responses using request identity; the key or currently issued operation
cannot identify the response type when requests overlap.

Use a monotonic deadline. At the measurement deadline, stop issuing measured
requests and emit the final partial interval, even when shorter than the normal
reporting period. Emit an end snapshot even if the partial interval is empty.

Drain pending requests in an explicitly separate `drain` phase. For primary
fixed-window throughput, count completions inside the measurement window only.
Keep a second histogram for all requests issued during measurement, including
those completed during drain; label it `issued_cohort`, record its observation
end, and record unresolved requests at the drain timeout. Do not mix its latency
population silently with the fixed-window completion population.

## Phase boundaries and server counters

Emit `load_end`, `warmup_start`, `warmup_end`, `measurement_start`,
`measurement_end`, `drain_start`, and `drain_end`. A zero-duration warmup still
has explicit boundaries. Warmup uses the target workload and drains before
measurement starts; define its duration in the run manifest.

For each participating KVS worker, collect acknowledged cumulative counter
snapshots at measurement start/end. Include worker identity, server boot ID,
counter generation, boundary ID, and local capture timestamps. Snapshot counters
without resetting them or competing with the monitoring accessor that resets
interval counters. Maintain a separate cumulative instrumentation view.

Workers acknowledge readiness after the start snapshot; clients issue measured
requests only after all acknowledgements. End snapshots occur after the client
deadline and have bounded coordination delay, which must be retained. A drain-end
snapshot allows a separate issued-cohort traffic estimate. Neither coordination
nor clock synchronization makes these endpoints simultaneous across machines.

Use end minus start for counters only when worker identity and counter generation
match. Counter reset, worker restart, missing acknowledgement, or missing endpoint
invalidates the delta; report null plus a quality flag instead of zero.

An alternative for tighter attribution is propagating phase IDs through requests
and counting work by phase. This requires accounting for asynchronous storage
work and retries too; timestamps alone cannot assign that work exactly.

## Comparable clocks

Record UTC and local monotonic time at every boundary and interval endpoint.
Record time synchronization status and offset estimates for host and all five VMs
before and after the experiment. Do not compare monotonic epochs across VMs.

Where synchronization telemetry is unavailable, use repeated clock probes with
local send/receive times and remote UTC. Retain round-trip time and the offset
estimate against the local midpoint. Minimum-RTT samples reduce queueing effects;
RTT/2 is an uncertainty estimate under a symmetric-path assumption, not a proof
of accuracy. Flag correlations whose uncertainty exceeds the event spacing.

Collect telemetry through drain end, not just a fixed number of samples started
before RUN delivery. Record the actual sampling window and every sample time.

## Mergeable latency histograms

Use the same histogram configuration for every component that will be merged:

- Unit: microseconds; clock source: monotonic request issue to terminal response.
- Proposed HDR histogram precision: three significant digits.
- Record lowest/highest trackable values, implementation/version, encoding,
  overflow count, and subminimum rounding rule in metadata.
- Separate reads and updates, successful and unsuccessful completions, and
  fixed-window versus issued-cohort populations.
- Retain interval histograms and one whole-run histogram for each population.

Verify histogram counts against completion counters. Never silently discard
out-of-range samples. Describe client-visible response latency separately from
server service time and persistence acknowledgement semantics.

This benchmark is concurrency-limited, not a fixed-rate open-loop generator.
Record that load model. Do not apply coordinated-omission correction without a
defined intended issue schedule and separately labelled corrected results.

## Counter dictionary

Every counter definition must identify component/worker scope, increment site,
units, reset behavior, overflow behavior, and inclusion of retries/background work.

| Metric | Meaning and aggregation rule |
| --- | --- |
| Client completed operations | Terminal logical completions; sum intervals or use boundary deltas |
| RDMA READ/WRITE/SEND/RECV/CAS/FAA operations | Audit whether counted at posting or successful completion; these are not automatically logical database operations |
| RDMA bytes | Audit API payload lengths and receive accounting; exclude any claim that these equal Ethernet wire bytes |
| Value-cache hit | Cached value path; document exactly where incremented |
| Shortcut-cache hit | Cached pointer/shortcut path; may still require RDMA |
| Local-log hit | Lookup satisfied through local log; document whether it overlaps another hit category |
| Cache miss | Document eligible lookup population; not necessarily every client operation |
| Value-cache size | Gauge; verify whether implementation returns entries or bytes before assigning units; never sum across time |
| Interface bytes/packets | Cumulative per-interface counters; do not sum the same traffic across bridge, tap, and guest interfaces |
| Memory usage | Gauge at a time; use peak/time series, not cumulative sums |

Preserve the existing combined hit ratio with its definition, but also report
each hit category. A local-service fraction requires a verified mutually exclusive
lookup outcome partition; do not invent it by subtracting shortcut hits alone.

## Analysis outputs and validity checks

For new measurements, produce interval, boundary, counter-delta, histogram, and
quality-flag tables. Summary rows should include:

- Total completions divided by actual measurement duration.
- Whole-run read/update p50, p95, p99 and latency sample counts.
- Boundary RDMA deltas, bytes/s, and operations/bytes per completed operation,
  with the attribution window stated.
- Cache category fractions and memory peaks over the measured phase.
- Missing intervals, counter-generation changes, clock uncertainty, pending
  requests at deadline, drain timeout, and histogram overflow.

Check interval continuity, endpoint coverage, histogram/completion count agreement,
and aggregate agreement with boundary counters. Workload PASS and measurement
validity are separate fields. A database run can pass while its telemetry is
incomplete.

Treat repetitions as independent experimental units. Report individual values,
mean, standard deviation, and range; more repetitions are needed for reliable
uncertainty estimates. Do not treat intervals within one run as independent
repetitions. Merging histograms across runs weights by completed operations;
label pooled percentiles separately from the distribution of per-run percentiles.

For existing data, retain `mean_epoch_*` names, missing-coverage flags, and the
server interval-boundary caveat. Whole-run latency distributions and exact
measurement-only counter deltas cannot be recovered from the saved summaries.

## Implementation order

1. Add versioned unified client intervals, monotonic timing, final partial
   reports, and explicit drain accounting; test count and time conservation.
2. Add operation-tagged histograms and a whole-run summary; test merge counts,
   quantile bounds, overflow, and read/update attribution with overlapping requests.
3. Add phase control and acknowledged non-resetting server boundary snapshots;
   test resets, missing workers, warmup exclusion, and timeout behavior.
4. Update the runner to collect manifests, clocks, records, and telemetry through
   drain; require the new schema rather than silently accepting old binaries.
5. Add an analysis tool that checks validity before computing normalized metrics.

Deployment must rebuild and update the affected benchmark and KVS binaries.
Record deployed binary hashes and deployed configuration, alongside the local
checkout commit, so source provenance is not confused with deployed provenance.
