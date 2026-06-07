# LAN-only vhost breaks over IPv6 / off-box DNS

**TL;DR** A `public = false` service is reachable *only* when the client
resolves its name via the box's own resolver (unbound). A client that
resolves via any other resolver — cellular DNS, a VPN's DNS (Mullvad,
etc.), Android "Private DNS" (DoT), a public DoH resolver — gets the
**public AAAA** for the name and connects to the box's **WAN IPv6**,
where the LAN-bound vhost is not served. Caddy's catch-all then answers
with an empty **HTTP 200**, which silently breaks WebSocket/streaming
clients. The classic symptom is *"works until I kill and restart the
app, and breaks again after a network change."*

## Symptom

A long-lived client (WebSocket, SSE, chunked-JSON long-poll) to a
LAN-only HomeFree service intermittently stops receiving data and does
not recover on its own. Observed first with the **ntfy Android app**:

```
NtfyWsConnection: Opening https://ntfy.<domain>/<topic>/ws?since=… …
NtfyWsConnection: Connection failed (response code 200, message: OK):
                  Expected HTTP 101 response but was '200 OK'
java.net.ProtocolException: Expected HTTP 101 response but was '200 OK'
… Scheduling a restart in 120 seconds …   ← retries the SAME dead endpoint forever
```

It "works until restart" because the app's HTTP stack caches the
resolved address / connection and keeps retrying it; a fresh start
re-resolves and may land back on the box's resolver (→ the LAN IPv4),
which works. A phone **network change** (Wi-Fi ⇄ cellular ⇄ VPN) flips
which resolver answers, which is what triggers the break.

## Root cause

Two independently-correct facts combine into a hole:

1. **Caddy binds LAN-only vhosts to the LAN addresses only.** For a
   `service-config` entry with `reverse-proxy.public == false`,
   `services/caddy/default.nix` emits `bind <lan-address> <lan-address-v6>`
   — the LAN IPv4 and the inside ULA (e.g. `10.0.0.1` + `fd01::1`). It is
   **not** served on the box's WAN/public IPv6, so a client that reaches
   the box's *public* IPv6 misses it. (Before the IPv6 split-horizon fix
   this was IPv4-only — `bind <lan-address>` — which is the historical
   shape that first surfaced this bug.)

2. **Public DNS has a wildcard `AAAA` (and `A`) for the box's domain.**
   `*.<domain>` resolves to the box's WAN addresses publicly. unbound
   does split-horizon for LAN-only names — returning `A <lan-address>` and
   `AAAA <lan-address-v6>` (the box's inside ULA) so on-box-resolver
   clients reach the LAN over either family (`services/unbound/default.nix`,
   the `reverse-proxy.public == false` filters). **But that split-horizon
   only protects clients that actually query unbound.**

So a client that resolves `ntfy.<domain>` via a **non-box resolver** gets
the public `AAAA` (the box's WAN IPv6), opens TLS to `[<box-wan-ipv6>]:443`
with SNI `ntfy.<domain>`, and lands on Caddy's WAN IPv6 listener — where no
site matches that host (the ntfy site binds only the LAN IPv4 + LAN ULA).
Caddy's
default/catch-all answers `HTTP 200` with `Content-Length: 0`. For a
plain page that looks like an empty success; for a **WebSocket** it means
the `Upgrade` never happens (101 expected, 200 returned) and the client
errors out. (Caddy auto-upgrades WebSockets on the *correctly matched*
vhost, so the LAN vhost returns 101 fine with a bare `reverse_proxy`
block — `flush_interval`/streaming tuning is **not** the issue here.)

On the box that first hit this, the phone was simultaneously on Wi-Fi +
cellular + a Mullvad VPN with Android Private DNS on "opportunistic", so
its resolver for the name was effectively non-deterministic across
network changes.

## How to confirm (all read-only)

Compare resolution paths — local vs public:

```bash
dig +short A    ntfy.<domain> @127.0.0.1   # box/unbound → <lan-address>
dig +short AAAA ntfy.<domain> @127.0.0.1   # box/unbound → <lan-address-v6> (the ULA; was NODATA before the IPv6 split-horizon fix)
dig +short AAAA ntfy.<domain> @1.1.1.1     # public      → <box WAN IPv6>
```

Reproduce the exact failure with a WebSocket upgrade handshake against
each listener (101 = good, 200 = the bug):

```bash
WS='-H Connection:Upgrade -H Upgrade:websocket -H Sec-WebSocket-Version:13
    -H Sec-WebSocket-Key:dGhlIHNhbXBsZSBub25jZQ=='
curl -sk --http1.1 $WS -o /dev/null -w '%{http_code}\n' \
  --resolve ntfy.<domain>:443:<lan-address>           https://ntfy.<domain>/x/ws  # → 101
curl -sk --http1.1 $WS -o /dev/null -w '%{http_code}\n' \
  --resolve 'ntfy.<domain>:443:[<box-wan-ipv6>]'      https://ntfy.<domain>/x/ws  # → 200
```

On an Android client, the smoking gun is in `ss`/logcat: the app's
ESTABLISHED socket is to a **public IPv6** (not `<lan-address>`), and
logcat shows the `Expected HTTP 101 … was '200 OK'` loop above.

## Fix

- **Preferred for a service that should work off-Wi-Fi:** make it public
  (`homefree.services.<svc>.public = true`). Caddy then drops the
  `bind <lan-address>` and serves the vhost on all interfaces, so the
  public-AAAA path returns 101. This is what ntfy now does (exposed via
  the Alerts page toggle); access stays gated by its unguessable topic
  UUID. A LAN-only service is, by definition, unreachable off the LAN —
  if a client needs it everywhere, it must be public or reached over the
  mesh VPN.
- **If it must stay LAN-only:** the client has to use the box as its
  resolver (point Android Private DNS / the VPN's custom DNS at the box),
  or the off-box public AAAA will keep winning.

## Generic hardening

**(a) IPv6 split-horizon — DONE.** LAN-only vhosts now also `bind` the
box's inside ULA (`homefree.network.lan-address-v6`, default `fd01::1`)
and unbound returns that ULA as the `AAAA` for non-public names
(previously NODATA). So IPv6-preferring clients *on the box's resolver*
get a working LAN path instead of being forced back to IPv4. This does
**not** help off-box resolvers — those still get the public AAAA → the WAN
listener → an empty 200; that is why a service that must work off-Wi-Fi is
made `public`. See the `bind ${lan-address} ${lan-address-v6}` lines in
`services/caddy/default.nix` and the `nonPublicProxyFqdns` AAAA records in
`services/unbound/default.nix`.

**(b) Misleading catch-all 200 — still open.** Make the unmatched-host
catch-all reject/close upgrade requests instead of returning an empty 200,
so a misrouted client fails loudly instead of looping forever. Touches a
global Caddy default (health checks, HTTP→HTTPS redirects, ACME) — a
maintainer decision, not yet done.

## Key files

- `module.nix` — `homefree.network.lan-address-v6` option (default
  `fd01::1`); also assigned on the LAN interface in `profiles/router.nix`.
- `services/caddy/default.nix` — `bind ${lan-address} ${lan-address-v6}`
  for `reverse-proxy.public == false` (the LAN-only bind; proxied-domains
  has the equivalent).
- `services/unbound/default.nix` — the per-FQDN `static` local-zone plus
  the LAN `A` **and** `AAAA` local-data generated for `public == false`
  entries (`nonPublicProxyFqdns` / `nonPublicBaseDomains`).
- `services/ntfy/default.nix` — the `public` option and its
  `reverse-proxy.public = cfg.public` wiring (the first service this bit).
