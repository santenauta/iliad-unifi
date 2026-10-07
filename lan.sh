#!/bin/bash
# Stage 2: send LAN IPv4 through the test tunnel (selftest.sh up first).
# Uses its own ip rules (prio 97/98), table and iptables chains; UniFi's tables and chains are
# left alone, so `down` (or a reboot, or a controller provision) puts everything back.
# Undoes itself after DEADMAN_MIN minutes unless you run `lan.sh keep`.
#   lan.sh up [--keep] | keep | status | down
. "$(dirname "$0")/lib.sh"
need_root
load_conf
[ -n "${CONF_ERR:-}" ] && die "config: $CONF_ERR"

lan_bridges() { ip -o -4 addr show | awk '$2 ~ /^br[0-9]/ {print $2}' | sort -u; }

up() {
    systemctl is-active --quiet iliad-wan.service 2>/dev/null && die "iliad-wan service is running: it owns the tunnel now (iliad-wan.sh uninstall to test by hand)"
    ip link show "$TEST_TUN" >/dev/null 2>&1 || die "no $TEST_TUN: run selftest.sh up first"
    iptables -S ILIAD_FWD >/dev/null 2>&1 && { info "already up, rebuilding"; down quiet; }
    local bridges b
    bridges=$(lan_bridges)
    [ -n "$bridges" ] || die "no LAN bridges with IPv4"

    hdr "Routing"
    # Anything main knows specifically (LAN-to-LAN, the gateway's subnets) stays in main;
    # only what would otherwise go to a default route is sent into the tunnel.
    ip rule add lookup main suppress_prefixlength 0 priority 97
    for b in $bridges; do ip rule add iif "$b" lookup "$TEST_TABLE" priority 98; done
    ok "LAN bridges → table $TEST_TABLE: $(echo $bridges)"
    info "while this is up, UniFi policy routes for LAN clients (VPN clients, traffic routes) are bypassed"

    hdr "NAT, MSS, firewall"
    ensure_chain iptables nat POSTROUTING ILIAD_NAT
    iptables -t nat -A ILIAD_NAT -o "$TEST_TUN" -j SNAT --to-source "$IP4_TUNNEL"
    ensure_chain iptables mangle FORWARD ILIAD_MSS
    iptables -t mangle -A ILIAD_MSS -o "$TEST_TUN" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
    iptables -t mangle -A ILIAD_MSS -i "$TEST_TUN" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
    ensure_chain iptables filter FORWARD ILIAD_FWD
    iptables -A ILIAD_FWD -i "$TEST_TUN" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    iptables -A ILIAD_FWD -i "$TEST_TUN" -j DROP
    for b in $bridges; do iptables -A ILIAD_FWD -i "$b" -o "$TEST_TUN" -j ACCEPT; done
    ok "SNAT to $IP4_TUNNEL, MSS clamp, inbound NEW on $TEST_TUN dropped"

    if [ "${1:-}" = --keep ]; then
        info "no auto-undo (--keep)"
    else
        systemctl stop iliad-deadman.timer 2>/dev/null
        systemctl reset-failed iliad-deadman.service 2>/dev/null
        systemd-run --quiet --unit=iliad-deadman --on-active="${DEADMAN_MIN}min" "$KIT_DIR/lan.sh" down ||
            warn "could not arm the auto-undo; run lan.sh down by hand if needed"
        warn "auto-undo in $DEADMAN_MIN min: run '$KIT_DIR/lan.sh keep' once a LAN machine browses fine"
    fi

    hdr "Now, from a LAN machine"
    info "curl -4 -s https://ifconfig.co          → should print $IP4_TUNNEL"
    info "then a speed test; watch 'top' here for CPU (the tunnel has no hardware offload)"
}

keep() {
    systemctl stop iliad-deadman.timer 2>/dev/null && ok "auto-undo cancelled" || info "no auto-undo was armed"
}

status() {
    hdr "lan state"
    ip rule show | grep -E '^(97|98):' | sed 's/^/  /'
    systemctl list-timers iliad-deadman.timer --no-pager 2>/dev/null | grep -q iliad-deadman &&
        info "auto-undo armed: $(systemctl list-timers iliad-deadman.timer --no-pager | sed -n 2p)"
    iptables -t nat -vnL ILIAD_NAT 2>/dev/null | sed 's/^/  /'
    iptables -vnL ILIAD_FWD 2>/dev/null | sed 's/^/  /'
}

down() {
    # Stop only the timer: when the auto-undo itself runs this, stopping its service would kill it.
    systemctl stop iliad-deadman.timer 2>/dev/null
    while ip rule del priority 98 lookup "$TEST_TABLE" 2>/dev/null; do :; done
    while ip rule del priority 97 lookup main suppress_prefixlength 0 2>/dev/null; do :; done
    drop_chain iptables nat POSTROUTING ILIAD_NAT
    drop_chain iptables mangle FORWARD ILIAD_MSS
    drop_chain iptables filter FORWARD ILIAD_FWD
    [ "${1:-}" = quiet ] || ok "LAN routing back to UniFi's own"
}

case "${1:-}" in
    up) up "${2:-}" ;;
    keep) keep ;;
    status) status ;;
    down) down ;;
    *) echo "usage: $0 up [--keep]|keep|status|down" >&2; exit 2 ;;
esac
