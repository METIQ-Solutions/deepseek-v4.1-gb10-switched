#!/usr/bin/env bash
# validate-fabric.sh - read-only checks for one node of a switched RoCE fabric.
#
# Verifies that this host's fabric interface, RoCE device, GID entry, MTU and
# RDMA mapping match what a switched profile declares, and that every peer is
# reachable with jumbo frames through that interface.
#
# It changes nothing: no interface state, no addressing, no sysctl, no RDMA
# configuration. The only traffic it generates is ICMP echo and, if you ask for
# it explicitly, a bounded RDMA read benchmark.
#
# Requirements: bash 4+, iproute2 (ip), iputils (ping), rdma-core (rdma or
# ibdev2netdev), read access to /sys/class/infiniband, and iputils ping with
# -M do support. Run it as a normal user; it does not need root.
#
# SYSFS_INFINIBAND overrides the sysfs root. It exists so the script can be
# exercised offline against a fixture tree; leave it unset in normal use.
#
# Exit status: 0 all checks passed, 1 one or more checks failed, 2 usage error.

set -u

PROGRAM=${0##*/}

INTERFACE=""
HCA=""
PEERS=""
GID_INDEX=3
MTU=9000
SUBNET=""
BANDWIDTH_PEER=""
TIMEOUT=2
COUNT=3
SKIP_PEERS=0

PASSES=0
FAILURES=0
FAILED_CHECKS=()

usage() {
    cat <<EOF
Usage: $PROGRAM --interface IF --hca DEV --peers IP[,IP...] [options]

Checks (read-only):
  1. the interface exists, is up and has the expected MTU
  2. it has an IPv4 address, optionally inside --subnet
  3. the RoCE device exists and GID <gid-index> holds that IPv4 address
  4. that GID's type is RoCE v2 and the RDMA device is ACTIVE on the interface
  5. a jumbo-frame ping reaches every peer through the interface

Required:
  --interface IF        fabric network interface, e.g. enp1s0f1np1
  --hca DEV             RDMA device behind it, e.g. rocep1s0f1
  --peers LIST          comma-separated peer fabric IPv4 addresses
                        (use --skip-peers for an offline-only check)

Options:
  --gid-index N         GID table index to validate (default: 3)
  --mtu N               expected interface MTU (default: 9000)
  --subnet CIDR         assert the interface IPv4 address is inside this /24
  --timeout SEC         ping timeout per packet (default: 2)
  --count N             ping packets per peer (default: 3)
  --skip-peers          do not contact peers
  --bandwidth IP        also run a bounded ib_read_bw read against this peer
                        (needs perftest; run with serving stopped)
  --help                this text

Examples:
  $PROGRAM --interface enp1s0f1np1 --hca rocep1s0f1 \\
      --subnet 10.100.0.0/24 --peers 10.100.0.12,10.100.0.13,10.100.0.14

  $PROGRAM --interface enp1s0f1np1 --hca rocep1s0f1 --peers 10.100.0.12 \\
      --bandwidth 10.100.0.12
EOF
}

usage_error() {
    printf '%s: %s\n\n' "$PROGRAM" "$1" >&2
    usage >&2
    exit 2
}

pass() {
    PASSES=$((PASSES + 1))
    printf 'PASS  %s\n' "$1"
}

fail() {
    FAILURES=$((FAILURES + 1))
    FAILED_CHECKS+=("$1")
    printf 'FAIL  %s\n' "$1" >&2
}

note() {
    printf '      %s\n' "$1"
}

have() {
    command -v "$1" >/dev/null 2>&1
}

is_ipv4() {
    local ip=$1 octet
    [[ $ip =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
    for octet in "${BASH_REMATCH[@]:1}"; do
        ((10#$octet <= 255)) || return 1
    done
    return 0
}

ipv4_to_int() {
    local a b c d
    IFS=. read -r a b c d <<<"$1"
    printf '%d' $(((10#$a << 24) + (10#$b << 16) + (10#$c << 8) + 10#$d))
}

in_subnet() {
    local ip=$1 cidr=$2 net prefix mask ip_int net_int
    net=${cidr%%/*}
    prefix=${cidr##*/}
    is_ipv4 "$ip" || return 1
    is_ipv4 "$net" || return 1
    [[ $prefix =~ ^[0-9]+$ ]] || return 1
    ((prefix >= 0 && prefix <= 32)) || return 1
    if ((prefix == 0)); then
        mask=0
    else
        mask=$(((0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF))
    fi
    ip_int=$(ipv4_to_int "$ip")
    net_int=$(ipv4_to_int "$net")
    (((ip_int & mask) == (net_int & mask)))
}

# Print the IPv4 address a GID value encodes, or nothing if it has none.
# Accepts both "::ffff:10.100.0.11" and the hex form "::ffff:0a64:000b".
gid_to_ipv4() {
    local gid=$1 head tail
    if [[ $gid =~ ([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]]; then
        printf '%s.%s.%s.%s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" \
            "${BASH_REMATCH[3]}" "${BASH_REMATCH[4]}"
        return 0
    fi
    # Only an IPv4-mapped GID (::ffff:a.b.c.d) carries an IPv4 address.
    case $gid in
        ::ffff:*|0000:0000:0000:0000:0000:ffff:*) ;;
        *) return 1 ;;
    esac
    tail=${gid##*:}
    head=${gid%:*}
    head=${head##*:}
    [[ $head =~ ^[0-9a-fA-F]{1,4}$ ]] || return 1
    [[ $tail =~ ^[0-9a-fA-F]{1,4}$ ]] || return 1
    while ((${#head} < 4)); do head="0$head"; done
    while ((${#tail} < 4)); do tail="0$tail"; done
    printf '%d.%d.%d.%d' \
        "$((16#${head:0:2}))" "$((16#${head:2:2}))" \
        "$((16#${tail:0:2}))" "$((16#${tail:2:2}))"
}

require_arg() {
    [[ -n ${2:-} ]] || usage_error "missing value for $1"
}

while (($# > 0)); do
    case $1 in
        --interface) require_arg "$1" "${2:-}"; INTERFACE=$2; shift 2 ;;
        --hca)       require_arg "$1" "${2:-}"; HCA=$2;       shift 2 ;;
        --peers)     require_arg "$1" "${2:-}"; PEERS=$2;     shift 2 ;;
        --gid-index) require_arg "$1" "${2:-}"; GID_INDEX=$2; shift 2 ;;
        --mtu)       require_arg "$1" "${2:-}"; MTU=$2;       shift 2 ;;
        --subnet)    require_arg "$1" "${2:-}"; SUBNET=$2;    shift 2 ;;
        --timeout)   require_arg "$1" "${2:-}"; TIMEOUT=$2;   shift 2 ;;
        --count)     require_arg "$1" "${2:-}"; COUNT=$2;     shift 2 ;;
        --bandwidth) require_arg "$1" "${2:-}"; BANDWIDTH_PEER=$2; shift 2 ;;
        --skip-peers) SKIP_PEERS=1; shift ;;
        --help|-h)   usage; exit 0 ;;
        *)           usage_error "unknown argument: $1" ;;
    esac
done

[[ -n $INTERFACE ]] || usage_error "--interface is required"
[[ -n $HCA ]] || usage_error "--hca is required"
[[ $SKIP_PEERS -eq 1 || -n $PEERS ]] || usage_error "--peers is required (or --skip-peers)"
[[ $GID_INDEX =~ ^[0-9]+$ ]] || usage_error "--gid-index must be a number"
[[ $MTU =~ ^[3-9][0-9]{2,4}$ ]] || usage_error "--mtu must be a plausible MTU (e.g. 1500 or 9000)"
[[ $TIMEOUT =~ ^[1-9][0-9]*$ ]] || usage_error "--timeout must be a positive integer"
[[ $COUNT =~ ^[1-9][0-9]*$ ]] || usage_error "--count must be a positive integer"
if [[ -n $SUBNET ]]; then
    [[ $SUBNET =~ ^[0-9.]+/[0-9]{1,2}$ ]] || usage_error "--subnet must be CIDR, e.g. 10.100.0.0/24"
    in_subnet "${SUBNET%%/*}" "$SUBNET" || usage_error "--subnet network address does not parse"
fi

PEER_LIST=()
if [[ $SKIP_PEERS -eq 0 ]]; then
    IFS=, read -r -a PEER_LIST <<<"$PEERS"
    for peer in "${PEER_LIST[@]}"; do
        [[ -n $peer ]] || usage_error "--peers contains an empty entry"
        is_ipv4 "$peer" || usage_error "--peers entry is not an IPv4 address: $peer"
    done
    ((${#PEER_LIST[@]} > 0)) || usage_error "--peers has no entries"
fi
if [[ -n $BANDWIDTH_PEER ]]; then
    is_ipv4 "$BANDWIDTH_PEER" || usage_error "--bandwidth is not an IPv4 address: $BANDWIDTH_PEER"
fi

# --- dependencies -----------------------------------------------------------

MISSING=()
have ip || MISSING+=(ip)
have ping || MISSING+=(ping)
if ! have rdma && ! have ibdev2netdev; then
    MISSING+=(rdma-or-ibdev2netdev)
fi
if [[ -n $BANDWIDTH_PEER ]] && ! have ib_read_bw; then
    MISSING+=(ib_read_bw)
fi
if ((${#MISSING[@]} > 0)); then
    printf '%s: missing required tools: %s\n' "$PROGRAM" "${MISSING[*]}" >&2
    printf 'Install iproute2, iputils-ping and rdma-core%s.\n' \
        "$([[ -n $BANDWIDTH_PEER ]] && printf ', plus perftest')" >&2
    exit 1
fi

printf 'Validating %s on %s (GID %s, MTU %s)\n\n' "$HCA" "$INTERFACE" "$GID_INDEX" "$MTU"

# --- 1. interface -----------------------------------------------------------

LINK_LINE=$(ip -o link show dev "$INTERFACE" 2>/dev/null || true)
if [[ -z $LINK_LINE ]]; then
    fail "interface $INTERFACE does not exist"
else
    pass "interface $INTERFACE exists"
    LINK_FLAGS=${LINK_LINE#*<}
    LINK_FLAGS=${LINK_FLAGS%%>*}
    if [[ ",$LINK_FLAGS," == *",UP,"* ]]; then
        pass "interface $INTERFACE is administratively up"
    else
        fail "interface $INTERFACE is not up (flags: $LINK_FLAGS)"
    fi
    if [[ $LINK_LINE == *" mtu $MTU "* ]]; then
        pass "interface $INTERFACE MTU is $MTU"
    else
        fail "interface $INTERFACE MTU is not $MTU (expected 'mtu $MTU')"
        note "$LINK_LINE"
    fi
fi

# --- 2. addressing ----------------------------------------------------------

IFACE_IP=""
IFACE_PREFIX=""
if [[ -n $LINK_LINE ]]; then
    while read -r line; do
        [[ $line =~ inet\ ([0-9.]+)/([0-9]+) ]] || continue
        IFACE_IP=${BASH_REMATCH[1]}
        IFACE_PREFIX=${BASH_REMATCH[2]}
        break
    done < <(ip -4 -o address show dev "$INTERFACE" 2>/dev/null || true)
fi

if [[ -z $IFACE_IP ]]; then
    fail "interface $INTERFACE has no IPv4 address"
else
    pass "interface $INTERFACE has IPv4 address $IFACE_IP/$IFACE_PREFIX"
    if [[ -n $SUBNET ]]; then
        if in_subnet "$IFACE_IP" "$SUBNET"; then
            pass "address $IFACE_IP is inside $SUBNET"
        else
            fail "address $IFACE_IP is outside $SUBNET"
        fi
    fi
fi

# --- 3./4. RDMA device, GID and link state ----------------------------------

SYSFS_INFINIBAND=${SYSFS_INFINIBAND:-/sys/class/infiniband}
HCA_PATH="$SYSFS_INFINIBAND/$HCA"
if [[ ! -d $HCA_PATH ]]; then
    fail "RDMA device $HCA does not exist under $SYSFS_INFINIBAND"
else
    pass "RDMA device $HCA exists"

    GID_TYPE_FILE="$HCA_PATH/ports/1/gid_attrs/types/$GID_INDEX"
    GID_FILE="$HCA_PATH/ports/1/gids/$GID_INDEX"

    if [[ ! -r $GID_FILE ]]; then
        fail "GID $GID_INDEX is not readable for $HCA ($GID_FILE)"
    else
        GID_VALUE=$(tr -d '[:space:]' <"$GID_FILE")
        if [[ -z $GID_VALUE || $GID_VALUE =~ ^[0:]+$ ]]; then
            fail "GID $GID_INDEX on $HCA is empty (no address configured)"
        else
            GID_IP=$(gid_to_ipv4 "$GID_VALUE" || true)
            if [[ -z $GID_IP ]]; then
                fail "GID $GID_INDEX on $HCA is not an IPv4-mapped RoCE GID ($GID_VALUE)"
            elif [[ -z $IFACE_IP ]]; then
                fail "GID $GID_INDEX holds $GID_IP but the interface has no IPv4 address"
            elif [[ $GID_IP == "$IFACE_IP" ]]; then
                pass "GID $GID_INDEX holds $GID_IP, matching the interface address"
            else
                fail "GID $GID_INDEX holds $GID_IP but the interface address is $IFACE_IP"
            fi
        fi
    fi

    if [[ ! -r $GID_TYPE_FILE ]]; then
        fail "GID type for index $GID_INDEX is not readable ($GID_TYPE_FILE)"
    else
        GID_TYPE=$(tr -d '\r\n' <"$GID_TYPE_FILE")
        if [[ $GID_TYPE == "RoCE v2" ]]; then
            pass "GID $GID_INDEX type is RoCE v2"
        else
            fail "GID $GID_INDEX type is '$GID_TYPE', expected 'RoCE v2'"
        fi
    fi
fi

RDMA_STATE=""
if have rdma; then
    RDMA_STATE=$(rdma link show 2>/dev/null || true)
elif have ibdev2netdev; then
    RDMA_STATE=$(ibdev2netdev 2>/dev/null || true)
fi
if [[ -z $RDMA_STATE ]]; then
    fail "cannot read the RDMA link table (rdma link show / ibdev2netdev)"
else
    if [[ $RDMA_STATE == *"$HCA"* ]]; then
        pass "RDMA device $HCA appears in the link table"
    else
        fail "RDMA device $HCA does not appear in the link table"
    fi
    if [[ $RDMA_STATE == *"$INTERFACE"* ]]; then
        pass "interface $INTERFACE is mapped to an RDMA device"
    else
        fail "interface $INTERFACE is not mapped to an RDMA device"
    fi
    if [[ $RDMA_STATE == *"state ACTIVE"* || $RDMA_STATE == *"ACTIVE"* ]]; then
        pass "RDMA link state is ACTIVE"
    else
        fail "no ACTIVE RDMA link reported"
        note "$RDMA_STATE"
    fi
fi

# --- 5. peers ---------------------------------------------------------------

if [[ $SKIP_PEERS -eq 0 ]]; then
    PAYLOAD=$((MTU - 28))
    if ((PAYLOAD < 1)); then
        fail "MTU $MTU is too small for a usable ping payload"
    else
        for peer in "${PEER_LIST[@]}"; do
            [[ $peer == "$IFACE_IP" ]] && { fail "peer $peer is this host's own address"; continue; }
            if ping -n -q -c "$COUNT" -W "$TIMEOUT" -M do -s "$PAYLOAD" -I "$INTERFACE" "$peer" >/dev/null 2>&1; then
                pass "jumbo ping ($PAYLOAD bytes, DF) reached $peer via $INTERFACE"
            else
                fail "jumbo ping ($PAYLOAD bytes, DF) failed to $peer via $INTERFACE"
                note "check cabling, switch port, MTU $MTU end to end, and the peer's address"
            fi
        done
    fi
fi

# --- optional bandwidth -----------------------------------------------------

if [[ -n $BANDWIDTH_PEER ]]; then
    printf '\nRDMA read against %s (1 MiB, 8 QPs, 5 s; serving must be stopped)\n' "$BANDWIDTH_PEER"
    BW_OUTPUT=$(ib_read_bw -d "$HCA" -x "$GID_INDEX" -i 1 -s 1048576 -q 8 -Q 512 -D 5 \
        "$BANDWIDTH_PEER" 2>&1) && BW_STATUS=0 || BW_STATUS=$?
    if ((BW_STATUS == 0)); then
        BW_LINE=$(printf '%s\n' "$BW_OUTPUT" | grep -E '^[[:space:]]*[0-9]+[[:space:]]+[0-9]+' | tail -1)
        if [[ -n $BW_LINE ]]; then
            pass "ib_read_bw completed: $BW_LINE"
        else
            pass "ib_read_bw completed"
            note "$BW_OUTPUT"
        fi
    else
        fail "ib_read_bw failed against $BANDWIDTH_PEER (status $BW_STATUS)"
        note "$BW_OUTPUT"
    fi
fi

# --- summary ----------------------------------------------------------------

printf '\n%d passed, %d failed\n' "$PASSES" "$FAILURES"
if ((FAILURES > 0)); then
    printf '\nFailed checks:\n'
    printf '  - %s\n' "${FAILED_CHECKS[@]}"
    exit 1
fi
exit 0
