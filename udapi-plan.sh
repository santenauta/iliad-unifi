#!/bin/bash
# Stage 3 preview: what UniFi's own fixed-IPv4 path (hb46pp capability ipip_jpix) would build on
# this gateway, and the exact udapi change that would switch it on. Read-only: applies nothing.
. "$(dirname "$0")/lib.sh"
need_root
load_conf
[ -n "${CONF_ERR:-}" ] && die "config: $CONF_ERR"

grep -q ipip_jpix /usr/bin/ubnt-hb46pp 2>/dev/null || die "this firmware has no ipip_jpix; stages 1-2 are the route here"

hdr "Live udapi objects (redacted)"
for id in "$WAN_PORT_IF" "$WAN_IF"; do
    if o=$(udapi_get_iface "$id"); then
        printf '%s' "$o" | jq -c "$REDACT | .[]" | sed 's/^/  /'
    else
        info "$id: not in udapi"
    fi
done
tunnels=$(ubios-udapi-client -r GET /interfaces 2>/dev/null |
    jq -c "[.[] | select(.identification.id | test(\"^ip6tnl[1-9]\"))] | $REDACT | .[]")
[ -n "$tunnels" ] && printf '%s\n' "$tunnels" | sed 's/^/  /' || info "no udapi-managed ip6tnl tunnel yet (UniFi makes one when the WAN's IPv4 is DS-Lite)"

hdr "hb46pp runtime"
if pgrep -f ubnt-hb46pp >/dev/null 2>&1; then pgrep -af ubnt-hb46pp | sed 's/^/  /'; else info "not running"; fi
for f in /run/hb46pp/*.json; do [ -r "$f" ] && info "$f: $(jq -c "$REDACT" "$f")"; done
ls /data/udapi-config/*address_update* 2>/dev/null | sed 's/^/  override file: /'

hdr "Prediction"
info "serverName: $ENCODED"
first=$(v6_globals "$WAN_IF" | head -1)
if [ -z "$first" ]; then
    warn "$WAN_IF has no preferred global IPv6, hb46pp would wait"
else
    pred=$(unifi_predict_local "$first")
    if [ "$pred" = "$LOCAL_C" ]; then
        ok "first WAN address $first → tunnel local $pred = IP6_TUNNEL_LOCAL"
    else
        warn "first WAN address $first → tunnel local $pred ≠ $LOCAL_C"
        info "fix: give $WAN_IF an address in $FIRST64 ahead of the others (or inject the parameters directly, see README)"
    fi
fi
pd=$(udapi_get_iface "$WAN_IF" | jq -r '.[0].ipv6.dhcp6PDRequestSize // empty' 2>/dev/null)
[ "$pd" = 60 ] && ok "prefix delegation /60" || warn "prefix delegation request is /${pd:-?}; set 60 in the WAN's IPv6 settings"

hdr "Change that stage 3 would make (NOT applied)"
info "1. $WAN_IF .ipv6.hb46pp = (key layout inferred from the binary; confirm against a live DS-Lite WAN first)"
jq -n --arg enc "$ENCODED" '{enabled: true, capability: "ipip_jpix",
    authentication: {username: "iliad", password: "iliad", serverName: $enc}}' | sed 's/^/           /'
info "   (username/password are placeholders: the script only checks they are 1-20 alphanumerics)"
info "2. the udapi ip6tnl tunnel bound to $WAN_IF: remoteAddress null, localAddress {source: interface, id: $WAN_IF}"
info "3. /data/udapi-config/jpix.$WAN_IF.address_update ← an IPv6-reachable URL (e.g. http://ipv6.icanhazip.com/)"
info "   hb46pp only provisions after that HTTP call returns; curl runs without -f, so any web server will do"
info "Every controller provision rewrites these, so the finished version re-applies them (watcher, after stage 3 works)."
