# Operational notes

What we learned running this deployment. Everything here is supported by
evidence recorded during the campaign; speculative additions are marked as such
or left out.

---

## 1. Qualify the fabric before you start inference

The cheapest hour is the one before the first start.

A switched fabric that is misconfigured does not fail — it works at reduced
bandwidth, with no error in any log, and every downstream number is quietly
wrong. Two specific traps cost us real time:

- A single-device rail. On the reference GB10 board, one switch port is reached
  through two RDMA device paths. Listing one halves the bandwidth silently.
- Reading the GID table as text. `gids/3` prints an IPv4-mapped IPv6 value in
  hex; searching it for dotted-quad text finds nothing and looks like a
  missing configuration.

Establish, per node, before starting anything: interface/address/MTU, GID index
and type, RDMA-to-netdev mapping and `ACTIVE` state, and jumbo-frame
reachability to every peer. Then measure pair bandwidth with the service
stopped. Our reconciliation was ~93.4 Gb/s per pair on 100 GbE, consistent with
a single path, and that consistency is exactly why the measurement was worth
taking.

## 2. On a switch, topology is data — not tuning

Coming from a ring, the instinct is to tune NCCL: pin the algorithm, fix the
channel count, balance traffic per channel. On a switch all of that is wrong.
SparkNet's `switched` profile keeps NCCL's own topology and algorithm selection
and hands the fabric policy to the one-shot transport; the ring's controls are
rejected, not ignored, because a switchless setting changes dispatch silently.

The practical rule: **if you are editing NCCL variables in a switched profile,
you are probably solving the wrong problem.** Change the node map, the
addressing or the release — not the transport knobs.

## 3. Pin everything, and never mix generations

Four identities have to agree on every node, and each is easy to get subtly
wrong:

| Identity | Consequence of drift |
| --- | --- |
| Runtime release + commit | image labels mismatch; `doctor --live` fails; behaviour differs between ranks |
| SparkNet revision | the renderer and the probe disagree about the transport |
| Checkpoint revision | the `1017` and original checkpoints share layout but not weights — mixing them "works" and produces wrong output |
| Site profile + node map | containers start with one person's idea of the fabric |

Two practical implications:

- **Do not reuse caches across checkpoint generations.** They look
  interchangeable and are not.
- **Keep the previous image tag.** `bin/spark` refuses to overwrite an existing
  tag, so a tag from yesterday is a usable rollback.

## 4. GB10 memory pressure is real, and mostly invisible

Unified memory means host and accelerator share one pool. Consequences:

- `nvidia-smi` cannot tell you framebuffer usage on GB10 (`N/A` on total, used
  and free). Process-reported "GPU memory" is a different metric from cgroup
  `memory.current`, and neither is the framebuffer.
- "80% memory used" on a host graph is mostly reclaimable cache, not a leak.
  `MemAvailable` is the headroom metric; understand that `MemTotal − MemAvailable`
  includes reclaimable memory.
- The runtime's memory guards are load-bearing, not decoration. A 5 GiB startup
  guard and a 3 GiB steady guard with a rollback on trip is the difference
  between a failed start and a node that needs intervention.
- Headroom that looks generous can be consumed by a single long-context
  request. Ours stayed ≥21.7 GiB `MemAvailable` through a 124.5-minute soak and
  ~23.9–25.4 GiB through 1M prefill, with zero OOM kills — but that is *this*
  context mix, not a guarantee.

## 5. Start, stop and recover as a cluster

TP4 over four nodes has one coordinated lifecycle, not four independent ones.

- Workers start before the head; the head is the last to be ready and the first
  to reveal a problem. Watch the head first when a start stalls.
- Startup guards are armed before any rank starts, and readiness waits for them
  to report. A guard trip rolls the whole launch back and leaves per-rank logs
  under `results/private/failed-starts/`. Read the first failing rank's log; the
  others are downstream noise.
- Stop with **the same profile** the engine was started from. The stop path
  refuses a profile that covers only some of the engine's nodes — that refusal
  is protecting you from half a cluster.
- Replacing a running service needs `--replace` in addition to `--apply`. Adding
  `--replace` to a failing start does not skip checks; it only permits replacing
  existing exact containers.
- The first start after a build is much slower (JIT compilation). Do not
  interpret it as a hang and restart into an even slower state.

## 6. Verify long context with retrieval, not with a flag

`--max-model-len 1048576` proves that a number was accepted. It does not prove
that a request at that length is answered correctly.

Our gate: insert a unique code at 25%, 50% and 75% depth of a genuinely 1M-token
prompt, ask for it, and require exact retrieval (6/6). Two details that make or
break the test:

- **Check `usage.prompt_tokens` against your target.** A tokenizer disagreement
  turns a 1M test into a 700K test that passes comfortably.
- **Expect minutes.** Our 1M requests took 222–223 s end to end. That is the
  configured runtime behaving correctly; a client timeout is a client setting.

We also ran the retrieval matrix on a trace-enabled instance and did not use
those numbers as performance measurements. Different purpose, different
instance.

## 7. GPU utilization is not throughput

We spent a long time looking at ~96% utilization and a fraction of expected
throughput. The cause was neither the model nor the fabric: the GB10s were
latched at 513–728 MHz under load, drawing ~10 W, with no throttle reason
reported. A warm reboot did not clear it and `nvidia-smi -lgc` did not either;
removing AC power for a minute did.

Lesson: **sample clocks and power, not just utilization.** A utilization
percentage tells you the GPU is busy; it does not tell you how fast it is
working. When throughput moves by tens of percent without a configuration
change, check clocks before you check anything else.

## 8. Benchmark state is part of the result

Two measurements of the same service can differ by more than 2× purely from
runtime state:

- **Prefix cache.** 55.20 tok/s cold versus 125.92 tok/s warm at a 130K context,
  with the same prompts and the same service. TTFT moved from 31.3 s to 0.81 s.
- **Trace instrumentation.** Useful for proving the transport, not for
  performance numbers.
- **Harness identity.** A long-generation sweep at 1,024 output tokens and a
  closed-loop 256-token workload are not the same measurement, even at the same
  concurrency.

So: state the harness, the prompt and output lengths, the cache state, the
repetitions and the attribution gate. Our own numbers are published that way,
including the ones that make us look worse.

## 9. Attribution discipline

The switched transport is upstream's work. Our prefill is 14–19% below upstream's
ring reference and we do not know why. The switch is not demonstrably faster
than a ring, and we did not run the A/B that would answer it.

Writing this down was harder than writing the instructions, and more useful. A
deployment reference that claims a transport win it did not measure is a
citation hazard; one that names its gaps lets the next operator reproduce what
is real.

## 10. What we would do differently

- **Cable both device paths per node** if the addressing permits it, then prove
  both carried payload with per-HCA sampling. We left one path unaddressed and
  accepted the bandwidth cost rather than change host networking mid-campaign.
- **Record the switch configuration** — PFC, ECN, QoS, firmware, port settings.
  Without it, "worked on defaults" is not a reproducible statement, and we cannot
  say whether a lossless class was in play.
- **Set the RoCE traffic class** (DSCP 26 / ECT(0), byte 106) and measure marked
  versus unmarked, rather than leaving it at best-effort and noting it later.
- **Run a controlled ring-versus-switch A/B** on identical hardware and the same
  build, so the transport question has an answer instead of a citation.
- **Capture per-collective counters** rather than aggregate RoCE bytes, so a
  fabric question can be answered at the operation level.
