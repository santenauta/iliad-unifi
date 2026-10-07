#!/bin/bash
# Read-only survey of a UniFi gateway for the Iliad IPv4-in-IPv6 test.
# Changes nothing, prints no credentials or serial numbers: the output is safe to paste.
. "$(dirname "$0")/lib.sh"
need_root
load_conf optional

hdr "Gateway"
model=$(ubnt-device-info model 2>/dev/null || tr -d '\0' </proc/device-tree/model 2>/dev/null)
fw=$(ubnt-device-info firmware 2>/dev/null || cat /etc/version 2>/dev/null)
netapp=$(dpkg-query -W -f='${Version}' unifi-native 2>/dev/null || dpkg-query -W -f='${Version}' unifi 2>/dev/null)
info "model: ${model:-?}   UniFi OS: ${fw:-?}   Network: ${netapp:-?}   kernel: $(uname -r)"

hdr "Fixed-IPv4 tunnel support"
CAP=0
if grep -q ipip_jpix /usr/bin/ubnt-hb46pp 2>/dev/null; then
    ok "ubnt-hb46pp knows ipip_jpix (IPIP6 + static IPv4, parameters from config)"; CAP=1
else
    bad "ubnt-hb46pp has no ipip_jpix: this firmware predates it (Early Access may have it)"
fi
grep -q ip6tnl_parameters_ipip_from_config /usr/bin/ubnt_hb46pp_calc.py 2>/dev/null &&
    ok "calculator takes encoded params" || warn "calculator has no ipip_from_config"
if [ -e /sys/class/net/ip6tnl0 ] || grep -q '^ip6_tunnel ' /proc/modules 2>/dev/null; then
    ok "kernel has ip6_tunnel"
else
    warn "no ip6tnl0 device: ip6_tunnel may be a module that is not loaded"
fi
missing=""
for t in jq python3 ethtool tcpdump iptables ip6tables curl systemd-run; do have "$t" || missing="$missing $t"; done
[ -z "$missing" ] && ok "tools present" || warn "missing tools:$missing"

hdr "Ports with link"
for p in /sys/class/net/eth*; do
    i=${p##*/}
    case $i in *.*) continue ;; esac
    carrier=$(cat "$p/carrier" 2>/dev/null || echo 0)
    [ "$carrier" = 1 ] || [ "$i" = "${WAN_PORT_IF:-}" ] || continue
    info "$i  link=$carrier  speed=$(cat "$p/speed" 2>/dev/null || echo ?)Mb/s  mac=$(cat "$p/address")"
done

hdr "SFP modules (serial numbers omitted)"
seen=0
for p in /sys/class/net/eth*; do
    i=${p##*/}
    case $i in *.*) continue ;; esac
    m=$(ethtool -m "$i" 2>/dev/null) || continue
    [ -n "$m" ] || continue
    seen=1
    info "$i:"
    printf '%s\n' "$m" | grep -E 'Identifier|Connector|Transceiver type|Encoding|BR, Nominal|Laser wavelength|Vendor name|Vendor PN|Vendor rev|Length \(SMF' |
        grep -vi 'serial\|vendor sn' | sed 's/^[[:space:]]*/           /'
done
if [ -r /data/udapi-config/sfp_cache_data.json ]; then
    info "UniFi SFP cache: $(jq -c 'walk(if type == "object" then with_entries(select(.key | test("serial|sn$"; "i") | not)) else . end)' /data/udapi-config/sfp_cache_data.json 2>/dev/null)"
fi
[ $seen = 1 ] || info "no module answered ethtool -m"

hdr "WAN side today"
WANS=$(ip rule show | grep -oE 'lookup 20[0-9]\.[^ ]+' | sed 's/lookup 20[0-9]\.//' | sort -u)
[ -n "$WANS" ] || warn "no UniFi WAN tables (2xx.<if>) in ip rule"
for w in $WANS; do
    tbl=$(ip rule show | grep -oE "lookup 20[0-9]\.$w\$|lookup 20[0-9]\.$w " | head -1 | awk '{print $2}')
    info "WAN $w (table $tbl):"
    for a in $(ip -4 -o addr show dev "$w" 2>/dev/null | awk '{print $4}'); do
        cls=$(python3 -c 'import ipaddress,sys
a=ipaddress.ip_address(sys.argv[1])
print("CGNAT" if a in ipaddress.ip_network("100.64.0.0/10") else "private" if a.is_private else "public")' "${a%/*}")
        note=""
        [ "${HAVE_CONF:-0}" = 1 ] && [ "${a%/*}" = "$IP4_TUNNEL" ] &&
            note=" = IP4_TUNNEL: something upstream (iliadbox?) already terminates the tunnel and hands this address down"
        info "    IPv4 $a ($cls)$note"
    done
    for a in $(v6_globals "$w"); do info "    IPv6 $a"; done
    [ -n "$tbl" ] && ip route show table "$tbl" 2>/dev/null | grep '^default' | sed 's/^/           v4 /'
done
ip -6 route show default 2>/dev/null | sed 's/^/           v6 /'

hdr "udapi view of WAN-side interfaces (redacted)"
jq -c --arg p "${WAN_PORT_IF:-__none__}" --argjson w "$(printf '%s\n' $WANS | jq -R . | jq -s .)" "
    [.interfaces[] | select(.identification.id as \$id |
        (\$w | index(\$id)) or (\$id | startswith(\$p)) or
        .identification.type == \"tunnel\" or .identification.type == \"pppoe\" or
        (.ipv6.hb46pp? != null))] | $REDACT | .[]" "$UDAPI_CFG" 2>/dev/null | sed 's/^/  /'
info "live ip6tnl tunnels:"
ip -d -6 tunnel show 2>/dev/null | grep -v 'remote :: ' | sed 's/^/           /'
info "masquerade / SNAT rules:"
iptables -t nat -S 2>/dev/null | grep -E 'MASQUERADE|SNAT' | sed 's/^/           /'
if pgrep -f ubnt-hb46pp >/dev/null 2>&1; then
    info "hb46pp running: $(pgrep -af ubnt-hb46pp | grep -v pgrep | awk '{print $3, $4, $5}' | tr '\n' ';')"
    for f in /run/hb46pp/*.json; do [ -r "$f" ] && info "  $f: $(jq -c "$REDACT" "$f")"; done
fi

if [ "${HAVE_CONF:-0}" = 1 ]; then
    hdr "Portal values ($CONF)"
    show_conf_checks
    info "ipip_jpix serverName would be: $ENCODED"
    wmac=$(cat "/sys/class/net/$WAN_PORT_IF/address" 2>/dev/null)
    if [ -z "${REGISTERED_MAC:-}" ]; then
        info "REGISTERED_MAC not set: Iliad expects $WAN_PORT_IF's MAC (${wmac:-?}) in the portal"
    elif [ "${REGISTERED_MAC,,}" = "${wmac,,}" ]; then
        ok "$WAN_PORT_IF MAC $wmac matches the MAC registered with Iliad"
    else
        warn "$WAN_PORT_IF MAC is ${wmac:-?} but Iliad has $REGISTERED_MAC: set UniFi WAN 'MAC Address Clone' to $REGISTERED_MAC"
    fi
    if [ -d "/sys/class/net/$WAN_IF" ]; then
        ok "$WAN_IF exists"
        first=$(v6_globals "$WAN_IF" | head -1)
        if [ -z "$first" ]; then
            warn "$WAN_IF has no preferred global IPv6 yet"
        else
            pred=$(unifi_predict_local "$first")
            if [ "$pred" = "$LOCAL_C" ]; then
                ok "hb46pp would use $first → tunnel local $pred = IP6_TUNNEL_LOCAL"
            else
                warn "hb46pp would use $first → tunnel local $pred, not $LOCAL_C (the WAN needs an address in $FIRST64 first)"
            fi
        fi
        pd=$(udapi_get_iface "$WAN_IF" | jq -r '.[0].ipv6.dhcp6PDRequestSize // empty' 2>/dev/null)
        [ -n "$pd" ] && { [ "$pd" = 60 ] && ok "prefix delegation request /60" || warn "prefix delegation request /$pd, Iliad delegates /60"; }
    else
        info "$WAN_IF does not exist yet (expected until the UniFi WAN is moved onto VLAN $VLAN)"
    fi
fi

hdr "Summary"
[ $CAP = 1 ] && ok "firmware can do UniFi-native fixed IPv4 (ipip_jpix)" || warn "firmware cannot: raw tunnel (selftest.sh / lan.sh) still works"
