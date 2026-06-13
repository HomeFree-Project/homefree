# Non-router mode — serving apps over TLS behind someone else's router

HomeFree can run with `homefree.network.router.enable = false` (the box is a
server on an existing LAN, not the gateway). Most of the public-serving stack is
router-independent, but a few pieces assumed router mode. This note records what
works, the host-firewall that fills the gap, and how an operator sets it up.

## What was already router-independent

- **TLS — DNS-01, no inbound port 80.** Caddy runs in both modes and issues
  certs via the Hetzner DNS API (`services/caddy/default.nix`, option
  `homefree.dns.remote.cert-management.dns-01`). It only needs the box to reach
  the internet (valid gateway + resolver) and the domain on Hetzner DNS.
- **ddclient.** Runs regardless of mode; publishes the box's *egress* IP
  (`ipinfo.io/ip`) to Hetzner A/AAAA (`homefree.dns.remote.dynamic-dns`). Behind
  NAT the egress IP is the upstream router's WAN IP — exactly what a port-forward
  targets. Breaks only under CGNAT.
- **unbound split-horizon.** `services/unbound/default.nix` binds `lan-address`,
  allows `${lan-subnet}`, and maps the domain → `lan-address`; none of it
  router-gated. So a LAN client that uses the box as its resolver gets the LAN
  address for the domain (and reaches `public=false` apps) without NAT hairpin.

## The gap that was fixed: the host firewall

In router mode `profiles/router.nix` opens 80/443 + per-app public ports and
declares the `abusive_nets*` / `f2b_banned*` nftables sets — all inside the
router-gated `networking = … {}` block. In non-router mode that block is empty,
so a real box (confirmed by eval) had THREE problems:

1. **Rebuild bricked** — `modules/abuse-blocking.nix` asserts
   `networking.nftables.enable = true`, which only the router branch sets.
2. **80/443 closed** — the NixOS default firewall opened only `[22, 2022]`
   (`profiles/common.nix`), so a forwarded 443 was dropped.
3. **fail2ban dangling** — its jails ban into sets that didn't exist.

Fix: `profiles/router.nix` now wraps `networking` in `lib.mkMerge` and adds a
non-router branch (`lib.mkIf (!router.enable)`) that sets `firewall.enable =
false` + a `nonRouterFirewallRuleset`. That ruleset is a **trimmed sibling of the
router ruleset — input chain only, no forward chain, no NAT**:

- declares the same `abusive_nets4/6` + `f2b_banned4/6` sets in `table inet
  filter`, so `modules/abuse-blocking.nix` is **unchanged** (assertion passes,
  jails have live targets);
- opens `tcp dport { http, https }` + `${service-input-rules}` (per-app public
  ports) to any source — the upstream router forwards them in;
- trusts the LAN by **source subnet** (`ip saddr ${lan-subnet}`) — not by
  `iifname`, because forwarded internet traffic arrives on the same NIC as LAN
  traffic — plus `tailscale0`/`wt0`/`podman*`;
- opens SSH + Eternal Terminal (`22, 2022`) from any source so a wrong/blank
  `lan-subnet` can't lock the operator out (rule 10) — only LAN-reachable unless
  the upstream router forwards those ports;
- allows DHCPv4/DHCPv6 client responses (a non-static box gets its address via
  the upstream router's DHCP, and the offer/ack isn't reliably `established`);
- drops `@abusive_nets*` / `@f2b_banned*` first.

The set declarations + ICMP lines are re-stated (not shared) because the router
and non-router rulesets live in mutually-exclusive `mkMerge` branches; the
helper let-bindings (`service-input-rules`, the abuse-CIDR strings) ARE reused.
A future cleanup could factor the shared helpers into `profiles/lib/`.

## What's still operator-side: LAN name resolution

In non-router mode the box no longer runs the LAN DHCP server (dnsmasq is gated
to router mode), so it doesn't *advertise* itself as the LAN resolver. Two ways
LAN clients reach apps by name:

- **Point LAN DNS at the box** (best): set the upstream router's DHCP "DNS
  server" to the box's IP. unbound's split-horizon then hands LAN clients the LAN
  IP for the domain — fast, and `public=false` apps work on the LAN.
- **NAT hairpin** (simplest): do nothing; LAN clients resolve the public IP and
  loop back through the router. Works on most routers; covers `public` apps only.

## Operator setup walkthrough (Spectrum / any home router)

1. **Network page:** Router Mode **off**; turn on **Static IP** and set
   Interface, IP Address (the box's fixed LAN IP), Subnet (the real LAN CIDR),
   Gateway (the router), DNS Servers. Add a DHCP reservation for that IP on the
   router. (Or leave static off and use a reservation — but a static IP is
   recommended so `lan-address` matches the box.)
2. **Domain on Hetzner DNS**, and set the **DNS-01 API token**
   (`dns.remote.cert-management.dns-01`) → real TLS, no port 80 needed.
3. **dynamic-dns** (`dns.remote.dynamic-dns`, Hetzner) → keeps the public A/AAAA
   on the WAN IP. Optional if the WAN IP is static.
4. **Upstream router:** forward TCP **80 + 443** (and any per-app public ports)
   to the box, or DMZ it.
5. **Mark the apps to expose `public = true`.** Private apps stay LAN-only.
6. **LAN access:** point the router's DHCP DNS at the box, or rely on hairpin
   (see above).

Caveat: **CGNAT** breaks inbound entirely (the published IP isn't reachable).
Spectrum residential is normally a real public IP; confirm the WAN IP isn't in
`100.64.0.0/10`.
