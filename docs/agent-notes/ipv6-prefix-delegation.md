# IPv6 prefix delegation — the "advertises v6, no working path" trap

## Symptom

A client behind a HomeFree router gets a working **ULA** address
(`fd01::…`, can reach the router at `fd01::1`) but **100% packet loss to
the public v6 internet** (`ping6 2001:4860:4860::8888`). Browsers/fast.com
that try v6 first stall, then fall back to v4. Looks connected, isn't.

## Why it happens

The LAN always has a static ULA (`profiles/router.nix`: `lan-address-v6`,
default `fd01::1/64`), and dnsmasq's `constructor:<lan>` RA SLAAC-advertises
**whatever global prefixes exist on the LAN NIC**. So the ULA always works,
regardless of the WAN.

Global v6 only works if the WAN obtains a DHCPv6-PD prefix *and that prefix
lands on the LAN as a **preferred** address*. The failure we actually hit:
the ISP **delegates the prefix permanently deprecated** — `valid_lft` keeps
getting refreshed but `preferred_lft` is pinned at **0**. A deprecated
address still routes fine (verified: ping out sourced from it = 1.7 ms), but
hosts refuse to use it as a *source* for new connections, so every client
falls back to the ULA → no global v6.

Confirmed on AT&T fiber behind a **BGW210/BGW320 gateway in IP Passthrough**
(DHCP server-id `192.168.1.254`, `attlocal.net`, 10-min v4 lease — the BGW
stays the v6 router and can't be true-bridged). Repeated BGW power-cycles do
**not** durably fix it. Reported identically on Spectrum gateways. Diagnose
with `ip -6 addr show dev <lan>` (look for a global `2xxx::/64` with
`preferred_lft 0sec`) and a LAN-side `tcpdump -ni <lan> 'icmp6 && ip6[40]==134'`
(the prefix-info option shows `pref. time 0s`).

Key facts: IP Passthrough is **IPv4-only** — there is no IPv6 passthrough on
an AT&T BGW; it always delegates and stays the router. `preferred 0` is a
broken *lifetime*, not "don't route this."

## The fix — `ipv6-pd-anchor` (in `profiles/router.nix`)

A oneshot + 60s timer that pins a preferred `<delegated-prefix>::1` on any
delegated **global** `/64` that currently has **no** usable (non-deprecated)
address. dnsmasq then advertises the prefix with a real preferred lifetime
(it mirrors the now-preferred interface address), clients use it, traffic
flows. The anchor is permanent-while-needed but refreshed every 60s and
bounded (`LIFE`), so it self-expires if the service stops.

Designed to be **strictly no-op unless the bug is present** — it only
touches a prefix where every PD-derived address is deprecated:

- healthy v6 (ISP sends `preferred > 0`) → does nothing (and removes any
  stale anchor it left earlier)
- no PD / no v6 at all → nothing on the LAN to act on
- non-router instances → unit not even defined (`lib.mkIf`, not the file's
  usual `optionalAttrs`, to avoid an empty no-`ExecStart` stub unit)
- ISP later sends a sane lifetime, or the prefix rotates → the now-stale
  anchor is auto-removed next tick

Assumption: a `valid`-but-deprecated prefix is routable (RFC 4862 semantics;
proven on the AT&T line). A pathological ISP that marks a prefix `valid`
while black-holing it would have clients try it and fall back to v4 via
Happy Eyeballs — a timeout penalty, not a hard break, on a box whose v6 is
already broken.

## Not addressed here: "PD never arrives" (branch B)

This anchor only helps once a prefix **arrives** but is deprecated. The
separate, **unobserved** failure mode is the WAN never obtaining a PD at all.
The WAN is configured only via `networking.interfaces.<wan>.useDHCP = true`
(→ `DHCP=yes`, no explicit `[DHCPv6]`, relying on networkd's `:auto` uplink
for `DHCPPrefixDelegation`). On every box checked this *does* obtain the PD,
so we deliberately did **not** harden it: an explicit WAN `[DHCPv6]`
(`WithoutRA=solicit`, `UseDelegatedPrefix`, a hint) would change WAN
addressing on *every* instance, risking regressions on the many where it
works today. If a real box ever fails to get a PD, fix it then, targeted and
tested on that box — don't pre-emptively rewrite the WAN.

## Adjacent cleanup (not required for the fix)

The LAN currently has **two** RA senders — networkd `IPv6SendRA=yes` and
dnsmasq `enable-ra=true`. dnsmasq is the de-facto sender (router lifetime
7200 + RDNSS); networkd isn't effectively advertising. Worth consolidating
to one for hygiene, but it's orthogonal to this bug.
