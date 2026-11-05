# Benchmark methodology

How the numbers in this repository were produced, what they measure, and what
makes them comparable with something else. If you take one thing from this
file: **every number here has a harness, a cache state and a token count
attached, and a number without them is an anecdote.**

---

## Runtime under test

| | |
| --- | --- |
| Runtime | `spark-ds41f-1030`, commit `9461a70546fcfdcac9c7d8fbc58a53230510fbc9` |
| Transport | SparkNet 0.5.0 `switched` (`oneshot-switched`), 100 GbE, one rail per node |
| Model | `DeepSeek-V4.1-Flash-1017`, revision `1bae0e1088993b9b82de08f59de5be5a34e42170` |
| Parallelism | TP4, PP1, four GB10 nodes |
| Kernels | TileLang attention/linear/MoE; DSpark speculative decoding k=5 |
| Scheduler | `max_num_seqs=16`, `max_num_batched_tokens=16384`, `max-parallel-prefills=1` |
| KV | `kv_cache_memory_bytes=11274289152` per rank |
| Context | 1,048,576 tokens |
| Image | built from the pinned sources on the site's own build host |

The service was otherwise idle during every measurement window: no other
clients, no other containers using the fabric, no concurrent builds.

---

## Harness 1 — Owen-equivalent decode (`servebench`)

Upstream's own workload, used at the pinned commit. This is the *only* decode
measurement here that can be compared with upstream's published release figures,
because it is their method.

| Parameter | Value |
| --- | --- |
| Mode | closed loop |
| Warmup | 60 s |
| Measurement | 300 s, 10 batches |
| Prompts | upstream's default set |
| Seed | 0 |
| Completion length | fixed 256 tokens |
| Thinking | off |
| Concurrency | C1 and C8 |
| Repetitions | 2 per load |

Attribution requirements applied per repetition: zero request errors, zero
foreign requests (no activity other than the test's own), zero prefix-cache hits
(so the comparison is not cache-assisted), and exact token timing from the
stream. A repetition failing any of these was excluded rather than annotated.

Reported: aggregate decode throughput, per-request throughput, engine steps/s,
output tokens per engine step, accepted drafts per draft, TTFT and mean TPOT
percentiles.

## Harness 2 — long-generation concurrency sweep

A token-calibrated driver against the OpenAI-compatible endpoint, written for
this campaign. It exists because `servebench` does not sweep concurrency, and
because "how does it scale?" is the question operators actually ask.

| Parameter | Value |
| --- | --- |
| Prompts | independent, deterministic, request-unique bulk tokens |
| Input length | calibrated with the service's own `/tokenize` to ~8K and ~32K (7,087 and 31,692 tokens) |
| Output length | 1,024 tokens per request |
| Concurrency | C1, C2, C4, C8, C16 |
| Repetitions | 3 per row |
| Attribution gate | the serving endpoint's `vllm:num_requests_running` and `vllm:num_requests_waiting` sampled once per second; activity must equal the requested concurrency for the whole batch |
| Validity gate | complete 1,024-token outputs, no errors, no timeouts, no cancellations, no short outputs |

Rows failing the attribution or validity gate were excluded and are not reported
as performance. This is stricter than it sounds: two earlier attempts at the 32K
C8/C16 rows were discarded because non-test activity was present, and a C2/128K
attempt was discarded because activity peaked at four for a two-request batch.

**Cache state:** the sweep reused prompt seeds across repetitions, so later
repetitions hit the prefix cache. This is stated in
[performance.md](../docs/performance.md) and is why the cold/warm pair below
exists: it quantifies how much that matters rather than hand-waving about it.

### Cold versus warm pair

Same prompt-set hash, same service, 130,084 input tokens, 1,024 output tokens,
three repetitions of two requests, C2. One run had zero prefix-cache hits; the
other reused the same prompts immediately afterwards and recorded 259,584 hit
tokens per repetition.

## Harness 3 — source prefill

The upstream source-text method: one-token completions over source text at
32K/131K/262K/524K/1M, three samples per size, "effective prefill" =
`prompt_tokens / TTFT`.

This includes HTTP, queueing and transport time. It is **not** pure GPU prefill
arithmetic and must not be compared with a kernel-level prefill figure.

## Harness 4 — long-context retrieval

Not a throughput measurement; a correctness gate at the configured maximum
context.

- Unique retrieval code inserted at 25%, 50% and 75% depth of a prompt that
  reaches ≥95% of 1,048,576 tokens.
- Two samples per depth.
- Small output budget (256 tokens) so the run measures retrieval, not
  generation.
- Acceptance requires exact retrieval and `usage.prompt_tokens` consistent with
  the target.

## Harness 5 — stability soak

Mixed load for a little over two hours: alternating short and long generation
bursts, multi-turn conversations, a periodic large-context reasoning request,
and synthetic tool round-trips, with quiet intervals.

| Parameter | Value |
| --- | --- |
| Duration target | ≥120 minutes |
| Output cap | 1,024 tokens |
| Cycles completed | 43 in 124.5 minutes |
| Requests | 417, all independent-attribution-checked |
| Fail-closed monitors | node unreachable or rebooted; new OOM kill; `MemAvailable` < 4 GiB; loaded SM clock < 1 GHz at ≥70% utilization |
| Telemetry | per-cycle Prometheus samples, plus a compact per-host summary |

The monitors are safety properties of the test, not production acceptance
thresholds. The soak stops load rather than continuing into a degraded node.

---

## Definitions, once, precisely

| Term | Definition |
| --- | --- |
| Aggregate decode throughput | `sum(completion_tokens − 1)` ÷ union of per-request decode intervals |
| End-to-end aggregate throughput | same numerator ÷ full batch wall-clock window |
| Per-request decode | that request's decode interval only |
| Mean TPOT | decode interval ÷ decoded tokens; a mean, not a distribution (the API exposes no per-token timestamps) |
| TTFT | submission to first generated token, content or reasoning |
| Effective prefill | `prompt_tokens / TTFT`, including HTTP, queueing and transport |
| Engine steps/s | engine steps reported by the runtime over the measurement window |
| Attribution valid | the service's own activity gauges equal the test's intended concurrency for the whole batch |

Percentiles use linear interpolation. With three samples, p95/p99 tails are
descriptive; they are printed because hiding them would be worse.

---

## What makes a comparison legitimate

Two numbers are comparable only when **all** of these match: runtime release and
commit, checkpoint revision, node count, transport and rail count, context
configuration, scheduler limits, harness, prompt and output lengths,
concurrency, cache state and repetitions.

Things we explicitly refuse to do:

- Compare a `servebench` 256-token decode result with a 1,024-token sweep row.
- Compare a cold-cache prefill with a warm-cache TTFT.
- Compare measured numbers taken on a latched-clock host with numbers taken on a
  healthy one.
- Attribute a difference to the fabric when the runtime build also changed.

---

## Provenance

Each results file records the date, the identities above, the exact conditions,
and the caveats for its own rows. Raw per-request records stay with the operator
who ran them; this repository publishes the derived tables and the conditions
that produced them, not a fabricated raw archive.

## Reproducing

See [performance.md](../docs/performance.md#8-reproducing-these-numbers). In
short: qualify the fabric, take a `bin/spark bench` baseline, then run the
harness whose workload you actually care about — and report it with the state
described above.
