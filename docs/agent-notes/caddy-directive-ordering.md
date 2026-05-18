# Caddy directive ordering and SSO gates

Caddy applies a [hard-coded directive
order](https://caddyserver.com/docs/caddyfile/directives#directive-order),
not source order. `forward_auth` and `redir` are positioned **before**
`handle` / `handle_path` / `route`.

## The trap

Wrapping an auth gate in `route @match { forward_auth ... }` makes the
whole block run at the `route` slot — which is **after** `handle`. So a
`handle /api/*` block fires first, proxies the request to the backend
with no auth header, and the gate never runs. Worst case: the backend
is reached completely unauthenticated.

## What to do

- For request-time SSO gating, write `forward_auth @match http://... { … }`
  at the **top level** of the site block — never inside `route`/`handle`.
- For URL rewrites (e.g. redirecting a service's native login path to
  the SSO path), use top-level `redir @match … 302` — not
  `route @match { redir … }`.
- `route` is correct only when you deliberately want to override
  Caddy's ordering and run a *sequence* of directives in literal source
  order. It is wrong for a single auth/redirect directive that needs
  its own ordering slot.

## How to verify

`curl -I` a private path with **no cookie** (expect a 302 to the SSO
start URL) and again with a **stub cookie** (`_oauth2_proxy=anything`).
If the stub-cookie request reaches the backend with a 200 instead of a
302, the gate isn't actually gating.
