# Layer 7: opt-in CDN/edge fronting for the landing page

The on-box surge defences (Layers 1–6) handle a Hacker News / Reddit
hit on a box with reasonable uplink and CPU headroom. They cannot
help an operator on a 25–50 Mbps residential up-link — once the pipe
saturates, no amount of caching / rate-limiting / cgroup tuning at the
origin matters. Layer 7 puts a third-party CDN edge in front of the
public landing page so the bandwidth bill is paid by someone with
more pipe.

This is **opt-in**: every HomeFree box defaults to `enable = false`.
The relevant NixOS option block lives at
`homefree.services.landing-page.edge.*` in `module.nix`.

## Trade-off the operator is opting into

- A third-party (Cloudflare / bunny.net / other) terminates TLS at
  the edge and pulls from your origin on cache miss. They see every
  visitor's IP, User-Agent, referrer, and URL. For the project's
  own marketing site this is the maintainer's call to accept.
  Personal HomeFree boxes (running `personal-mode`) have no
  marketing site to defend and should leave this off.
- The edge can be slow / down / blocked in some geographies. You
  trade origin-saturation risk for edge-availability risk.
- The trusted-proxies CIDR list lives in the Caddy global config,
  so it applies to the whole Caddy listener — admin.\<domain\>,
  manual.\<domain\>, every other vhost. See "Side effects" below.

## What the option does

When `homefree.services.landing-page.edge.enable = true`, two pieces
of Caddy config get emitted:

1. **Global `servers { trusted_proxies static <CIDRs> }`** in the
   Caddy module. Defaults to Cloudflare's published edge ranges when
   `provider = "cloudflare"` (or bunny.net's when `"bunny"`). Trusts
   those CIDRs to set `X-Forwarded-For` / `X-Real-IP`, so
   `{remote_host}` in Caddy logs and fail2ban targets the real
   client, not the edge IP. (Without this, every fail2ban ban
   would land on a CDN IP — useless.)

2. **Apex landing site block** (`services/landing-page/default.nix`,
   `edgeFrontingConfig`):
   - Origin-bypass check: a named matcher rejects every request
     that doesn't carry the shared secret in the
     `X-Edge-Origin-Auth` header. The CDN injects it on every
     origin pull; a request without it must be hitting the
     origin IP directly, so we 403 it.
   - `Vary: Accept-Encoding, Cookie` for defence-in-depth on
     intermediate caches.

The option does NOT contact the CDN itself. CDN-side configuration
is the operator's responsibility — see below.

## Operator-side setup (out-of-band — the part this module can't do)

### Cloudflare

1. Create a Cloudflare account and add your domain (apex zone, e.g.
   `homefree.host`). Use the **Free** plan; nothing on the paid plans
   is required for this layer to function.
2. DNS:
   - `@` (apex): A record pointing to your origin IP, Proxy
     status **Proxied** (orange cloud).
   - `home`, `admin`, `manual`, every other subdomain that
     **should NOT** go through Cloudflare: Proxy status **DNS
     only** (grey cloud). These stay direct so SSO callbacks and
     admin traffic don't run through Cloudflare.
3. Cache: Caching → Configuration → Cache Reserve / Tiered Cache
   defaults are fine. Add a page rule:
   - URL: `<your-apex>/*`
   - Setting: **Cache Level: Cache Everything**
   - Setting: **Edge Cache TTL: 1 hour** (or `Respect Existing
     Headers` to honour Layer 2's `?v=*` Cache-Control)
4. Origin-bypass shared secret:
   - Generate one: `openssl rand -hex 32`
   - On the **origin** box, add to Caddy's EnvironmentFile:
     `EDGE_ORIGIN_SECRET=<paste>` (whatever variable name you set
     in `originSharedSecretEnv`).
   - On Cloudflare: Rules → Transform Rules → Modify Request
     Header. Create a rule that matches `Hostname equals
     <your-apex>` and sets request header
     `X-Edge-Origin-Auth: <same secret>`.
5. Rebuild the box. Verify:
   - `curl https://<your-apex>/` through the CDN succeeds (you'll
     see Cloudflare's response headers).
   - `curl -H 'Host: <your-apex>' https://<origin-IP>/` fails with
     403 (origin-bypass blocked).
   - `journalctl -u caddy` shows real client IPs on requests, not
     Cloudflare's edge IPs.

### bunny.net

The general shape is the same but the dashboards and header-rule UIs
differ:
- Pull Zone pointing at your origin IP.
- "Edge Rules" allows injecting custom request headers on
  origin pulls — use that for `X-Edge-Origin-Auth`.
- CDN.ip-list updates more often than Cloudflare's; check it
  every few months and update `trustedProxies` in NixOS.

### Custom provider

Set `provider = "custom"` and populate `trustedProxies` with your
provider's published edge CIDRs. Implement the origin-shared-secret
header injection at the CDN side however that provider exposes
request-header modification on origin pull.

## Side effects to be aware of

- **Per-listener trusted_proxies** applies to every vhost on the
  Caddy listener (`:443`). `admin.<domain>` ALSO trusts
  X-Forwarded-For from the CDN's IPs. In practice this is benign
  because admin isn't routed through Cloudflare and the SSO gate
  authenticates everything, but if you ever decide to put admin
  behind Cloudflare too you must audit the X-Forwarded-For trust
  chain through the OAuth callback flow first.
- **TLS termination at the edge** means the visitor's TLS session
  is with Cloudflare, not your box. Browser-side certificate
  pinning to your origin won't work.
- **Without `originSharedSecretEnv`**, the origin-bypass check is
  silently skipped — an attacker who learns the origin IP can hit
  it directly and bypass the CDN entirely, defeating Layer 7's
  whole purpose. Always set the secret in production.

## Future work

This option block currently has no `homefree-config.json` loader
binding — operators set it in `/etc/nixos/configuration.nix` directly.
When the Privacy admin page (separate planned work) lands, this
block will be one of the things it surfaces, at which point the
loader binding should be added to `modules/homefree-config-loader.nix`
so the admin UI can edit it.
