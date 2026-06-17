---
title: "How HomeFree is built — Developers"
permalink: "/manual/developers/index.html"
---

# How HomeFree is built

This is the entry point for anyone hacking on HomeFree itself — adding new services, fixing bugs, customizing a deployment beyond the installer's options. If you're just running HomeFree on your own box, you don't need anything on this page.

## What HomeFree is, technically

HomeFree is a single **NixOS** configuration that wires together about twenty containerized services behind one reverse proxy, with one identity provider providing SSO across all of them. The whole system is declarative: the running machine is a build artifact of a Nix flake.

The headline pieces:

- **NixOS** — the base OS. Everything is configured in `*.nix` files. `nixos-rebuild switch` is how you change anything.
- **Podman** — runs each app as an isolated container. One container per app (FreshRSS, Immich, Nextcloud, etc.). State lives outside the container at `/var/lib/<app>-podman/`.
- **Caddy** — the single reverse proxy. Terminates TLS, fronts every app at its own subdomain (`freshrss.<domain>`, `immich.<domain>`, etc.), and gates web UIs behind the SSO check via `forward_auth`.
- **Zitadel** — the identity provider. Native OIDC. Apps integrate either through Caddy's SSO gate (web-only apps) or natively if they support OIDC themselves (FreshRSS, Nextcloud, etc.).
- **PostgreSQL** — the shared database backend. Each app gets its own role and database, owned by that role. No shared superuser TCP access.
- **Headscale** — the mesh VPN control plane (Tailscale-compatible).
- **Borg + S3** — automated encrypted backups of every app's data + database.

## Repo layout

`~/homefree` is the shared HomeFree source. It's used as-is across many boxes; instance-specific files (your domain, your hostname, your hardware-configuration.nix) live in `/etc/nixos` on each deployment, not in this repo.

- `configuration.nix` / `configuration.example.nix` — the entrypoint.
- `module.nix` — central options namespace (`homefree.*`).
- `profiles/` — host/role profile compositions.
- `services/` — one `*.nix` per integrated service. Each file declares its container, its Postgres role/db, its Caddy reverse-proxy entry, its Zitadel client, its backup paths.
- `scripts/` — operational scripts (build, sync-config, ISO publishing, etc.).
- `web-platform/` — the admin UI (FastAPI backend + JS frontend).

## SSO model

Every web UI on the box uses Zitadel. There are no local username/password forms anywhere — if you're adding a service, that's a hard requirement.

Two integration patterns:

- **Native OIDC** (preferred) — the app speaks OIDC directly. Configured with a Zitadel client and the app's own OIDC settings. Used by FreshRSS, Nextcloud, Immich, etc.
- **Caddy `forward_auth` gate** (fallback) — for apps that don't speak OIDC. Caddy challenges every request through `oauth2-proxy` before forwarding. The app sees an authenticated user via headers.

For APIs and DAV endpoints that can't do OIDC (mobile sync clients, CalDAV), apps use per-user API passwords or a `zitadel-password-shim` ROPC wrapper. See `services/radicale-podman.nix` and `services/zitadel-password-shim.nix` for the pattern.

## Where things live on disk

| Thing | Path |
|---|---|
| Per-app container state | `/var/lib/<app>-podman/` |
| Per-app secrets (provisioned PATs, OIDC creds) | `/var/lib/homefree-secrets/<app>/` |
| Admin metadata (admin username, etc.) | `/var/lib/homefree-admin/` |
| Backups (default) | Whatever `homefree.backups.to-path` resolves to |
| Caddy state, ACME data | `/var/lib/caddy/` |
| Rendered Caddy config | `/etc/caddy/caddy_config` |

## Next

- **[Advanced installation](/developers/advanced-installation/)** — build from source / deploy from a workstation Nix install.
- [Issue tracker](https://git.homefree.host/homefree/homefree/issues) — current bug list and incoming feature work.
- `#homefree:homefree.host` on Matrix for questions.
