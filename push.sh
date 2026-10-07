#!/bin/bash
# From the Mac: copy the kit and a line config to a gateway's /data/iliad.
#   ./push.sh root@192.168.1.1 [local/iliad-ucg.conf]     (config defaults to local/iliad.conf)
set -eu
cd "$(dirname "$0")"
dest=${1:?usage: push.sh root@<gateway-ip> [config]}
conf=${2:-local/iliad.conf}
COPYFILE_DISABLE=1 tar --no-xattrs -cf - lib.sh preflight.sh selftest.sh lan.sh udapi-plan.sh iliad-wan.sh native.sh \
    tools/fastpath.sh iliad.conf.example |
    ssh "$dest" 'mkdir -p /data/iliad && tar xf - -C /data/iliad && chmod 755 /data/iliad/*.sh /data/iliad/tools/*.sh'
if [ -f "$conf" ]; then
    ssh "$dest" 'umask 077 && cat > /data/iliad/iliad.conf' <"$conf"
    echo "config: $conf → $dest:/data/iliad/iliad.conf"
fi
echo "copied to $dest:/data/iliad"
echo "next: ssh $dest /data/iliad/preflight.sh"
