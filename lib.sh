# Shared helpers for the iliad-unifi kit. Sourced by the scripts, never run directly.
# Runs on UniFi OS (bash, jq, python3, iproute2, iptables-legacy).

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF="${ILIAD_CONF:-$KIT_DIR/iliad.conf}"
UDAPI_CFG=/data/udapi-config/udapi-net-cfg.json

hdr()  { printf '\n== %s\n' "$*"; }
ok()   { printf '  [ok]   %s\n' "$*"; }
info() { printf '  [..]   %s\n' "$*"; }
warn() { printf '  [warn] %s\n' "$*"; }
bad()  { printf '  [FAIL] %s\n' "$*"; }
die()  { printf 'error: %s\n' "$*" >&2; exit 2; }

need_root() { [ "$(id -u)" = 0 ] || die "run as root on the gateway"; }
have()      { command -v "$1" >/dev/null 2>&1; }

# jq filter that blanks anything that looks like a credential, so output is safe to paste.
REDACT='walk(if type == "object" then with_entries(
          if (.key | test("pass|secret|key|token|psk|private|cert"; "i")) and (.value | type == "string")
          then .value = "<redacted>" else . end) else . end)'

# load_conf [optional]  — with "optional", a missing config is not fatal.
load_conf() {
    if [ ! -r "$CONF" ]; then
        [ "${1:-}" = optional ] && { HAVE_CONF=0; return 0; }
        die "no config at $CONF (copy iliad.conf.example to iliad.conf)"
    fi
    # shellcheck disable=SC1090
    . "$CONF"
    : "${WAN_PORT_IF:?set in $CONF}" "${VLAN:?}" "${IP6_NETWORK:?}" "${IP6_TUNNEL_LOCAL:?}" \
      "${IP6_TUNNEL_GW:?}" "${IP4_TUNNEL:?}"
    WAN_IF="${WAN_IF:-$WAN_PORT_IF.$VLAN}"
    TEST_TUN="${TEST_TUN:-iltest0}"
    TEST_TABLE="${TEST_TABLE:-4646}"
    DEADMAN_MIN="${DEADMAN_MIN:-10}"
    HAVE_CONF=1
    eval "$(conf_facts)"
}

# Derives canonical forms and checks the portal values against each other (RFC 7597 layout).
# Prints shell assignments plus CHECK_n lines for the caller to show.
conf_facts() {
    python3 - "$IP6_NETWORK" "$IP6_TUNNEL_LOCAL" "$IP6_TUNNEL_GW" "$IP4_TUNNEL" <<'PY'
import ipaddress, sys
def q(s): return "'" + str(s).replace("'", "") + "'"
net_s, loc_s, br_s, v4_s = sys.argv[1:5]
try:
    net = ipaddress.IPv6Network(net_s, strict=True)
    loc = ipaddress.IPv6Address(loc_s)
    br = ipaddress.IPv6Address(br_s)
    v4 = ipaddress.IPv4Address(v4_s)
except ValueError as e:
    print("CONF_ERR=" + q(e)); sys.exit(0)
first64 = ipaddress.IPv6Network((int(net.network_address), 64))
iid = int(loc) & ((1 << 64) - 1)
iid_s = str(ipaddress.IPv6Address(iid))
checks = []
checks.append(("ok" if loc in first64 else "warn",
               f"IP6_TUNNEL_LOCAL is in the first /64 of IP6_NETWORK ({first64})" if loc in first64
               else f"IP6_TUNNEL_LOCAL is NOT in {first64}; UniFi's '/64 + IID' rule needs a WAN address in its /64"))
emb = (iid >> 16) & 0xFFFFFFFF
if iid >> 48 == 0 and emb == int(v4):
    checks.append(("ok", f"interface id {iid_s} = RFC 7597 layout: IPv4 {v4} embedded, PSID {iid & 0xFFFF}"))
else:
    checks.append(("warn", f"interface id {iid_s} does not embed {v4} in RFC 7597 layout"))
if iid & 0xFFFF:
    checks.append(("warn", "PSID is non-zero: this is a shared IPv4 (port-set), not a full one"))
hi16 = int(v4) >> 16
if any(int(h, 16) == hi16 for h in br.exploded.split(":")):
    checks.append(("info", f"Border Relay {br.compressed} carries the IPv4 /16 ({hi16:x}): expect it to change if the IPv4 does"))
print("NET_C=" + q(net.compressed))
print("LOCAL_C=" + q(loc.compressed))
print("BR_C=" + q(br.compressed))
print("FIRST64=" + q(first64))
print("IID=" + q(iid_s))
print("ENCODED=" + q(f"{iid_s}|{br.compressed}|{v4}|32"))
print("CHECK_COUNT=" + str(len(checks)))
for i, (lvl, msg) in enumerate(checks):
    print(f"CHECK_{i}_LVL={lvl}")
    print(f"CHECK_{i}_MSG=" + q(msg))
PY
}

show_conf_checks() {
    [ -n "${CONF_ERR:-}" ] && { bad "config: $CONF_ERR"; return 1; }
    local i lvl msg
    for ((i = 0; i < CHECK_COUNT; i++)); do
        eval "lvl=\$CHECK_${i}_LVL; msg=\$CHECK_${i}_MSG"
        "$lvl" "$msg"
    done
}

# addr_in_net ADDR NET → exit 0 if ADDR is inside NET
addr_in_net() {
    python3 -c 'import ipaddress,sys; sys.exit(0 if ipaddress.ip_address(sys.argv[1]) in ipaddress.ip_network(sys.argv[2], strict=False) else 1)' "$1" "$2"
}

# Global, preferred, non-tentative IPv6 addresses on an interface, in kernel order — the same
# filter ubnt-hb46pp uses, so the first line is the address it would build the tunnel from.
v6_globals() {
    ip -json -6 addr show dev "$1" scope global 2>/dev/null |
        jq -r '.[].addr_info[] | select(.preferred_life_time > 0) | select(has("tentative") | not) | .local' 2>/dev/null
}

# What UniFi's calculator makes of our encoded params for a given WAN address: prints the tunnel local.
unifi_predict_local() {
    printf '{"encoded_params": "%s"}' "$ENCODED" |
        python3 /usr/bin/ubnt_hb46pp_calc.py ipip_jpix "$WAN_IF" "$1" 2>/dev/null | cut -d'|' -f2
}

# udapi's JSON array for one interface; fails (prints nothing) when udapi does not know it.
udapi_get_iface() {
    local o
    o=$(ubios-udapi-client -r GET "/interfaces?id=$1" 2>/dev/null) || return 1
    printf '%s' "$o" | jq -e 'type == "array" and length > 0' >/dev/null 2>&1 || return 1
    printf '%s\n' "$o"
}

# Insert "-j CHAIN" at the top of BUILTIN in TABLE once; create CHAIN if missing. $1=cmd (iptables|ip6tables)
ensure_chain() {
    local cmd=$1 table=$2 builtin=$3 chain=$4
    $cmd -t "$table" -N "$chain" 2>/dev/null || true
    $cmd -t "$table" -C "$builtin" -j "$chain" 2>/dev/null || $cmd -t "$table" -I "$builtin" 1 -j "$chain"
}
drop_chain() {
    local cmd=$1 table=$2 builtin=$3 chain=$4
    while $cmd -t "$table" -D "$builtin" -j "$chain" 2>/dev/null; do :; done
    $cmd -t "$table" -F "$chain" 2>/dev/null || true
    $cmd -t "$table" -X "$chain" 2>/dev/null || true
}
