#!/bin/bash
# Stage 1: prove the Iliad IPv4-in-IPv6 tunnel from the gateway itself.
# Builds its own tunnel ($TEST_TUN) and routes ONLY traffic sourced from IP4_TUNNEL through it,
# so LAN clients and UniFi's own objects are untouched. Nothing survives a reboot.
#   selftest.sh up | test | status | down
. "$(dirname "$0")/lib.sh"
need_root
load_conf
[ -n "${CONF_ERR:-}" ] && die "config: $CONF_ERR"
PRIO=${TEST_PRIO:-99}

up() {
    systemctl is-active --quiet iliad-wan.service 2>/dev/null && die "iliad-wan service is running: it owns the tunnel now (iliad-wan.sh uninstall to test by hand)"
    hdr "Preconditions"
    [ -d "/sys/class/net/$WAN_IF" ] || die "$WAN_IF does not exist: put the UniFi WAN on VLAN $VLAN first"
    local g
    g=$(v6_globals "$WAN_IF" | tr '\n' ' ')
    [ -n "$g" ] && ok "$WAN_IF global IPv6: $g" || warn "$WAN_IF has no global IPv6 (the tunnel carries its own address, so carry on)"
    ip -6 route show default | grep -q "dev $WAN_IF" ||
        die "no IPv6 default route via $WAN_IF: IPv6 on the line is not up (unregistered WAN MAC looks exactly like this)"
    ok "IPv6 default route via $WAN_IF"
    if iptables -S ILIAD_FWD >/dev/null 2>&1; then die "lan.sh is up; run lan.sh down first"; fi
    ip link show "$TEST_TUN" >/dev/null 2>&1 && { info "$TEST_TUN exists, rebuilding"; down quiet; }

    hdr "Building $TEST_TUN"
    local wan_mtu tun_mtu
    wan_mtu=$(cat "/sys/class/net/$WAN_IF/mtu")
    tun_mtu=$((wan_mtu - 40))
    # encaplimit none: without it Linux adds a Destination Options header that relays commonly drop.
    ip -6 tunnel add "$TEST_TUN" mode ipip6 local "$LOCAL_C" remote "$BR_C" dev "$WAN_IF" encaplimit none hoplimit 64 ||
        die "could not create $TEST_TUN"
    ip -6 addr add "$LOCAL_C/128" dev "$TEST_TUN" nodad
    ip link set "$TEST_TUN" mtu "$tun_mtu" up
    ip addr add "$IP4_TUNNEL/32" dev "$TEST_TUN"
    sysctl -qw "net.ipv4.conf.$TEST_TUN.rp_filter=2"
    ip route replace default dev "$TEST_TUN" table "$TEST_TABLE"
    ip rule add from "$IP4_TUNNEL" lookup "$TEST_TABLE" priority "$PRIO"
    # Let the relay's encapsulated packets in (only relay → our tunnel address), and keep the
    # public IPv4 closed to anything we did not start.
    ensure_chain ip6tables filter INPUT ILIAD_IN6
    ip6tables -A ILIAD_IN6 -i "$WAN_IF" -s "$BR_C" -d "$LOCAL_C" -p 4 -j ACCEPT
    ensure_chain iptables filter INPUT ILIAD_IN4
    iptables -A ILIAD_IN4 -i "$TEST_TUN" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    iptables -A ILIAD_IN4 -i "$TEST_TUN" -j DROP
    ok "$TEST_TUN: $LOCAL_C → $BR_C, mtu $tun_mtu (WAN $wan_mtu), $IP4_TUNNEL/32, table $TEST_TABLE"
    [ "$wan_mtu" -ge 1540 ] || info "WAN MTU $wan_mtu: full 1500 inside the tunnel needs 1540 on $WAN_IF (Iliad advertises up to 1700)"
    run_tests
}

run_tests() {
    hdr "Tests"
    local cap tpid trace seen where n_out n_in
    cap=$(mktemp)
    timeout 20 tcpdump -lni "$WAN_IF" "ip6 and host $BR_C" >"$cap" 2>/dev/null &
    tpid=$!
    sleep 1
    if ping -6 -c 2 -W 2 "$BR_C" >/dev/null 2>&1; then ok "Border Relay answers ping6"; else info "Border Relay does not answer ping6 (not necessarily a problem)"; fi
    if ping -c 3 -W 2 -I "$IP4_TUNNEL" 1.1.1.1 >/dev/null 2>&1; then ok "IPv4 ping 1.1.1.1 from $IP4_TUNNEL"; else bad "IPv4 ping 1.1.1.1 from $IP4_TUNNEL"; fi
    # https: plain http://1.1.1.1 now answers 301, which reads as "got nothing" (2026-09-29).
    trace=$(curl -s -m 8 --interface "$IP4_TUNNEL" https://1.1.1.1/cdn-cgi/trace 2>/dev/null)
    seen=$(printf '%s\n' "$trace" | sed -n 's/^ip=//p')
    where=$(printf '%s\n' "$trace" | sed -n 's/^loc=//p')
    if [ "$seen" = "$IP4_TUNNEL" ]; then ok "HTTP through the tunnel: Cloudflare sees $seen (loc=$where)"; else bad "HTTP through the tunnel: got '${seen:-nothing}'"; fi
    sleep 2
    kill "$tpid" 2>/dev/null
    wait "$tpid" 2>/dev/null
    n_out=$(grep -c "$LOCAL_C > $BR_C" "$cap")
    n_in=$(grep -c "$BR_C > $LOCAL_C" "$cap")
    info "capture on $WAN_IF: $n_out packets to the relay, $n_in back"
    if [ "$n_out" -gt 0 ] && [ "$n_in" = 0 ]; then
        warn "nothing comes back: does $WAN_IF's MAC ($(cat /sys/class/net/$WAN_IF/address)) match the one in the Iliad portal (allow up to 48 h after registering), and is the /60 delegation active?"
    fi
    [ "$n_out" = 0 ] && warn "nothing left $WAN_IF towards the relay: check 'ip -6 route get $BR_C'"
    head -4 "$cap" | cut -c1-160 | sed 's/^/           /'
    rm -f "$cap"
}

status() {
    hdr "selftest state"
    ip link show "$TEST_TUN" >/dev/null 2>&1 || { info "$TEST_TUN not present"; return 0; }
    ip -d link show "$TEST_TUN" | sed 's/^/  /'
    ip addr show dev "$TEST_TUN" 2>/dev/null | grep inet | sed 's/^/  /'
    ip rule show | grep "lookup $TEST_TABLE" | sed 's/^/  /'
    ip route show table "$TEST_TABLE" 2>/dev/null | sed 's/^/  table: /'
    ip6tables -vnL ILIAD_IN6 2>/dev/null | sed 's/^/  /'
    iptables -vnL ILIAD_IN4 2>/dev/null | sed 's/^/  /'
}

down() {
    if iptables -S ILIAD_FWD >/dev/null 2>&1; then die "lan.sh is up; run lan.sh down first"; fi
    while ip rule del from "$IP4_TUNNEL" lookup "$TEST_TABLE" priority "$PRIO" 2>/dev/null; do :; done
    ip route flush table "$TEST_TABLE" 2>/dev/null
    ip link del "$TEST_TUN" 2>/dev/null
    drop_chain ip6tables filter INPUT ILIAD_IN6
    drop_chain iptables filter INPUT ILIAD_IN4
    [ "${1:-}" = quiet ] || ok "selftest removed"
}

case "${1:-}" in
    up) up ;;
    test) run_tests ;;
    status) status ;;
    down) down ;;
    *) echo "usage: $0 up|test|status|down" >&2; exit 2 ;;
esac
