# 2026-11-02 — Owen-equivalent decode and source prefill

The measurement that can be compared with upstream's published release
figures, because it uses upstream's own workload.

## Conditions

| | |
| --- | --- |
| Service | untraced, otherwise idle, TP4 across four GB10 nodes |
| Transport | `oneshot-switched` over 100 GbE, one rail per node |
| Runtime | `spark-ds41f-1030` @ `9461a70546fcfdcac9c7d8fbc58a53230510fbc9` |
| Model | `DeepSeek-V4.1-Flash-1017` @ `1bae0e1088993b9b82de08f59de5be5a34e42170` |
| Context | 1,048,576; KV `11274289152` bytes per rank |
| Host | kernel `7.0.0-1019-nvidia-64k`, driver `580.178.04`, 64 KiB pages |
| Decode harness | `servebench`: closed loop, 60 s warmup, 300 s measurement, 10 batches, default prompts, seed 0, 256-token completions, thinking off |
| Decode repetitions | 2 per concurrency |
| Prefill harness | source text, one-token completions, three samples per size |
| Thinking | off |

All decode repetitions reported zero request errors, zero foreign requests, zero
prefix-cache hits, and exact token timing.

## Decode

| Load | Repetition 1 | Repetition 2 | Mean | Per-request | Engine steps/s | Output tokens/step | Accepted/draft | p50 TTFT | p50 TPOT |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| C1 | 77.723 tok/s | 77.567 tok/s | **77.645 tok/s** | 77.7–78.1 tok/s | 34.11–34.16 | 2.275–2.279 | 1.277–1.280 | 0.125 s | 12.7 ms |
| C8 | 194.420 tok/s | 194.793 tok/s | **194.607 tok/s** | ~24.3 tok/s | 11.75–11.78 | 16.520–16.592 | 1.316–1.319 | 0.293–0.297 s | 40.5 ms |

Interpretation:

- Speculative decoding was active for the whole window (`accepted_per_draft`
  1.28–1.32; output tokens per engine step rising from ~2.28 to ~16.5).
- Aggregate throughput at C8 is ~2.5× C1 while per-request rate falls to ~31%,
  i.e. batching behaves as expected rather than superlinearly.
- Engine step rate falls from ~34/s to ~11.8/s as batch size grows — the
  expected trade of more work per step.

## Comparison with upstream's published ring reference

Upstream's `spark-ds41f-1030` README reports, on their four-node **ring** over a
200 Gb/s switch: **78.3 tok/s** at one stream and **198.4 output tok/s** at
eight.

| Load | Ours | Reference | Difference |
| --- | ---: | ---: | ---: |
| C1 | 77.645 | 78.3 | −0.8% |
| C8 | 194.607 | 198.4 | −1.9% |

What this comparison supports: on a 100 GbE switched fabric with one rail per
node, decode is within 2% of the ring reference.

What it does **not** support: any claim that the switched transport is faster or
slower than a ring. The fabrics, rail counts and switch speeds differ, no
controlled A/B was run, and upstream's own switched-versus-ring comparison
(+3.1% geometric mean over 24 cells) explicitly declined to call that a transport
win.

## Source prefill

| Prompt tokens | Sample 1 | Sample 2 | Sample 3 | Mean | Upstream reference | Difference |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 32,768 | — | — | — | **5,935 tok/s** | 7,313 | −18.8% |
| 131,072 | — | — | — | **6,044 tok/s** | 7,396 | −18.3% |
| 262,144 | — | — | — | **5,853 tok/s** | 7,120 | −17.8% |
| 524,288 | — | — | — | **5,443 tok/s** | 6,538 | −16.7% |
| 1,000,000 | — | — | — | **4,734 tok/s** | 5,549 | −14.7% |

Per-sample throughput is not retained in the summary table; the means above are
over three one-token samples per size, with no failed samples. At 1M, actual
prompt lengths were 996,544–998,585 tokens and TTFT was 210.21–211.02 s (mean
210.67 s).

**This gap is real and unexplained.** Observations that help constrain it:

| Hypothesis | Evidence |
| --- | --- |
| GPU clocks | Rejected for these windows: ~2.42–2.49 GHz sampled during 1M prefill |
| Host memory pressure | Rejected: `MemAvailable` minimum ~23.9–25.4 GiB, zero OOM kills, negligible PSI |
| Broken fabric | Rejected: ~93.4 Gb/s pairwise RDMA read; 1M prefill carried ~3.6–3.8 GB/s per node |
| Single-device rail | Not isolated; plausible contributor, untested |
| Fabric topology/speed | Not isolated; upstream saw prefill as the ring's advantage, which is consistent but not proof |

We are not publishing a cause we did not measure.

## Hardware during the windows

| Metric | C1/C8 decode (300 s windows) | 1M prefill |
| --- | --- | --- |
| GPU utilization | ~96% on all four nodes | ~96% |
| SM clock (per-node means) | ~2.44–2.54 GHz | ~2.42–2.49 GHz |
| Power draw | ~36–46 W | — |
| Maximum temperature | 69 °C | — |
| `MemAvailable` | ~24.4–25.5 GiB | ~23.9–25.4 GiB minimum |
| RoCE counters per node | ~0.49 / 0.94 GB/s (C1 / C8) | ~3.6–3.8 GB/s |

RoCE counters are aggregate device counters, not NCCL-attributed traffic, and
they sit well below the 100 Gb/s link rate in every window.

## Caveats

- Two repetitions per decode load is enough to detect a gross problem, not to
  resolve a 1% difference. The comparison above is stated to one decimal place
  for readability, not precision.
- Prefill means are over three samples; per-sample values are not reproduced
  here.
- These are cross-fabric comparisons, not controlled experiments.
- Nothing in this file was measured on a trace-enabled instance.
