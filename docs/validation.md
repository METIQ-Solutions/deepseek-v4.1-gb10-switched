# Validation

A switched fabric has a failure mode that no error message will tell you about:
it works, at some fraction of the bandwidth you paid for. Every layer below
exists to make that specific outcome impossible to miss.

Six layers, in the order you run them. Each one says what it proves and what it
does **not** prove — that distinction is the useful part.

| # | Layer | Tool | Proves |
| --- | --- | --- | --- |
| 1 | Configuration coherence | `bin/spark doctor`, `bin/spark render` | The profile and node map are internally consistent and renderable. Nothing about hardware. |
| 2 | Host and fabric | `scripts/validate-fabric.sh` | Each node's interface, address, MTU, HCA, GID and peer reachability match the map. |
| 3 | Launch preflight | `bin/spark ... cluster start --apply` | Kernel, driver, memory policy, image labels and fabric checks across all ranks, before any container starts. |
| 4 | Live comparison | `bin/spark ... doctor --live` | The *running* service and nodes still match the profile. |
| 5 | Collective probe | `bin/spark ... topology probe` + `probe_collectives.py` | RDMA collectives complete over the switched fabric with the configured identity. |
| 6 | Functional and long-context | API requests, retrieval tests, soak | The model serves, the context limit is real, and it survives sustained load. |

---

## 1. Configuration coherence

```sh
bin/spark --cluster-config config/tp4-switched.local.json doctor
bin/spark --cluster-config config/tp4-switched.local.json render node-1
```

`doctor` validates the profile, node map, model paths and repository state, and
prints `configuration OK`. `render` prints the environment a rank will receive;
read it once and compare it with
[switched-configuration.md](switched-configuration.md#the-node-map). You are
looking for `SPARKNET_ROCE_HCA`, `NCCL_IB_HCA` (leading `=`), the GID index, the
socket interface, and the **absence** of `NCCL_ALGO`,
`NCCL_MIN_NCHANNELS`, `NCCL_MIN_TRAFFIC_PER_CHANNEL`, `NCCL_THREAD_THRESHOLDS`
and `NCCL_SWITCHLESS_BIDIRECTIONAL`.

Neither command touches a node. Both fail if you added a ring control to a
switched profile — that is a feature.

## 2. Host and fabric

Run on **every** node:

```sh
./scripts/validate-fabric.sh \
  --interface enp1s0f1np1 \
  --hca rocep1s0f1 \
  --gid-index 3 \
  --mtu 9000 \
  --peers 10.100.0.12,10.100.0.13,10.100.0.14
```

Checks, all read-only:

1. The interface exists, has an IPv4 address in the expected subnet, is up, and
   has the expected MTU.
2. The HCA device exists and its GID table entry at the given index resolves to
   that same IPv4 address.
3. The GID's type is `RoCE v2` and the RDMA device is mapped to that netdev and
   `ACTIVE`.
4. A jumbo-frame ping (`-M do`, MTU − 28 bytes) reaches every peer through that
   interface, with zero loss.

Options: `--subnet 10.100.0.0/24` to assert the address is in the rail subnet,
`--bandwidth <peer>` for the optional RDMA read test (see below), `--timeout`
and `--count` for slow fabrics. Exit status is non-zero on any failed check.
The script requires `ip`, `ping` and `rdma`/`ibdev2netdev` from iproute2 and
rdma-core, `bash` 4+, and root-free read access to `/sys/class/infiniband`.

What it does **not** prove: that RDMA actually works, or that both device paths
of your switch port are in use. Reachability is IP-level.

### Optional: bandwidth

With serving stopped, from each node towards each peer:

```sh
./scripts/validate-fabric.sh --interface enp1s0f1np1 --hca rocep1s0f1 \
  --gid-index 3 --peers 10.100.0.12 --bandwidth 10.100.0.12
```

This wraps `ib_read_bw` (1 MiB messages, 8 QPs, 5 s) and requires `perftest`.
Our six pair tests measured 11,677–11,678 MB/s ≈ 93.4 Gb/s on a 100 GbE link.
Materially less than that on a 100 GbE fabric means a single device path, a
misnegotiated link, or an MTU problem — not a runtime problem.

## 3. Launch preflight

`cluster start --apply` runs the preflight itself and refuses to start on a
failure. That includes the cross-rank comparison `doctor --live` cannot do
before the service exists: kernel, page size, driver, memory policy, image
labels and the fabric contract must be identical and valid on all four nodes.

A preflight failure is a real failure. Do not "fix" it with `--replace`; that
flag replaces existing containers, it does not skip checks.

## 4. Live comparison

```sh
bin/spark --cluster-config config/tp4-switched.local.json doctor --live
```

Compares the running container's command line, image, labels, environment and
fabric mapping against the profile, and checks node-level facts again. Warnings
are expected and should be read; errors are not.

## 5. Collective probe — the one that matters

The probe is model-free: it starts a small container per rank and runs an
all-reduce/all-gather set over the configured transport. It is the only check
that proves the switched fabric carries collectives *with your profile's
environment*, rather than merely that the link is reachable.

Serving must be stopped, and all four ranks must run in one coordinated window.

```sh
# prints a plan-only docker command for one node; nothing is executed
bin/spark --cluster-config config/tp4-switched.local.json topology probe node-1 --master-port 29999
```

Run the printed command on each node within the same window. The probe reads
`SPARK_DEPLOYMENT_TRANSPORT` and refuses to start if the ranks disagree about
the deployment identity — which is exactly how you catch "I thought this was a
switched profile" mistakes before they turn into a stalled all-reduce.

Append `--port-samples` to the printed `python3 /probe.py ...` arguments to
record per-HCA payload and per-port counters. **If you list two device paths per
node, this is the check that tells you whether both carried traffic**; a map
that lists one device, or two devices on different ports, runs at reduced
bandwidth with no error anywhere.

What it does **not** prove: that the *serving* engine uses the same path. For
that, run inference under SparkNet's trace and confirm the one-shot sequence
advances on every rank (see below).

### Optional: proving it during inference

SparkNet can emit one-shot trace records (`SPARKNET_ROCE_TRACE=1`, a supported
upstream setting) around real traffic. We used this to prove that the switched
one-shot path — not a silent NCCL fallback — carried inference: a traced
startup, a trace baseline, API inference, and a second capture, requiring

- sequence advancement on **all four** ranks,
- direct arrivals from **all three** peers per rank,
- all **six** pair timing summaries present.

Environment variables alone cannot satisfy that gate; the trace records can.
Our trace harness was internal and is not published here, but the mechanism is
upstream and the acceptance criteria above are the ones we applied. If you
cannot reproduce a trace check, treat "the transport is in use" as unverified.

## 6. Functional and long-context validation

### Model identity

```sh
curl -s http://<head>:8000/v1/models | jq -r '.data[].id'
```

One name (`deepseek-v4.1-flash`) unless you kept the GLP block.

### Chat, tools, reasoning

Plain chat completion; a request with `tools` and `tool_choice` to confirm
`--enable-auto-tool-choice` works end to end; and one request at each supported
reasoning level if your clients use them (`chat_template_kwargs.thinking` or the
documented effort aliases). A response whose text arrives in `delta.reasoning`
rather than `delta.content` is valid.

### Near-1M retrieval — the hard context gate

Starting successfully with `--max-model-len 1048576` is **not** evidence that
the context works. Insert a unique fact deep inside a genuinely large prompt and
ask for it back:

- total prompt length ≥ 95% of 1,048,576 tokens,
- a unique, unguessable retrieval code at 25%, 50% and 75% depth (two samples
  each is what we ran: 6 requests),
- a small output budget (we used 256 tokens),
- verify exact retrieval, not "plausible answer".

Our six requests all retrieved exactly, with full-request times of 222.1–223.0 s
on a trace-enabled instance. Expect a long wait: a ~1M-token prefill takes
minutes, and that is the runtime behaving as configured, not hanging.

Also record `usage.prompt_tokens` from the response and confirm it is close to
what you intended to send — a tokenizer disagreement makes a "1M" test a 800K
test with a comfortable pass.

### Sustained load

Run a mixed soak against the live service. Ours alternated short and long
generation bursts with conversations and tool calls, for a little over two
hours, with a fail-closed monitor for: node unreachable or rebooted, a new OOM
kill, `MemAvailable` below 4 GiB, or a loaded SM clock below 1 GHz at ≥70%
utilization ([troubleshooting](troubleshooting.md#gpu-clocks-stuck-low-under-load)).

Result to compare against: 124.5 minutes, 43 cycles, 417/417 requests,
43/43 conversations, 10/10 tool round-trips, minimum `MemAvailable` 21.7 GiB,
no OOM, no PSI pressure, no swap-out, no process restart, 63 °C maximum.

A soak that "mostly" passes is not a pass. Record the per-cycle numbers, not a
summary.

---

## What we validated, and when

| Date | Validation | Outcome |
| --- | --- | --- |
| 2026-10-31 | Read-only host baseline on all four nodes | Passed, no changes |
| 2026-10-31 | Fabric preflight: rank/addressing, GID 3 RoCE v2, MTU 9000, RDMA-netdev mapping, 3 peer pings per node | Passed with `changed=0` |
| 2026-11-01 | RDMA pairwise bandwidth, 1 MiB / 8 QPs / 5 s | 11,677–11,678 MB/s (~93.4 Gb/s) per pair |
| 2026-11-01 | Model-free switched collective probe | Passed |
| 2026-11-02 | Traced start + live doctor (`configuration OK`, 46 warnings) | Passed |
| 2026-11-02 | Inference advances the one-shot trace on all ranks; 4/4 direct peers; 6/6 pair timings | Passed |
| 2026-11-02 | Near-1M retrieval, 25/50/75% × 2 | 6/6 exact |
| 2026-11-02 | Untraced start, live doctor, API/model identity, tool call, reasoning levels (none/low/high/max) | Passed |
| 2026-11-02 | Owen-equivalent decode C1/C8, two repetitions each | 77.645 / 194.607 tok/s |
| 2026-11-02 | Source prefill 32K → 1M, three samples each | 5,935 / 6,044 / 5,853 / 5,443 / 4,734 tok/s |
| 2026-11-03 | Concurrency sweep C1–C16 at ~8K and ~32K, three repetitions | See [performance](performance.md) |
| 2026-11-03 | Stability soak, 124.5 min | 417/417 requests, no adverse events |

The `configuration OK; 46 warnings` doctor line is upstream's live doctor
reporting expected, non-blocking differences (node-local settings it cannot
reconcile with a reference). Read warnings; only errors block.

---

## Failure diagnosis

[troubleshooting.md](troubleshooting.md) covers the failures we actually hit,
including the ones that cost the most time: a collective that silently halves
itself, a checkpoint that looks complete, and GPU clocks that are wrong while
utilization reads 96%.
