# Installation

From four freshly-installed GB10 nodes to a switched TP4 service. Every step
either uses upstream tooling or configures your fabric; nothing here replaces
`bin/spark`.

Read [hardware-and-network.md](hardware-and-network.md) first if the nodes are
not yet cabled, and keep upstream's
[`docs/setup.md`](https://github.com/christopherowen/spark-ds41f/blob/main/docs/setup.md)
open: it is the authoritative host-preparation guide, including what each stage
changes and how to revert it. This document only adds what is different or
critical for a **switched** fabric.

---

## 0. What you need before you start

| Requirement | Detail |
| --- | --- |
| Nodes | 4 × GB10 systems, 128 GiB unified memory each |
| Disk | ~480 GiB free per node (checkpoint ≈ 510.3 GB of weights, plus JIT caches) |
| Memory on the build host | ~64 GiB free during the image build |
| Switch | 100 GbE (or faster) RoCEv2-capable, one port per node |
| Management network | SSH, API and Gloo; separate from the fabric |
| Access | passwordless SSH **and** passwordless `sudo` from the head node to every node, as one user |
| Model | permission to download `deepseek-ai/DeepSeek-V4.1-Flash-1017` |
| Host baseline | DGX OS 26.09.2 or later; the recipe's 64 KiB kernel and signed memory-saver module |

"Passwordless `sudo`" is not optional: the memory guards, the collector and
several checks use `sudo -n`.

---

## 1. Host baseline

Follow upstream's `docs/setup.md` stage 1: recovery policy, headless boot,
`nvidia-drm` mode setting, memory accounting, NVMe settings, boot order. Check
it with `scripts/host-recovery check` from the upstream checkout.

Do **not** install upstream's fan-floor control on an ASUS GX10. It is a DKMS
module that binds NVIDIA's P4242 board; our site profile sets
`host.fan_control: false` and keeps the vendor EC/BMC fan policy. See
[hardware-and-network.md](hardware-and-network.md#thermal-and-fan-policy).

Stage 2 (64 KiB kernel + memory saver) is required by this recipe: the profile
carries `host.kernel: {release: "7.0.0-1019-nvidia-64k", page_size: 65536,
memory_saver_required: true}`. `cluster start` refuses to launch if it is not
met.

```sh
getconf PAGESIZE        # 65536
```

---

## 2. Fabric build-out

Cable each node's ConnectX-7 port 1 into a 100 GbE switch port, address the
fabric interfaces (one `/24`, MTU 9000), then run the read-only check on every
node:

```sh
./scripts/validate-fabric.sh \
  --interface enp1s0f1np1 \
  --hca rocep1s0f1 \
  --gid-index 3 \
  --mtu 9000 \
  --peers 10.100.0.12,10.100.0.13,10.100.0.14
```

It reports every failed check and exits non-zero if any failed. It prints what
it found and changes nothing. Details and the optional bandwidth test:
[validation.md](validation.md).

Do not proceed to the runtime with a fabric you have not qualified. A misrouted
or half-rate fabric does not fail — it just makes every collective slower, and
you will spend the next day blaming the model.

---

## 3. Obtain the pinned sources

On **every** node (the checkout path must be the same everywhere — it is
`deployment.path` in the profile, and `cluster sync` compares `origin`):

```sh
# on every node, as the automation user
mkdir -p ~/projects && cd ~/projects
git clone https://github.com/christopherowen/spark-ds41f.git
git -C spark-ds41f checkout 9461a70546fcfdcac9c7d8fbc58a53230510fbc9

git clone https://github.com/christopherowen/dgx-spark-networking.git
git -C dgx-spark-networking checkout ed6af327a8953eb71de2ed925a5e605cb5eb6e20
```

On the head node (and any host from which you run `bin/spark` commands):

```sh
export PYTHONPATH="$HOME/projects/dgx-spark-networking"
```

SparkNet supplies the profile renderer and node-map validation; `bin/spark`
imports it from `PYTHONPATH` when it renders and launches. If you prefer,
install SparkNet's CPU tooling from the checkout instead — upstream's
integration guide covers that — but keep the revision pinned.

Both checkouts must be **clean**. The runtime commit must be reachable from a
branch on `origin`: `cluster sync --apply` refuses a dirty checkout and refuses
a commit that no published branch contains, because it deploys only a commit
that anyone could name.

---

## 4. Site configuration

From the `spark-ds41f` checkout root, with this repository available locally:

```sh
cp <this-repo>/configs/cluster.example.json  config/tp4-switched.local.json
cp <this-repo>/configs/nodes.example.json    config/nodes.json
```

Both names are covered by upstream's `.gitignore` (`*.local.json`,
`config/nodes.json`), which is what keeps the checkout clean.

Edit `config/nodes.json` — node names, ranks, fabric addresses / subnet,
management addresses and interface, SSH user, HCA names:

| Field | Check it against |
| --- | --- |
| `ssh_user` | the account with passwordless SSH and `sudo -n` |
| `name`, `rank`, `head` | one head, ranks 0..3, `name` resolvable from the head |
| `management_ip` | reachable from every node |
| `management_interface` | the 1/10 GbE device name on that host |
| `roce_hcas` | `rdma link show` — one or two entries: the RDMA rail(s) behind the used port (both PCIe paths of one port may be listed) |
| `roce_subnets` | the `/24` you actually put on that rail, same on all nodes |
| `roce_gid_index` | the index whose type file says `RoCE v2` (3 on our nodes) |

Edit `config/tp4-switched.local.json`:

| Field | Check it against |
| --- | --- |
| `host.home` | the automation user's home |
| `host.kernel` | `uname -r` and `getconf PAGESIZE` on the nodes |
| `deployment.path` | where you cloned the runtime on every node |
| `deployment.repository`, `deployment.branch` | each node's `git remote get-url origin`; keep `main` |
| `distributed.master_addr` | the head's **management** IP or name |
| `distributed.master_port` | below the head's ephemeral range |
| `serve_args` `--port` | your API port; `deployment.ready_url` must match |
| `container.docker_run_args` | `--cpuset-cpus`, the DRM bind source, `--memory` |
| `container.mounts` | `{home}/.cache/huggingface/hub` (read-only) and the writable cache |
| `container.image` | the tag you will build |
| `fabric` | must remain `{"transport": "oneshot-switched", "topology": "switched"}` |

`{home}` and `{checkout}` are upstream placeholders and are substituted per
node; do not replace them with absolute paths.

**Do not add NCCL variables.** The switched environment in the profile comes
from SparkNet's `switched` profile. If you want to change a transport value,
change it upstream or derive the profile from a different release — see
[switched-configuration.md](switched-configuration.md#reproducing-the-derivation).

### If you relocate the cache

`container.mounts` maps a host directory to `/cache` read-write, and every JIT
cache path in `environment` (`TILELANG_CACHE_DIR`, `TRITON_CACHE_DIR`,
`VLLM_CACHE_DIR`, `CUDA_CACHE_PATH`, `XDG_CACHE_HOME`) points inside it. If you
mount a dedicated volume there instead of `{checkout}/cache`, `cluster start`
checks that every node can write to it and refuses otherwise. That is what we
did; the example keeps upstream's default because it needs no extra setup.

---

## 5. Model checkpoint

On **every** node, into the hub the profile mounts:

```sh
hf download deepseek-ai/DeepSeek-V4.1-Flash-1017 \
  --revision 1bae0e1088993b9b82de08f59de5be5a34e42170
```

Then prove completeness **offline**:

```sh
HF_HUB_OFFLINE=1 hf download deepseek-ai/DeepSeek-V4.1-Flash-1017 \
  --revision 1bae0e1088993b9b82de08f59de5be5a34e42170
```

Do not treat a snapshot directory, or a total that is "close", as done. The
index declares 510,286,023,000 bytes of weights; a cache that looks finished can
still be missing shards. See
[troubleshooting.md](troubleshooting.md#checkpoint-looks-downloaded-but-startup-fails).

If you copy the cache between nodes instead of downloading four times, copy both
`hub/blobs` and the repository's snapshot directory — recent `hf` versions link
files into the shared blob store, so copying one without the other produces a
snapshot of dangling links.

---

## 6. Image

On one idle node (the build host), from a clean checkout:

```sh
bin/spark --cluster-config config/tp4-switched.local.json build prepare
bin/spark --cluster-config config/tp4-switched.local.json build image --apply
```

`build prepare` fetches the pinned vLLM, B12X, NCCL, TileLang, TileKernels and
SparkNet sources, applies the patch series and verifies the tree hashes.
`build image --apply` refuses to build next to a live service, sizes compile jobs
to available memory, never overwrites an existing tag, and runs a GPU import
smoke test. The first build is slow (TileLang and TileKernels compile).

Distribute and confirm the **same image on every node by its layers**, not by
image ID (a containerd-store node and an overlay2 node name the same image
differently):

```sh
image=$(python3 -c 'import json; print(json.load(open("config/tp4-switched.local.json"))["container"]["image"])')
for host in node-2 node-3 node-4; do
  docker save "$image" | ssh "$host" docker load
done
for host in node-1 node-2 node-3 node-4; do
  ssh "$host" docker image inspect "$image" --format '{{json .RootFS.Layers}}' | sha256sum
done
```

The source-tree labels in `container.expected_labels` are what `doctor --live`
and the launch preflight compare; they come from the pinned sources, so they
should match on every node without intervention.

---

## 7. Validate the configuration, then start

```sh
bin/spark --cluster-config config/tp4-switched.local.json doctor
bin/spark --cluster-config config/tp4-switched.local.json render node-1
```

`doctor` should print `configuration OK` and touches no node; `render` prints
the exact per-rank environment. Then:

```sh
bin/spark --cluster-config config/tp4-switched.local.json cluster sync  --apply
bin/spark --cluster-config config/tp4-switched.local.json cluster start --apply --unqualified-shape
bin/spark --cluster-config config/tp4-switched.local.json doctor --live
```

- `cluster sync` fetches the published commit and moves every clean node
  checkout to exactly that revision; it also copies the head's node map to the
  others. Fetch a published commit first (a detached checkout of the pinned
  commit is fine as long as that commit is on `origin/main`).
- `--unqualified-shape` is **required** for this profile: it has no upstream
  `benchmark_reference`, because no upstream release benchmark was run on a
  switched fabric. The flag acknowledges that; it disables no check.
- `--replace` is additionally required when a service from this profile is
  already running.
- `cluster start` preflights every rank, arms a 5 GiB startup memory guard per
  node, starts workers before the head, waits for the API, then drops to the
  3 GiB steady guard. If a guard trips, the launch rolls back and each rank's
  log is kept under `results/private/failed-starts/`.
- `doctor --live` is the gate that matters: it compares the running service and
  every node's kernel, driver, memory policy, fabric mapping and image labels
  against the profile.

The first start is slow: JIT compilation happens then. Startup timeouts are set
generously (`VLLM_ENGINE_READY_TIMEOUT_S=3600`, `ready_timeout_seconds=3600`);
a first start on four nodes plus a cold cache can take a long time, and that is
expected rather than a hang.

---

## 8. Readiness and inference

```sh
curl -s http://<head>:8000/v1/models | jq -r '.data[].id'
```

Expect exactly `deepseek-v4.1-flash` (plus any GLP name if you kept the `glp`
block — we removed it).

```sh
curl -s http://<head>:8000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"deepseek-v4.1-flash",
       "messages":[{"role":"user","content":"Reply with the single word: ready"}],
       "max_tokens":16,
       "chat_template_kwargs":{"thinking":false}}' | jq -r '.choices[0].message.content'
```

Reasoning is on by default; `chat_template_kwargs.thinking=false` turns it off
per request. Note that some responses arrive as `delta.reasoning` rather than
`delta.content` when thinking is enabled — a client that only reads `content`
will see an empty string and a full `usage` block. That is a client bug, not a
runtime bug.

Then prove the transport actually carried the collectives:
[validation.md](validation.md).

---

## 9. Lifecycle

| Action | Command |
| --- | --- |
| Status | `bin/spark status` |
| Live comparison | `bin/spark --cluster-config config/tp4-switched.local.json doctor --live` |
| Stop | `bin/spark --cluster-config config/tp4-switched.local.json cluster stop --apply` |
| Restart same profile | `cluster start --apply --unqualified-shape --replace` |
| Benchmark | `bin/spark bench` (or `--full`) |

Always stop with the **same profile** the engine was started from; the stop path
refuses a profile that covers only some of the running engine's nodes. Stopping
keeps the containers, image, caches and state for inspection — it does not
delete your checkpoint.

---

## 10. Upgrading or reverting

- **New upstream release:** read its release notes, re-derive the switched
  profile from the new recipe (never hand-patch the old one), re-pin the
  commits in your notes, rebuild the image, and re-run the fabric and collective
  qualification before trusting performance numbers.
- **Revert:** check out the previous pinned commit on every node, regenerate or
  restore the matching profile, `cluster sync --apply`, `cluster start --apply
  --unqualified-shape --replace`. Keep the previous image tag: `bin/spark`
  refuses to overwrite an existing tag, which makes rollback by tag practical.
- **Nothing in this repository is installed on the nodes.** There is no agent,
  no service and no scheduled job. Removing this repository from your working
  copy changes nothing on the fleet.
