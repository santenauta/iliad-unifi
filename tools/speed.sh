#!/bin/bash
# From a LAN Mac: download through the gateway while it samples its own CPU and fast path.
# Cloudflare only (Hetzner gave erratic numbers for forwarded traffic on 2026-09-29).
#   tools/speed.sh root@192.168.1.1 [STREAMS=4] [SECONDS=12]
#   IFACE=en11 tools/speed.sh ...   send the downloads out of that Mac interface (the gateway's LAN cable)
#                                   while the Mac's default route stays on Wi-Fi
#   IFACE="en11 en12" ...           several LAN cables: streams are dealt out in turn, to go past one 2.5G link
set -u
gw=${1:?usage: speed.sh root@<gateway> [streams] [seconds]}
streams=${2:-4}
secs=${3:-12}
url="https://speed.cloudflare.com/__down?bytes=1000000000"
ssh -q "$gw" true || exit 1
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

read -r -a ifs <<<"${IFACE:-}"
for i in "${ifs[@]:-}"; do
    ifopt=${i:+--interface $i}
    # shellcheck disable=SC2086
    ip4=$(curl $ifopt -4 -s -m 5 https://1.1.1.1/cdn-cgi/trace | awk -F= '$1 == "ip" {print $2}')
    echo "Mac leaves as ${ip4:-?} (IPv4)${i:+ via $i}"
done
for n in $(seq "$streams"); do
    i=${ifs[$(( (n - 1) % (${#ifs[@]} > 0 ? ${#ifs[@]} : 1) ))]:-}
    ifopt=${i:+--interface $i}
    # shellcheck disable=SC2086
    curl $ifopt -4 -s -o /dev/null --max-time "$secs" -A "Mozilla/5.0" -H "Referer: https://speed.cloudflare.com/" \
        -w "${i:-default} %{speed_download}\n" "$url" >>"$tmp/rates" &
done
sleep 3   # let TCP ramp up before the gateway starts sampling
ssh -q "$gw" "/data/iliad/tools/fastpath.sh $((secs - 5))" >"$tmp/gw" 2>&1
wait
printf 'download: %s Mb/s (%s streams, %ss)\n' "$(awk '{s += $2} END {printf "%.0f", s * 8 / 1e6}' "$tmp/rates")" "$streams" "$secs"
[ "${#ifs[@]}" -gt 1 ] && awk '{s[$1] += $2} END {for (i in s) printf "  %-8s %.0f Mb/s\n", i, s[i] * 8 / 1e6}' "$tmp/rates"
sed -n '/== Load over/,$p' "$tmp/gw"
