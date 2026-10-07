#!/bin/bash
# From a LAN Mac: try RPS mask combinations on the gateway's iliad-wan service and measure each one.
# Needs iliad-wan.sh with the /run/iliad-wan.rps override (2026-09-29). Takes ~2 min; the LAN stays online
# throughout (only the RPS masks change). Leaves the gateway on the service's configured masks afterwards.
#   tools/rps-bench.sh root@192.168.0.1
set -u
gw=${1:?usage: rps-bench.sh root@<gateway>}
url="https://speed.cloudflare.com/__down?bytes=500000000"
# "<iliad0 mask> <WAN port mask>": 0 = off. The tunnel's receive IRQ sat on cpu3 on 2026-09-29.
# third field: the WAN NIC's rxhash. With it on, every flow carries the same outer hash (run 1: RPS moved
# all work to one core). Run 2 re-tests with it off.
configs=("e 0 on" "f 0 off" "7 0 off" "0 7 off" "0 f off" "7 7 off" "f f off")
ssh -q "$gw" true || exit 1
printf '%-7s %-7s %-7s %7s   %s\n' iliad0 eth9 rxhash "Mb/s" "per-core busy% (softirq%)"
for c in "${configs[@]}"; do
    ssh -q "$gw" "echo '$c' > /run/iliad-wan.rps"
    sleep 7   # the service applies it within one 5 s cycle
    ssh -q "$gw" 'sleep 2; head -5 /proc/stat > /tmp/b1; sleep 5; head -5 /proc/stat > /tmp/b2; paste /tmp/b1 /tmp/b2 | awk "NR>1 {n=NF/2; t1=0; t2=0; for(i=2;i<=n;i++){t1+=\$i; t2+=\$(i+n)}; idle=(\$(n+5)-\$5)+(\$(n+6)-\$6); si=\$(n+8)-\$8; tot=t2-t1; printf \"%s %.0f(%.0f) \", \$1, 100*(tot-idle)/tot, 100*si/tot}"' >/tmp/rps-bench-cpu 2>/dev/null &
    mbps=$(for i in 1 2 3 4; do curl -4 -s -o /dev/null --max-time 9 -A "Mozilla/5.0" -H "Referer: https://speed.cloudflare.com/" -w "%{speed_download}\n" "$url" & done | awk '{s+=$1} END {printf "%.0f", s*8/1e6}')
    wait
    read -r t l h <<<"$c"
    printf '%-7s %-7s %-7s %7s   %s\n' "$t" "$l" "${h:--}" "$mbps" "$(cat /tmp/rps-bench-cpu)"
done
ssh -q "$gw" 'rm -f /run/iliad-wan.rps'
echo "override removed: the service is back on its configured masks within 5 s"
