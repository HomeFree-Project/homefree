# TODO

Instructions: Complete the next bullet in this file. Create a plan for that item
only. Once complete and confirmed, mark the item off with a strike-through or
check, then await further instructions.

Notes:
- The admin UI is now in `./web-platform`. The code at `./services/_deprecated/admin` is deprecated.
- To update flakes properly, don't use `nixos-rebuild` directly — use `./scripts/build.sh`.
- System config is at `/etc/nixos`.

## Critical

- **Eliminate the first-boot LUKS passphrase prompt (TPM2 enrollment timing).**
  HIGHEST PRIORITY. Today an encrypted install prompts for the disk passphrase
  **once on the first boot** of the installed system, then is unattended on every
  boot after. This is a consequence of *when* TPM2 enrollment happens, not a bug —
  but it's a rough edge for an unattended-server product and should be removed.

  Why the prompt exists today:
  - TPM2 auto-unlock works by sealing the LUKS key to the TPM, released only when
    boot measurements (we bind PCR 7 = Secure Boot state) match.
  - `systemd-cryptenroll` must run against the **real installed system's TPM and
    its final PCR values**. During installation we are in the installer ISO — its
    PCRs reflect the ISO's boot, not the installed system. Enrolling there (even
    via `nixos-enter`) would seal to the wrong measurements and never unlock.
  - So enrollment is deferred to `homefree-tpm2-enroll.service`, a oneshot that
    runs on first boot of the installed system. But the disk must already be
    unlocked for the initrd to reach the point where that service runs — and on
    boot 1 no TPM keyslot exists yet. Hence: boot 1 prompts for the passphrase,
    the service enrolls the TPM slot, boot 2+ is unattended.
  - We deliberately do NOT bake the keyfile into the initrd: the initrd lives on
    the unencrypted ESP, so a keyfile there is readable by anyone with the disk —
    that would defeat encryption.

  How other systems avoid any prompt (and the tradeoff each makes):
  - **Windows BitLocker** (TPM, default): never prompts — but the drive starts
    encrypted with a plaintext "clear key" on disk, TPM enrollment happens in the
    background, then the clear key is removed. There is a real window where the
    disk is not actually protected; Windows just hides it from the user.
  - **Ubuntu experimental TPM-FDE / systemd `bootctl` installs**: enroll the TPM
    *during installation* with no first-boot prompt — but only because they use
    **signed PCR policies** (`systemd-pcrlock` / signed `.pcrs`) so a seal made in
    the installer stays valid on the installed system. This needs a predictable /
    signed measured-boot chain.

  Options to fix (pick when revisiting):
  - **Option A — BitLocker model.** Keep the install-time keyfile in the initrd
    for the first boot only; boot unattended; the enroll service seals to the TPM;
    a follow-up removes the keyfile-in-initrd and rebuilds. Accepts a brief
    plaintext-key window (install → first successful TPM boot). Moderate change.
  - **Option B — signed PCR policy (Ubuntu/systemd model).** Enroll during install
    using a signed PCR policy so it stays valid on the installed system. The
    cleanest result (zero prompts, no plaintext window) but significantly more
    complex, and really only sound *with* a signed measured-boot chain — i.e. it
    wants lanzaboote/Secure Boot, which is currently an opt-in, not the default.

  Constraint from the original design decision: we chose TPM2-only (no lanzaboote)
  as the default, which rules out Option B's clean path unless Secure Boot becomes
  default too. So the realistic near-term choice is Option A (brief plaintext-key
  window) vs. keeping the single first-boot prompt (never exposes a plaintext
  key). For a server installed once by an admin who is physically present at first
  boot, the one-time prompt is arguably the safer default — but capture this so
  it's a deliberate, revisited decision rather than an accident.

  Relevant code: `ENCRYPTION_MODULE_TEMPLATE` /
  `homefree-tpm2-enroll.service` in `web-platform/backend/services/install.py`;
  `DiskoConfigBuilder` LUKS `passwordFile` handling in
  `web-platform/backend/services/disko_builder.py`.

- **Refactor — services in one place.** `web-platform/backend/services/install.py`
  still references mediawiki due to image paths (`install.py:281-312`). Make this
  generic so any service needing image-path conversion is handled uniformly.
- **Installer polish**
  - How does it look on small screens? Only `location-step.js` has a media query;
    most installer steps lack responsive CSS.
  - Location & Region:
    - "Advanced (optional)" should be expanded by default.
    - Does "UI Language" really need to be separate from "Language & Locale"?
    - If someone enters an address or lat/long, automatically fill in altitude
      (currently a manual "Look up from coords" button).
    - Going to the next step then back leaves fields empty.
  - Disk Partitioning:
    - Need advanced disk setup, e.g. RAID.
    - Need LUKS (`install.py` currently raises "LUKS encryption not yet implemented").
    - Need Lanzaboote or equivalent.
- **Missing from installer?**
  - Perhaps after first install, have steps at http://10.0.0.1 to finish setup.
    On reboot, tell the user to visit http://10.0.0.1 (also helps with hardware).
  - User SSH key.
  - Let's Encrypt setup DNS-01.
  - DDNS setup.
  - Command-line wizard that helps set this up as well.
- **Backups** — `/etc/nixos` and Postgres DBs are already backed up. Still missing:
  - Auto-provisioned secrets (`/var/lib/homefree-secrets`).
  - Zitadel users (explicit Zitadel/Postgres dump).

## Bugs

- Verify `https://*.homefree.lan` works (wildcard LAN domains).
- Does NetBird punch a hole through the firewall?
- Verify the admin-api restart-by-UI flow no longer drops the connection. It used
  to show "Lost connection to rebuild process" and never reconnect.
- Sometimes after disabling a service, the nixos-rebuild log says the service
  failed to start, which doesn't make sense. Debug and fix. Example after
  disabling baikal: `Failed to start podman-baikal.service: Unit
  podman-baikal.service has a bad unit file setting.`

## New features

- Migrations.
- Audit all services and the rest of the codebase for "hacky/fragile" code with
  a high maintenance burden.
- Audit everything that needs to change when the domain changes (Zitadel surgical
  DB change; any other apps?).
- Add image uploading.
- Update website.
- Per-system docs:
  - Create a visual diagram showing how things should eventually be connected.
  - Create a wizard walking people through physical setup.
  - et2251 Spectrum modem — already in bridge mode; only need to power-cycle
    after connecting to HomeFree.
  - eero 6 (not plus) wifi — connect/configure the eero through the app before
    changing anything; once everything is set up (eero connected to LAN side),
    switch the eero to bridge mode.
- Move any podman container that doesn't require root to non-root.
- Detect that nixcfg is dirty and show this in the admin UI.
  *(Note: a `/api/config/dirty` backend endpoint exists; surface it in the frontend.)*
- **Custom Flakes: restore app settings when a removed flake is re-added.**

  DONE (already implemented): removing a custom-flake app no longer breaks the
  build. `homefree-configuration.nix` used to do `homefree.services =
  jsonData.services`, so an orphaned `services.<name>` block left behind by a
  removed flake (whose option-declaring module is gone) aborted every rebuild
  with `error: The option 'homefree.services.<name>' does not exist`. It now
  filters `jsonData.services` to keys with a declared `homefree.services.<name>`
  option (`lib.filterAttrs ... options.homefree.services ? ${name}`), so an
  orphaned key is silently ignored. The orphaned settings stay inert in
  `homefree-config.json`. Applied in both `install.py`'s
  `HOMEFREE_CONFIG_TEMPLATE` and live `/etc/nixos/homefree-configuration.nix`.

  STILL TODO — *active* restore: because the orphaned `services.<name>` block is
  left in place (just not evaluated), re-adding the flake currently does NOT
  surface those old settings in the admin UI until... actually it should — the
  block is still in the JSON, so once the flake's module re-declares the option,
  the filter stops dropping it and the settings come back automatically. So the
  remove→re-add round-trip likely already preserves settings. **Verify this**:
  remove a custom flake, confirm `services.<name>` stays in `homefree-config.json`,
  re-add the flake, rebuild, and confirm the app comes back with its prior
  `enable`/options rather than defaults. If it works, this item is fully done and
  can be struck. If the admin UI or some save path strips the orphaned block in
  the meantime, then implement explicit orphan-and-restore in `DevelopersService`
  (it owns the `developers` section + flake lifecycle).

  (Earlier this item proposed a separate `developers.orphaned-settings` store and
  a `provides:[service-names]` field on flake entries to map flake→service. With
  the filter approach above, neither is needed — the orphaned block can simply
  remain in `services.<name>` harmlessly. Keep the `provides` idea on file only
  if a future need to *purge* orphaned settings arises.)
- HA: declarative pre-seeded config entries with `!secret` resolution
  - `homefree.service-options.home-assistant.configEntries = { hacs = { data = { token = "!secret hacs_github_token"; ... }; }; ... };`
  - preStart strict-overlay-merges entries into `.storage/core.config_entries`
    (keyed by domain+unique_id), resolving `!secret <key>` from
    `/var/lib/homefree-secrets/home-assistant/<key>`.
  - Unblocks declarative HACS (with user-generated GitHub PAT), and declarative
    Enphase Envoy, Synology DSM, OpenSprinkler, hp_ilo — any integration with
    static auth (not OAuth).
  - Path migration first: move HA secrets from `…/home-assistant/secrets/<key>`
    to `…/home-assistant/<key>` so they're discoverable by admin-web's existing
    secrets resolver (rest of HomeFree puts secrets directly under the service dir).
  - Then declare `secrets = { hacs_github_token = mkOption {...}; ilo_password = mkOption {...}; };`
    on the HA service-options — admin-web auto-generates the schema and renders
    input fields with descriptions in a "Secrets" section.
  - Optional polish: extend the secrets schema with `required-when = { path; equals; }`
    so the admin UI can show a yellow warning badge when a dependent toggle is on
    but the secret isn't set (currently the dependency only shows in the
    description text).
- Auto-sync per-service API passwords with the user's main password (declined for now)
  - Mechanism would parallel `services/zitadel-pam-bridge.nix`: a PAM hook
    captures the new authtok on `passwd`, then
    `podman exec freshrss php /var/www/FreshRSS/cli/update-user.php --user X --api-password $NEW`
    for each integrated app that exposes an API-password CLI.
  - Tradeoffs (why we are not doing this yet):
    - FreshRSS docs explicitly note the API password "may be used in less safe
      situations than the main password" — mobile apps cache it in plaintext on
      disk. Making it equal to the SSO password upgrades a single mobile-app
      theft to full SSO compromise.
    - The PAM hook only fires for the OS admin on local `passwd`. Password
      changes made through the Zitadel web UI (the documented SSO flow) would not
      propagate, so "sync" would be only half true and confusing.
    - Per-user generalization is even worse — every Zitadel user who never SSHes
      to the box has no `passwd` event to intercept.
  - Better future direction: derived-but-distinct credential (e.g.
    `HMAC(main_pw, per-machine secret)`) or admin-UI-surfaced random app
    passwords with user-driven rotation. Solve as part of a broader
    "app-password manager" workflow, not a one-off FreshRSS hook.

## Infrastructure

- Templatize the `flake.nix` installed by `install.py` and update
  `/scripts/build-image.sh` to substitute the current branch name appended to
  the homefree flake.
- Split `development-mode` into `development-mode` and `vm-mode`, which each have
  their own config includes in `/etc/nixos`.
- Scrub out all references to "erahhal" (~24 remain).
- Make sudo require a password unless in dev mode (`profiles/common.nix` currently
  grants unconditional NOPASSWD to the wheel group).
- **Patch Zitadel's database at the heart when critical config (domain,
  hostname, etc.) changes — never wipe Zitadel again.** On 2026-05-13 we migrated
  the external SSO domain from `sso.slacktopia.org` → `sso.homefree.host` by
  dropping Zitadel's Postgres DB and re-bootstrapping. Every OIDC-using
  downstream (Vaultwarden, Immich, CryptPad, Forgejo, …) holds user records
  pinned to the old Zitadel `sub` IDs, so the wipe cascaded into per-service SQL
  re-keying, a hung Vaultwarden postStart, lost CryptPad keypairs (per-user seed
  derived from `sub` at `data/data/sso_user/zitadel/<sub>.json`), and a swath of
  "heal" code that is itself fragile scar tissue. The right approach is SQL
  surgery on Zitadel directly: patch `instance_domains` /
  `projections.instance_domains`, regenerate the relevant rows in the `events`
  table that reference the old domain, update any cached `external_domain`
  reference, and leave all `sub` IDs intact. Build
  `scripts/zitadel-rename-domain.sh` that takes old/new domain args, stops the
  container, runs the SQL inside the Postgres pod, restarts Zitadel, and verifies
  discovery comes up on the new domain. Document the procedure in `docs/`. If SQL
  surgery proves genuinely intractable for a given field, the alternative is a
  transition path (dual-issue tokens with both old and new sub for a window, let
  downstreams re-link, retire old sub) — NOT a wipe. See
  `~/.claude/.../memory/feedback_never_wipe_zitadel.md` for the full incident
  write-up.
- **Zitadel→Forgejo (and other downstream services) role/group sync via Zitadel
  Actions.** Currently Forgejo SSO is identity-only — admin status comes from the
  OS-bootstrap `forgejo admin user create --admin` and is not driven by Zitadel
  role membership. Attempted but parked: we provisioned a Zitadel Action
  (`homefreeFlattenGroups`) intended to flatten the nested
  `urn:zitadel:iam:org:project:roles` claim into a flat `homefree.groups` array,
  bound to the Complement Token flow on triggers PRE_USERINFO (4) and
  PRE_ACCESS_TOKEN (5). The action runs and successfully writes `homefree.groups`
  into the **userinfo** response (verified via PAT). It does NOT appear in the
  **ID token** that Forgejo uses for OIDC login — Zitadel v4's CustomiseToken
  flow seems to scope the claim emission per trigger and there's no separate
  PRE_ID_TOKEN trigger. Also tried `idTokenUserinfoAssertion: false` to force
  Forgejo to call userinfo, but Forgejo's OIDC implementation in v15 reads the ID
  token only. Path forward when revisiting: either (a) find a Zitadel v4 trigger
  / per-app setting that makes Actions claims land in the ID token, (b) patch
  Forgejo to call userinfo on each login, or (c) drop the Action approach and use
  Zitadel's PreAuthentication External flow to issue a custom IDP that exposes
  flat groups natively. See `services/zitadel-provision.nix` section 4d (action
  provisioning, currently dormant — provisioned but no consumer) and the
  historical context in `services/forgejo-podman.nix` postStart.
- **Non-admin user OIDC re-key after Zitadel rotation.** Today the Vaultwarden
  and Immich postStart hooks only heal the admin user's
  `oauthId`/`sso_users.identifier` after a Zitadel DB wipe. Other human users
  will still hit "Existing SSO user with same email" / "User already exists, but
  is linked to another account" on first login post-rotation and require manual
  SQL to recover. Two options when revisiting: (a) extend the postStart hooks to
  iterate ALL local users, look up each one's current Zitadel sub by email, and
  rewrite the link — risky if two users ever share an email or if there are stale
  rows; (b) build a small admin-UI "Re-link my account" flow that runs after auth
  and asks Zitadel for the current sub. (a) is simpler but the footgun is real;
  (b) is the right design but more code.
- **CryptPad SSO keypair recovery after Zitadel rotation.** CryptPad derives the
  per-user encryption keypair from `(Zitadel sub → server-stored seed at
  /data/data/sso_user/zitadel/<sub>.json) + preferred_username`. When the sub
  changes, derivation produces a different keypair and the user lands in a fresh
  empty drive while their actual pads remain encrypted under the old keypair on
  disk. Today this requires either renaming the seed file
  (`mv sso_user/zitadel/OLD-SUB.json sso_user/zitadel/NEW-SUB.json`) or flipping
  `enforced: false` and logging in via the classic username/password form (which
  uses an entirely different derivation path). Path forward: postStart hook in
  `services/cryptpad-podman.nix` that detects orphan `sso_user` files (sub not
  present in current Zitadel) and offers a remediation path. Or simpler — accept
  that classic-login coexistence is the supported recovery story and document it.
- **Caddy `default-landing-page` artifact still showing up in the rendered
  config.** Search the rendered caddy_config for `default-landing-page`; if
  present it's wired from `services/landing-page/default.nix` even when the user
  has their own landing page. Confirm and clean up — the static path should
  always be `homefree-site` (or whatever the configured landing-page derivation is).

## Web Installer

- The web installer should detect if there is no internet and indicate to the
  user that the installation will not complete successfully without an internet
  connection.
- Add an advanced networking step that allows editing of the LAN IP range. This
  should be filled in with sensible defaults, which change when development mode
  is selected.

## Admin UI

- Update the Services page so that each item reflects the config options exposed
  by the services besides `enable` and `public`. For secrets, implement a secrets
  management module in the backend that saves them in `/etc/nixos/`. Use sops-nix
  with age, and use both the system key and the user key. If a user public key is
  not available (configured on the System page), disable secrets input and
  indicate to the user that a public key needs to be added first.
- For failed services, provide a button or clickable element that pops up a modal
  with the error (currently shown only as inline text).
- Make sure the files created for secrets (e.g. `.sops.nix` and anything else new
  in `/etc/nixos`) are stamped from templates by the installer for new installs.
- For the Status page, add system details, the same as those in the old admin UI
  at `services/_deprecated/admin/site/components/hf-system-status.js`.
- The system status on the Status page is too simple — it only takes into account
  the last build. Create a system health module that considers the last build
  status, whether any systemd services have failed, low disk space, lack of
  connectivity, and SMART status. Have it return a list of issues as warnings and
  errors plus an overall status: error if there is at least one error, warning if
  there are no errors and at least one warning, healthy otherwise. Display these
  on the Status page.
- The admin-api service is still often not restarting after a build if there have
  been changes to it. We've made changes to avoid the admin-api being restarted
  during the build (it interferes with access to the admin UI), but we still need
  to restart it when it has changed.

## Code

- Move to module-based dev.
- Try prompt: Make sure resulting code is documented, with tests, and highly
  encapsulated with clear well-defined interfaces. Build it so that an LLM with
  minimal context could come in later and make changes with minimal mistakes and
  guidance.
- Prompt: Best framework for automating e2e testing by LLM.

## Podman failures due to DNAT drift

Goal: detect silent DNAT drift over a multi-day window without manual checks. If
`netavark-nftables-reload.service` is doing its job, this monitor should report
green for the entire soak. If a stall recurs, the logs pinpoint which container
drifted and when.

Approach

A NixOS-declared systemd timer + oneshot service pair. Timer fires every 15
minutes (frequent enough to catch drift within an hour, infrequent enough to be
invisible in load). On each fire, the service:

1. Reads `/run/homefree/admin/config.json` (already populated by
   `service-config-json.nix`), pulls out every entry that has
   `reverse-proxy.enable = true` plus its host and port.
2. For each target, does a small TCP connect with a 5-second timeout —
   `nc -w 5 -z <host> <port>` or bash `/dev/tcp`. We're not testing HTTP, just
   whether the kernel forwards the SYN to the container. That's the exact symptom
   of DNAT drift.
3. Records the result as a single JSON-Lines record per target per run, written
   to `/var/log/homefree/port-forward-soak.jsonl`. Fields: `ts`, `label`, `host`,
   `port`, `ok` (bool), `latency_ms`, `error` (string if failed). Append-only, no
   rotation needed for a short soak; if it gets big, logrotate via
   `services.logrotate.settings`.
4. On any failure, also log a marker to journald with `logger -t
   port-forward-soak` so it shows up in `journalctl` alongside container logs for
   cross-correlation.

One subtlety — distinguish DNAT drift from "container is just down"

A bare TCP-connect fail can't tell DNAT-drift from a stopped container. To
disambiguate, before recording a failure, check whether the container is healthy:

- `systemctl is-active podman-<label>.service` returns `active` → container is
  up. Failure = DNAT drift (the bug we're hunting).
- Returns anything else → container is genuinely down, not a port-forward issue.
  Still log it, but with `error = "container_down"` so it filters cleanly.

For non-podman services (e.g., headscale via NixOS module), same logic against
the relevant unit name. The catalog's `systemd-service-names` gives the unit list
per service.

Inspection workflow during the soak

After 72 hours, one command:

```
jq -c 'select(.ok == false and .error != "container_down")' /var/log/homefree/port-forward-soak.jsonl
```

Zero lines = the fix works, close the ticket. Any lines = root cause hunt:
capture `nft list ruleset` / `podman network inspect` immediately while drift is
fresh.

Why declarative vs. an ad-hoc cron

The monitor itself shouldn't add new failure modes. A NixOS module with a
`systemd.timers.port-forward-soak` + `systemd.services.port-forward-soak-check`
is reproducible, stops cleanly when you remove the module, and follows the same
restart/dependency conventions as everything else on the box. ~80 lines of Nix,
no external dependencies (bash + jq + systemctl + coreutils).

Cleanup

Once Stage 5 is verified, either remove the module entirely (the simpler path —
soak is a one-time exercise) or keep it as a permanent low-cost watchdog with
output trimmed by logrotate. Recommend removal; if DNAT drift recurs months
later, the same module can be re-added from version control.
