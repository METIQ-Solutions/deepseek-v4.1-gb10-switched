# The switched configuration, and what actually differs from a ring

This is the technical core of the repository: the site configuration that makes
four GB10 nodes run DeepSeek V4.1 Flash **through a switch**, and an honest
account of which parts of it are *required by the switched fabric*, which are
required by *our hardware*, which are *site preference*, and which are simply
upstream's values left alone.

Everything here is expressed through files and interfaces that upstream already
provides. No upstream source file is patched, and no runtime code is added.

---

## How an upstream profile becomes a switched one

Upstream ships one recipe — `releases/spark-ds41f-1030/cluster.json` — that
describes every shape on one image. A shape changes the cabling, the transport
and the memory sizing. Switched is *not* a separate build: it is the same image
with a different fabric declaration and a different node map.

Three upstream inputs produce our profile:

| Input | What it contributes |
| --- | --- |
| `releases/spark-ds41f-1030/cluster.json` (release recipe) | Shared environment, `serve_args`, container recipe, host memory guards, model + checkpoint selection, sizing for `tp4-ring` |
| `scripts/recipe.py` (`resolve`) | Flattens the recipe's `tp4-ring` shape into a concrete profile |
| `sparknet/nccl/profiles.py` (`environment`, `profile`) | The `switched` profile's NCCL and one-shot settings |

`configs/cluster.example.json` in this repository is the **output** of that
process for one concrete site: a resolved profile, not a recipe. It has no
`shapes` block, so `bin/spark` uses it directly rather than resolving a shape
again.

The derivation is:

```
environment =
    release recipe environment                             # shared
  + release tp4-ring shape environment, minus every
    NCCL_* and SPARKNET_ROCE_* key                         # sizing-era leftovers
  + sparknet COMMON_IB_ENV                                 # fabric policy
  + sparknet switched profile: nccl + oneshot              # the switched numbers
  - every key the profile sets to None                     # "use the default"
  - GLOO_SOCKET_IFNAME, TP_SOCKET_IFNAME, NCCL_SOCKET_IFNAME
                                                           # rendered per node
```

That ordering matters. The shape's ring-era NCCL values are dropped *before*
the switched profile is applied, so a ring control cannot survive by accident.
The last three socket variables are removed because, on a switched fabric, the
rendezvous interface comes from the node map (`management_interface`) and is
identical for every rank only if your nodes are identical — upstream renders it
per node instead of assuming.

Per rank, `sparknet/topology/render.py` then adds:

| Variable | Value (our site) | Source |
| --- | --- | --- |
| `SPARKNET_ROCE_TOPOLOGY` | `direct` | transport (`oneshot-switched` → a direct clique) |
| `SPARKNET_ROCE_HCA` | `rocep1s0f1` | the node's `roce_hcas` |
| `SPARKNET_ROCE_GID_INDEX` | `3` | the node's `roce_gid_index` |
| `NCCL_IB_HCA` | `=rocep1s0f1` | the node's `nccl_hcas`, else `roce_hcas`; `=` forces exact device matching |
| `NCCL_IB_GID_INDEX` | `3` | the node's `roce_gid_index` |
| `NCCL_SOCKET_IFNAME`, `GLOO_SOCKET_IFNAME`, `TP_SOCKET_IFNAME` | `enp1s0f0np0` | the node's `management_interface` |
| `SPARK_DEPLOYMENT_TRANSPORT` | `oneshot-switched` | the deployment's transport, so the probe cannot confuse a physical switch with SparkNet's `direct` kernel mode |

`SPARKNET_ROCE_TOPOLOGY=direct` does **not** mean "direct cables". It is the
kernel-side clique mode, and it is the same string on both fabrics; the
deployment identity is `SPARK_DEPLOYMENT_TRANSPORT`, which is why upstream
renders it separately. Confusing the two is the single easiest way to believe a
ring is a switch.

---

## The node map

The switched schema needs three fields the switchless maps do not use. Upstream
documents them in `docs/switched-fabric.md`; in practice:

| Field | Meaning | Our value |
| --- | --- | --- |
| `management_interface` | The one interface carrying Gloo, TP and NCCL bootstrap | `enp1s0f0np0` |
| `roce_hcas` | The node's rails, in order: the RDMA devices behind its switch port | `["rocep1s0f1"]` |
| `roce_subnets` | One IPv4 `/24` per rail, **the same rail subnet on every node** | `{"rocep1s0f1": "10.100.0.0/24"}` |

Also required, and shared with the switchless schema: `name`, `rank` (head is
rank 0), `management_ip`, `head`, and `roce_gid_index` on our site (GID 3 is
RoCE v2 on the ConnectX-7 functions, on every node).

Optional fields:

| Field | When to use it |
| --- | --- |
| `nccl_hcas` | Only when NCCL should use a **different** device set than the one-shot path. Defaults to `roce_hcas`. |
| `roce_traffic_class` | The IP traffic-class byte for every RoCE packet, identical on every node. See [marking the lossless class](#what-we-did-not-set-and-why). |
| `ssh_host` | When the head reaches a node by a name other than `name` |
| `transfer_host` | Bulk-copy only (upstream laboratory feature) |

`configs/nodes.example.json` is exactly this, minimal.

### One rail, or two?

This is the most consequential hardware decision in a switched GB10 fabric, and
it is easy to get wrong silently.

On the reference GB10 board, **one physical switch port is reached through two
HCA device nodes** — for example `rocep1s0f1` and `roceP2p1s0f1` are two PCIe
paths to the same cable, not two rails. Upstream measured ~196 Gb/s all-pairs
with both listed and ~112 Gb/s with one, with **no error anywhere** in the
single-device case. Both must appear in `roce_hcas`.

Our deployment listed **one** device (`rocep1s0f1`) because the second PCIe
path's netdev had no IPv4 address in our site addressing, and we refused to
change host networking just to make it appear. Our measured ~93.4 Gb/s per pair
is consistent with a single path. That is a limitation we own, not a
recommendation: **if both of your device paths carry an address in the rail
subnet, list both, then qualify the pair** with the collective probe and its
per-HCA payload sampling (see [validation](validation.md)).

---

## Differences from upstream's resolved `tp4-ring` profile

Counted by flattening both profiles and comparing every leaf: **41
differences**, of which **21 are environment variables**. Of the 41, **26 are
transport machinery**, **14 are site identity, paths and names**, and **1 is
the fan policy**. The full list, classified.

### A. Required for switched networking

These are consequences of declaring a switched fabric. They are not tuning.

| Difference | Why |
| --- | --- |
| `fabric.transport`: `oneshot-ring4` → `oneshot-switched` | Declares the transport. A transport alone is ambiguous; a topology alone has no runtime — both are required. |
| `fabric.topology`: *(absent)* → `switched` | The other half of the declaration. |
| `nodes_config`: `config/nodes-ring4.local.json` → `config/nodes.json` | The switched node map is a different schema. |
| `shape`: `tp4-ring` → `tp4-switched` | The site shape's name, used in reports and bench comparisons. |
| `benchmark_reference` removed | Our site shape has no upstream release benchmark; claiming one would be a lie. This is why `cluster start` needs `--unqualified-shape`. |
| `NCCL_ALGO=Ring` removed | The ring fixes the algorithm. A switch keeps NCCL's own topology and algorithm selection. |
| `NCCL_MIN_NCHANNELS=4` removed | The ring fixes a channel count. |
| `NCCL_MIN_TRAFFIC_PER_CHANNEL=512` removed | Ring channel balancing. |
| `NCCL_THREAD_THRESHOLDS="-2 -2 -2 1 1 1"` removed | Ring adaptive-thread policy. |
| `NCCL_SWITCHLESS_BIDIRECTIONAL=2` removed | Bidirectional relay across ring neighbours. There are no ring neighbours. |
| `NCCL_RUNTIME_CONNECT`, `NCCL_PAT_ENABLE`, `NCCL_COLLNET_ENABLE`, `NCCL_MNNVL_ENABLE`, `NCCL_RMA_DISABLE`, `NCCL_GIN_ENABLE`, `NCCL_CUMEM_HOST_ENABLE`, `NCCL_IB_SUBNET_PREFIX_LEN` removed | The rest of SparkNet's ring policy bundle. They belong to the ring's routing model; the switched profile does not carry them. |
| `NCCL_CUMEM_ENABLE`: `1` → `0` | Ring relies on cuMem/runtime-connect behaviour; the switch does not. |
| `NCCL_MAX_NCHANNELS`: `4` → `8` | The ring pins four balanced channels. Behind a switch, eight is the switched profile's ceiling. |
| `NCCL_BUFFSIZE`: `4194304` → `1048576` | Switched profile value. |
| `SPARKNET_ROCE_ALLREDUCE_DISPATCH_MAX_BYTES=2097152` removed | Ring dispatch split. The switched profile registers capacity and lets the implementation dispatch. |
| `SPARKNET_ROCE_ALLGATHER_MAX_BYTES`: `2097152` → `4194304` | Switched profile value. |
| `GLOO_SOCKET_IFNAME`, `TP_SOCKET_IFNAME`, `NCCL_SOCKET_IFNAME` removed from the profile | Rendered per rank from the node map, so the rendezvous interface is a node-map fact rather than a profile assumption. |

Upstream does not merely ignore ring controls on a switched fabric — the
renderer **rejects** `NCCL_ALGO`, `NCCL_MIN_NCHANNELS`,
`NCCL_MIN_TRAFFIC_PER_CHANNEL`, `NCCL_THREAD_THRESHOLDS` and
`NCCL_SWITCHLESS_BIDIRECTIONAL`. Leaving one behind is an error, because a
switchless setting changes dispatch silently.

### B. Required for our hardware

| Difference | Why |
| --- | --- |
| `host.fan_control`: `true` → `false` | Upstream's fan-floor control is a DKMS module that binds **NVIDIA's P4242** board. Our nodes are ASUS GX10s with their own EC/BMC fan policy. `bin/spark doctor` then records the absence instead of erroring, and `bench` skips its fan performance curve. Setting this on a P4242 would remove a control that board needs. |
| Single rail `rocep1s0f1` in `roce_hcas` | Our second device path had no address in the rail subnet. See [one rail or two](#one-rail-or-two). |

The 64 KiB kernel and memory-saver requirements are *not* differences: the
recipe already asks for them, and our hardware met them as-is.

### C. Optional site customization

Safe to change; nothing here affects correctness of the transport.

| Difference | Our choice | Note |
| --- | --- | --- |
| `host.home` | `/home/spark` | Any user with passwordless SSH and `sudo -n` |
| `distributed.master_addr` | the head's management IP | Must be reachable from every node |
| `distributed.master_port` | `25001` on our site | Keep it below the head's ephemeral port range (`sysctl net.ipv4.tcp_local_port_range`); otherwise an outgoing connection can hold it and the head fails to start. The example keeps upstream's `9999`. |
| API port | `8889` on our site | The example keeps `8000` |
| `container.name`, `container.image` | site names | The image is built per site; upstream publishes none |
| `container.mounts` | `/cache` on a dedicated volume | The example keeps upstream's `{checkout}/cache` |
| `glp` block and `WEIGHTLESS_STEER_*` | removed | We serve only the stock model. Upstream's 1030 recipe additionally serves a GLP-steered name; removing the block also removes the second `--served-model-name` entry. Not needed for switched networking, and not a comment on it. |
| `roce_traffic_class` | omitted | See below |
| `cluster start --unqualified-shape` | required | Consequence of A's `benchmark_reference` removal |

Two more values in the example are **host-specific and must be checked** on
your machines, because the upstream recipe carries its own build host's values:
`--cpuset-cpus=5-9,15-19` in the container run arguments, and the DRM bind
source `/dev/dri/by-path/pci-000f:01:00.0-card`. Neither affects the fabric;
both will break a start on a host with a different CPU or PCI topology.
`bin/spark doctor --live` reports both.

### D. Independent runtime/security choices

| Choice | What it is | What it is not |
| --- | --- | --- |
| A bounded seccomp profile instead of `--security-opt=seccomp=unconfined` and `--security-opt=label=disable` | We replaced upstream's two LSM-relaxing flags with a Moby-default-plus-`io_uring` seccomp profile, and kept default label confinement. Our runtime ran this way for every measurement in this repository. | It is **not** a requirement of switched networking, and it is **not** a change to Owen's source: it is a container run argument in the site profile. Upstream's default is `unconfined`; if you diverge, expect to diagnose a denied syscall yourself, and do not copy our profile file blindly. |

### E. Inherited unchanged (the rest)

Sizing and serving behaviour come from upstream's `tp4-ring` shape and are
untouched: `max_model_len=1048576`, `max_num_seqs=16`,
`max_num_batched_tokens=16384`, `kv_cache_memory_bytes=11274289152`,
`prefix_cache_retention_interval=8192`, `gpu_memory_utilization=0.82`,
`--block-size 256`, TileLang for attention/linear/MoE, DSpark speculative
decoding at k=5 with adaptive verification, disk-backed Engram, the cudagraph
capture sizes, the 5 GiB startup guard and 3 GiB steady guard, the kernel
requirements, and the container's `expected_labels`.

We did not retune the model for the switch. Anything that looks like a tuning
knob above is a *transport* value from Owen's switched profile, and the numbers
he recorded are the numbers we ran.

---

## The effective environment, in full

This is the profile-level environment of `configs/cluster.example.json`, i.e.
what every rank receives before the per-node rendering above. Grouped by origin.

**Fabric policy — SparkNet `COMMON_IB_ENV` (identical to the ring):**
`NCCL_NET=IB`, `NCCL_NET_PLUGIN=none`, `NCCL_IB_DISABLE=0`,
`NCCL_IB_MERGE_NICS=1`, `NCCL_IB_SUBNET_AWARE_ROUTING=1`,
`NCCL_IB_ADDR_FAMILY=AF_INET`, `NCCL_IB_ROCE_VERSION_NUM=2`,
`NCCL_IB_GID_INDEX=3`, `NCCL_CROSS_NIC=1`, `NCCL_IGNORE_CPU_AFFINITY=1`,
`NCCL_P2P_DISABLE=1`, `NCCL_SHM_DISABLE=1`, `NCCL_NVLS_ENABLE=0`,
`NCCL_DEBUG=WARN`, `NCCL_DEBUG_SUBSYS=INIT`,
`TORCH_NCCL_ASYNC_ERROR_HANDLING=1`.

**Switched NCCL values:** `NCCL_CUMEM_ENABLE=0`, `NCCL_MAX_NCHANNELS=8`,
`NCCL_BUFFSIZE=1048576`, `NCCL_LL128_BUFFSIZE=262144`, `NCCL_PROTO=^LL128`.

**Switched one-shot values:** `SPARKNET_ROCE_ALLREDUCE_CAPACITY_BYTES=2097152`,
`SPARKNET_ROCE_ALLGATHER_MAX_BYTES=4194304`, `SPARKNET_ROCE_TIMEOUT_MS=10000`,
`SPARKNET_ROCE_PROXY_CPU=big`.

**Runtime and cache (inherited):** the `VLLM_*`, `SPARK_DS41F_*`, `TILELANG_*`,
`TRITON_*`, `CUDA_*`, `HF_*`, `MALLOC_*`, `OMP_NUM_THREADS`, `MAX_JOBS`,
`SAFETENSORS_FAST_GPU`, `TRANSFORMERS_OFFLINE`, `XDG_CACHE_HOME` values.

Note what is **absent**: `NCCL_ALGO`, `NCCL_MIN_NCHANNELS`,
`NCCL_MIN_TRAFFIC_PER_CHANNEL`, `NCCL_THREAD_THRESHOLDS`,
`NCCL_SWITCHLESS_BIDIRECTIONAL`, and every socket-interface variable. Their
absence is the contract.

---

## What we did not set, and why

### RoCE traffic class (DSCP marking)

We ran with the traffic class at its default (0, best-effort). Upstream
recommends marking DSCP 26 with ECT(0) — traffic-class byte `106`,
`(26 << 2) | 2` — on a switched fabric, because a lossless class on the switch
protects nothing until the sender marks the packets, and an all-reduce is incast
by construction. At SparkNet 0.5.0 the host-side field is
`roce_traffic_class` in the node map, which renders `NCCL_IB_TC` and
`SPARKNET_ROCE_TRAFFIC_CLASS`; the NIC and the switch must map that DSCP to a
PFC-enabled priority.

We did not measure marked versus unmarked. Our fabric passed ~93.4 Gb/s
per-pair RDMA reads and carried every collective in this repository's tests
without visible retransmission problems, which is *not* the same as proving a
lossless class was unnecessary. **We do not know whether our switch had PFC or
ECN configured** for these runs; that configuration was not recorded. If you are
building a switch configuration from scratch, set the lossless class up
front and record what you did.

### Two rails

See [one rail or two](#one-rail-or-two). Listing one device is a working
configuration at reduced bandwidth; listing a device that has no address is a
worse one.

### Any change to Owen's source tree

None. `spark-ds41f` was checked out at
`9461a70546fcfdcac9c7d8fbc58a53230510fbc9` and left clean;
`dgx-spark-networking` at `ed6af327a8953eb71de2ed925a5e605cb5eb6e20`. Site
configuration lives in the two ignored `config/` files that upstream expects,
which is why `cluster sync` (which refuses a dirty checkout) still works.

---

## Reproducing the derivation

You can copy `configs/cluster.example.json` and edit it, which is what most
sites should do. If you would rather derive it from a newer release than
`spark-ds41f-1030`, do it in code, not by hand:

```sh
python3 - <<'PY'
import copy, json, sys
sys.path[:0] = ["spark-ds41f/scripts", "dgx-spark-networking"]

import recipe
from sparknet.nccl import profiles

release = json.load(open("spark-ds41f/releases/spark-ds41f-1030/cluster.json"))
base = copy.deepcopy(release)
base.pop("glp", None)                                  # optional: stock model only
base["models"]["v41-flash-1017"]["hub"] = "{home}/.cache/huggingface/hub"

cluster = recipe.resolve(base, "tp4-ring")             # sizing from the ring shape
cluster["shape"] = "tp4-switched"
cluster.pop("benchmark_reference", None)
cluster["fabric"] = {"transport": "oneshot-switched", "topology": "switched"}
cluster["nodes_config"] = "config/nodes.json"

environment = {k: str(v) for k, v in release["environment"].items()}
for key, value in release["shapes"]["tp4-ring"].get("environment", {}).items():
    if not key.startswith(("NCCL_", "SPARKNET_ROCE_")):
        environment[key] = str(value)

switched = profiles.profile("switched")
environment.update(profiles.environment("switched"))
for key, value in switched["nccl"].items():
    if value is None:
        environment.pop(key, None)
for key, value in switched["oneshot"].items():
    if value is None:
        environment.pop(f"SPARKNET_ROCE_{key}", None)
for key in ("GLOO_SOCKET_IFNAME", "TP_SOCKET_IFNAME", "NCCL_SOCKET_IFNAME"):
    environment.pop(key, None)
cluster["environment"] = environment

json.dump(cluster, open("config/tp4-switched.local.json", "w"), indent=2, sort_keys=True)
PY
```

Then `bin/spark doctor` to prove the result is coherent, and `bin/spark render
<node>` to see the per-rank environment.

Do not hand-edit NCCL variables into the profile. Every value above comes from
`sparknet/nccl/profiles.py` at the revision you pinned, and that file is where
the measured numbers and their provenance live.
