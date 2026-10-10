# iliad-unifi

**English** · [Italiano](README.it.md) — guida completa in italiano

Run an **Iliad Italia "modem libero" (net neutrality) FTTH line directly on a UniFi gateway**, with no iliadbox
in front. It uses UniFi's own *IPv4 Over IPv6 → IPIP* WAN type (UniFi Network 11.0.81 Early Access and later)
plus a small helper that covers the places where Iliad differs from the Japanese ISPs that feature was written for.

**Status (2026-10-08):** working on an Iliad 5 Gbps line (5000/700) with a **UniFi Cloud Gateway Fiber** and a
**UDM Pro**, and on a **2.5 Gbps GPON line** (2500/1000) with a UCG Fiber, all on UniFi OS 6.0.11 and UniFi Network
11.0.81 EA. The IPIP type is marked *Labs* in an Early Access release and may change under you. Reports welcome.

## How Iliad delivers IPv4

Iliad's access network is IPv6-only: **VLAN 836**, DHCPv6 with a **/60 delegated**. IPv4 is carried in an
**IPv4-in-IPv6 tunnel (RFC 2473)** to a Border Relay, with a **static public IPv4** on the customer side and NAT
done locally. The values come from *Area Personale → Informazioni Net Neutrality*:

| Portal field | Meaning |
|---|---|
| `IP6_NETWORK` | the delegated /60 |
| `IP6_TUNNEL_LOCAL` | tunnel local address = first /64 of the /60 + an RFC 7597 interface ID `0:<IPv4>:0` |
| `IP6_TUNNEL_GW` | the Border Relay |
| `IP4_TUNNEL` | your static public IPv4 |

In other words it is MAP-E with a whole IPv4 (1:1), which is the same shape as Japan's fixed-IP "v6 Plus"
service. That is why UniFi's v6 Plus profile fits.

## What UniFi 11.0.81 does, and what `native.sh` adds

*Settings → Internet → IPv4 Over IPv6 → IPIP → v6 Plus* takes a Border Relay, an interface ID and a fixed IPv4.
The controller stores them, builds the tunnel and treats the public IPv4 like any other WAN: NAT, firewall, WAN
health, failover. On Iliad it still does not come up on its own:

| # | Gap | What `native.sh` does |
|---|---|---|
| 1 | The tunnel's local address is derived from the WAN's **first** global IPv6. On Iliad that is the DHCPv6 /128 from a separate access prefix, which Iliad does not route at all. | Puts `<first /64 of the /60>::46/64` (`nodad noprefixroute`) on the WAN and keeps an address of that /64 first in the list. |
| 2 | The tunnel is built only after an HTTP "address update" to the Japanese ISP succeeds, with a mandatory login. One failure means no retry until the WAN's IPv6 changes. | Points UniFi's per-WAN override (`/data/udapi-config/jpix.<wan>.address_update`) at a tiny responder on the gateway itself, so the dummy login never leaves the box, and nudges UniFi again if IPv4 stays down for 60 s. |
| 3 | With a VLAN on the WAN, Network 11.0.81 binds the tunnel to the **port** (`eth9`) instead of the **VLAN interface** (`eth9.836`). The right parameters are computed but the tunnel stays at `::ffff:192.0.0.2 → any`. | Re-points the tunnel at the VLAN interface after every provision. It checks every second, so IPv4 is gone for a second or two (about 4 s with the old 5 s loop). UniFi still shows the WAN *down* for ~10 s more, because the re-point restarts its health check. Still needed on 11.0.83. |
| 4 | **Trap:** saving that WAN in the **UniFi iOS app**, which does not know the IPIP type, silently turns it into DHCP and deletes the Border Relay, interface ID and login. Iliad goes down. | Optional guard: with a UniFi API key it notices exactly that state and writes the IPIP settings back (at most 3 times an hour). |
| 5 | *LAN IPv6:* nothing routes the unused part of the /60, so packets to it bounce between the gateway and Iliad until their hop limit runs out. | Adds an unreachable route for the /60 (the LAN /64s are more specific). |
| 6 | *LAN IPv6:* UniFi's domain-based **Traffic Routes** (a site sent through a VPN client, say) act on IPv4 only. Their IPv6 address lists fill up but nothing uses them, so dual-stack clients reach those sites over Iliad directly: wrong country, no kill switch. | Refuses IPv6 to those sites with an immediate reset; clients fall back to IPv4, which the route carries. Off: `NATIVE_V6_ROUTES=off`. |

Pieces 5 and 6 matter only once a LAN has public IPv6 from the /60, and do nothing harmful without one.
Everything else is UniFi's own. As a service (`iliad-native`) the helper re-checks every 5 s and goes idle if the
WAN is no longer an IPIP WAN.

## Results

**5 Gbps** (XGS-PON, 2026-10-06):

| | UCG Fiber | UDM Pro |
|---|---|---|
| UniFi's own speed test (ends on the gateway) | 3688 / 684 Mb/s | 4449 / 686 Mb/s |
| Forwarded to a LAN client on 2 × 2.5G | **3.70 Gb/s** | **4.32 Gb/s** (IPS off, RPS tuned) |
| Forwarded, default settings | 2.2–2.3 Gb/s on one 2.5G link (client limit) | 1.80 Gb/s with IPS on |
| What limits it | one RX ring on cpu0; Qualcomm ECM/SFE accelerates every tunnel flow | CPU: no offload hardware, all four cores ~90 % |

Upload is the plan's 700 Mb/s either way. For comparison, an iliadbox in front of a UniFi router reaches it through
its single 2.5G port, so the router sees at most about 2.35 Gb/s.

**2.5 Gbps** (GPON, UCG Fiber, 2026-10-08): UniFi's speed test **2192 / 924** and 2003 / 952 Mb/s; plain-HTTP
downloads on the gateway 2.10–2.19 Gb/s, native IPv6 a little faster than the tunnel. That is about all GPON
carries: 2.488 Gb/s raw, minus its framing, the 2.5G Ethernet link to the ONT and the tunnel's 40-byte header.
Until a QoS rule was switched off the same line read ~1.6 Gb/s day and night (see *Tuning*).

## Requirements

- **Gateway:** UniFi OS 6.0.11 or later with **UniFi Network 11.0.81 or later** (Early Access at the time of
  writing). Tested: UCG Fiber, UDM Pro. Other gateways that offer the IPIP type will probably work but are untested.
- **SSH** on the gateway (UniFi OS console settings, *SSH* with a password) and your key installed
  (`ssh-copy-id root@<gateway>`).
- **The ONT.** On the 5 Gbps offer this is Iliad's external ONT box, **Freebox F-MDONU05A**: the fibre goes into its
  FIBER cage, and a **10G SFP+ DAC** goes from its BOX cage to the gateway's SFP+ WAN port. A 20 cm 10G DAC linked at
  10G and carried over 4 Gb/s. On the 2.5 Gbps GPON offer the ONT is a **ZTE ZXHN F6005** with a 2.5G RJ45 port:
  cable it to a 2.5G (or faster) RJ45 port on the gateway. Tested on a UCG Fiber's port 1.
- **MAC address.** Iliad sees the **router's WAN port MAC** (the ONT is a layer-2 bridge). Use a MAC already
  registered in the portal, either because it is the port's own MAC or through UniFi's *MAC Address Clone*. The
  portal has only a few slots, which could not be deleted (2024), and a new registration can take up to 48 h.
- A Mac or Linux machine with `ssh` and `tar` to copy the kit over.

## Setup

1. **Config.** `mkdir -p local && cp iliad.conf.example local/iliad.conf` and fill in the four portal values,
   `WAN_PORT_IF` (the port facing the ONT: on a UDM Pro `eth9` = port 10, the SFP+ WAN) and `REGISTERED_MAC`.
   `local/` is gitignored.
2. **Copy the kit:** `./push.sh root@<gateway>` (installs it in `/data/iliad`, which survives reboots).
3. **Preflight (changes nothing):** `ssh root@<gateway> /data/iliad/preflight.sh`. It checks that the firmware
   has the `ipip_jpix` capability, the ports and SFP modules, the current WAN, and whether the WAN port MAC matches
   the registered one. Keep the output and a screenshot of your current WAN settings for rollback.
4. **What to type into UniFi:** `ILIAD_CONF=local/iliad.conf ./native.sh ui` (on your computer) prints every field.
5. **UniFi web UI, not the app** → *Settings → Internet →* the WAN port with the ONT:
   - VLAN ID **836**; MAC Address Clone if needed.
   - IPv4: **IPv4 Over IPv6 → IPIP → v6 Plus**. Border Relay = `IP6_TUNNEL_GW`; **Interface ID in the
     `::`-compressed form** (for 192.0.2.43: `::c000:22b:0`; the four-group form `0:c000:22b:0` crashes UniFi's
     calculator); IPv4 = `IP4_TUNNEL` with a /32 mask; username and password = any 1–20 letters and digits
     (Iliad has no login; the helper answers that call locally).
   - IPv6: **DHCPv6, prefix delegation size 60**.
   - LAN networks: no IPv6, or an IPv6 prefix ID other than 0 (the first /64 belongs to the tunnel).
   - *Test*, then *Confirm*. An unconfirmed *Test* reverts after 5 minutes.
6. **Install the helper:** `ssh root@<gateway> /data/iliad/native.sh check`, then `… native.sh install`.
   `native.sh status` should show UniFi's tunnel with local = `IP6_TUNNEL_LOCAL`, the public IPv4 on it and pings
   answered. The WAN turns green in the UI.
7. **Verify:** from a LAN machine, `curl -4 -s https://1.1.1.1/cdn-cgi/trace` shows your static IPv4. Then
   port-scan that IPv4 from outside your network: nothing should be open. (On a UCG Fiber an outside scan found
   all 65,535 TCP ports filtered; check yours. A network that intercepts a port, as some mobile carriers do with
   21 and VPNs with 53, shows it "open" for any address: try a documentation address such as `192.0.2.1` too.)
8. **Optional guard against the iOS app:** create an API key in *UniFi OS → Control Plane → Integrations* and
   store it on the gateway with `umask 077; cat > /data/iliad/api.key` (root only, never in `iliad.conf`).
   `native.sh guard-check` (read-only) tests the key and shows what the guard would do. The key can change your
   whole network configuration, so treat it like the admin password. To switch the guard off:
   `NATIVE_GUARD=off` in the config or `touch /data/iliad/guard.off`.
9. **Optional, public IPv6 on a LAN:** give that network a /64 of the /60 **other than the first**, either by prefix
   delegation with a prefix ID other than 0 or as a static address. (Tested: the network kept its ULA as its static
   IPv6 and got `<second /64>::1/64` as an additional subnet, `ipv6_aliases` in the API. The gateway advertises
   every /64 on the bridge, so clients take both.) Before you do:
   - UniFi firewall rules set to *IPv4* do not cover IPv6. A network kept off the internet by an IPv4 rule (IoT,
     say) gets out over IPv6 once it has a public /64: leave such networks without one, or make the rules *Both*.
   - Every device on the network takes a public address, containers included. UniFi drops new inbound IPv6 by
     default; prove it with a scan from outside.
   - Pieces 5 and 6 above apply; `native.sh status` shows both.

**Rollback:** `native.sh uninstall`, put the WAN back as it was in UniFi, move the fibre back to the iliadbox.

**After a firmware update** check `native.sh status`. The kit in `/data/iliad` persists; if the update dropped
the service, run `native.sh install` again.

## Tuning

- **UDM Pro** (Annapurna Alpine, no packet engine, so the tunnel is decapsulated in software):
  - turn **Intrusion Prevention** off; with it on, forwarding stopped at 1.80 Gb/s;
  - set `NATIVE_RXHASH=off` and `NATIVE_TUN_RPS` to every core **except** the one that services the tunnel's RX
    queue. The NIC gives every tunnel packet the same hash of the outer header, so the work otherwise piles onto
    one core. Find the core under load with `grep rx-comp /proc/interrupts`. It was cpu2 here, so the mask was
    `b` (cores 0, 1, 3). The queue is picked by hashing, so re-check after a reboot.
- **UCG Fiber:** nothing to tune. Qualcomm's ECM/SFE fast path picks up UniFi's tunnel; `tools/fastpath.sh` shows
  its counters and per-core load. Turning GRO off made it worse.
- **Any gateway: watch for QoS rules.** A QoS rule (here the "Critical Apps Prioritization" UniFi offers) sends all
  WAN ingress through a software shaper, HTB on an `ifb` device with a burst smaller than one packet, even with
  Smart Queues off and no rate set. On the 2.5 Gbps line it held downloads at ~1.6 Gb/s, off-peak included, which
  looks exactly like a line limit; disabling the rule gave 2.0–2.2 Gb/s at once. On the gateway,
  `tc qdisc show | grep -c htb` should print 0.
- `tools/speed.sh root@<gateway> [streams] [seconds]` (run on a LAN computer) downloads from Cloudflare while the
  gateway samples per-core load and interface rates.

## Commands

`native.sh check | ui | up | down | kick | status | guard-check | install | uninstall | run`

- `check`, `ui`, `status`, `guard-check` change nothing.
- `up` / `down` apply or remove the helper's pieces once; `install` / `uninstall` manage the service.
- `kick` makes UniFi recompute the tunnel now.

## Older firmware: the hand-built tunnel

Before 11.0.81 there is no IPIP type. The earlier scripts build the tunnel by hand and were proven on a UDM Pro with
UniFi OS 6.0.10 (2026-09-29). There the UniFi WAN is set to VLAN 836, DS-Lite (AFTR = Border Relay) and DHCPv6 with
PD 60, just to bring the VLAN and IPv6 up.

| Script | Changes |
|---|---|
| `selftest.sh up\|test\|status\|down` | its own tunnel `iltest0`: proves the line from the gateway, LAN untouched |
| `lan.sh up\|keep\|status\|down` | LAN IPv4 through `iltest0`; undoes itself after 10 min unless `keep` |
| `iliad-wan.sh install\|uninstall\|status` | permanent service: tunnel `iliad0`, its own routing table and chains, an inbound guard, ping failover to UniFi's other WAN |
| `udapi-plan.sh` | read-only preview of UniFi's `ipip_jpix` objects (written before the controller supported them) |

It works, but the UI shows that WAN red, the gateway's own traffic stays on the other WAN, and UniFi's traffic
rules are bypassed for traffic in the tunnel. Use the native path if your firmware has it.

## Things learnt on the way

- Iliad routes **only the delegated /60**. Traffic sourced from the WAN's own DHCPv6 /128 gets no reply.
- Iliad advertises an MTU of up to 1700 on the access link, so a WAN MTU of 1540 lets the tunnel carry full
  1500-byte packets; below that, TCP depends on MSS clamping.
- A hand-made Linux `ip6tnl` needs `encaplimit none`. Otherwise it adds a Destination Options header, which
  relays commonly drop.
- The F-MDONU05A's BOX side was reported as 1G-only before a February 2024 firmware update. Today it links at 10G
  with a 10G DAC.
- To find who or what changed a WAN setting, UniFi's admin activity log
  (`POST /proxy/network/v2/api/site/default/system-log/admin-activity`) lists old and new values in `updates[]`.
  That is how the iOS app wipe was found.
- UniFi's IPv6 policy routing does not work on this WAN: the default route learned from Iliad's router
  advertisements sits in the `main` table, which rule 32000 consults before any VPN rule, so IPv6 marked for a VPN
  client still leaves through Iliad. Piece 6 sidesteps it for domain routes. A whole-device VPN route on a LAN with
  public IPv6 would leak over IPv6 the same way.

## Background

Before 11.0.81, Ubiquiti support confirmed in writing (case 5924768, 2026-09-02) that neither custom MAP-E
parameters nor a static IPv4 on the DS-Lite tunnel were supported. The feature request, with Iliad's published
specification, is on the UniFi community:
[Generic MAP-E parameters — Iliad Italia, fully specified](https://community.ui.com/questions/FEATURE-REQUEST-Generic-MAP-E-parameters-the-code-already-ships-Iliad-Italia-fully-specified/b34bd953-1295-4459-98eb-056b45e03bf2).
If UniFi fixes gaps 1–3 (local address from the delegated prefix, an optional address update, and binding to the
VLAN interface), the helper's job reduces to the iOS-app guard and, with IPv6 on the LAN, pieces 5 and 6.

## Disclaimer

Unofficial, and not affiliated with or endorsed by Iliad or Ubiquiti. The scripts run as root on your gateway and
can take your internet connection down; read them before you run them, and keep a way back (the iliadbox, a
second WAN). Use at your own risk. MIT licence.
