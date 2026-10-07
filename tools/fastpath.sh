#!/bin/bash
# On the gateway: is the Iliad tunnel on Qualcomm's fast path (ECM + SFE/PPE), and what does it cost the CPU?
# Prints the fast-path modules and counters, then samples per-core load and interface rates.
# Run it while a LAN client downloads; tools/speed.sh on the Mac does both at once.
#   tools/fastpath.sh [SECONDS]            sample for SECONDS (default 10); 0 = snapshot only
#   tools/fastpath.sh --mount [SECONDS]    mount debugfs first if it is not (the only thing this can change)
. "$(dirname "$0")/../lib.sh"
need_root
load_conf optional
[ "${1:-}" = --mount ] && { MOUNT=1; shift; }
SECS=${1:-10}
DBG=/sys/kernel/debug

# The Iliad tunnel, whoever built it: UniFi's native one, iliad-wan's iliad0, or the test tunnel.
TUN=""
if [ "${HAVE_CONF:-0}" = 1 ]; then
    TUN=$(ip -6 tunnel show 2>/dev/null | grep -F "remote $BR_C " | head -1 | cut -d: -f1)
    WAN=$WAN_IF PORT=$WAN_PORT_IF
fi

hdr "Fast-path modules"
lsmod 2>/dev/null | awk '$1 ~ /ecm|sfe|ppe|nss/ {printf "  %s(%s)", $1, $3} END {print ""}'
info "tunnel: ${TUN:-none found}   WAN: ${WAN:-?} on ${PORT:-?}"
[ -n "$TUN" ] && ip -d link show "$TUN" | sed -n '2,3p' | sed 's/^ */  /'

if ! grep -q " $DBG debugfs " /proc/mounts; then
    if [ "${MOUNT:-0}" = 1 ]; then mount -t debugfs none "$DBG" && ok "debugfs mounted"
    else info "debugfs not mounted: ECM counters hidden (re-run with --mount)"; fi
fi

# Small counter files, read with a timeout (some debugfs nodes block or are write-only).
dump_counters() {   # dump_counters DIR MAXDEPTH NAME-REGEX
    [ -d "$1" ] || return 0
    find "$1" -maxdepth "$2" -type f 2>/dev/null | grep -E "$3" | head -60 | while read -r f; do
        v=$(timeout 1 head -c 160 "$f" 2>/dev/null | tr '\n' ' ' | tr -s ' ')
        [ -n "$v" ] && printf '  %s: %s\n' "${f#$DBG/}" "$v"
    done
}
ecm_snapshot() {
    dump_counters "$DBG/ecm" 2 'count|accel|stop|enable|limit'
}
if [ -d "$DBG/ecm" ]; then
    hdr "ECM counters"
    ecm_snapshot
    # Connection dump: which connections ECM accelerated, and whether any of them goes through the tunnel.
    if [ -r "$DBG/ecm/ecm_state/state_dev_major" ]; then
        major=$(cat "$DBG/ecm/ecm_state/state_dev_major")
        [ -c /tmp/ecm_state ] || mknod /tmp/ecm_state c "$major" 0 2>/dev/null
        if timeout 5 cat /tmp/ecm_state >/tmp/ecm_state.xml 2>/dev/null; then
            info "ECM state: $(grep -c '<conn' /tmp/ecm_state.xml) connection records"
            grep -oE '(accel_mode|front_end|can_accel|accel_state|regen)[a-z_]*="[^"]*"' /tmp/ecm_state.xml |
                sort | uniq -c | sort -rn | head -12 | sed 's/^/  /'
            [ -n "$TUN" ] && info "records naming $TUN: $(grep -c "$TUN" /tmp/ecm_state.xml)"
            info "full dump: /tmp/ecm_state.xml"
        fi
    fi
fi
hdr "SFE / PPE counters"
for d in $(find /sys "$DBG" -maxdepth 2 -type d \( -iname '*sfe*' -o -iname '*ppe*' \) 2>/dev/null | grep -v '/module/' | head -8); do
    dump_counters "$d" 2 'stat|count|connection|exception|accel|flow' | head -20
done

[ "$SECS" -gt 0 ] 2>/dev/null || exit 0

IFS_LIST=""
for i in $PORT $WAN $TUN $(ip -o -4 addr show | awk '$2 ~ /^br[0-9]/ {print $2}' | sort -u); do
    [ -d "/sys/class/net/$i" ] && IFS_LIST="$IFS_LIST $i"
done
snap() {
    head -n $(($(nproc) + 1)) /proc/stat | tail -n +2
    local i
    for i in $IFS_LIST; do
        echo "if $i $(cat "/sys/class/net/$i/statistics/rx_bytes") $(cat "/sys/class/net/$i/statistics/tx_bytes")"
    done
}
hdr "Load over ${SECS}s"
a=$(snap)
e1=$(ecm_snapshot 2>/dev/null)
sleep "$SECS"
b=$(snap)
paste <(printf '%s\n' "$a") <(printf '%s\n' "$b") | awk -v s="$SECS" '
    $1 ~ /^cpu/ { n = NF / 2; t = 0; for (i = 2; i <= n; i++) t += $(i + n) - $i
                  idle = ($(n + 5) - $5) + ($(n + 6) - $6); si = $(n + 8) - $8
                  printf "  %-5s busy %3.0f%%  softirq %3.0f%%\n", $1, 100 * (t - idle) / t, 100 * si / t }
    $1 == "if"  { printf "  %-10s rx %7.0f Mb/s  tx %7.0f Mb/s\n", $2, ($7 - $3) * 8 / s / 1e6, ($8 - $4) * 8 / s / 1e6 }'
if [ -d "$DBG/ecm" ]; then
    e2=$(ecm_snapshot 2>/dev/null)
    [ "$e1" = "$e2" ] && info "ECM counters unchanged" || diff <(printf '%s\n' "$e1") <(printf '%s\n' "$e2") | grep '^[<>]' | sed 's/^/  /' | head -20
fi
