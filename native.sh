#!/bin/bash
# Stage 3, native: Iliad on UniFi's own WAN type "IPv4 Over IPv6 → IPIP → v6 Plus" (Network 11.0.81 Early
# Access, UniFi OS 6.0.11). The controller then builds the tunnel and holds the public IPv4 itself (firewall,
# NAT, failover and WAN health all as for any WAN). This helper only covers the two places where Iliad differs
# from the Japanese ISPs the feature was written for:
#   1. ubnt-hb46pp takes the tunnel's local address from the WAN's FIRST global IPv6 (its /64 + interface id).
#      Iliad's DHCPv6 address comes from an access prefix it does not route, so the helper puts an address from
#      the delegated /60's first /64 on the WAN and keeps it first in the list.
#   2. ubnt-hb46pp only builds the tunnel after an HTTP "address update" to a Japanese ISP answers. The helper
#      points the per-WAN override at a responder on the gateway itself, so the dummy login never leaves the box.
#   3. Network 11.0.81 binds the udapi tunnel to the WAN's PORT (eth6) even when the WAN is on a VLAN (eth6.836),
#      where its IPv6 and ubnt-hb46pp live: the parameters get computed but never reach the tunnel, which stays at
#      ::ffff:192.0.0.2 → any. The helper re-points it at the VLAN interface after every provision.
#   4. Guard (needs a UniFi API key): the UniFi iOS app silently turns the WAN back into DHCP when anyone saves it
#      there. The helper notices that exact state and writes the IPIP settings back through the controller.
# Everything else is UniFi's. `check` and `ui` change nothing.
#   native.sh check | ui | up | down | kick | status | guard-check | install | uninstall | run
. "$(dirname "$0")/lib.sh"
[ "${1:-}" = ui ] || need_root
load_conf
[ -n "${CONF_ERR:-}" ] && die "config: $CONF_ERR"

INTERVAL=${NATIVE_INTERVAL:-5}
KICK_AFTER=${NATIVE_KICK_AFTER:-60}     # s without UniFi's tunnel (address, override and responder in place) before a kick
KICK_EVERY=${NATIVE_KICK_EVERY:-300}    # s between kicks
RESP_PORT=${NATIVE_RESP_PORT:-4646}
IPIP_USER=${IPIP_USER:-iliad}           # v6 Plus wants 1-20 alphanumerics; Iliad has no login, these never leave the box
IPIP_PASS=${IPIP_PASS:-iliad46}
UNIT=/etc/systemd/system/iliad-native.service
STATE=/run/iliad-native.state
RESP_PID=/run/iliad-native.resp.pid
GUARD=INATIVE_RESP
API_KEY_FILE=${NATIVE_API_KEY_FILE:-$KIT_DIR/api.key}   # UniFi API key with write access, root-only; enables the guard
GUARD_EVERY=${NATIVE_GUARD_EVERY:-30}                   # s between controller checks while the WAN is not IPIP
GUARD_MAX=${NATIVE_GUARD_MAX:-3}                        # restores per hour before the guard gives up
API=https://127.0.0.1/proxy/network/api/s/default

# The WAN address: FIRST64 + NATIVE_HOST (hex). Not ::1, which UniFi gives a LAN gateway on prefix id 0.
native_facts() {
    python3 - "$FIRST64" "${NATIVE_HOST:-46}" "$IID" <<'PY'
import ipaddress, sys
n = ipaddress.IPv6Network(sys.argv[1])
a = n.network_address + int(sys.argv[2], 16)
iid = int(ipaddress.IPv6Address(sys.argv[3]))
print("NATIVE_ADDR=" + a.compressed)
print("KICK_ADDR=" + (a + 1).compressed)
print("IID4=" + ":".join("%x" % ((iid >> s) & 0xFFFF) for s in (48, 32, 16, 0)))
PY
}
eval "$(native_facts)"
[ "$NATIVE_ADDR" = "$LOCAL_C" ] && die "NATIVE_HOST makes the WAN address equal IP6_TUNNEL_LOCAL; pick another"
OVERRIDE=/data/udapi-config/jpix.$WAN_IF.address_update
URL="http://[$NATIVE_ADDR]:$RESP_PORT/"

say() { printf '%s\n' "$*"; }   # journald timestamps it
now() { date +%s; }

# --- what UniFi has ------------------------------------------------------------------------------

# "<id> <capability>" for every udapi interface with an enabled hb46pp block.
hb46pp_wans() {
    # Searched at any depth: on 09-26 it sat at .ipv6.hb46pp, but nothing pins that down.
    jq -r '.interfaces[] | .identification.id as $id | .. | objects | select(has("hb46pp")) | .hb46pp |
           select(type == "object" and .enabled != false) | "\($id) \(.capability // "?")"' "$UDAPI_CFG" 2>/dev/null
}
is_native_wan() {
    [ "${NATIVE_FORCE:-0}" = 1 ] && return 0
    hb46pp_wans | awk -v w="$WAN_IF" -v p="$WAN_PORT_IF" '($1 == w || $1 == p) && $2 ~ /^ipip/ {f = 1} END {exit !f}'
}
# UniFi's tunnel with the right local address, if there is one.
unifi_tunnel() {
    ip -6 tunnel show 2>/dev/null | grep -F " local $LOCAL_C " | grep -F "remote $BR_C " | head -1 | cut -d: -f1
}
# Any tunnel towards the Border Relay with some OTHER local (UniFi built it from the wrong WAN address).
stale_tunnel() {
    ip -6 tunnel show 2>/dev/null | grep -F "remote $BR_C " | grep -vF " local $LOCAL_C " | head -1
}

# udapi tunnels bound to the WAN's port instead of its VLAN interface (gap 3; seen on a UCG Fiber and a UDM Pro, 2026-10-06).
misbound_tunnels() {
    [ "$WAN_IF" = "$WAN_PORT_IF" ] && return 0
    ubios-udapi-client -r GET /interfaces 2>/dev/null | jq -r --arg p "$WAN_PORT_IF" \
        '.[] | select(.tunnel?.mode == "ip6tnl" and .tunnel.localAddress?.source == "interface" and .tunnel.localAddress.id == $p) |
         .identification.id' 2>/dev/null
}
fix_binding() {   # fix_binding TUNNEL — PUT the same object with localAddress.id = WAN_IF (udapi wants an array)
    local f=/run/iliad-native.tunnel.json
    ubios-udapi-client -r GET "/interfaces?id=$1" 2>/dev/null | jq --arg w "$WAN_IF" \
        '[.[0] | .tunnel.localAddress.id = $w | del(.status.statistics, .status.timestamp, .status.wan, .tunnel.endpointStatus, .addresses)]' \
        >"$f" 2>/dev/null && [ -s "$f" ] || return 1
    ubios-udapi-client -r PUT "/interfaces?id=$1" "@$f" >/dev/null 2>&1
}
ensure_binding() {
    local t
    for t in $(misbound_tunnels); do
        fix_binding "$t" && say "udapi tunnel $t re-pointed from $WAN_PORT_IF to $WAN_IF" || say "could not re-point udapi tunnel $t"
    done
}

# --- our pieces ----------------------------------------------------------------------------------

addr_present() { ip -6 addr show dev "$WAN_IF" 2>/dev/null | grep -qF " $NATIVE_ADDR/64 "; }
# Any address of FIRST64 heading the list will do (the calculator keeps only its /64): if UniFi puts the
# tunnel local itself on the WAN, that is fine too, and re-adding ours would only start a tug of war.
addr_first() {
    local f
    f=$(v6_globals "$WAN_IF" | head -1)
    [ -n "$f" ] && addr_in_net "$f" "$FIRST64"
}
# Delete + add: the kernel lists the newest address of a scope first, and the change itself makes
# ubnt-hb46pp run again. noprefixroute: Iliad's link is not that /64, nothing should look on-link there.
put_addr() {
    ip -6 addr del "$NATIVE_ADDR/64" dev "$WAN_IF" 2>/dev/null
    ip -6 addr add "$NATIVE_ADDR/64" dev "$WAN_IF" nodad noprefixroute
}
drop_addr() { ip -6 addr del "$NATIVE_ADDR/64" dev "$WAN_IF" 2>/dev/null; return 0; }

# Only the gateway itself may reach the responder: drop anything whose source is not one of its own
# addresses (ubnt-hb46pp binds its request to the WAN, so don't rely on it arriving on lo).
# -w 10: a UniFi provision holds the xtables lock for a moment, and right after the guard restores the WAN
# that is exactly when this runs (2026-10-06 23:09:28 the chain failed once without it).
IP6T="ip6tables -w 10"
ensure_guard() {
    local rule="-p tcp --dport $RESP_PORT -m addrtype ! --src-type LOCAL -j DROP"
    # shellcheck disable=SC2086
    $IP6T -t filter -N "$GUARD" 2>/dev/null
    # shellcheck disable=SC2086
    $IP6T -C "$GUARD" $rule 2>/dev/null || { $IP6T -F "$GUARD"; $IP6T -A "$GUARD" $rule; }
    # shellcheck disable=SC2086
    $IP6T -C INPUT -j "$GUARD" 2>/dev/null || $IP6T -I INPUT 1 -j "$GUARD"
}
drop_guard() { drop_chain "$IP6T" filter INPUT "$GUARD"; }

responder_up() { [ -r "$RESP_PID" ] && kill -0 "$(cat "$RESP_PID")" 2>/dev/null; }
# 200 "OK" to any GET. Logs the path and the parameter names only (the values are the dummy login).
# exec: run in the background, the subshell becomes python, so $! is the responder itself.
responder_py() {
    exec python3 -u - "$RESP_PORT" >/dev/null <<'PY'
import http.server, socket, sys, urllib.parse
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = b"OK\n"
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, fmt, *args):
        u = urllib.parse.urlsplit(self.path)
        keys = ",".join(sorted(urllib.parse.parse_qs(u.query).keys()))
        sys.stderr.write("responder: address update from %s: %s %s params=[%s]\n" % (self.client_address[0], self.command, u.path, keys))
class S(http.server.HTTPServer):
    address_family = socket.AF_INET6
    def server_bind(self):
        self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
        super().server_bind()
S(("::", int(sys.argv[1])), H).serve_forever()
PY
}
# start_responder [LOG] — the service leaves stderr to the journal (a socket: /dev/stderr cannot be
# reopened there); a one-shot `up` logs to a file, since its ssh session ends.
start_responder() {
    if [ -n "${1:-}" ]; then responder_py 2>>"$1" &
    else responder_py &
    fi
    echo $! >"$RESP_PID"
}
stop_responder() {
    responder_up && kill "$(cat "$RESP_PID")" 2>/dev/null
    rm -f "$RESP_PID"
}
# Same request options as ubnt-hb46pp's query_address_update_server (6.0.11).
responder_answers() { [ "$(curl -s -6 -L -m 7 --interface "$WAN_IF" --url "$URL" 2>/dev/null)" = OK ]; }

ensure_override() {
    [ "$(cat "$OVERRIDE" 2>/dev/null)" = "$URL" ] && return 1
    printf '%s\n' "$URL" >"$OVERRIDE"
    return 0
}

# Receive tuning for gateways without a fast path (UDM Pro, 2026-09-29): every tunnel packet carries the same
# outer header, so a NIC hash sends them all to one core and survives decapsulation. NATIVE_RXHASH=off makes the
# kernel hash the inner flow; NATIVE_TUN_RPS=<mask> then spreads UniFi's tunnel over the cores. Both unset = left
# alone (the UCG Fiber needs neither: UniFi sets RPS itself and its NIC has no hash). /run/iliad-native.rps
# ("<mask>") overrides the mask for benches.
apply_tuning() {
    local m=${NATIVE_TUN_RPS:-} f=/sys/class/net/$1/queues/rx-0/rps_cpus
    [ -r /run/iliad-native.rps ] && read -r m </run/iliad-native.rps
    if [ -n "$m" ] && [ -w "$f" ]; then
        [ "$(sed 's/,//g; s/^0*//' "$f")" = "$(printf '%s' "$m" | sed 's/^0*//')" ] || echo "$m" >"$f"
    fi
    if [ -n "${NATIVE_RXHASH:-}" ]; then
        ethtool -k "$WAN_PORT_IF" 2>/dev/null | grep -q "^receive-hashing: $NATIVE_RXHASH" ||
            ethtool -K "$WAN_PORT_IF" rxhash "$NATIVE_RXHASH" 2>/dev/null
    fi
    return 0
}

# IPv4 really works through the tunnel: the one thing that matters, whatever the tunnel looks like.
v4_ok() {
    local h
    for h in 1.1.1.1 9.9.9.9; do ping -c 1 -W 2 -I "$IP4_TUNNEL" "$h" >/dev/null 2>&1 && return 0; done
    return 1
}

up() {   # one-shot: put the three pieces in place (the service does this continuously)
    [ -d "/sys/class/net/$WAN_IF" ] || die "$WAN_IF does not exist: set the UniFi WAN to VLAN $VLAN first"
    is_native_wan || warn "$WAN_IF is not an IPIP WAN in UniFi yet: this only stages the pieces"
    ensure_guard
    responder_up || start_responder /run/iliad-native.resp.log
    ensure_override && info "override written: $OVERRIDE → $URL" || info "override already $URL"
    put_addr && ok "$NATIVE_ADDR/64 on $WAN_IF, first: $(addr_first && echo yes || echo no)"
    ensure_binding
    sleep 1
    responder_answers && ok "responder answers on $URL" || warn "responder does not answer on $URL"
    info "ubnt-hb46pp should now rebuild the tunnel; watch with: $0 status"
}

down() {   # down [quiet|keep-override]
    [ -n "${NATIVE_RXHASH:-}" ] && ethtool -K "$WAN_PORT_IF" rxhash on 2>/dev/null
    drop_addr
    # keep-override: a still-running hb46pp re-queries when the address goes; without the override it would send
    # the dummy login to the Japanese default server (seen 2026-10-06 22:39). The file is inert once hb46pp stops.
    [ "${1:-}" = keep-override ] || rm -f "$OVERRIDE"
    stop_responder
    drop_guard
    rm -f "$STATE"
    [ -z "${1:-}" ] && ok "removed: WAN address, override, responder, guard (UniFi will rebuild from the DHCPv6 address, i.e. no IPv4)"
    return 0
}

# ubnt-hb46pp only retries when its list of WAN addresses CHANGES (it polls once a second), so a delete and
# re-add of the same address can go unnoticed. Add a second address of FIRST64 for a few seconds instead:
# two visible changes, and the first address stays inside FIRST64 throughout, so both runs compute the right local.
kick_hb46pp() {
    ip -6 addr add "$KICK_ADDR/64" dev "$WAN_IF" nodad noprefixroute 2>/dev/null
    sleep 3
    ip -6 addr del "$KICK_ADDR/64" dev "$WAN_IF" 2>/dev/null
    return 0
}
kick() { addr_present || die "$NATIVE_ADDR is not on $WAN_IF (run: $0 up)"; kick_hb46pp; ok "ubnt-hb46pp saw the WAN address list change twice"; }

# --- guard: undo the UniFi app's wipe of the IPIP WAN --------------------------------------------
# The UniFi iOS app (seen 2026-10-06) does not know the "IPIP (Labs)" WAN type: saving that WAN there switches
# wan_type to dhcp and deletes the Border Relay, interface ID and login, keeping the VLAN and IPv6. Iliad never
# answers DHCPv4 on its VLAN, so that combination is never wanted, and the guard writes the IPIP fields back
# through the controller (API key in $API_KEY_FILE). Anything else (VLAN off, another WAN type) is left alone.
# Off: NATIVE_GUARD=off in the config, or touch $KIT_DIR/guard.off.

guard_on() { [ "${NATIVE_GUARD:-on}" != off ] && [ ! -e "$KIT_DIR/guard.off" ] && [ -s "$API_KEY_FILE" ]; }
api() {   # api METHOD PATH [JSON-FILE] — the key goes in a header file, never on the command line
    curl -sk -m 15 -X "$1" -H @<(printf 'X-API-KEY: %s\n' "$(tr -d '\n' <"$API_KEY_FILE")") \
        -H 'Content-Type: application/json' ${3:+--data @"$3"} "$API$2"
}
# The wiped WAN: on our VLAN, IPv4 = dhcp, no Border Relay. Prints its object (one line) or nothing.
wiped_wan() {
    api GET /rest/networkconf | jq -c --arg v "$VLAN" '.data[]? | select(.purpose == "wan"
        and .wan_vlan_enabled == true and ((.wan_vlan // "") | tostring) == $v
        and .wan_type == "dhcp" and ((.wan_ipip_ipv6_gateway // "") == ""))' 2>/dev/null | head -1
}
guard_restore() {
    local w id name out f=/run/iliad-native.guard.json
    w=$(wiped_wan)
    [ -n "$w" ] || return 1
    id=$(jq -r ._id <<<"$w") name=$(jq -r .name <<<"$w")
    ( umask 077; jq --arg br "$BR_C" --arg iid "$IID" --arg ip "$IP4_TUNNEL" --arg u "$IPIP_USER" --arg p "$IPIP_PASS" \
        '. + {wan_type: "ipip,jpix", wan_ipip_ipv6_gateway: $br, wan_ipip_ipv6_identifier: $iid,
              wan_ipip_username: $u, x_wan_ipip_password: $p, wan_ip: $ip, wan_netmask: "255.255.255.255"}' <<<"$w" >"$f" )
    out=$(api PUT "/rest/networkconf/$id" "$f")
    rm -f "$f"
    if [ "$(jq -r '.meta.rc // empty' <<<"$out" 2>/dev/null)" = ok ]; then
        say "GUARD: \"$name\" had been switched to DHCP with its IPIP fields deleted (UniFi app?): IPIP restored"
        return 0
    fi
    say "GUARD: restoring \"$name\" failed: $(jq -c '.meta // .' <<<"$out" 2>/dev/null | cut -c1-200)"
    return 1
}

run() {
    local note last_note="" t n active=0 waiting=0 last_kick=0 readds="" last_guard=0 restores=""
    trap 'say "stopping"; stop_responder; exit 0' TERM INT
    say "starting: WAN $WAN_IF, address $NATIVE_ADDR, address update → $URL, tunnel local must be $LOCAL_C"
    while :; do
        n=$(now)
        if [ ! -d "/sys/class/net/$WAN_IF" ]; then
            note="waiting for $WAN_IF"
        elif ! is_native_wan; then
            note="$WAN_IF is not an IPIP WAN in UniFi (hb46pp: $(hb46pp_wans | tr '\n' ';')): idle"
            [ "$active" = 1 ] && { down keep-override; active=0; say "WAN type changed: helper pieces removed (override kept)"; }
            if guard_on && [ $((n - last_guard)) -ge "$GUARD_EVERY" ]; then
                last_guard=$n
                restores=$(for r in $restores; do [ $((n - r)) -lt 3600 ] && echo "$r"; done)
                if [ "$(printf '%s\n' $restores | grep -c .)" -ge "$GUARD_MAX" ]; then
                    note="GUARD gave up: $GUARD_MAX restores within an hour, something keeps undoing them; fix the WAN in the web UI"
                elif guard_restore; then
                    restores="$restores $n"
                fi
            fi
        else
            active=1
            ensure_guard
            responder_up || { start_responder; say "responder started on port $RESP_PORT"; }
            ensure_override && say "override written: $OVERRIDE → $URL"
            if ! addr_present || ! addr_first; then
                # Guard against a tug of war with something else that keeps re-adding addresses.
                readds=$(for r in $readds; do [ $((n - r)) -lt 300 ] && echo "$r"; done)
                if [ "$(printf '%s\n' $readds | grep -c .)" -ge 5 ]; then
                    note="flapping: $NATIVE_ADDR lost first place 5 times in 5 min; not re-adding (see the log, then: $0 kick)"
                else
                    say "putting $NATIVE_ADDR first on $WAN_IF (first was: $(v6_globals "$WAN_IF" | head -1))"
                    put_addr
                    readds="$readds $n"
                    last_kick=$n
                fi
            fi
            ensure_binding
            t=$(unifi_tunnel)
            if v4_ok; then
                note="IPv4 up: ${t:-a tunnel ip6tnl show does not list with local $LOCAL_C} carries $IP4_TUNNEL"
                waiting=0
                [ -n "$t" ] && apply_tuning "$t"
            else
                [ "$waiting" = 0 ] && waiting=$n
                if [ -n "$t" ]; then
                    note="UniFi tunnel $t exists but $IP4_TUNNEL gets no ping replies"
                elif [ -n "$(stale_tunnel)" ]; then
                    note="UniFi tunnel has the wrong local: $(stale_tunnel | awk '{print $1, $5, $6}')"
                else
                    note="waiting for UniFi's tunnel"
                fi
                # Kick only while IPv4 is really down: a kick rebuilds the tunnel, i.e. a short outage.
                if [ $((n - waiting)) -ge "$KICK_AFTER" ] && [ $((n - last_kick)) -ge "$KICK_EVERY" ]; then
                    kick_hb46pp
                    last_kick=$n
                    say "no IPv4 for $((n - waiting))s: kicked ubnt-hb46pp ($KICK_ADDR added for 3 s)"
                fi
            fi
        fi
        [ "$note" != "$last_note" ] && say "$note"
        last_note=$note
        printf 'at=%s note=%s\n' "$n" "$note" >"$STATE"
        sleep "$INTERVAL"
    done
}

# No ExecStopPost teardown: a stop or restart (an update of this script) leaves the address and override in
# place, so the tunnel keeps working — only `uninstall` removes them. Re-running install restarts the service.
install() {
    cat >"$UNIT" <<EOF
[Unit]
Description=Iliad helper for UniFi's native IPIP WAN (iliad-unifi kit, $KIT_DIR)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$KIT_DIR/native.sh run
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable iliad-native.service >/dev/null 2>&1 || die "systemctl enable failed"
    systemctl restart iliad-native.service || die "systemctl restart failed"
    ok "installed and (re)started: $UNIT"
    sleep $((INTERVAL * 3))
    status
}

uninstall() {
    systemctl disable --now iliad-native.service >/dev/null 2>&1
    rm -f "$UNIT"
    systemctl daemon-reload
    down
}

# --- reports -------------------------------------------------------------------------------------

# Clone only when the registered MAC is not the port's own. The port's MAC is known on the gateway, not when `ui`
# runs on a computer.
mac_clone_hint() {
    local own reg
    own=$(tr A-F a-f 2>/dev/null <"/sys/class/net/$WAN_PORT_IF/address")
    reg=$(echo "${REGISTERED_MAC:-}" | tr A-F a-f)
    if [ -z "$reg" ]; then
        echo "off if $WAN_PORT_IF's own MAC${own:+ ($own)} is the one registered in the Iliad portal, else the registered MAC"
    elif [ -z "$own" ]; then
        echo "off if $REGISTERED_MAC is $WAN_PORT_IF's own MAC, else $REGISTERED_MAC"
    elif [ "$own" = "$reg" ]; then
        echo "off ($WAN_PORT_IF's own MAC $own is the registered one)"
    else
        echo "$REGISTERED_MAC  ($WAN_PORT_IF's own MAC is $own)"
    fi
}

ui() {
    hdr "UniFi → Settings → Internet → the Iliad WAN (Network 11.0.81 EA or later)"
    cat <<EOF
  Port / interface   the gateway port the ONT is cabled to  (kit: WAN_PORT_IF=$WAN_PORT_IF)
  VLAN ID            $VLAN
  MAC Address Clone  $(mac_clone_hint)
  IPv4 connection    IPv4 Over IPv6 → IPIP → v6 Plus
    Border Relay     $BR_C
    Interface ID     $IID        (this form: UniFi's calculator crashes on $IID4)
    IPv4 address     $IP4_TUNNEL
    Netmask          255.255.255.255  (/32)
    Username         $IPIP_USER       (dummy: Iliad has no login; the helper answers the update locally)
    Password         $IPIP_PASS
  IPv6 connection    DHCPv6, Prefix Delegation size 60
  LAN networks       no IPv6, or a prefix ID other than 0 ($FIRST64 belongs to the tunnel)
EOF
    info "Expected tunnel local: $LOCAL_C  (= $FIRST64 + $IID)"
    info "Helper WAN address:    $NATIVE_ADDR/64 (noprefixroute)   address-update URL: $URL"
}

check() {
    hdr "Versions"
    info "model: $(ubnt-device-info model 2>/dev/null)   UniFi OS: $(ubnt-device-info firmware 2>/dev/null)   Network: $(dpkg-query -W -f='${Version}' unifi-native 2>/dev/null || dpkg-query -W -f='${Version}' unifi 2>/dev/null)"

    hdr "ubnt-hb46pp: address update, address choice, retry (read off the script)"
    local s=/usr/bin/ubnt-hb46pp
    [ -r "$s" ] || die "no $s"
    grep -nE 'address_update|curl|ipip_jpix|enabler|ip -json|ip -6|preferred|tentative|sleep|retry|inotify|monitor|hb46pp-update|jpix\.' "$s" |
        cut -c1-180 | head -70 | sed 's/^/  /'
    grep -nE 'def |ipip_jpix|ipip_from_config|split|/64|prefixlen' /usr/bin/ubnt_hb46pp_calc.py | cut -c1-160 | head -30 | sed 's/^/  calc: /'

    hdr "Calculator: which Interface ID form reproduces IP6_TUNNEL_LOCAL"
    local form enc pred
    for form in "$IID" "$IID4"; do
        enc="$form|$BR_C|$IP4_TUNNEL|32"
        pred=$(printf '{"encoded_params": "%s"}' "$enc" | python3 /usr/bin/ubnt_hb46pp_calc.py ipip_jpix "$WAN_IF" "$NATIVE_ADDR" 2>&1 | cut -d'|' -f2)
        [ "$pred" = "$LOCAL_C" ] && ok "IID '$form' + WAN address $NATIVE_ADDR → $pred" || warn "IID '$form' → '${pred:-nothing}'"
    done

    hdr "UniFi's view"
    local wans
    wans=$(hb46pp_wans)
    [ -n "$wans" ] && printf '%s\n' "$wans" | sed 's/^/  hb46pp enabled: /' || info "no udapi interface has hb46pp enabled yet"
    is_native_wan && ok "$WAN_IF is an IPIP WAN: the service will act" || warn "$WAN_IF is not an IPIP WAN: the service would idle"
    jq -c --arg w "$WAN_IF" --arg p "$WAN_PORT_IF" ".interfaces[] | select(.identification.id == \$w or .identification.id == \$p or .identification.type == \"tunnel\") | $REDACT" \
        "$UDAPI_CFG" 2>/dev/null | cut -c1-900 | sed 's/^/  /'
    local sn
    sn=$(jq -r '.. | objects | select(has("hb46pp")) | .hb46pp.authentication?.serverName // empty' "$UDAPI_CFG" 2>/dev/null | head -1)
    if [ -n "$sn" ]; then
        info "serverName from the controller: $sn"
        pred=$(printf '{"encoded_params": "%s"}' "$sn" | python3 /usr/bin/ubnt_hb46pp_calc.py ipip_jpix "$WAN_IF" "$NATIVE_ADDR" 2>&1 | cut -d'|' -f2)
        [ "$pred" = "$LOCAL_C" ] && ok "controller's serverName + $NATIVE_ADDR → $LOCAL_C" || warn "controller's serverName + $NATIVE_ADDR → '$pred', not $LOCAL_C"
    fi
    ls -l /data/udapi-config/jpix.* 2>/dev/null | sed 's/^/  override: /'
    local mb
    mb=$(misbound_tunnels)
    [ -n "$mb" ] && warn "udapi tunnel(s) bound to $WAN_PORT_IF, not $WAN_IF: $mb (the service re-points them)"

    hdr "Conflicts"
    local clash
    clash=$(ip -6 -o addr show scope global | awk -v w="$WAN_IF" '$2 != w {print $2, $4}' | while read -r i a; do
        addr_in_net "${a%/*}" "$FIRST64" && echo "$i $a"; done)
    [ -z "$clash" ] && ok "nothing else uses $FIRST64" || warn "already in $FIRST64 (give that LAN a prefix ID ≠ 0): $clash"
    ss -ltnH 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$RESP_PORT\$" && ! responder_up && warn "port $RESP_PORT already taken: set NATIVE_RESP_PORT"

    if [ -d "/sys/class/net/$WAN_IF" ]; then
        hdr "Now on $WAN_IF"
        local mac
        mac=$(cat "/sys/class/net/$WAN_IF/address")
        if [ -n "${REGISTERED_MAC:-}" ]; then
            [ "$(echo "$mac" | tr A-F a-f)" = "$(echo "$REGISTERED_MAC" | tr A-F a-f)" ] &&
                ok "$WAN_IF MAC $mac = the one registered with Iliad" ||
                warn "$WAN_IF MAC $mac ≠ registered $REGISTERED_MAC: set the WAN's MAC Address Clone (no IPv6 until then)"
        fi
        v6_globals "$WAN_IF" | head -4 | sed 's/^/  global (in order): /'
        local first
        first=$(v6_globals "$WAN_IF" | head -1)
        [ -n "$first" ] && info "hb46pp would derive: $(unifi_predict_local "$first")"
        ip -d -6 tunnel show 2>/dev/null | grep -v 'remote :: ' | sed 's/^/  tunnel: /'
    fi
    hdr "Fast path modules"
    lsmod 2>/dev/null | awk '$1 ~ /ecm|sfe|ppe|nss/ {printf "  %s", $1} END {print ""}'
}

status() {
    hdr "iliad-native"
    info "service: $(systemctl is-active iliad-native.service 2>/dev/null), enabled: $(systemctl is-enabled iliad-native.service 2>/dev/null)"
    [ -r "$STATE" ] && info "$(cat "$STATE")"
    addr_present && { addr_first && ok "$NATIVE_ADDR first on $WAN_IF" || warn "$NATIVE_ADDR on $WAN_IF but not first"; } ||
        warn "$NATIVE_ADDR not on $WAN_IF"
    [ "$(cat "$OVERRIDE" 2>/dev/null)" = "$URL" ] && ok "override → $URL" || warn "override missing or different: $OVERRIDE"
    responder_answers && ok "responder answers" || warn "responder does not answer on $URL"
    local t
    t=$(unifi_tunnel)
    if [ -n "$t" ]; then
        ok "UniFi tunnel $t: $LOCAL_C → $BR_C"
        ip -4 addr show dev "$t" | grep -qF " $IP4_TUNNEL/" && ok "$t holds $IP4_TUNNEL" || warn "$t has no $IP4_TUNNEL"
        info "$t mtu $(cat "/sys/class/net/$t/mtu"), rps_cpus $(cat "/sys/class/net/$t/queues/rx-0/rps_cpus" 2>/dev/null), $WAN_PORT_IF $(ethtool -k "$WAN_PORT_IF" 2>/dev/null | grep '^receive-hashing')"
        ping -c 2 -W 2 -I "$IP4_TUNNEL" 1.1.1.1 >/dev/null 2>&1 && ok "ping 1.1.1.1 from $IP4_TUNNEL" || warn "no ping reply from 1.1.1.1 via $IP4_TUNNEL"
        iptables -t mangle -S 2>/dev/null | grep -q "TCPMSS.*$t\|$t.*TCPMSS" && ok "MSS clamp on $t" || info "no TCPMSS rule naming $t (check if MTU < 1500)"
    else
        warn "no UniFi tunnel with local $LOCAL_C"
        [ -n "$(stale_tunnel)" ] && warn "stale: $(stale_tunnel)"
    fi
    local mb
    mb=$(misbound_tunnels)
    [ -z "$mb" ] && ok "no udapi tunnel bound to $WAN_PORT_IF instead of $WAN_IF" || warn "udapi tunnel(s) bound to $WAN_PORT_IF: $mb"
    pgrep -a -x dpinger 2>/dev/null | grep -F -- "-I $t " | head -2 | cut -c1-160 | sed 's/^/  dpinger: /'
    if guard_on; then ok "guard on (undoes the app's switch to DHCP on VLAN $VLAN; $0 guard-check tests the key)"
    else info "guard off ($([ -s "$API_KEY_FILE" ] || echo "no API key in $API_KEY_FILE")$([ -e "$KIT_DIR/guard.off" ] && echo " guard.off present")$([ "${NATIVE_GUARD:-on}" = off ] && echo " NATIVE_GUARD=off"))"; fi
    # By time, not line count: a busy UDM journal pushes these past the last few hundred lines within minutes.
    hdr "hb46pp log (last 24 h)"
    journalctl --no-pager --since "-24h" -o short-iso 2>/dev/null | grep -E 'hb46pp \(|Provisioning IP6TNL' | tail -8 | cut -c1-220 | sed 's/^/  /'
    hdr "helper log"
    journalctl -u iliad-native.service -n 10 --no-pager -o short-iso 2>/dev/null | sed 's/^/  /'
}

guard_check() {   # read-only: does the key work, and what would the guard do right now
    hdr "guard"
    [ -s "$API_KEY_FILE" ] || die "no API key in $API_KEY_FILE (create one in UniFi OS → Control Plane → Integrations, then: umask 077; cat > $API_KEY_FILE)"
    [ "$(stat -c %a "$API_KEY_FILE")" = 600 ] || warn "$API_KEY_FILE should be mode 600 (chmod 600 it)"
    local out
    out=$(api GET /rest/networkconf)
    [ "$(jq -r '.meta.rc // empty' <<<"$out" 2>/dev/null)" = ok ] || die "the key cannot read the controller: $(jq -c '.meta // .' <<<"$out" 2>/dev/null | cut -c1-200)"
    ok "key reads the controller (whether it may also write shows on the first restore)"
    jq -r --arg v "$VLAN" '.data[] | select(.purpose == "wan") |
        "  \(.name): wan_type=\(.wan_type) vlan=\(if .wan_vlan_enabled then (.wan_vlan|tostring) else "off" end)\(if ((.wan_vlan // "")|tostring) == $v then "  ← on Iliad VLAN" else "" end)"' <<<"$out"
    [ -n "$(wiped_wan)" ] && warn "a WAN is in the wiped state right now: the service would restore it" || ok "no WAN in the wiped state"
    guard_on && ok "guard on" || info "guard off (NATIVE_GUARD=off or $KIT_DIR/guard.off)"
}

case "${1:-}" in
    guard-check) guard_check ;;
    check) check ;;
    ui) ui ;;
    up) up ;;
    down) down "${2:-}" ;;
    kick) kick ;;
    run) run ;;
    install) install ;;
    uninstall) uninstall ;;
    status) status ;;
    *) echo "usage: $0 check|ui|up|down|kick|status|guard-check|install|uninstall|run" >&2; exit 2 ;;
esac
