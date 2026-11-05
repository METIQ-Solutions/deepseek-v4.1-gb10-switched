# 2026-11-03 — concurrency sweep, long context, and stability soak

Three different questions answered in one campaign: how the service scales with
concurrent long generations, whether the full configured context actually
works, and whether it survives sustained load.

Same runtime and transport as the
[decode and prefill results](2026-11-02-owen-equivalent-decode-and-prefill.md).

---

## 1. Concurrency sweep

Three repetitions per row, 1,024 generated tokens per request, independent
prompts, attribution and validity gates enforced per batch. Excluded rows are
listed at the bottom; they are not silently missing.

| Input tokens | C | Aggregate decode tok/s, mean (range) | End-to-end aggregate | Per-request decode | TTFT p50/p95/p99 (s) | Mean TPOT p50/p95/p99 (s) | Peak KV |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 7,087 | C1 | 85.4 (80.9–90.1) | 83.5 | 80.9–90.1 | 0.274/0.275/0.275 | 0.012/0.012/0.012 | 0.156% |
| 7,087 | C2 | 126.3 (123.6–129.0) | 122.9 | 61.8–70.9 | 0.483/0.507/0.508 | 0.015/0.016/0.016 | 0.307% |
| 7,087 | C4 | 179.0 (176.9–180.6) | 174.8 | 44.3–48.0 | 0.623/0.630/0.630 | 0.021/0.022/0.023 | 0.582% |
| 7,087 | C8 | 250.7 (247.1–254.2) | 244.7 | 31.0–34.5 | 0.916/0.920/0.921 | 0.031/0.032/0.032 | 1.168% |
| 7,087 | C16 | 337.3 (336.5–338.6) | 329.2 | 21.1–22.8 | 1.374/1.381/1.383 | 0.046/0.047/0.047 | 2.393% |
| 31,692 | C1 | 85.1 (83.7–85.9) | 82.8 | 83.7–85.9 | 0.335/0.336/0.336 | 0.012/0.012/0.012 | 0.352% |
| 31,692 | C2 | 125.7 (125.0–126.3) | 121.6 | 62.7–65.5 | 0.583/0.604/0.604 | 0.016/0.016/0.016 | 0.691% |
| 31,692 | C4 | 179.9 (178.0–182.3) | 174.6 | 44.6–50.8 | 0.774/0.784/0.785 | 0.022/0.022/0.022 | 1.360% |
| 31,692 | C8 | 249.9 (246.6–253.2) | 243.8 | 31.1–34.5 | 1.171/1.203/1.208 | 0.031/0.032/0.032 | 2.765% |
| 31,692 | C16 | 332.8 (328.9–334.8) | 327.3 | 20.9–24.2 | 1.772/1.811/1.818 | 0.046/0.047/0.048 | 5.475% |

Notes:

- **Cache state:** prompt seeds repeated across repetitions, so later
  repetitions were partially warm. Decode figures are therefore optimistic
  relative to a cold workload; see the cold/warm pair below for the size of the
  effect.
- Input length has almost no effect on decode throughput at equal concurrency
  (85.4 vs 85.1 at C1; 337.3 vs 332.8 at C16), which is what an efficient
  prefix/attention path should look like at these ratios of context to batch.
- KV occupancy stays under 6% at C16 with ~32K inputs. The scheduler limit of 16
  is the binding constraint, not the cache.
- Saturation beyond C16 was not tested; raising `max_num_seqs` would be a
  runtime change.

### Speculative decoding during the sweep

`accepted_per_draft` ranged 1.30–1.73 at C1, 1.48–1.58 at C2, 1.40–1.51 at C4,
1.34–1.41 at C8, 1.33–1.38 at C16. Output tokens per engine step rose from
2.30–2.72 (C1) to 31.45–32.25 (C16). Acceptance falling with batch size is the
expected behaviour for a fixed draft budget.

### Excluded rows, and why

| Row | Reason |
| --- | --- |
| 32K C8/C16, first attempt | non-test activity present during the batch (attribution invalid) |
| 32K C8/C16, fresh-seed attempt | same |
| C2/128K, two attempts | activity peaked at four for a two-request batch |
| Earlier C2/C4 attempts | incomplete stream; in one case six running requests for a four-request batch |

Exclusions are a sign the gate works. The recheck of the 32K C8/C16 rows was
included after it passed attribution.

---

## 2. Cold versus warm prefix cache

Same prompt-set hash, same service, C2, 130,084 input tokens, 1,024 output
tokens, three repetitions of two requests. All six requests per run completed
with full output, valid attribution, and peak activity exactly C2.

| Cache state | Aggregate decode | End-to-end aggregate | TTFT p50/p95/p99 | Prefix-cache hits | Peak KV |
| --- | ---: | ---: | ---: | ---: | ---: |
| Cold | **55.20 tok/s** (54.98–55.52) | 35.31 tok/s | 31.349/41.866/41.872 s | 0 | 9.852% |
| Warm | **125.92 tok/s** (125.02–127.41) | 120.17 tok/s | 0.809/0.855/0.857 s | 259,584 tokens | 2.225–2.251% |

Cold effective prefill was 3,107–6,227 tok/s; the warm run reported
151,780–165,641 tok/s because almost the entire repeated prompt was served from
cache — which is exactly why warm TTFT figures must never be quoted as prefill
performance.

Engine-step-rate figures derived from these rows (11.1–11.5 steps/s cold,
24.9–25.7 warm) are **derived** from aggregate rate ÷ output tokens per step,
not sampled. The harness had no reliable direct step-rate series for this
window.

---

## 3. Long context

| Property | Result |
| --- | --- |
| Advertised limit | 1,048,576 tokens |
| Retrieval samples | 2 per depth × 3 depths (25%, 50%, 75%) |
| Exact retrievals | **6/6** |
| Full-request time, 1M cases | 222.1–223.0 s |
| Instance | trace-enabled; not used as a performance baseline |

Correctness at depth is the point. A service can accept `--max-model-len
1048576` and still fail to answer at that depth; this gate is what distinguishes
the two.

---

## 4. Stability soak

Mixed load: C4/~8K and C2/~32K 1,024-token bursts, a 128K reasoning request
every fourth cycle, a growing three-turn conversation each cycle, a synthetic
tool round-trip every fourth cycle, quiet intervals between cycles (longer every
sixth).

| | |
| --- | --- |
| Duration | 124.5 minutes / 43 cycles |
| Requests | **417/417 succeeded** |
| Multi-turn conversations | 43/43 |
| Tool round-trips | 10/10 |
| Concurrent batches/samples attributable | 96/96 |
| Request errors, timeouts, cancellations, short outputs | 0 |
| Process restarts | none |
| OOM kills, PSI pressure, swap-out | none |
| Minimum `MemAvailable` per node | 21.706 GiB |
| Minimum loaded SM clock | 2,385 MHz |
| Maximum temperature | 63 °C |
| Safety aborts | none |

Follow-up probe immediately after the soak, C2/~32K: three valid 1,024-token
repetitions at 96.683–97.220 aggregate decode tok/s, 8.084% peak KV, zero
errors, no OOM/PSI/swap activity.

### Context on earlier, shorter-output soaks

Earlier 120-minute runs at a 128-token output cap completed but succeeded on
98.4% and 99.2% of requests — six and three short responses respectively — and
several partial runs stopped safely on monitoring failures of their own (a
dropped Prometheus connection, a missing host series, a DNS failure). Those
partial runs are evidence about the harness, not about the runtime. The
1,024-token run above is the primary stability result; the small-budget
empty-response behaviour is not claimed to be fixed.

---

## 5. Interpretation

Supported by these measurements:

- The service scales from C1 to C16 with diminishing returns, limited by the
  configured admission cap, not by KV capacity at these context lengths.
- The full 1M context works, verified by retrieval rather than by a startup flag.
- A 2-hour mixed workload at 1,024-token outputs completes with no errors, no
  restarts and no memory-safety events.
- Cache state changes decode throughput by ~2.3× at long context; any number
  without a stated cache state is not comparable.

Not supported:

- Any claim about scaling beyond C16.
- Any claim about multiple simultaneous 1M contexts.
- Any claim that the switched fabric caused or prevented any of the above. This
  campaign measured one fabric configuration on one set of four nodes.
