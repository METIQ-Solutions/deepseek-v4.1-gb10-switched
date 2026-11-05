# Performance

Measured on the deployment described in this repository:

| | |
| --- | --- |
| Runtime | `spark-ds41f-1030`, commit `9461a70546fcfdcac9c7d8fbc58a53230510fbc9`, unmodified upstream |
| Transport | SparkNet 0.5.0 `switched` (`oneshot-switched`) over 100 GbE, **one rail per node** |
| Model | `DeepSeek-V4.1-Flash-1017`, revision `1bae0e10`, native BF16 |
| Parallelism | TP4, PP1, four GB10 nodes |
| Scheduler | `max_num_seqs=16`, `max_num_batched_tokens=16384`, `kv_cache_memory_bytes=11274289152` per rank |
| Context | 1,048,576 tokens |
| Speculative decoding | DSpark, k=5, adaptive verification |
| Measurement dates | 2026-11-02 (decode/prefill) and 2026-11-03 (concurrency, soak) |

Read the definitions before comparing anything with anything.

---

## Definitions

| Term | Definition used here |
| --- | --- |
| **Aggregate decode throughput** | `sum(completion_tokens − 1)` over the batch, divided by the **union** of the per-request decode intervals. This is what a client fleet sees, not the sum of per-request rates. |
| **End-to-end aggregate throughput** | The same token count divided by the complete batch window, including prefill and first-token latency. Always lower than decode throughput; more honest for interactive use. |
| **Per-request decode** | That request's own decode interval, in isolation. With C16 this is a third of C1 — expected, not a regression. |
| **TTFT** | Request submission to first generated token (content *or* reasoning). |
| **Mean TPOT** | Decode interval divided by decoded tokens. The API exposes no per-token timestamps, so this is a mean, not an inter-token distribution; percentile tails over three samples are descriptive only. |
| **Source prefill throughput** | `prompt_tokens / TTFT` for a one-token completion on a single request. Includes HTTP, queueing and transport. It is **effective** prefill, not pure GPU prefill arithmetic. |

Two harnesses appear below. They are **not** interchangeable:

1. **Owen-equivalent decode** — upstream's own `servebench` workload: closed
   loop, 60 s warmup, 300 s measurement, 10 batches, fixed 256-token
   completions, thinking off. This is the only decode measurement here that can
   be compared with upstream's published figures, because it is their workload.
2. **Long-generation concurrency sweep** — 1,024-token outputs per request,
   independent prompts, three repetitions, one token-calibrated input length per
   row (~8K and ~32K). This harness answers "how does the service scale?" and is
   not comparable with the numbers above or with upstream's release table.

---

## 1. Owen-equivalent decode

Two repetitions per load. Both had zero request errors, zero foreign requests,
zero prefix-cache hits, and exact token accounting.

| Load | Repetition means | Mean | Per-request | Engine steps/s | Output tokens/step | Accepted/draft | p50 TTFT / TPOT |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| C1 | 77.723 / 77.567 tok/s | **77.645 tok/s** | 77.7–78.1 tok/s | 34.11–34.16 | 2.275–2.279 | 1.277–1.280 | 0.125 s / 12.7 ms |
| C8 | 194.420 / 194.793 tok/s | **194.607 tok/s** | ~24.3 tok/s | 11.75–11.78 | 16.520–16.592 | 1.316–1.319 | 0.293–0.297 s / 40.5 ms |

Against upstream's published `spark-ds41f-1030` reference on their four-node
**ring** over a 200 Gb/s switch:

| Load | Ours (switched 100 GbE, 1 rail) | Upstream reference | Difference |
| --- | ---: | ---: | ---: |
| C1 | 77.645 tok/s | 78.3 tok/s | −0.8% |
| C8 | 194.607 tok/s | 198.4 tok/s | −1.9% |

That is close enough to be considered "the same number" by the standards of a
different fabric, and we are not going to claim more than that. Speculative
decoding was active throughout (`accepted_per_draft` 1.28–1.32; output tokens
per engine step rising from ~2.28 at C1 to ~16.5 at C8).

## 2. Concurrency sweep

Three repetitions per row, 1,024 generated tokens per request, independent
prompts, complete outputs only, attribution-valid batches only. Requested ~8K
and ~32K prompts tokenized to 7,087 and 31,692 input tokens.

| Input tokens | Concurrency | Aggregate decode tok/s, mean (range) | End-to-end aggregate tok/s | Per-request decode tok/s | TTFT p50 / p95 / p99 (s) | Mean TPOT p50 / p95 / p99 (s) | Peak KV utilization |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 7,087 | C1 | 85.4 (80.9–90.1) | 83.5 | 80.9–90.1 | 0.274 / 0.275 / 0.275 | 0.012 / 0.012 / 0.012 | 0.156% |
| 7,087 | C2 | 126.3 (123.6–129.0) | 122.9 | 61.8–70.9 | 0.483 / 0.507 / 0.508 | 0.015 / 0.016 / 0.016 | 0.307% |
| 7,087 | C4 | 179.0 (176.9–180.6) | 174.8 | 44.3–48.0 | 0.623 / 0.630 / 0.630 | 0.021 / 0.022 / 0.023 | 0.582% |
| 7,087 | C8 | 250.7 (247.1–254.2) | 244.7 | 31.0–34.5 | 0.916 / 0.920 / 0.921 | 0.031 / 0.032 / 0.032 | 1.168% |
| 7,087 | C16 | 337.3 (336.5–338.6) | 329.2 | 21.1–22.8 | 1.374 / 1.381 / 1.383 | 0.046 / 0.047 / 0.047 | 2.393% |
| 31,692 | C1 | 85.1 (83.7–85.9) | 82.8 | 83.7–85.9 | 0.335 / 0.336 / 0.336 | 0.012 / 0.012 / 0.012 | 0.352% |
| 31,692 | C2 | 125.7 (125.0–126.3) | 121.6 | 62.7–65.5 | 0.583 / 0.604 / 0.604 | 0.016 / 0.016 / 0.016 | 0.691% |
| 31,692 | C4 | 179.9 (178.0–182.3) | 174.6 | 44.6–50.8 | 0.774 / 0.784 / 0.785 | 0.022 / 0.022 / 0.022 | 1.360% |
| 31,692 | C8 | 249.9 (246.6–253.2) | 243.8 | 31.1–34.5 | 1.171 / 1.203 / 1.208 | 0.031 / 0.032 / 0.032 | 2.765% |
| 31,692 | C16 | 332.8 (328.9–334.8) | 327.3 | 20.9–24.2 | 1.772 / 1.811 / 1.818 | 0.046 / 0.047 / 0.048 | 5.475% |

Observations we are willing to defend:

- Throughput scales to the configured admission limit (`max_num_seqs=16`) with
  diminishing returns: C8 → C16 adds ~33–35% aggregate while per-request rate
  falls by roughly a third.
- KV use is nowhere near the limit at these context lengths (5.5% peak at 16 ×
  31,692 tokens). Concurrency here is limited by the scheduler, not the cache.
- Nothing above C16 was tested, because raising `max_num_seqs` is a runtime
  change this campaign deliberately did not make.

### The caveat that matters: prefix cache

The repetitions reused prompt seeds, so later repetitions hit the prefix cache.
That inflates TTFT-derived and end-to-end figures, and it inflates **decode**
figures too — a cached prompt changes how much of the batch is prefill work.

Measured directly on a targeted C2/128K pair (130,084 input tokens, 1,024
output tokens, same prompt set):

| Cache state | Aggregate decode | End-to-end aggregate | TTFT p50 |
| --- | ---: | ---: | ---: |
| Cold (no prefix hits) | **55.20 tok/s** | 35.31 tok/s | 31.3 s |
| Warm (259,584 hit tokens) | **125.92 tok/s** | 120.17 tok/s | 0.81 s |

A factor of 2.3 on decode and 39× on TTFT, from cache state alone. Treat the
"sweep" rows as warm-cache results and the cold row as the honest
long-prompt number. Any comparison that does not state its cache state is
worthless.

## 3. Source-text prefill

Three one-token samples per size, exact `1017` context, no sample failures.

| Prompt tokens | Ours (tok/s) | Upstream 1030 reference (tok/s) | Difference |
| ---: | ---: | ---: | ---: |
| 32,768 | 5,935 | 7,313 | −18.8% |
| 131,072 | 6,044 | 7,396 | −18.3% |
| 262,144 | 5,853 | 7,120 | −17.8% |
| 524,288 | 5,443 | 6,538 | −16.7% |
| 1,000,000 | 4,734 | 5,549 | −14.7% |

At 1M, actual prompt lengths were 996,544–998,585 tokens and TTFT was
210.21–211.02 s (mean 210.67 s).

**We do not have an explanation for this gap, and we are not going to invent
one.** The obvious candidates are the fabric (100 GbE switched, one rail, versus
200 Gb/s ring) and the single-device rail configuration; neither was isolated.
What we can say precisely:

- It is not a clock problem: sampled SM clocks during these windows were
  2.42–2.49 GHz.
- It is not memory pressure: per-node `MemAvailable` minimum during 1M prefill
  was ~23.9–25.4 GiB, with zero OOM kills and effectively zero PSI.
- It is not a broken fabric: pairwise RDMA read measured ~93.4 Gb/s, and the
  1M prefill windows carried ~3.6–3.8 GB/s of aggregate RoCE traffic per node.
- Decode is within 1–2% of the reference *on the same fabric*, so a uniformly
  slower fabric is not a satisfying explanation for a prefill-specific gap.

Upstream's own switched-versus-ring comparison found prefill to be where a ring
has the advantage and reported the transport as "no worse, possibly a few
percent better" for decode. That is consistent with what we see, but our
numbers are not a controlled comparison of the two fabrics, so treat it as a
hypothesis that fits, not as a finding.

## 4. Long context

| Test | Result |
| --- | --- |
| Configured and advertised limit | 1,048,576 tokens |
| Near-1M retrieval, 2 samples × 3 depths (25%, 50%, 75%) | **6/6 exact retrievals** |
| Full-request time, 1M cases | 222.1–223.0 s (trace-enabled instance; not a performance baseline) |
| 1M prefill TTFT, source-text harness | 210.2–211.0 s |

The retrieval test is the one that matters: a service can start with
`--max-model-len 1048576` and still not answer correctly at depth.

## 5. Sustained load

| | |
| --- | --- |
| Duration | 124.5 minutes, 43 cycles |
| Requests | **417/417 succeeded** |
| Conversations | 43/43 multi-turn |
| Tool round-trips | 10/10 |
| Concurrent batches attributable | 96/96 |
| Errors, timeouts, short outputs, cancellations | 0 |
| Process restarts | none |
| OOM kills, PSI pressure, swap-out | none |
| Minimum `MemAvailable` per node | 21.706 GiB |
| Minimum loaded SM clock | 2,385 MHz |
| Maximum temperature | 63 °C |

Earlier 120-minute runs at a 128-token output cap failed 0.8–1.6% of requests
with empty responses; the longer-cap run above did not. We report the
longer-cap result as the primary evidence and do not claim the small-budget
behaviour is fixed.

## 6. What the hardware was doing

Recorded across the 300-second C1/C8 decode windows and the prefill windows:

| Metric | Value |
| --- | --- |
| GPU utilization | ~96% on all four nodes |
| SM clock (decode) | means ~2.44–2.54 GHz per node |
| SM clock (1M prefill) | ~2.42–2.49 GHz |
| Power draw | ~36–46 W |
| Maximum temperature | 69 °C |
| `MemAvailable` (decode) | ~24.4–25.5 GiB per node |
| RoCE counters, C1 / C8 | ~0.49 / 0.94 GB/s per node (aggregate, not NCCL-attributed) |
| RoCE counters, 1M prefill | ~3.6–3.8 GB/s per node |

Do not read the "~80% memory used" figure you will see on a GB10 host as
"80% of memory is stuck": `MemTotal − MemAvailable` on Linux includes
reclaimable page cache and slab. On these nodes `MemTotal` is 123.72 GiB, and
the categories (`AnonPages`, `Cached`, `Slab`, …) overlap and must not be summed.
`nvidia-smi` reports `N/A` for GB10 total/used/free framebuffer fields, so
"GPU memory" is not directly readable; use host `MemAvailable` and the cgroup's
`memory.current`/`memory.peak` and treat each as its own metric.

## 7. What we did not measure

Listed so nobody has to guess whether a missing number was omitted on purpose.

- **A controlled ring-versus-switch A/B.** Not run. Any claim that switching is
  faster or slower on our hardware would be fabrication. Upstream's own
  comparison (different builds, their hardware) found +3.1% geometric mean
  across 24 cells and explicitly declined to call it a transport win.
- **Two-rail bandwidth.** We ran one device path per node; we did not measure
  what a second path would add here. Upstream reports ~196 Gb/s with both paths
  listed versus ~112 Gb/s with one.
- **Traffic-class marking.** Not enabled, so no marked-versus-unmarked data.
- **Concurrency above 16, or multiple simultaneous 1M contexts.**
- **Engine step rate as a time series.** Derived from tokens-per-step only.
- **Per-collective fabric attribution.** Our counters are aggregate RoCE byte
  counters, not per-operation.
- **Long-run drift beyond ~2 hours.**
- **Any other hardware.** One board vendor, one switch, one node count.

## 8. Reproducing these numbers

1. Complete [validation](validation.md) first. Numbers from an unqualified
   fabric are not comparable with anything.
2. Use `bin/spark bench` for a same-methodology baseline. It runs the quality
   gate and its decode matrix, and records the configuration hash, image and
   checkout per node. This profile names no `benchmark_reference`, so the run
   measures without comparing — keep its JSON as *your* reference and pass
   `--compare` on later runs.
3. For Owen-equivalent decode, use upstream's `servebench` at the pinned commit,
   closed loop, 60 s warmup, 300 s measurement, 256-token completions, thinking
   off — that is what makes the comparison legitimate.
4. For prefill, use the same source-text method with three one-token samples per
   size.
5. State your cache state, prompt token counts (from `usage`, not from your
   estimate), output token counts, concurrency, and repetitions. Without those,
   a number is an anecdote.
