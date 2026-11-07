# iliad-unifi: rules for agents

Shell kit that runs an Iliad Italia "modem libero" FTTH line straight on a UniFi gateway: UniFi's own
*IPv4 Over IPv6 → IPIP → v6 Plus* WAN plus `native.sh`, a helper that fills the gaps (README, "What `native.sh`
adds"). Public, MIT. Users are Iliad customers with UniFi gear, mostly Italian. The scripts run as root on the
gateway in `/data/iliad`, and `native.sh run` runs there all the time as the `iliad-native` service: a mistake in
it takes someone's internet down.

## Never
- Never touch a real gateway or line from an agent session: no `ssh` to a gateway, no `push.sh`, no UniFi API
  call. Only the offline checks below. Whoever owns the gateway runs the rest by hand.
- Never commit real values: portal values (/60, tunnel local, Border Relay, IPv4), MACs, serials, API keys,
  host names, people's names. Make up examples from scratch in the documentation ranges (`2001:db8::/32`,
  `192.0.2.0/24`, `02:00:00:…` MACs). Never build one by swapping the start of a real value: the rest still
  leaks. Real configs live in `local/`, which is gitignored.
- Never push without a privacy pass on a fresh clone. Search the tree and `git log -p --all` for real
  addresses, including partial forms: single IPv6 hextets, an IPv4 written in hex inside an interface ID, MAC
  tails without separators. The history is public, so a leak means rewriting it.
- Never use process substitution (`<(…)`, `< <(…)`) in `native.sh`: bash 5.2 can wait on one forever (the
  comment above `quick_tunnel`). Capture into a variable, then `<<<"$out"`.
- Never make `check`, `ui`, `status` or `guard-check` write anything: the README promises they change nothing.
- Never add teardown on stop: a service stop or restart (= an update) must leave the address and override in
  place. Only `uninstall` removes them.
- Never change README.md without README.it.md (or the other way round) in the same commit: Italian is the
  users' language. Script output is English.

## Check your work
Run these from the repo root. There are no tests and no CI.
- `for f in *.sh tools/*.sh; do bash -n "$f" || echo "FAIL $f"; done`: prints nothing.
- `LC_ALL=C.UTF-8 shellcheck -x -S warning native.sh preflight.sh selftest.sh lan.sh iliad-wan.sh udapi-plan.sh push.sh tools/*.sh`:
  today it prints only SC2034 (`i` unused) in `tools/rps-bench.sh` and exits 1. Anything else is new. Without
  a UTF-8 locale shellcheck chokes on the `→` characters. Run `lib.sh` only through `-x`, never on its own.
- `ILIAD_CONF=iliad.conf.example ./native.sh ui`: prints the UniFi fields with Interface ID `::c000:22b:0`
  and tunnel local `2001:db8:1234:5670:0:c000:22b:0`, exit 0. It needs `python3` and no root.
- `grep -nE '^[^#]*<\(' native.sh`: should print nothing. Today it prints line 358 (`api()`), a known bug.
- Everything else (`preflight`, `check`, `status`, `up`, `install`, the guard) only runs on a real UniFi
  gateway. Say what you could not test.

## Traps
- hb46pp builds the tunnel local from the WAN's *first* global IPv6 and only retries when the address *list*
  changes. That is why `kick` adds a second address for 3 s instead of re-adding the same one.
- Interface ID must be the `::` form; the four-group form (`IID4`) crashes `ubnt_hb46pp_calc.py`.
- Every controller provision binds the tunnel back to the port (`eth9`) instead of the VLAN interface
  (`eth9.836`). `ensure_binding` and the 1 s checks in `nap` exist for that. Don't slow them down.
- Removing the override while hb46pp still runs makes it send the dummy login to the Japanese default
  server: that is what `down keep-override` is for.
- Use `iptables`/`ip6tables` with `-w` in anything the loop runs: a provision holds the xtables lock.
- The guard acts on one exact state only (VLAN on, `wan_type` dhcp, no Border Relay). Widening it fights
  changes the user made on purpose.
- `selftest.sh`, `lan.sh`, `iliad-wan.sh` and `udapi-plan.sh` are the hand-built path for firmware older than
  Network 11.0.81. Leave them out of `native.sh` changes.

## Words
Border Relay (BR): Iliad's tunnel end. IID: interface ID. hb46pp: `ubnt-hb46pp`, UniFi's IPv4-over-IPv6
daemon. udapi: the gateway's lower config layer (`ubios-udapi-client`). Provision: the controller re-applying
its config. v6 Plus / `ipip_jpix`: the Japanese fixed-IPv4 profile Iliad's line fits.

## Where to look
README.md / README.it.md (setup, the six gaps, rollback); the header of `native.sh`; `lib.sh` (`load_conf`,
`conf_facts`: config checks); `iliad.conf.example` (every setting).
