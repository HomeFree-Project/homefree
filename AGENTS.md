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
- **Instance state** lives elsewhere — `/etc/nixos/` on an installed
  system. ONLY these files belong there: `flake.nix` (wires the
  shared loader), `homefree-config.json` (per-instance config),
  `configuration.nix` (instance hardware/bootloader overrides),
  `disko.nix` (filesystem layout), `hardware-configuration.nix`,
  optional `custom-flakes.nix`, and the encrypted `secrets/` dir.
- **The boundary is bidirectional.** Never put instance-specific
  files in this repo, AND never put shared/generic code in
  `/etc/nixos`. See rule 12.

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

8. **All web assets must be vendored locally — ZERO external requests
   from any HomeFree-served page, ever.** Every font, JS/CSS library,
   icon set, image, analytics/telemetry beacon, and other asset used by
   any web page (`web-platform/`, `services/landing-page/`,
   `services/landing-page/site/src/manual/`, any new service that ships
   HTML, etc.) must be served from this repo. NEVER from a CDN, Google
   Fonts, jsdelivr/unpkg/cdnjs, Gravatar, a favicon service, an
   analytics pixel, a Sentry/error beacon, OR any other third-party
   URL — not even at runtime as a "convenience," not even behind a
   `<script async>`, not even if it's "industry standard." HomeFree
   boxes must render fully offline and leak no requests to outside
   hosts. The repo already vendors Lit
   (`web-platform/frontend/src/vendor/`) and the Inter font
   (`web-platform/frontend/src/assets/fonts/` + landing's
   `services/landing-page/site/src/fonts/`); follow that pattern for
   anything new.

   **Before** declaring any new web surface "done" — and **whenever**
   editing an HTML template — grep the templates and CSS for these
   patterns and confirm zero hits: `https?://`, `fonts.googleapis`,
   `fonts.gstatic`, `cdn.`, `jsdelivr`, `unpkg`, `cdnjs`, `gravatar`,
   `googletagmanager`, `google-analytics`, `sentry.io`. Then load the
   page in a real browser with the network panel filtered to
   "3rd-party" and confirm zero off-domain requests. A single
   third-party `<link>` slipped into a layout breaks the whole
   privacy + resilience promise — a single Google Fonts line in
   `services/landing-page/site/src/layouts/base.html` and a single
   jsdelivr Mermaid `<script>` in `manual.html` were in production
   for months before the audit caught them.

9. **Fix root causes, not symptoms — and ask before working around.**
   When something breaks, find the real cause and fix it there. Do
   not paper over a problem with negative margins, `!important`,
   per-page CSS resets, ad-hoc `try/except`, hard-coded fallbacks,
   skipped tests, or duplicate logic that just sidesteps the issue.
   If a proper fix would touch shared/global code and a localised
   workaround tempts you, STOP and ask the maintainer first —
   describe the root cause, the proposed real fix, the workaround
   alternative, and let them choose. A workaround applied without
   permission is a regression: it hides the underlying bug and
   accumulates as tech debt. Confirmation also applies to "small"
   hacks (a one-line override, a stub return, a hard-coded value to
   unblock a build) — ask first.

10. **NEVER ship a broken admin/home UI — it is the recovery surface.**
    The web UI is how the box is operated *and* repaired; if it
    white-screens, there is no in-product way back. Recovery then means
    SSH into the box and `nixos-rebuild` from the CLI — and on a real
    deployment that box may be remote, headless, or unreachable, so a
    broken UI can be a hard outage. Treat any UI regression as
    severity-1. Concretely:
    - A single missing/!untracked frontend module white-screens the
      *entire* SPA: the browser fetches the absent `.js`, gets an
      empty/404 body with MIME `""`, and blocks the ES module — every
      page dies, not just the new one. This is the most common way the
      UI breaks, and it is rule 2 (stage every new file) — verify the
      new file is **git-tracked in the tree the box actually builds
      from**, not merely present on disk. `git add` ≠ synced; a file
      rsynced to the box but unstaged in the box's flake repo is invisible
      to the Nix path import.
    - A frontend change is **not done** until it has been built and
      loaded the way the box serves it. The frontend is served as raw,
      unbundled ES modules (`environment.etc."homefree-installer/frontend"
      .source = ./frontend`), so a bad import is caught only at runtime in
      the browser — never assume "it parsed locally" means "it loads on
      the box."
    - If you have already caused a UI breakage, say so loudly and treat
      restoring the UI as the top priority over any other in-flight work.

11. **Never hand-migrate deployment data; changes are backwards-compatible
    or run an explicit on-activation migration.** This shared code runs on
    many live boxes, each with its own `/etc/nixos` instance state
    (`homefree-config.json`, `applied-config.json`, per-instance assets).
    Do NOT edit a box's instance files to fit a new format, and do NOT write
    one-off agent-run "backfill"/migration steps against deployed data. If
    you change a config/data format, either keep it **backwards-compatible**
    (tolerate old shapes with `or`-defaults, optional fields, fallbacks — as
    the JSON→Nix loader already does), OR add an **explicit, idempotent
    migration that runs on activation** (checked into the repo, applied by
    every box on rebuild). There is currently **no migration system**, so
    default to backwards-compatible changes; introducing a migration
    mechanism is a maintainer decision, not something to improvise.

12. **Generic code does not belong in `/etc/nixos`.** The instance tree
    is *state*, not *source* — anything that would also apply to a
    second HomeFree box belongs in this shared repo (`profiles/`,
    `services/`, `apps/`, `modules/`), behind a config-driven toggle
    if it should be opt-in. A `.nix` module dropped into `/etc/nixos`
    is invisible to every other deployment and rots there forever; the
    very existence of `homefree-configuration.nix` (now deprecated)
    happened because generated/shared logic was written into the
    instance tree, and a binding added later in shared code silently
    failed on every existing box. The temptation is real: dropping a
    file in `/etc/nixos` is faster than threading a new option through
    `module.nix` + the loader + a shared module. Don't take the
    shortcut. If you are tempted to write any `.nix` file under
    `/etc/nixos/` other than the seven listed in "What this repository
    is" above, STOP and ask. `configuration.nix` is the one ambiguous
    file — it legitimately holds instance hardware/bootloader overrides
    but is also the easiest place to accidentally drop generic logic;
    apply the same test (would this apply to another HomeFree box? →
    it does not belong there).

13. **New apps/services must not run as root unless absolutely
    necessary.** A new container or systemd service that defaults to
    running as root inside is a regression on the Phase 3 hardening
    work. Before adding one:

    - **Containers**: set `user = "<uid>:<gid>"` on the
      `virtualisation.oci-containers.containers.<name>` declaration,
      pointing at a dedicated `users.users.<name>` system user
      (HomeFree app range is 800–899; check
      `docs/agent-notes/security-audit-phase-5.md` and existing
      `apps/*/default.nix` files for already-claimed UIDs). Chown the
      bind-mounted data dir to that UID in the container's
      `preStart`, gated by a marker file so the recursive walk is
      one-shot. Same pattern as `apps/vaultwarden/default.nix`,
      `apps/webdav/default.nix`, `apps/homebox/default.nix`.

    - **LinuxServer (lscr.io/linuxserver/*) images**: use
      `PUID`/`PGID` env vars instead of `user=` — their s6-overlay
      init needs root, but renames the internal `abc` user to the
      PUID at runtime, so the app process runs as the dedicated
      UID. Pattern at `apps/grocy/default.nix`,
      `apps/jellyfin/default.nix`.

    - **Privileged ports (<1024) inside the container**: drop root +
      add `--cap-add=CAP_NET_BIND_SERVICE` to `extraOptions` rather
      than reaching for `--privileged`. If the upstream image lets
      you change the listen port via env (e.g., Rocket's
      `ROCKET_PORT`), do that instead — see
      `apps/vaultwarden/default.nix`. Apache/nginx-based PHP images
      typically need the `CAP_NET_BIND_SERVICE` route.

    - **`--privileged` is forbidden** unless the image genuinely
      needs raw device access AND no specific `--cap-add` +
      `--device=` combination achieves the same thing. Gate any
      remaining `--privileged` behind a per-service option default-
      `true` (so the operator can opt out per-deployment), the same
      way `apps/home-assistant/default.nix` does.

    - **If the image refuses non-root** (entrypoint runs `chown
      -R` over root-owned image files, or runs `su`, or writes
      `/etc/...`): document-skip with an inline comment explaining
      what was tried and why the image is incompatible, the way
      `apps/forgejo/default.nix`, `apps/baikal/default.nix`,
      `apps/freshrss/default.nix`, `apps/trilium/default.nix` do.
      Don't silently leave it as root.

    - **Systemd services on the host** (non-container): set an
      explicit `User = "..."` on `serviceConfig` and create the
      matching `users.users.<name>` system user. Default-root
      systemd units leak privileges that the service almost never
      actually needs.

    See `docs/agent-notes/security-audit-phase-5.md` for the full
    audit context and the catalog of which apps are non-root vs
    documented-skip.

## Version control

This repo uses **jj (jujutsu)**, colocated with git — prefer it for
branching and committing. For parallel or independent strands of work
(including multiple agents), use `jj workspace add` so concurrent edits
don't collide on a single working tree; jj's first-class conflicts make
later integration cleaner than git worktrees. Caveat: don't run jj on a
tree another agent is actively editing with plain git — its auto-snapshot
can capture half-finished edits. Rule 6 still applies: never commit
without being asked.

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
- A container app declares its workload via the **app-platform primitive**:
  one `homefree.containers.<container>` entry per container (the generator
  emits the user/group, chown, CA-bundle, oci-container, and dns-ready unit).
  → `docs/agent-notes/app-platform.md`
- An SSO-gated app declares its OIDC client via the **SSO registry**: a
  `homefree.sso.clients` push (consumed by `apps/zitadel/provision.nix`),
  not a hardcoded entry in provision.nix.
  → `docs/agent-notes/sso-client-registry.md`
- Behaviour-preserving changes to apps / Caddy are gated by the **snapshot
  test net** (`nix flake check`); during a refactor the goldens are FROZEN,
  but any INTENDED output change (version bump, container/preStart/Caddy/SSO
  edit, app add/remove) MUST regenerate its golden **in the same commit** —
  and `nixos-rebuild` does NOT run `nix flake check`, so a missed regen
  deploys fine and the net goes silently red. Run `nix flake check` before
  calling a snapshot-affecting change done.
  → `docs/agent-notes/snapshot-test-net.md`

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
- **Stale DNS after a rebuild** — switch restart bookkeeping is not a
  guarantee: a `failed (status 4)` switch (e.g. fwupd-refresh, now
  guarded) makes the retry skip DNS restarts, and even a successful
  switch's unbound restart has been observed silently ineffective; the
  `dns-conf-coherence` watchdog self-heals the drift, AdGuard's cache
  is a second stale layer.
  → `docs/agent-notes/failed-switch-skips-dns-restarts.md`
- **LAN-only vhost breaks over IPv6 / off-box DNS** — a `public = false`
  Caddy vhost binds only the box's LAN addresses (IPv4 + inside ULA via
  `lan-address-v6`), NOT the WAN IPv6; unbound's split-horizon hands
  on-box-resolver clients the LAN `A`+`AAAA`. But the domain's wildcard
  public AAAA points at the box WAN, so a client on a non-box resolver
  (cellular/VPN/Private-DNS) gets that AAAA, hits the box WAN IPv6 `:443`
  where the vhost isn't served, and a catch-all returns an empty `200` —
  silently breaking WebSocket/streaming clients (`Expected HTTP 101 … was
  '200 OK'`), classically "works until the app is restarted." Fix: make
  the service `public`, or keep it LAN-only and point the client's
  resolver at the box.
  → `docs/agent-notes/lan-only-vhost-ipv6-split-horizon.md`
- **systemd unit patterns** — restart policy applied to all catalog
  services (a disabled app must set `service-config.enable` or it leaks
  a no-`ExecStart` stub unit that fails the rebuild); oneshot bootstrap
  units and `RemainAfterExit`; podman readiness vs. process readiness.
  → `docs/agent-notes/systemd-unit-patterns.md`
- **Podman/netavark shutdown hang** — every podman container's pre-stop
  hook spawns a transient aardvark-dns scope, which systemd refuses
  once `reboot.target` is queued (destructive transaction). We wrap
  `reboot`/`poweroff`/`halt` to stop containers FIRST; `systemctl
  reboot`, `shutdown`, power button, IPMI bypass the wrapper.
  → `docs/agent-notes/podman-shutdown-hang.md`
- **Blue/green deployment** — admin-api and oauth2-proxy run as two
  colour units; a flip activation script swaps them with zero downtime.
  Never `exit` in an activation script; snippets must precede flips.
  → `docs/agent-notes/blue-green-deployment.md`
- **oauth2-proxy OIDC readiness gate** — the blue/green readiness gate
  must probe that Zitadel actually *serves* OIDC discovery (200), not
  just that the OIDC secrets exist; a secrets-only gate lets a colour
  start against a restarting Zitadel, which 502s discovery and crash-
  loops the colour into `start-limit-hit`, failing the rebuild.
  → `docs/agent-notes/oauth2-proxy-oidc-readiness-gate.md`
- **Secrets anchoring** — every auto-generated secret must be anchored
  into encrypted `/etc/nixos/secrets` (the only backed-up location) via
  `lib/secrets-anchor.nix`; generating straight into
  `/var/lib/homefree-secrets` loses the value on restore.
  → `docs/agent-notes/secrets-anchoring.md`
- **Flake-lock local-input refresh** — a dev box pins the `homefree`
  input to the local checkout; `nixos-rebuild` builds the *locked*
  snapshot, and `flake update <input>` will NOT re-hash a dirty tree.
  The lock node must be stripped and re-locked, or edits silently don't
  take effect. → `docs/agent-notes/flake-lock-local-input-refresh.md`
- **Local-flake `.git` ACL** — a root-run rebuild's git+file: fetcher
  writes inside the developer's source `.git` as root, eventually
  locking the owning user out of their own `objects/` subdirs and
  silently corrupting refs (commit object never lands; ref points at a
  ghost). Registering a local flake via the Developers UI applies an
  owner-rwX ACL so root's writes stay writable for the developer.
  Hand-edited local inputs bypass this and need the ACL applied
  manually. → `docs/agent-notes/local-flake-acl.md`
- **JSON→Nix mapping lives in a shared module** — `homefree-config.json`
  is the per-instance source of truth; the box's `flake.nix` reads it and
  the SHARED `modules/homefree-config-loader.nix` maps it into `homefree.*`
  (wired via `homefree.nixosModules.homefree-config-loader` + the
  `homefreeConfigJson`/`homefreeInstanceDir` specialArgs). There is NO
  generated `/etc/nixos/homefree-configuration.nix` anymore (the old
  `HOMEFREE_CONFIG_TEMPLATE` + `sync-template.py` model went stale on a
  bare `nixos-rebuild switch`). Add any new JSON→Nix binding to the loader
  module — never to install.py. Admin password hash lives in the JSON
  under `system.hashedPassword`.
  → `docs/agent-notes/homefree-configuration-nix-is-generated.md`
- **Lit tagged-template backticks** — ⚠️ **REPEAT AGENT FAILURE.**
  Agents in this repo have white-screened the SPA with this *at least
  five times*. The rule is: a backtick *anywhere* inside a `css\`...\``
  or `html\`...\`` template body — including inside `/* ... */`
  comments, prose explanations, and class/selector references — closes
  the tagged template, and everything after parses as JavaScript. The
  trap is the markdown-style "wrap an identifier in backticks for
  emphasis" reflex; the JS parser does not know what CSS is. **Use
  single quotes or plain words for emphasis in comments inside the
  template, never backticks.** After ANY edit to a file under
  `web-platform/frontend/src/components/` (or any other file with a
  Lit `css\`/`html\`` block), grep your own diff for a stray ` `` `
  inside the template body before declaring the edit done — *that
  scan is the rule, not a suggestion.* Fails as `SyntaxError`
  (parse-time, `node --check` catches it) or `TypeError: … is not a
  function` (runtime, parse looks clean and only blows up at module
  evaluation in the browser).
  → `docs/agent-notes/lit-tagged-template-backticks.md`
- **Admin table column sizing on mobile** — a `table-layout: fixed`
  table's `min-width` must include cell padding or the unsized column
  starves to 0px (headers overlap); and a `%`-width cell under
  `min-width: max-content` balloons the table to thousands of px wide.
  Use a length, never a `%`.
  → `docs/agent-notes/table-column-sizing-mobile.md`
- **UI consistency + mobile** — every layout/UI change must work at
  phone width (add a `@media` fold when the desktop layout doesn't
  collapse gracefully), and must reuse the established pattern (the
  canonical button/modal styles, `--hf-content-max` width cap, `--hf-*`
  design tokens, `actionIcon`/`navIcon`) instead of inventing a new
  one-off per task. A genuinely new pattern is a maintainer decision.
  → `docs/agent-notes/ui-consistency-and-mobile.md`
- **Config source-of-truth + undeployed-change indication** — disk
  (`homefree-config.json`) is the source of truth; Apply is *build-only against
  disk* (ignores its body); the UI flags anything differing from the deployed
  snapshot (`applied-config.json`) via a semantic diff. Adding a new editable
  section means updating `admin-app.getMergedConfig` (or edits silently vanish);
  External Proxies' enable/public live in their `service-config` entry, never
  `services.<label>`; per-row highlighting needs a `table-editor` `rowKey`.
  → `docs/agent-notes/undeployed-change-indication.md`
- **Storage volume encryption** — data pools LUKS-unlock LATE via `/etc/crypttab`
  (never initrd, per rule 10); ONE master passphrase across system+data lives at
  `/etc/nixos/secrets/recovery-passphrase.txt`, MUST be `rstrip("\n")` before
  use (slot is bound passphrase-semantics, file has trailing newline on old
  installs); mixed layout = per-disk LUKS for btrfs-native, LUKS-on-md for
  parity; reclaim MUST `cryptsetup close` before `mdadm --stop`; create has
  rollback (close+erase) on any raised exception — don't add `return _error()`
  in the encrypted path. → `docs/agent-notes/storage-encryption.md`
- **DLNA media server (minidlna)** — the Shared Folders page's per-folder
  `media` toggle is served by a HOST `services.minidlna` (NOT podman: SSDP
  multicast on 1900/udp can't cross the bridge), driven from
  `homefree.storage.shares`. LAN-only + unauthenticated; `openFirewall` off
  (reach via the nftables LAN-accept rule, never WAN). Shares 1900/udp with Home
  Assistant's SSDP integration (coexist via `SO_REUSEADDR` — verify, don't
  assume); Jellyfin stays a separate app, not a DLNA engine.
  → `docs/agent-notes/dlna-media-server.md`
- **Meilisearch data-migration on minor bumps** — `data.ms` carries a
  version marker; the engine refuses to start on a newer image until
  the operator dump/imports or rebuilds. Only `apps/linkwarden`
  uses it today, and Linkwarden's index is derived from its postgres,
  so the recovery is: stop, `mv data.ms data.ms.old-<old>`, start
  fresh, click Re-index in Linkwarden. Don't generalise to apps where
  meili is the source-of-truth. The `upgrade-apps.py` safety guard
  doesn't catch this — bumps look semver-clean.
  → `docs/agent-notes/meilisearch-data-migration.md`
- **Landing-page edge fronting (Layer 7, opt-in)** — `trusted_proxies`
  must live in Caddy's global `servers { }` block (per-listener, not
  per-site); shipped CIDRs for `cloudflare`/`bunny` need diffing against
  the upstream list periodically; without `originSharedSecretEnv` the
  origin-bypass check is silently skipped (CDN bypassable by IP).
  Operator-side CDN setup (DNS proxy, Transform Rule for the secret
  header, page rule) is out-of-band.
  → `docs/agent-notes/landing-page-edge-fronting.md`
- **NVMe temperature thresholds** — Composite carries spec-defined
  WCTEMP (`temp1_max`) and CCTEMP (`temp1_crit`); USE THEM as warn/err
  directly, don't subtract a CPU-style margin (CCTEMP-15 sits below the
  drive's own WCTEMP and false-positives). Auxiliary sensors (Sensor 1
  / Sensor 2) deliberately omit limits — skip them in the alert source,
  surface on the Hardware page only.
  → `docs/agent-notes/nvme-threshold-cascade.md`
- **Security audit — Phase 5** — Standing list of residual
  hardening findings beyond the per-app Phases 1–4 work, with
  severity, fix path, and a Status: field per item so the doc
  evolves as fixes land. Read this before starting any new
  hardening work to avoid duplicating effort.
  → `docs/agent-notes/security-audit-phase-5.md`
- **Deferred cleanup — developers→plugins rename** — Standing
  punch list of the back-compat surfaces (route aliases, JSON
  reader fallback, frontend export aliases, one-shot startup
  migration) tagged `TODO(homefree-next)` to delete once every
  deployed box has booted on the renamed code.
  → `docs/agent-notes/developers-to-plugins-rename-cleanup.md`
- **App-platform primitive** — `homefree.containers.<name>` registry +
  generator that emits the per-container skeleton (user/group, marker
  chown, CA-bundle, oci-container, dns-ready unit). How to add/migrate an
  app, the `runAs` modes (rootless/linuxserver/root + `createUser`), the
  escape hatch for bespoke postStart/ordering.
  → `docs/agent-notes/app-platform.md`
- **SSO client registry** — `homefree.sso.clients`: each SSO-gated app
  pushes its own OIDC descriptor; `apps/zitadel/provision.nix` consumes the
  deduped/sorted result instead of a hardcoded catalog.
  → `docs/agent-notes/sso-client-registry.md`
- **Snapshot test net** — the app-config / preStart / Caddyfile snapshots
  + the `frontend-eval` Lit module-eval gate: what each catches, the
  FROZEN-during-refactor vs regenerate-in-the-same-commit-for-intended-changes
  discipline, the SILENT-staleness trap (`nixos-rebuild` skips `nix flake
  check`, so a missed regen deploys fine and the net goes red invisibly), and
  how to regenerate a golden (incl. the live-VM `vm-state` socket gotcha that
  breaks impure golden regen).
  → `docs/agent-notes/snapshot-test-net.md`
- **Version-tracking strategies** — the App Versions page's per-app
  `version-tracking` descriptor: core owns a named-strategy catalog
  (default `image` = unchanged), apps override (github/docker/gitlab/
  forgejo/nixpkgs/url-regex/command/none). Gotchas: `channel`
  stable-vs-prerelease anchor reshape + the loose tuple compare for a
  declared `current-version`; `command` must be a `/nix/store` path;
  descriptors are keyed per-LABEL but rows per-CONTAINER (primary-container
  metadata alias); host apps come via `host-apps.json`; NO `release-tracking`
  shim (would regress nextcloud).
  → `docs/agent-notes/version-tracking-strategies.md`

When you discover a new non-obvious, repeatable gotcha, add a note
under `docs/agent-notes/` and link it here — keep the entry one line.
