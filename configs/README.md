# Example site configuration

Two files, both consumed by Christopher Owen's `bin/spark` from inside a
`spark-ds41f` checkout:

| File | Goes to | Purpose |
| --- | --- | --- |
| `cluster.example.json` | `config/tp4-switched.local.json` | The resolved site profile: switched fabric declaration, transport environment, sizing, container recipe |
| `nodes.example.json` | `config/nodes.json` | The four-node switched node map: ranks, addresses, rails, rendezvous interface |

Both destination names are matched by the upstream `.gitignore`
(`*.local.json`, `config/nodes.json`), which matters: `cluster sync` refuses a
checkout that these files would make dirty.

## Provenance

`cluster.example.json` is not hand-written. It is a **resolved profile** derived
from upstream's Apache-2.0 release recipe
`releases/spark-ds41f-1030/cluster.json` (resolved at its `tp4-ring` shape),
with the fabric declaration switched and the environment replaced by SparkNet's
`switched` transport profile. The derivation, and the classification of every
difference, is in
[`../docs/switched-configuration.md`](../docs/switched-configuration.md).

It was validated against the pinned upstream sources: upstream's own
`recipe.is_recipe`, `topology.problems`, `sparknet.topology.nodes.problems` and
`sparknet.nccl.profiles.problems` all accept it, and its per-rank render produces
`SPARKNET_ROCE_TOPOLOGY=direct`, `SPARKNET_ROCE_HCA=rocep1s0f1`,
`NCCL_IB_HCA==rocep1s0f1`, GID 3 and the management interface as the socket
path. `bin/spark doctor` is the authority for your own copy.

## What you must change

Everything site-specific is in the files, and none of it is subtle when it is
wrong:

| In `nodes.example.json` | Check |
| --- | --- |
| `ssh_user` | the account with passwordless SSH and `sudo -n` |
| `name`, `rank`, `head`, `management_ip` | one head, ranks 0–3, resolvable from the head |
| `management_interface` | the interface that carries SSH, the API and Gloo |
| `roce_hcas` | one entry per RDMA device behind the used switch port |
| `roce_subnets` | the `/24` you actually assigned, identical on every node |
| `roce_gid_index` | the index whose type file says `RoCE v2` |

| In `cluster.example.json` | Check |
| --- | --- |
| `host.home`, `deployment.path`, `deployment.repository`, `deployment.branch` | your paths and your `origin` |
| `host.kernel` | `uname -r`, `getconf PAGESIZE` on your nodes |
| `distributed.master_addr`, `master_port` | head reachable from every node; port below the ephemeral range |
| `serve_args` `--port` and `deployment.ready_url` | the API port you will use |
| `container.docker_run_args` | `--cpuset-cpus` and the `/dev/dri/by-path/...` bind are the upstream build host's values |
| `container.mounts` | the Hugging Face hub (read-only) and a writable cache |
| `container.image` | the tag you built |

## What you must not change casually

- `fabric` must stay `{"transport": "oneshot-switched", "topology": "switched"}`.
  Both keys are required: a transport alone leaves the fabric ambiguous and a
  topology alone has no runtime.
- Do not add `NCCL_ALGO`, `NCCL_MIN_NCHANNELS`, `NCCL_MIN_TRAFFIC_PER_CHANNEL`,
  `NCCL_THREAD_THRESHOLDS` or `NCCL_SWITCHLESS_BIDIRECTIONAL`. They belong to a
  ring; the renderer rejects them on a switched fabric.
- Do not add `GLOO_SOCKET_IFNAME`, `TP_SOCKET_IFNAME` or `NCCL_SOCKET_IFNAME` to
  the profile: they are rendered per rank from `management_interface`.
- Do not hand-edit the transport environment. Derive it from
  `sparknet/nccl/profiles.py` at your pinned revision — that file is where the
  measured numbers and their provenance live.

## Optional: two rails

If both PCIe device paths of a node's switch port carry an address in the rail
subnet, list both in `roce_hcas` and add both to `roce_subnets`. Upstream
measured roughly double the all-pairs bandwidth that way. Confirm both carried
payload with the collective probe's per-HCA sampling; a single-device map runs
at reduced bandwidth with no error.

## Optional: RoCE traffic class

If your switch has a lossless class configured, add the upstream-recommended
traffic-class byte to each node:

```json
"roce_traffic_class": 106
```

That is DSCP 26 with ECT(0), `(26 << 2) | 2`, and at SparkNet 0.5.0 it renders
`NCCL_IB_TC` and `SPARKNET_ROCE_TRAFFIC_CLASS`. The host NIC and the switch must
map that DSCP to a PFC-enabled priority. The example omits the field, which is
what our validated deployment ran: unmarked, best-effort. We have no
marked-versus-unmarked measurement.

## Licence

The upstream portions of `cluster.example.json` are Apache License 2.0,
Copyright 2026 Christopher Owen. See [`../NOTICE.md`](../NOTICE.md).
