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

8. **All web assets must be vendored locally.** Every font, JS/CSS
   library, icon set, and other asset used by any web page
   (`web-platform/`, `services/landing-page/`, etc.) must be served
   from this repo — never loaded from a CDN, Google Fonts, or any
   third-party URL. HomeFree boxes must render fully offline and leak
   no requests to outside hosts. The repo already vendors Lit
   (`web-platform/frontend/src/vendor/`) and the Inter font
   (`src/assets/fonts/`); follow that pattern for anything new.

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
  services (a disabled app must set `service-config.enable` or it leaks
  a no-`ExecStart` stub unit that fails the rebuild); oneshot bootstrap
  units and `RemainAfterExit`; podman readiness vs. process readiness.
  → `docs/agent-notes/systemd-unit-patterns.md`
- **Blue/green deployment** — admin-api and oauth2-proxy run as two
  colour units; a flip activation script swaps them with zero downtime.
  Never `exit` in an activation script; snippets must precede flips.
  → `docs/agent-notes/blue-green-deployment.md`
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

When you discover a new non-obvious, repeatable gotcha, add a note
under `docs/agent-notes/` and link it here — keep the entry one line.
