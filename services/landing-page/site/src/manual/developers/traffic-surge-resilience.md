---
title: "Traffic-surge resilience — Developers"
---

# Surviving a traffic surge

This page is the design rationale and operator's guide for how HomeFree stays up when its public landing page lands somewhere unexpectedly popular — Hacker News front page, a viral Reddit thread, a self-hosting newsletter, whatever. It applies to any HomeFree box exposing a public web surface, but the canonical case is project mode (`homefree.host`).

If you're just running HomeFree at home and nobody outside your family knows about it, you don't need anything on this page. The defaults are already on. This page exists so that when someone *does* need to tune, troubleshoot, or extend, the why is here in one place.

## What we're defending against

A HomeFree box is one machine on one residential or small-business uplink, fronting a static marketing landing page **and** the operator's own admin / SSO / services on the same Caddy listener, on the same public IP. A 5-figure-visitor surge from a HN/Reddit post can:

- Saturate a residential uplink (the typical 25–50 Mbps up is gone in a few hundred concurrent visitors).
- Exhaust Caddy worker capacity so admin requests get queued behind landing-page traffic.
- Trigger fail2ban on legitimate-but-bursty patterns (a HN comment with a wrong URL → 404 storm → real users banned).
- Take the operator's *own* admin UI offline at exactly the moment they need to react.

There's also the unsophisticated long tail — broken bots, scrapers, slowloris, opportunistic DoS — that behave like a small surge whenever they're pointed at you.

The design assumption is **shared code, generalized across deployments**: the box being hugged might be on 1 Gbps symmetric fiber, or it might be on 25 Mbps up cable. The mitigations stack from cheap and always-on to opt-in and operator-managed, so each operator chooses how far down the stack they need.

## The seven layers

Each layer stands alone; you can disable any one and the others still help. They compose from the **input side** (reduce requests reaching origin) to the **impact side** (cap what one overloaded subsystem can do to the rest).

### Layer 1 — Vendor every web asset locally

**Files:** `services/landing-page/site/src/layouts/base.html`, `…/layouts/manual.html`, `…/src/fonts/`, `…/src/manual/hardware-setup.md`

The single biggest unforced error in a self-hosted landing page is loading fonts, JS, or icons from a third-party CDN. Three reasons it matters under load:

1. **Resilience.** Every visitor's page first-paint depends on `fonts.googleapis.com` (or jsdelivr, unpkg, gravatar) being fast. If they're slow, blocked, or down, *every* visit is broken — and you can't fix it from your side.
2. **Privacy.** Every visit leaks the visitor's IP and Referer to the third party. That isn't a HomeFree-style tradeoff.
3. **Bandwidth math.** A vendored 350 KB font loaded with `Cache-Control: max-age=31536000, immutable` (Layer 2) gets browser-cached forever after first load. A CDN-fetched font… also gets cached, but you have no control over what the CDN does.

This is also AGENTS.md rule 8. **Before declaring a web surface "done," grep its templates for** `https?://`, `fonts.googleapis`, `fonts.gstatic`, `cdn.`, `jsdelivr`, `unpkg`, `cdnjs`, `gravatar`, **and friends, then load it in a browser with the network panel filtered to "3rd party" and confirm zero off-domain requests.**

For diagrams specifically: don't reach for a runtime renderer (Mermaid, PlantUML). Pre-render to inline SVG at write-time. The one diagram that currently lives in the manual (`hardware-setup.md`) is hand-authored inline SVG for exactly this reason.

### Layer 2 — Smart caching of hashed assets

**File:** `services/caddy/default.nix` (apex vhost), `services/landing-page/site/eleventy.config.js` (`assetVersion` filter)

The Eleventy build emits asset references with a SHA1 content-hash query string — `/css/main.css?v=a1b2c3d4`. Because the hash changes whenever the bytes change, the URL is a permanent identifier for that exact content: a stale browser cache can never serve the wrong thing, by construction.

Caddy applies this policy on the apex landing site (and `manual.<domain>`):

- **`?v=*` URLs:** `Cache-Control: public, max-age=31536000, immutable`. Browser and any intermediate cache keep it forever.
- **Everything else (HTML, unhashed paths):** `Cache-Control: no-store`. Always-fresh, always-revalidated.

The reason for the asymmetry is the past `/nix/store` epoch-mtime trap. Nix normalizes every file's mtime to the Unix epoch across rebuilds, so a naive `Cache-Control` strategy would have file_server returning `304 Not Modified` on a request for a *newly-deployed* file (the browser's cache mtime is newer than epoch, so its `If-Modified-Since` header makes Caddy say "you have the latest"). The result: stale JS served after a rebuild, with no in-browser fix short of DevTools "Disable cache."

The defence is layered: HTML stays `no-store` (with `ETag` / `Last-Modified` stripped and inbound `If-Modified-Since` / `If-None-Match` stripped before file_server sees them) so the epoch-mtime trap can never fire on the live HTML. Hashed assets get the long-cache headers added back via a later `header @hashed_assets …` directive that overrides the catch-all for matching requests; Caddy resolves multiple `header` directives in source order, so the later one wins for the matched query string.

The policy is opt-in per site via the `staticCachePolicy = "vendor-hashed"` option on `reverse-proxy` in `module.nix`. The default — for the admin app and any other `static-path` site — stays `"no-store"`.

### Layer 3 — Per-IP nftables connection cap

**File:** `profiles/router.nix`

The kernel-level cap: a single source IP cannot hold more than `homefree.network.perIpConnectionLimit` concurrent TCP connections to ports 80/443 on the WAN interface. Default 64; tunable.

The mechanism is nftables `ct count over N` keyed off a dynamic set (`conn_count_v4` / `conn_count_v6`). New connections from an IP that already has 64 open get dropped before the SYN is accepted. The set keys are per `/32` for IPv4 and per `/64` for IPv6 — IPv6 must be capped by prefix, not by full address, because SLAAC privacy addresses give a single client many addresses in its `/64`.

Why this matters even though we have fail2ban: fail2ban is *reactive* — it scrapes Caddy's access log, decides an IP is misbehaving, then writes a ban. By the time the ban lands, the abusive client has already done the damage. nftables here is *structural* — the cap is a hard ceiling, applied on every new connection. Slowloris, broken bots, a single misbehaving client opening thousands of sockets: caught at the firewall, never reaches Caddy.

Operators behind a heavy NAT (corporate egress, cellular CGN) may need to raise the limit; the option lives at `homefree.network.perIpConnectionLimit`, and `0` disables the cap entirely.

LAN / VLAN / tailscale / podman traffic is unrestricted — this only applies to WAN ingress.

### Layer 4 — Proactive Caddy rate limit

**Files:** `overlays/caddy-with-plugins.nix` (`caddy-ratelimit` plugin), `services/landing-page/default.nix` (`rateLimitConfig`)

Layer 3 caps sockets; Layer 4 caps **requests**. The two are not redundant because HTTP/2 multiplexes many requests over one connection: a well-behaved-looking client opening a single TCP connection can hammer Caddy with 50 streams in parallel and never trip the nftables conn count.

Caddy's `rate_limit` directive (from `mholt/caddy-ratelimit`, built into the HomeFree Caddy binary via the plugin overlay) implements a per-IP sliding-window cap. Defaults: **30 requests per 10 s** per source IP, applied only to landing-page HTML routes — `?v=*` hashed assets, `/downloads/*`, `/.well-known/*`, and `/manual` are exempt because they're either browser-cached, cheap, or have their own pipelines.

The 429 responses this directive emits are **deliberately not caught by the existing fail2ban jails.** The 404-storm and error-flood filters key on `"status":404` and `"status":5[0-9][0-9]"` respectively, both narrow enough to ignore 429 by construction. Don't loosen those regexes to a status-class match without revisiting this — a legitimate HN surge tripping the rate-limit must not result in everyone reading HN getting banned at the firewall.

Tunable knobs:

- `homefree.services.landing-page.rateLimit.enable` (default `true`)
- `homefree.services.landing-page.rateLimit.events` (default `30`)
- `homefree.services.landing-page.rateLimit.window` (default `"10s"`)

Adding or removing the `caddy-ratelimit` plugin from `overlays/caddy-with-plugins.nix` changes Caddy's `vendorHash`. The next `nixos-rebuild` will print a "hash mismatch, got: sha256-XXXXX=" line — paste that value into the overlay and rebuild again. Standard Nix workflow.

### Layer 5 — Cgroup isolation for the Caddy unit

**Files:** `services/caddy/default.nix` (`serviceConfig` block), `module.nix` (`homefree.services.caddy.resources.*`)

Layers 1–4 reduce what reaches Caddy. Layer 5 caps what Caddy can do *to the rest of the system* when overload happens anyway. Defaults (tunable):

| Setting | Default | What it does |
|---|---|---|
| `MemoryHigh` | `512M` | Soft throttle — kernel reclaims aggressively above this, caddy keeps running but slows. |
| `MemoryMax` | `1G` | Hard cap — exceed and the kernel OOM-kills caddy (which restarts via the catalog `Restart=always` policy). |
| `CPUWeight` | `200` | 2× share of CPU under contention vs an unweighted service. Not a cap. |
| `TasksMax` | `4096` | Pid/task ceiling — bounds runaway goroutine / connection growth. |

This is **not** intended to make Caddy faster. It's intended to make sshd, admin-api, the monitoring stack, and the rest of the system stay responsive even when Caddy is being hammered. If caddy is being OOM-killed once per minute, that's a sign to raise `MemoryMax` (or look at why caddy is using that much memory). If admin requests are timing out during a surge, that's a sign the system needs the isolation to be doing more work, not less.

This is **not** intra-Caddy isolation — landing-page requests and admin-app requests share the same Caddy process, so a saturated Caddy worker pool can still affect admin latency. True intra-Caddy isolation (separate landing-only Caddy process behind the public one) is intentionally deferred: significant complexity for diminishing return once Layers 1–4 are doing their job. Reach for it only if you have evidence it's needed.

### Layer 6 — Tune fail2ban for surge tolerance

**File:** `modules/abuse-blocking.nix`

fail2ban is the long-tail defence — it catches the misbehaviour Layers 3 and 4 don't (cross-IP patterns, slow-roll scraping, repeat offenders). Three jails relevant to a public landing page:

- **`caddy-oauth-hammer`** — >20 hits/min on `/user/oauth2/*` from one IP. Triggered by the 2026-05-15 Forgejo incident (Go runtime crash under sustained OAuth callbacks). Not a landing-page concern, but in the same file.
- **`caddy-404-storm`** — >100 404s/min from one IP. Per-IP via the `<HOST>` macro, so a 50 000-visitor surge with a 1% typo rate (500 404s/min spread across distinct legitimate IPs) does *not* trigger it; only a single IP doing 100/min does.
- **`caddy-error-flood`** — >200 5xx-responses-to-same-IP per minute. Catches bots that keep retrying during a real outage and amplify load when the service is already on its knees.

The thresholds are set high enough on purpose: a HN surge of legitimate-looking traffic shouldn't trigger anything, only obviously-abusive single-IP patterns. The status-code matchers are narrow on purpose too — 429s from Layer 4 must not feed back into a ban (see Layer 4 for the rationale).

What you can do on the marketing site to reduce false-positive risk further: **add 301 redirects for likely-typo'd URLs.** If a HN comment writes `/docs` and you don't have that path, every reader of that comment hits a 404. Same for `/install`, `/api`, `/login` — add 301s in `services/landing-page/site/src/_redirects` or as Caddy `redir` directives pointing at the canonical URL.

### Layer 7 (opt-in) — CDN / edge fronting

**Files:** `module.nix` (`homefree.services.landing-page.edge.*`), `services/landing-page/default.nix` (`edgeFrontingConfig` — site-block pieces), `services/caddy/default.nix` (global `servers { trusted_proxies static … }` block — Caddy requires `trusted_proxies` at the per-listener level), `docs/agent-notes/landing-page-edge-fronting.md` (operator-side setup walkthrough)

For boxes on residential asymmetric uplinks (25–50 Mbps up cable / DSL), no amount of origin tuning will keep a HN front-page hit from saturating the pipe. The only real defence is to offload the bandwidth to an edge that has more of it.

This layer is **opt-in via `homefree-config.json`** and accepts the tradeoff explicitly. When enabled, the apex landing site:

- Sets `trusted_proxies` to the CDN provider's IP ranges so `{remote_host}` in Caddy logs reflects the *real* client IP (otherwise every fail2ban ban targets the CDN edge — useless).
- Rejects requests that didn't arrive through the edge (header-token check), so attackers can't bypass the CDN by hitting the origin IP directly. Without this check, Layer 7 is a security regression, not an improvement.
- Sets `Vary: Accept-Encoding` and `Vary: Cookie` so the edge doesn't accidentally serve a logged-in user's cached response to an anonymous visitor.

Operators on 1 Gbps symmetric fiber don't need this. Operators on cable do. There's no shame in turning it on; the marketing site is a different surface from the operator's own per-instance HomeFree box, and a third-party CDN for the project's public-facing marketing site doesn't compromise the box's own privacy.

Note that **personal HomeFree boxes — running in `personal-mode` — don't have a public marketing site to defend**, so Layer 7 simply doesn't apply. Their apex redirects everything to `home.<domain>` (the SSO gate), and the surge problem manifests differently (probably as an OAuth-hammer pattern, which Layer 6 already addresses).

## How the layers compose

Reading the layers as a request's lifetime:

```
HN reader's browser
  ├─ [Layer 7] CDN edge cache (if enabled)  ─── most hits stop here
  │
  v
nftables input chain
  ├─ [Layer 3] Per-IP connection cap        ─── abusers drop here
  │
  v
Caddy listener
  ├─ [Layer 5] Cgroup-bounded process       ─── damage stays inside cgroup
  │
  ├─ [Layer 4] Per-IP request rate limit    ─── 429 to flooders
  │
  ├─ [Layer 2] Cache-Control on response    ─── visitor caches assets locally
  │
  v
file_server  ─── serves the static asset
  │
  v
  └─ [Layer 1] Local asset (no off-domain fetch)

Async, log-driven:
  └─ [Layer 6] fail2ban → nftables ban set  ─── slow-roll offenders drop in Layer 3 next time
```

A real HN surge is mostly *legitimate* visitors. Layers 1, 2, and 5 carry most of the load — vendoring keeps the page renderable, caching keeps the bandwidth manageable, cgroups keep the rest of the system responsive. Layers 3, 4, and 6 handle the unsophisticated minority that crosses the threshold from "burst" to "abuse." Layer 7 is the bandwidth circuit-breaker for operators who don't have the pipe to absorb a real surge at the origin.

## Verification

When you change anything in this stack, the verification path:

1. **Layer 1.** `grep -rE 'https?://' services/landing-page/site/src/` (and `web-platform/frontend/src/`) — confirm zero matches outside `<a href>` navigation links and SVG `xmlns=` namespace identifiers. Then load every page in a browser with the network panel filtered to "3rd party" and confirm zero off-domain requests.
2. **Layer 2.** `curl -I https://<domain>/` shows `Cache-Control: no-store`; `curl -I 'https://<domain>/css/main.css?v=<hash>'` shows `Cache-Control: public, max-age=31536000, immutable`. Edit a CSS file, rebuild, reload — confirm the new content appears (new `?v=` hash) without manual cache clearing. *This is the regression check for the past `/nix/store` epoch-mtime fix.*
3. **Layer 3.** Open >64 concurrent connections from one client (`ab -c 80 -n 100 https://…`); confirm the cap engages without affecting a second client on a different IP. Verify with `nft list set inet filter conn_count_v4`.
4. **Layer 4.** Fire >30 requests in 10 s from one IP at `/`; expect 429s after the burst, expect a second IP to still get 200s. Confirm with `fail2ban-client status caddy-404-storm` that nobody got banned.
5. **Layer 5.** Under `systemd-cgtop`, watch `caddy.service` during a synthetic surge (`wrk` from a second host). Memory should plateau at `MemoryHigh`; sshd / admin-api stay responsive throughout.
6. **Layer 6.** Simulate 200 distinct-IP 404s in one minute; expect no bans of legitimate IPs.
7. **Layer 7** (if enabled). `curl -H 'Host: <domain>' https://<origin-IP>/` must be rejected (origin-bypass blocked). Real visits through the CDN must succeed, and `journalctl -u caddy` must show real client IPs, not the CDN edge.

## Things deliberately not done

- **No bot-detection / CAPTCHA.** Stays out of the request path. If you need it, that's a sign Layer 7 belongs in front.
- **No application-layer DoS protection** (e.g. WAF rules, JS-challenge pages). Adds runtime weight and surfaces; Layers 3 + 4 cover the cheap-to-catch cases and Layer 7 covers the bandwidth-saturation case.
- **No intra-Caddy isolation.** A separate landing-only Caddy process behind the public Caddy is a real option, but the complexity isn't justified by the data; revisit only if Layers 1–4 + 5 demonstrably leave admin starving.
- **No external uptime monitoring** required for this design to function. If you want it (Pingdom, Uptime Kuma, etc.), add it separately — but keep in mind the AGENTS.md no-external-resources rule applies to any web surface you build for monitoring too.

## Future work

- Bind the `perIpConnectionLimit`, `rateLimit.*`, and `resources.*` options into `homefree-config.json` via `modules/homefree-config-loader.nix` so they're tunable from the admin UI instead of `/etc/nixos/configuration.nix`.
- Add a Grafana panel to the existing monitoring stack that visualises the 429-rate from Layer 4, the nftables drop-counter from Layer 3, and the cgroup pressure metrics from Layer 5 — so operators can see a surge in progress.
- A `/admin` toggle to set Layer 7's `edge.enabled` and the operator-facing DNS / cert origin-pull instructions. Today it requires editing JSON.

If you do any of those, this page is also the right place to document the new knob — keep the seven-layer map current.
