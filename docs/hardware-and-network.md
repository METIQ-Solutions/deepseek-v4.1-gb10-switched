# Hardware and network

What we plugged in, how it is addressed, and which parts of that you have to
change. Upstream owns the runtime; the fabric is the part of a switched
deployment that is genuinely site-specific.

---

## The nodes

| | |
| --- | --- |
| Model | ASUS Ascent GX10 (NVIDIA GB10 Grace Blackwell) |
| Nodes | 4 |
| Memory | 128 GiB unified memory per node (the kernel reports 123.72 GiB `MemTotal`) |
| Accelerator interconnect | 1 × ConnectX-7 per node, two 200 GbE-capable ports |
| Fabric port used | port 1, one QSFP28 link per node at **100 GbE** |
| Fabric device | `rocep1s0f1` (one RDMA device node per used port in our site) |
| Fabric netdev | `enp1s0f1np1` |
| Management netdev | `enp1s0f0np0` |
| OS | DGX OS 26.09.2-class base |
| Kernel | `7.0.0-1019-nvidia-64k` (64 KiB pages) |
| NVIDIA driver | `580.178.04` |
| UVM module | signed memory-saver DKMS module (required by the recipe's `host.kernel`) |

The ConnectX-7 exposes **two PCIe paths per physical port** — for example
`rocep1s0f1` and `roceP2p1s0f1` both reach the same QSFP28 cage. They are not
two cables. Which of them carries an address is a property of your host
addressing, not of the switch. See
[the rail decision](switched-configuration.md#one-rail-or-two).

## The switch

| | |
| --- | --- |
| Model | QNAP QSW-M7308R-4X |
| Uplink ports used | 4 × 100 GbE QSFP28 (the switch has exactly four; one per node) |
| Other ports | 8 × 25 GbE SFP28 (unused here) |
| Switching capacity | 1200 Gbps |
| Features available | PFC, ECN, QoS |
| Cabling | one QSFP28 DAC/AOC per node, node port 1 → switch port *n* |

A four-node fabric that consumes all four 100 GbE ports leaves nothing for
uplinks. Plan management on a separate switch; do not try to carry SSH, the API
and Gloo over the inference fabric.

**What we did not record:** the switch's PFC/ECN/QoS configuration for our
validation runs. We know the fabric carried every collective we tested at
~93.4 Gb/s per pair, and we know we did not mark a traffic class on the hosts.
We do **not** know whether a lossless class was configured on the switch.
Treat that as a gap, not as a "defaults are fine" result — if you are
configuring a switch from scratch, set up the lossless class and record it.

## Topology

```
            QNAP QSW-M7308R-4X  (4 × 100 GbE QSFP28)
              |        |        |        |
        QSFP28   QSFP28   QSFP28   QSFP28        one 100 GbE link per node
              |        |        |        |
          node-1   node-2   node-3   node-4      GB10, 128 GiB each
             rank 0 (head)  1        2        3
              \        \        |        /
               \        \       |       /        separate management LAN:
                +--------+------+------+         1 or 10 GbE per node
                        |
                   management switch
             SSH · OpenAI API · Gloo · TP bootstrap
```

There is no node-to-node cabling. Rank *i* reaches rank *j* through the switch,
which is why the node map declares a rail subnet rather than peer routes:
`expected_peers` for a switched transport is *every other rank*, not the two
ring neighbours.

## Addressing

One `/24` on the 100 GbE interface of each node, in the same subnet for every
node, MTU 9000. The example uses `10.100.0.0/24` and `192.0.2.0/24` for
management (TEST-NET-1, deliberately unroutable documentation space — replace
it).

| Node | Rank | Fabric address | Management address |
| --- | ---: | --- | --- |
| node-1 | 0 (head) | `10.100.0.11/24` | `192.0.2.11` |
| node-2 | 1 | `10.100.0.12/24` | `192.0.2.12` |
| node-3 | 2 | `10.100.0.13/24` | `192.0.2.13` |
| node-4 | 3 | `10.100.0.14/24` | `192.0.2.14` |

A minimal netplan for the fabric interface (adapt the device name, address and
parent interface; do not copy it blind):

```yaml
# /etc/netplan/40-cx7.yaml
network:
  version: 2
  ethernets:
    enp1s0f1np1:
      addresses: [10.100.0.11/24]
      mtu: 9000
      dhcp4: false
      dhcp6: false
      link-local: []
```

`sudo netplan apply`, then verify — the fabric is now a real network and every
later check depends on it.

Addressing rules that matter:

- **One subnet per rail, identical on every node.** The renderer validates
  this; two rails sharing a subnet is rejected.
- **The management interface must not be a loopback, container bridge, overlay
  or wireless device.** Newer SparkNet releases reject those explicitly; 0.5.0
  checks the map shape and the rendezvous path at run time.
- **`management_ip` may be on any reachable network.** It does not have to be
  on a fabric lane. Do not put the head's API on the fabric subnet just because
  it is the fast one.
- **MTU 9000 end to end**, including the switch ports. A jumbo-frame ping that
  succeeds at 8972 bytes of payload is the cheapest proof.
- **GID index 3 must be RoCE v2 with your IPv4 address in it.** `cat
  /sys/class/infiniband/<hca>/ports/1/gids/3` prints an IPv4-mapped IPv6 value
  such as `::ffff:0a64:000b` — that is `10.100.0.11` in hex, not a v6 address.
  Do not grep it for dotted-quad text; parse it or compare the type file:
  `cat /sys/class/infiniband/<hca>/ports/1/gid_attrs/types/3` should print
  `RoCE v2`.

## Bring-up order

1. Cable the four nodes to the switch. Record which node is on which port; you
   will not be able to tell from the host side later.
2. Address the fabric interfaces on all four nodes, MTU 9000.
3. Address the management interfaces and confirm SSH from the head to every
   node with the automation user.
4. Run [`../scripts/validate-fabric.sh`](../scripts/validate-fabric.sh) on
   **each** node.
5. Optionally measure pair bandwidth (`--bandwidth`, or `ib_read_bw` directly)
   with the service stopped.
6. Then, and only then, configure and start the runtime.

## Verifying bandwidth

A reachability ping says nothing about throughput. The check that we used is a
pairwise RDMA read with `ib_read_bw` (part of `perftest`), 1 MiB messages, 8 QPs,
TX depth 512, RDMA-CM, GID 3, run from each node against each peer:

```sh
ib_read_bw -d rocep1s0f1 -x 3 -i 1 -s 1048576 -q 8 -Q 512 -D 5 <peer-fabric-ip>
```

Our six sequential pair tests reported **11,677–11,678 MB/s**, i.e. about
**93.4 Gb/s** on a 100 GbE link. That is the number to beat or explain on your
own fabric.

Two cautions:

- Run it with **serving stopped**. A bandwidth test beside a live TP4 engine
  measures contention, not the fabric.
- It is an aggregate pair number, not a model-performance claim. Upstream is
  explicit that fabric numbers and serving numbers must be reported separately.

If you list two device paths per node, test each and then test the aggregate;
the per-HCA payload sampling in the collective probe is the authoritative
answer for whether both carried traffic.

## Thermal and fan policy

Our nodes are ASUS GX10s with vendor EC/BMC fan control, and the site profile
sets `host.fan_control: false`. Upstream's fan-floor control is a DKMS module
that binds **NVIDIA's P4242** board; installing it on a non-P4242 GB10 board is
not a supported configuration. Setting the flag false makes `bin/spark doctor`
record the absence rather than error, and makes `bench` skip its fan
performance curve.

Consequences to keep in mind:

- Benchmarks here were taken without an upstream fan curve. Temperatures stayed
  at or below 69 °C under sustained decode and 63 °C through the long soak, so
  no thermal throttling was observed — but "we did not see throttling" is not
  the same as "the cooling policy is equivalent to the reference platform's".
- Record your own thermals. `nvidia-smi --query-gpu=temperature.gpu,clocks.sm,power.draw --format=csv` during a benchmark is enough to catch the failure
  mode described in [troubleshooting](troubleshooting.md#gpu-clocks-stuck-low-under-load).

## What is not in this repository

- No switch configuration export. We did not have one to publish (see above).
- No firmware bundle. Node firmware is a vendor concern; our nodes ran the
  vendor-supplied EC/SoC firmware with the driver and kernel listed above.
- No host baseline automation. Upstream's `docs/setup.md` stages host baseline,
  kernel, memory-saver and recovery policy step by step with checks and revert
  instructions; this repository deliberately does not duplicate it.
