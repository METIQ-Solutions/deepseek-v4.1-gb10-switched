# Troubleshooting

Failures we actually hit while building this deployment, in the order they tend
to appear. Ring-era (RT1/RT2/RT3) advice from older write-ups does not apply
here: the transport, the NCCL policy and the profile are different.

Each entry states the symptom, what it means, and what fixed it.

---

## Startup and configuration

### `bin/spark` looks for a ring node map and fails

```
... config/nodes-ring4.local.json: no such file
```

The profile was not named. `bin/spark` falls back to the recipe's
`default_shape` (`tp4-ring`) and looks for the ring's node map.

**Fix:** pass the profile *before* the subcommand:

```sh
bin/spark --cluster-config config/tp4-switched.local.json cluster start --apply --unqualified-shape
```

Every command that changes nodes needs it. There is no default for a mutating
command, deliberately.

### `cluster sync` refuses the checkout

Two distinct refusals:

| Message meaning | Cause | Fix |
| --- | --- | --- |
| uncommitted files on a node | your site profile is inside the tree but not ignored | keep site files at `config/tp4-switched.local.json` and `config/nodes.json` (both ignored), or commit on your own branch |
| the commit is not published on `origin` | you are on a local commit or a shallow clone cannot see the ancestry | fetch `origin/main`; the pinned commit must be an ancestor of a branch on `origin` |

`cluster sync` deploys only commits that anyone could name. That is a safety
property, not an inconvenience.

### `cluster start` refuses an unqualified shape

```
shape tp4-switched has no qualified release benchmark
```

Expected. Our site shape has no upstream `benchmark_reference`, because no
upstream release benchmark was run on a switched fabric. Add
`--unqualified-shape` to acknowledge that. It disables no check.

### Configuration changes but `doctor --live` still reports the old command

The running container's arguments were compared against the profile — and they
differ. A profile edit does not restart anything. Stop and start with
`--replace`:

```sh
bin/spark --cluster-config config/tp4-switched.local.json cluster stop  --apply
bin/spark --cluster-config config/tp4-switched.local.json cluster start --apply --unqualified-shape --replace
```

---

## Fabric

### Reachability is fine, collectives are slow or stall

The most expensive class of failure, because nothing errors. Check, in order:

1. **Both device paths of the switch port listed?** On the reference GB10 board
   one physical port is reached by two RDMA devices (`rocep1s0f1`,
   `roceP2p1s0f1`). Listing one gives roughly half the bandwidth and *no error*.
   If you list two, confirm both carried payload — per-HCA payload sampling in
   the collective probe is the only direct evidence.
2. **Same rail subnet on every node?** `roce_subnets` must agree across the map;
   the renderer validates it, but a hand-edited map can still be wrong.
3. **MTU 9000 end to end?** A host at 9000 behind a switch port at 1500 works for
   small collectives and degrades on large ones. Jumbo ping is the cheap test.
4. **GID index correct?** It must be the entry whose type file says `RoCE v2`
   with your IPv4 address in it.
5. **Rendezvous on the right interface?** `NCCL_SOCKET_IFNAME`,
   `GLOO_SOCKET_IFNAME` and `TP_SOCKET_IFNAME` come from
   `management_interface`. If that is a bridge, an overlay or a wireless device,
   bootstrap may work intermittently.
6. **Ring controls left in the profile?** `NCCL_ALGO`, `NCCL_MIN_NCHANNELS`,
   `NCCL_MIN_TRAFFIC_PER_CHANNEL`, `NCCL_THREAD_THRESHOLDS`,
   `NCCL_SWITCHLESS_BIDIRECTIONAL`. A switched profile must not carry them; the
   renderer rejects them, so seeing them means the profile was edited by hand.

### `ping` works but RDMA does not

`ping` proves IP reachability through the switch, not RDMA. Prove RDMA
separately:

```sh
ib_read_bw -d rocep1s0f1 -x 3 -i 1 -s 1048576 -q 8 -D 5 <peer>
rdma link show
ibdev2netdev
```

Our pair reads measured ~11,677 MB/s. A link that reports `ACTIVE` but carries
nothing usually means the GID index or the device name is wrong for that port.

### Reading `gids/3` looks like garbage

```sh
cat /sys/class/infiniband/rocep1s0f1/ports/1/gids/3
::ffff:0a64:000b
```

That is `10.100.0.11` as an IPv4-mapped IPv6 address, in hex. This is not a v6
address and not an error. Do not grep it for dotted-quad text — that mistake
cost us a full validation cycle. Compare the type file instead
(`.../gid_attrs/types/3` → `RoCE v2`) and decode the hex, or let
`validate-fabric.sh` do it.

### The collective probe refuses to start

```
deployment transport mismatch
```

The ranks disagree about `SPARK_DEPLOYMENT_TRANSPORT`. Usually one node is
running a container set with an older profile. Re-render the profile, re-sync
and re-probe. This check exists precisely because environment variables are easy
to get "almost right".

---

## Model and checkpoint

### Checkpoint looks downloaded but startup fails

A snapshot directory, or a plausible-looking size, is not completion evidence.
We watched four caches report 35 GB, 17 GB, 417 GB and 43 GB while all four
looked "present"; the index declares 510,286,023,000 bytes.

Verify offline, on every node, before starting:

```sh
HF_HUB_OFFLINE=1 hf download deepseek-ai/DeepSeek-V4.1-Flash-1017 \
  --revision 1bae0e1088993b9b82de08f59de5be5a34e42170
```

This must exit 0 with nothing to download. `HF_HUB_OFFLINE=1` on the serving
container comes from the profile; a runtime that starts with a partial cache can
fail minutes into loading, with errors that point at the model rather than at
the download.

### Copying the cache between nodes breaks the snapshot

Recent `hf` versions link repository files into a shared blob store under
`hub/blobs`. Copy **both** `hub/blobs` and the repository's snapshot directory.
Copying only the snapshot produces dangling links that resolve to nothing.

### Two checkpoints, two caches

`DeepSeek-V4.1-Flash` (`dba1be0a`) and `DeepSeek-V4.1-Flash-1017` (`1bae0e10`)
share config, tokenizer and tensor layout but **every weight shard differs**.
The `1030` recipe selects `1017`. Never reuse one cache for the other, and never
mix them in one cluster.

---

## Runtime

### The first start takes a very long time

Expected. The first start JIT-compiles kernels into `cache/spark-ds41f/jit/`,
and a cold four-node start includes checkpoint loading of ~510 GB of weights
split across ranks. Timeouts are set accordingly
(`VLLM_ENGINE_READY_TIMEOUT_S=3600`, `ready_timeout_seconds=3600`). A start that
is slow but progressing is not a hang; check the rank logs rather than
restarting.

### A start rolled back and left logs

`bin/spark` keeps each rank's log under `results/private/failed-starts/` when a
memory guard trips or readiness fails. The guard trips at 5 GiB during startup
and 3 GiB steady-state. Read the log of the rank that failed first — usually the
head, because it starts last and waits.

### Responses come back with empty `content` and a full `usage`

Some responses carry visible text in `delta.reasoning` rather than
`delta.content` when thinking is enabled. A client that only accumulates
`content` reports an empty response and blames the server. Parse both, and use
`chat_template_kwargs.thinking=false` for benchmarks where you want plain text.

### A 128-token completion occasionally comes back empty

We saw this at the short output cap in early 120-minute soaks (0.8–1.6% of
requests) and did not see it at a 1,024-token cap (417/417). We did not
root-cause it. If you depend on tiny completions, test that path explicitly
rather than assuming the long-generation result covers it.

---

## GPU clocks stuck low under load

Symptom: GPU utilization reads ~96%, throughput is a fraction of expectation,
and clocks sit between ~500 and ~750 MHz with power around 10 W. Upstream's
`doctor --live` samples `clocks.sm` once after readiness and fails below
1,000 MHz.

This is real, and it is not an artifact of idle down-clocking. We observed it on
all four nodes in earlier runs, with under-load samples in the 513–728 MHz range
while utilization was 96%, and it recovered only after a full power cycle:
shutdown, **remove AC power for at least one minute**, power back on. A warm
reboot did not clear it, and neither did `nvidia-smi -lgc`. Upstream documents
the same condition and the same recovery in its
[`docs/recovery.md`](https://github.com/christopherowen/spark-ds41f/blob/main/docs/recovery.md).

After the AC cycle, a model-free 45-second FP16 matrix probe on each node
reported loaded-clock medians of 2,301–2,379 MHz at 93–95 W and ≤66 °C.
Subsequent serving ran at 2.44–2.54 GHz.

What this means for you: **a low throughput number on a GB10 may be a hardware
state, not a configuration problem.** Before you touch the profile, sample
clocks under load and compare with the numbers above. If they are wrong, no
amount of NCCL tuning will help.

---

## Memory on GB10 is not what the graphs suggest

Three traps, all of which cost us time:

1. **"80% memory used" is not 80% stuck.** `MemTotal − MemAvailable` includes
   reclaimable page cache and slab. On these nodes `MemTotal` is 123.72 GiB and
   `MemAvailable` is ~22–24 GiB while serving; that is normal, not a leak.
2. **`nvidia-smi` reports `N/A` for GB10 total/used/free framebuffer.** There is
   no readable framebuffer-usage number. Per-process "used GPU memory" from
   `nvidia-smi --query-compute-apps` is a process-reported value, not the
   framebuffer, and it is not directly comparable with the cgroup's
   `memory.current`.
3. **Linux memory categories overlap.** `AnonPages`, `Cached`, `Active_file`,
   `Inactive_file`, `Shmem`, `Slab` (with `SReclaimable`/`SUnreclaim`) must not be
   summed. Use `MemAvailable` for headroom and the cgroup's
   `memory.current`/`memory.peak` for the container, and treat each as a
   separate metric.

A cgroup `memory.peak` from startup is a high-water mark during checkpoint load,
not steady-state usage. Comparing it with a mid-request `memory.current` sample
produces a scary and meaningless "gap".

---

## Performance surprises

### Throughput doubles with no configuration change

Check the prefix cache first. On identical prompts with a 130K context we
measured 55.20 tok/s cold and 125.92 tok/s warm — a 2.3× difference from cache
state alone, plus 31.3 s versus 0.81 s TTFT. Any benchmark that does not state
its cache state is not a benchmark.

### Prefill is well below upstream's reference

Ours is 14–19% below the upstream ring reference while decode is within 2%.
This is documented in [performance.md](performance.md#3-source-text-prefill)
with the explanations we ruled out. We do not have a root cause; treat any
one-line explanation you read elsewhere with suspicion.

### Everything is slower after a reboot

Check clocks before anything else (see above), then check that the fabric
interface came back with the right MTU and address, then check that the image
and profile are the ones you think they are (`doctor --live`).

---

## Before you ask for help

Collect, from the head node and one worker:

```sh
bin/spark --cluster-config config/tp4-switched.local.json doctor --live
bin/spark status
bin/spark render <node>
rdma link show
ip -4 -o address show dev <fabric-iface>
ip -o link show dev <fabric-iface>
nvidia-smi --query-gpu=clocks.sm,power.draw,utilization.gpu,temperature.gpu --format=csv
```

and from the failing rank: its container log, `dmesg | tail -50`, and the
`results/private/failed-starts/` entry if a start rolled back.

Runtime, transport and NCCL questions belong in Owen's issue trackers, with the
pinned commit and the rendered environment attached. Problems with *this*
deployment description belong here.
