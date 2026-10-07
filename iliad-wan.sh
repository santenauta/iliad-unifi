#!/bin/bash
# Permanent Iliad WAN, built on what selftest.sh + lan.sh proved: keeps the IPv4-in-IPv6 tunnel up and
# sends LAN IPv4 through it, falling back to UniFi's own routing (the other WAN) whenever the tunnel
# stops answering. Runs as a systemd service. Everything it adds lives in its own interface, table,
# ip rules (94-96) and iptables chains (IWAN_*), and it re-asserts them every few seconds because a
# UniFi provision can rewrite the firewall. The UniFi UI never sees any of this (WAN1 stays red).
#   iliad-wan.sh install | uninstall | status | run | down
. "$(dirname "$0")/lib.sh"
need_root
load_conf
[ -n "${CONF_ERR:-}" ] && die "config: $CONF_ERR"

TUN=${WAN_TUN:-iliad0}
TABLE=${WAN_TABLE:-4647}
INTERVAL=${WAN_INTERVAL:-5}
FAILS_DOWN=${WAN_FAILS_DOWN:-3}
OKS_UP=${WAN_OKS_UP:-3}
CHECK_HOSTS=${WAN_CHECK_HOSTS:-"1.1.1.1 9.9.9.9 8.8.8.8"}
FALLBACK_IF=${WAN_FALLBACK_IF:-eth8}
RPS=${WAN_RPS:-on}
# RPS on the physical WAN port too: one core otherwise receives and decapsulates everything (measured
# 2026-09-29: cpu0 100% softirq at ~1.4 Gb/s). Iliad sets no IPv6 flow label, so the kernel hashes on the
# inner IPv4 flow. Off by default: with mask e it measured WORSE (0.9 vs 1.4 Gb/s) — see tools/rps-bench.sh.
RPS_LOWER=${WAN_RPS_LOWER:-off}
RPS_LOWER_MASK=${WAN_RPS_LOWER_MASK:-$(printf '%x' $(( (1 << $(nproc)) - 2 )))}
# The al_eth NIC hands every packet an L4-type hash of the OUTER header, which is identical for all tunnel
# traffic and survives decapsulation, so RPS sent every flow to one core (rps-bench, 2026-09-29).
# rxhash off makes the kernel hash the inner flow instead (no flow label is set). RSS is unaffected.
# Measured from a 2.5G Mac, 4 streams: rxhash on + best mask 1.29-1.34 Gb/s; rxhash off + tunnel RPS f = 2.05 Gb/s
# (Mac's own LAN ceiling ~2.2). WAN-port RPS stays off: it cost throughput in every combination.
RXHASH=${WAN_RXHASH:-off}
UNIT=/etc/systemd/system/iliad-wan.service
STATE=/run/iliad-wan.state
P_MAIN=94 P_LAN=95 P_SRC=96

say() { printf '%s\n' "$*"; }   # journald timestamps it

lan_bridges() { ip -o -4 addr show | awk '$2 ~ /^br[0-9]/ {print $2}' | sort -u; }

# --- tunnel -------------------------------------------------------------------------------------

tunnel_ok() {
    ip -d link show "$TUN" 2>/dev/null | grep -q "remote $BR_C local $LOCAL_C dev $WAN_IF " || return 1
    ip link show "$TUN" | grep -q ',UP' || return 1
    ip -6 addr show dev "$TUN" | grep -q " $LOCAL_C/128 " || return 1
    ip -4 addr show dev "$TUN" | grep -q " $IP4_TUNNEL/32 " || return 1
    ip route show table "$TABLE" | grep -q "^default dev $TUN" || return 1
}

build_tunnel() {
    ip link del "$TUN" 2>/dev/null
    [ -d "/sys/class/net/$WAN_IF" ] || { say "cannot build $TUN: $WAN_IF missing"; return 1; }
    local mtu=$(( $(cat "/sys/class/net/$WAN_IF/mtu") - 40 ))
    # encaplimit none: without it Linux adds a Destination Options header that relays commonly drop.
    ip -6 tunnel add "$TUN" mode ipip6 local "$LOCAL_C" remote "$BR_C" dev "$WAN_IF" encaplimit none hoplimit 64 ||
        { say "cannot build $TUN: ip -6 tunnel add failed"; return 1; }
    ip -6 addr add "$LOCAL_C/128" dev "$TUN" nodad
    ip link set "$TUN" mtu "$mtu" up
    ip addr add "$IP4_TUNNEL/32" dev "$TUN"
    sysctl -qw "net.ipv4.conf.$TUN.rp_filter=2"
    ip route replace default dev "$TUN" table "$TABLE"
    say "tunnel $TUN built: $LOCAL_C -> $BR_C via $WAN_IF, mtu $mtu"
}

# RPS: every tunnel packet has the same outer IPv6 header, so the NIC puts them all on one core.
# Steering the decapsulated packets by their inner flow hash spreads forwarding/NAT over all cores.
set_rps() {   # set_rps FILE MASK — writes only when different
    [ -w "$1" ] || return 0
    [ "$(sed 's/,//g; s/^0*//' "$1")" = "$(printf '%s' "$2" | sed 's/^0*//')" ] || echo "$2" >"$1"
}
ensure_rps() {
    local tun=0 lower=0 q
    [ "$RPS" = on ] && tun=$(printf '%x' $(( (1 << $(nproc)) - 1 )))
    [ "$RPS_LOWER" = on ] && lower=$RPS_LOWER_MASK
    local rxh=$RXHASH o1 o2 o3
    # /run/iliad-wan.rps ("<tunnel mask> <WAN port mask> [rxhash on|off]") overrides until removed: rps-bench.sh uses it.
    if [ -r /run/iliad-wan.rps ] && read -r o1 o2 o3 </run/iliad-wan.rps; then
        tun=${o1:-$tun} lower=${o2:-$lower} rxh=${o3:-$rxh}
    fi
    set_rps "/sys/class/net/$TUN/queues/rx-0/rps_cpus" "$tun"
    for q in /sys/class/net/"$WAN_PORT_IF"/queues/rx-*/rps_cpus; do set_rps "$q" "$lower"; done
    ethtool -k "$WAN_PORT_IF" 2>/dev/null | grep -q "^receive-hashing: $rxh" || ethtool -K "$WAN_PORT_IF" rxhash "$rxh" 2>/dev/null
}

# --- firewall -----------------------------------------------------------------------------------

# sync_chain CMD TABLE BUILTIN CHAIN RULES: RULES is one rule per line. If any rule is missing the
# chain is rebuilt in order; the jump from BUILTIN is restored if a UniFi provision dropped it.
sync_chain() {
    local cmd=$1 table=$2 builtin=$3 chain=$4 rules=$5 r ok=1
    if $cmd -t "$table" -S "$chain" >/dev/null 2>&1; then
        while IFS= read -r r; do
            [ -n "$r" ] || continue
            # shellcheck disable=SC2086
            $cmd -t "$table" -C "$chain" $r 2>/dev/null || { ok=0; break; }
        done <<<"$rules"
    else
        $cmd -t "$table" -N "$chain"
        ok=0
    fi
    if [ "$ok" = 0 ]; then
        $cmd -t "$table" -F "$chain"
        while IFS= read -r r; do
            # shellcheck disable=SC2086
            [ -n "$r" ] && $cmd -t "$table" -A "$chain" $r
        done <<<"$rules"
        say "firewall: $table/$chain (re)built"
    fi
    $cmd -t "$table" -C "$builtin" -j "$chain" 2>/dev/null ||
        { $cmd -t "$table" -I "$builtin" 1 -j "$chain"; say "firewall: jump $table/$builtin -> $chain restored"; }
}

ensure_firewall() {
    local wg=""
    # UniFi keeps its WireGuard server ports in this ipset, so a WireGuard server bound to the Iliad IP stays reachable.
    ipset list -n 2>/dev/null | grep -qx UBIOS_wireguard_ports &&
        wg="-i $TUN -p udp -m set --match-set UBIOS_wireguard_ports dst -j RETURN"
    # Same policy UniFi applies to its WANs (UBIOS_WAN_LOCAL_USER / UBIOS_WAN_IN_USER): replies and
    # WireGuard in, everything else dropped. RETURN rather than ACCEPT, so UniFi's own chains
    # (threat lists, isolation) still see the traffic afterwards.
    sync_chain iptables filter INPUT IWAN_IN4 "-i $TUN -m conntrack --ctstate RELATED,ESTABLISHED -j RETURN
-i $TUN -m conntrack --ctstate INVALID -j DROP
$wg
-i $TUN -j DROP"
    sync_chain iptables filter FORWARD IWAN_FWD "-i $TUN -m conntrack --ctstate RELATED,ESTABLISHED -j RETURN
-i $TUN -j DROP"
    sync_chain ip6tables filter INPUT IWAN_IN6 "-i $WAN_IF -s $BR_C/128 -d $LOCAL_C/128 -p 4 -j ACCEPT"
    sync_chain iptables nat POSTROUTING IWAN_NAT "-o $TUN -j SNAT --to-source $IP4_TUNNEL"
    sync_chain iptables mangle FORWARD IWAN_MSS "-o $TUN -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
-i $TUN -p tcp -m tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu"
}

drop_firewall() {
    drop_chain iptables filter INPUT IWAN_IN4
    drop_chain iptables filter FORWARD IWAN_FWD
    drop_chain ip6tables filter INPUT IWAN_IN6
    drop_chain iptables nat POSTROUTING IWAN_NAT
    drop_chain iptables mangle FORWARD IWAN_MSS
}

# --- routing ------------------------------------------------------------------------------------

has_rule() { ip rule show | grep -qE "^$1:[[:space:]]+$2\$"; }

ensure_src_rule() {
    has_rule $P_SRC "from $IP4_TUNNEL lookup $TABLE" ||
        { ip rule add from "$IP4_TUNNEL" lookup "$TABLE" priority $P_SRC; say "rule $P_SRC restored"; }
}

lan_on() {
    local b cur
    # Anything main knows specifically (LAN-to-LAN, the gateway's subnets) stays in main; only
    # what would otherwise take a default route goes into the tunnel.
    has_rule $P_MAIN "from all lookup main suppress_prefixlength 0" ||
        ip rule add lookup main suppress_prefixlength 0 priority $P_MAIN
    for b in $(lan_bridges); do
        has_rule $P_LAN "from all iif $b lookup $TABLE" || ip rule add iif "$b" lookup "$TABLE" priority $P_LAN
    done
    for cur in $(ip rule show | awk -v p="$P_LAN:" '$1 == p {for (i = 1; i < NF; i++) if ($i == "iif") print $(i + 1)}'); do
        lan_bridges | grep -qx "$cur" || ip rule del iif "$cur" lookup "$TABLE" priority $P_LAN
    done
}

lan_off() {
    while ip rule del priority $P_LAN 2>/dev/null; do :; done
    while ip rule del priority $P_MAIN 2>/dev/null; do :; done
}

# Flows NATed to the side we are leaving would keep their old source address and hang; drop their
# conntrack entries so the next packet is NATed afresh on the new path.
flush_nat_to() {
    [ -n "$1" ] && have conntrack && conntrack -D --src-nat --reply-dst "$1" >/dev/null 2>&1
    return 0
}
fallback_ip() { ip -4 -o addr show dev "$FALLBACK_IF" 2>/dev/null | awk '{sub("/.*", "", $4); print $4; exit}'; }

# --- service ------------------------------------------------------------------------------------

probe() {
    local h
    for h in $CHECK_HOSTS; do ping -c 1 -W 2 -I "$IP4_TUNNEL" "$h" >/dev/null 2>&1 && return 0; done
    return 1
}

run() {
    if systemctl is-active --quiet iliad-deadman.timer 2>/dev/null || ip link show "$TEST_TUN" >/dev/null 2>&1; then
        say "test setup (selftest/lan) still up: taking it down first"
        "$KIT_DIR/lan.sh" down >/dev/null 2>&1
        "$KIT_DIR/selftest.sh" down >/dev/null 2>&1
    fi
    local state=down oks=0 fails=0 since
    since=$(date +%s)
    lan_off
    trap 'say "stopping"; exit 0' TERM INT
    say "starting: $IP4_TUNNEL via $BR_C, checks every ${INTERVAL}s, down after $FAILS_DOWN misses, up after $OKS_UP answers"
    while :; do
        tunnel_ok || build_tunnel
        ensure_rps
        ensure_src_rule
        ensure_firewall
        if probe; then
            oks=$((oks + 1)) fails=0
            if [ "$state" = down ] && [ "$oks" -ge "$OKS_UP" ]; then
                lan_on
                flush_nat_to "$(fallback_ip)"
                state=up since=$(date +%s)
                say "UP: LAN IPv4 now leaves as $IP4_TUNNEL"
            fi
            [ "$state" = up ] && lan_on   # cheap no-op unless a bridge appeared or a rule went missing
        else
            fails=$((fails + 1)) oks=0
            if [ "$state" = up ] && [ "$fails" -ge "$FAILS_DOWN" ]; then
                lan_off
                flush_nat_to "$IP4_TUNNEL"
                state=down since=$(date +%s)
                say "DOWN: tunnel stopped answering, LAN back on UniFi's routing ($FALLBACK_IF)"
            fi
            # A tunnel that exists but never answers may be bound to a stale $WAN_IF: rebuild now and then.
            [ $((fails % 12)) = 0 ] && build_tunnel
        fi
        printf 'state=%s since=%s fails=%s oks=%s\n' "$state" "$since" "$fails" "$oks" >"$STATE"
        sleep "$INTERVAL"
    done
}

down() {
    lan_off
    while ip rule del priority $P_SRC 2>/dev/null; do :; done
    ip route flush table "$TABLE" 2>/dev/null
    ip link del "$TUN" 2>/dev/null
    drop_firewall
    local q
    for q in /sys/class/net/"$WAN_PORT_IF"/queues/rx-*/rps_cpus; do [ -w "$q" ] && echo 0 >"$q"; done
    ethtool -K "$WAN_PORT_IF" rxhash on 2>/dev/null
    rm -f "$STATE"
    [ "${1:-}" = quiet ] || ok "iliad-wan removed: LAN on UniFi's own routing"
}

install() {
    cat >"$UNIT" <<EOF
[Unit]
Description=Iliad IPv4-in-IPv6 WAN (iliad-unifi kit, $KIT_DIR)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$KIT_DIR/iliad-wan.sh run
ExecStopPost=$KIT_DIR/iliad-wan.sh down quiet
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now iliad-wan.service >/dev/null 2>&1 || die "systemctl enable failed"
    ok "installed and started: $UNIT"
    info "watching the first checks (about $((INTERVAL * (OKS_UP + 1)))s)..."
    sleep $((INTERVAL * (OKS_UP + 1)))
    status
}

uninstall() {
    systemctl disable --now iliad-wan.service >/dev/null 2>&1
    rm -f "$UNIT"
    systemctl daemon-reload
    down
}

status() {
    hdr "iliad-wan"
    info "service: $(systemctl is-active iliad-wan.service 2>/dev/null), enabled: $(systemctl is-enabled iliad-wan.service 2>/dev/null)"
    [ -r "$STATE" ] && info "$(cat "$STATE")"
    tunnel_ok && ok "$TUN: $LOCAL_C -> $BR_C, $IP4_TUNNEL" || warn "$TUN missing or incomplete"
    info "rps_cpus: $TUN $(cat "/sys/class/net/$TUN/queues/rx-0/rps_cpus" 2>/dev/null || echo -), $WAN_PORT_IF $(cat /sys/class/net/"$WAN_PORT_IF"/queues/rx-*/rps_cpus 2>/dev/null | tr '\n' ' '), rxhash $(ethtool -k "$WAN_PORT_IF" 2>/dev/null | awk '/^receive-hashing:/ {print $2}')"
    ip rule show | grep -E "^($P_MAIN|$P_LAN|$P_SRC):" | sed 's/^/  /'
    iptables -t nat -vnL IWAN_NAT 2>/dev/null | sed -n '3,$p' | sed 's/^/  nat: /'
    iptables -vnL IWAN_IN4 2>/dev/null | sed -n '3,$p' | sed 's/^/  in4: /'
    hdr "last log lines"
    journalctl -u iliad-wan.service -n 12 --no-pager -o short-iso 2>/dev/null | sed 's/^/  /'
}

case "${1:-}" in
    run) run ;;
    down) down "${2:-}" ;;
    install) install ;;
    uninstall) uninstall ;;
    status) status ;;
    *) echo "usage: $0 install|uninstall|status|run|down" >&2; exit 2 ;;
esac
