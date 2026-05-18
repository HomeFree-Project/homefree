# AGENTS.md

Guidance for AI coding agents (and humans) working in this repository.
Keep this file short — it is meant to be read in full every session.
Detailed, situational knowledge lives in `docs/agent-notes/` and is
linked from the Gotchas section below.

## What this repository is

`homefree` is the **shared source** for the HomeFree self-hosting
platform — a NixOS distribution consumed as a flake input by many
separate deployments. It is *not* one machine's config.

- **Shared code** (this repo): `profiles/`, `services/`, `apps/`,
  `modules/`, `web-platform/`, `module.nix`, `configuration.nix`.
  Everything here ships to every HomeFree box.
- **Instance config** lives elsewhere — `/etc/nixos/` on an installed
  system (`configuration.nix`, `homefree-config.json`,
  `homefree-configuration.nix`, per-instance assets). Never put
  instance-specific files in this repo.

## Rules for changes

1. **Shared-repo fixes must be generic.** Never hardcode a single
   deployment's domain, hostname, IPs, MAC addresses, hardware
   VID:PIDs, or network assumptions into shared code. Find the
   class-level fix (kernel param, udev attribute class, a NixOS
   option, a config-driven value). If a fix is genuinely
   instance-specific, say so and point at the `/etc/nixos` override
   path — don't smuggle it into shared code.

2. **Stage every file that is part of the Nix config.** This repo is a
   Nix flake; path imports are materialized from git's *tracked* tree,
   so untracked files are silently excluded and the rebuild fails
   (`ModuleNotFoundError`, 404s on new frontend files). After creating
   *any* new file that the build evaluates or imports — `.nix` modules,
   `web-platform/` sources, assets referenced by a Nix path — `git add`
   it. Staging only; see rule 6 for committing.

3. **SSO-only — no local accounts.** Every HomeFree-deployed service
   authenticates exclusively via Zitadel SSO. No local
   registration/username-password surface anywhere, not even as a
   fallback. See `docs/agent-notes/sso-integration.md`.

4. **Verify the live system before blaming a missing rebuild.** When a
   change "doesn't work," check what is actually deployed first
   (`/etc/caddy/caddy_config`, `systemctl show`, the running
   container's env, the `/nix/store` path an `ExecStart` points at).
   The cause is usually an untracked file, a service that didn't
   restart, a code bug, or a stale browser cookie — not an un-run
   rebuild.

5. **Research a service's real config before wiring it.** For any new
   service integration, read the service's `--help`/source/docs and a
   known-working example FIRST. Capture exact env-var names, callback
   paths, CA-trust mechanism, and local-login disable knob before
   writing the `.nix` file. Don't iterate by guessing.

6. **Never commit or rebuild without being asked.** `git commit`,
   `nixos-rebuild`, and `scripts/build.sh` are run only when the
   maintainer explicitly asks for it in the current turn. Default to
   staging changes (`git add`) and stopping there; leave committing and
   building to the maintainer. Do not assume a prior "go ahead" carries
   into a later turn.

7. **No AI attribution in commits.** Do not add `Co-Authored-By: Claude`
   (or any similar AI/agent attribution) trailers or sign-offs to commit
   messages. Write the commit message as plain content with no
   tool-attribution footer.

## How services are structured

- Each app/infra module is one directory under `apps/` or `services/`,
  auto-discovered by `configuration.nix` (a `_` prefix disables one).
- A service declares options in **two** namespaces — `module.nix`
  declares `homefree.services.<name>` (the `homefree-config.json`
  binding target) and the app declares
  `homefree.service-options.<name>`; `module.nix` mirrors one into the
  other. An app that lives outside this repo (a custom flake) must
  declare both itself.
- `homefree.service-config` entries drive the reverse proxy, backups,
  the admin UI catalog, and SSO metadata.

## Gotchas

Situational knowledge — read the linked note when working in that area:

- **Caddy directive ordering** — `forward_auth`/`redir` must be
  top-level, never wrapped in `route`/`handle`, or the SSO gate runs
  after `handle` and is bypassed.
  → `docs/agent-notes/caddy-directive-ordering.md`
- **Container reverse-proxy auth** — a header-auth container app sees
  Caddy traffic sourced from the host's `lan-address`, not the podman
  subnet; source-IP whitelists must use the `lan-address`.
  → `docs/agent-notes/container-reverse-proxy-auth.md`
- **`dns-ready` ordering** — the DNS-readiness gate must re-arm when
  unbound/adguard restart, or container image pulls race a stale gate.
  → `docs/agent-notes/dns-ready-ordering.md`
- **systemd unit patterns** — restart policy applied to all catalog
  services; oneshot bootstrap units and `RemainAfterExit`; podman
  readiness vs. process readiness.
  → `docs/agent-notes/systemd-unit-patterns.md`

When you discover a new non-obvious, repeatable gotcha, add a note
under `docs/agent-notes/` and link it here — keep the entry one line.
