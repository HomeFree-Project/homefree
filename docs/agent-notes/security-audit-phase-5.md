# Security audit — Phase 5

Phases 1–4 of focused hardening landed per-app DB credentials, scram
postgres auth, non-root containers where image-feasible, the sshd
fail2ban jail, MariaDB LAN-binding drop, the `--privileged` audit, and
the nextcloud AppAPI default-off gate. This Phase 5 audit looks at the
**residual** posture — host-level, system-level, web/SSO orchestration,
backups, and supply chain — to identify what those earlier phases
deliberately left out of scope.

Each finding below has a `Status:` field. Items still `pending` are
work to do; items marked `done in <module>` are landed (read the
linked file for the implementation + rationale).

## Post-Phase-2 follow-up — host postgres superuser password

A latent gap from the Phase 2 hardening surfaced when a coworker
rebuilt their box and Zitadel couldn't authenticate to host postgres
as the `postgres` superuser over TCP. Root cause: Phase 2 wave (b)'s
`pg_hba.conf` swap from `trust` → `scram-sha-256` turned a
sent-but-ignored hardcoded literal `ZITADEL_DATABASE_POSTGRES_ADMIN_PASSWORD
= "postgres"` into a sent-and-checked password — and the `postgres`
role's `rolpassword` was `NULL` on a fresh NixOS install (default).
The operator's deployment box (10.0.0.1) survived only by coincidence
because its `postgres` role had a non-null `rolpassword` set by some
old Zitadel-image bootstrap that happened to match the literal.

**Fix landed**: the `@TODO Phase 2` in `apps/zitadel/default.nix` is
closed. New oneshot `postgres-anchor-superuser-password.service` in
`services/postgres/default.nix` anchors a real random password and
runs `ALTER USER postgres WITH PASSWORD` via the local socket (still
trust). Zitadel's `zitadelPreStart` reads the anchored value into
its env file (replacing the literal). `podman-zitadel.service` is
ordered after the new oneshot so the value is guaranteed materialised
before Zitadel's init container tries to connect.

Pattern lesson: when introducing `trust` → password auth swaps,
**enumerate every TCP consumer by role, not just by username**, and
specifically verify TCP-as-superuser. The original Phase 2
verification only tested TCP-as-per-app-user; TCP-as-postgres was
the gap.

The companion implementation lives in shared modules under `profiles/`,
`services/`, `modules/`, `apps/`, `web-platform/`, `lib/` — so every
HomeFree instance picks the fixes up automatically on its next
`nixos-rebuild`. Per-instance choices (key-only SSH, sudo password,
etc.) are exposed as admin-UI options in `homefree-config.json`, not
baked into the shared code as a hard flip.

---

## HIGH severity

### H1. SSH `PasswordAuthentication` defaults on (option, default-on for operator convenience)
- **Where**: `profiles/common.nix` enables `services.openssh` with no
  overrides → NixOS defaults take effect (`PasswordAuthentication
  yes`, `KbdInteractiveAuthentication yes`).
- **Impact**: Brute-force surface against any OS user with shell
  access. Mitigated by (a) sshd reachable only on LAN (firewalled
  from WAN per `profiles/router.nix`), (b) the Phase 4 sshd fail2ban
  jail (5 fails/10 min → 1 h ban), (c) `PermitRootLogin
  prohibit-password` (default — root cannot brute-force at all).
  Residual: LAN-side attacker brute-forcing the admin user.
- **Treatment**: Expose a `homefree.system.ssh-key-only` option
  (default `false`). When `true`, set
  `services.openssh.settings.PasswordAuthentication = false` plus
  `KbdInteractiveAuthentication = false`. Admin-UI metadata entry
  with the security note: "Disables SSH password login. Confirm your
  SSH public key is already configured and works before enabling —
  otherwise you'll lose remote SSH access."
- **Migration**: zero (default preserves current behaviour).
- **Status**: done — option declared in `module.nix`, loaded from
  JSON in `modules/homefree-config-loader.nix`, gating in
  `profiles/common.nix`'s `services.openssh.settings`, admin-UI
  toggle in
  `web-platform/frontend/src/components/admin/modules/system-module.js`.

### H2. Wheel `NOPASSWD: ALL` (option, default-on for operator convenience)
- **Where**: `profiles/common.nix:120-125` — every wheel user can
  `sudo` any command without re-entering their password.
- **Impact**: Any process running as the wheel user can become root
  with no friction. Mitigated by the single-admin assumption typical
  of a HomeFree appliance.
- **Treatment**: Expose a `homefree.system.wheel-passwordless`
  option (default `true`). When `false`, drop the `NOPASSWD` rule
  so wheel members re-enter their password on `sudo`. Admin-UI
  metadata entry with the security note: "Requires re-entering your
  password on every sudo. Tighter security, but breaks unattended
  automation that relies on passwordless sudo."
- **Migration**: zero (default preserves current behaviour).
- **Status**: done — option declared in `module.nix`, loaded from
  JSON in `modules/homefree-config-loader.nix`, gating in
  `profiles/common.nix`'s `security.sudo.extraRules`, admin-UI
  toggle in
  `web-platform/frontend/src/components/admin/modules/system-module.js`.

### H3. Installer ISO leaves `root:root` + `nixos:nixos` plaintext SSH
- **Where**: `web-platform/installer.nix:367-374` — `PermitRootLogin
  yes`, `PasswordAuthentication true`, `users.users.root.password =
  "root"`, `users.users.nixos.password = "nixos"`. sshd listens on
  all interfaces.
- **Impact**: A networked installer ISO left running unattended, or
  booted on a hostile LAN, accepts SSH as root with the literal
  password `"root"`.
- **Fix**: Bind sshd to `127.0.0.1` on the installer ISO so the
  operator must `ssh -L` from the install console (or `[disable
  sshd entirely on the ISO]`).
- **Status**: done in `web-platform/installer.nix` — sshd now binds
  `127.0.0.1` + `::1` only. The weak default passwords stay (they
  are kept for the kiosk-mode console operator) but are no longer
  reachable from the LAN.

### H4. Installer ISO opens cockpit port 9090 to LAN
- **Where**: `web-platform/shared.nix:162-165` —
  `networking.firewall.allowedTCPPorts = [ 8000 9090 ]`. Verified
  `shared.nix` is imported only by `installer/default.nix`, so this
  is installer-only.
- **Impact**: Same window as H3 — fine attended, exposes cockpit
  (full system-management UI) on a hostile LAN during the install
  window.
- **Fix**: Pair with H3; bind cockpit to loopback on the ISO.
- **Status**: done in `web-platform/shared.nix` — port 9090 dropped
  from `networking.firewall.allowedTCPPorts`. Cockpit still listens
  inside the host but is unreachable from the LAN. Anyone needing
  the cockpit UI tunnels via `ssh -L 9090:127.0.0.1:9090` once
  they're already SSHed in (which H3 also gates to loopback).

---

## MEDIUM severity

### M1. `auditd` not enabled — no forensic trail for sensitive paths
- **Where**: `security.audit.enable` not set anywhere; verified
  `systemctl is-active auditd` returns `inactive`.
- **Impact**: No log of who/what modified `/etc/nixos`, `/etc/sudoers`,
  `/etc/ssh/`, `/var/lib/homefree-secrets/`.
- **Fix**: New `modules/auditd.nix` enabling `security.audit` with
  watch rules for those directories, journald sink.
- **Status**: done — `modules/auditd.nix` created and wired into
  `configuration.nix`'s imports. Watch rules for `/etc/nixos`,
  `/etc/sudoers`, `/etc/sudoers.d`, `/etc/ssh`,
  `/var/lib/homefree-secrets`, `/etc/nixos/secrets` with grep-friendly
  `hf-*` keys. Reads via `sudo ausearch -k <key>` or
  `journalctl _TRANSPORT=audit -g hf-`.

### M2. systemd hardening not uniformly applied
- **Where**: admin-web, headscale, alerts already set
  `NoNewPrivileges`, `ProtectHome`, `ProtectSystem=strict`. unbound,
  caddy, postgresql, podman-* units don't.
- **Impact**: A compromised service unit has more host access than
  needed — can write outside its data dir, read `/home/*`, mount
  privileged kernel interfaces.
- **Fix**: New `modules/systemd-hardening.nix` overlay applying a
  baseline (NoNewPrivileges, ProtectSystem=strict, ProtectHome,
  PrivateTmp, ProtectKernelTunables/Modules/Logs, ProtectControlGroups,
  RestrictNamespaces, RestrictRealtime, RestrictSUIDSGID) to every
  long-lived unit. Per-service exceptions (e.g., postgres needs
  writable `/var/lib/postgresql`).
- **Status**: pending.

### M3. No CSP / Permissions-Policy headers in Caddy
- **Where**: `services/caddy/default.nix` sets HSTS, X-Frame-Options,
  X-Content-Type-Options, Referrer-Policy — missing CSP and
  Permissions-Policy.
- **Fix**: Add baseline `Content-Security-Policy "default-src 'self';
  script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline';
  img-src 'self' data: blob:; font-src 'self' data:; connect-src
  'self'; frame-ancestors 'self'; base-uri 'self'; form-action 'self'"`
  and `Permissions-Policy "geolocation=(), microphone=(), camera=(),
  usb=(), payment=()"` to the global security-headers snippet, with
  per-vhost overrides where needed (Jellyfin camera, Nextcloud iframes).
- **Status**: done in `services/caddy/default.nix` — CSP +
  Permissions-Policy added to the global security-headers snippet
  (the `# Phase 5 M3` blocks, ~L765 and ~L945). CSP allows `'self'`
  + `https://*.<domain>` with a per-call `cspExtra` hook for hosts
  needing extra origins; Permissions-Policy locks
  geolocation/microphone/camera/usb/payment (+ `interest-cohort=()`).
  Per-vhost opt-out via the `disable-csp` reverse-proxy flag for hosts
  that need a looser policy.

### M4. No per-endpoint rate limiting on auth surfaces beyond fail2ban
- **Where**: `services/caddy/default.nix` registers caddy-ratelimit
  but has no per-path rules for `/oauth2/auth`, `/password`,
  `/api/v1/auth/*`, Zitadel login endpoints.
- **Impact**: Distributed brute-force from many IPs (botnet) is
  rate-limited only at the per-IP fail2ban layer; a 1000-IP botnet
  gets 5000 attempts before any ban hits.
- **Fix**: Add path-scoped rate limits keyed by `{client_ip}` for
  the auth paths (10 events / 1 minute starting point).
- **Status**: pending.

### M5. IPv6 ND-redirect accepted from WAN
- **Where**: `profiles/router.nix:362` — `icmpv6 type nd-redirect`
  accepted with no source-address constraint.
- **Fix**: Add `ip6 saddr fe80::/10 accept` qualifier (link-local
  only).
- **Status**: done in `profiles/router.nix` — the nd-redirect type
  was split out of the catch-all ICMPv6 allowlist and gated to
  `ip6 saddr fe80::/10` (link-local only).

### M6. `net.ipv4.conf.all.rp_filter = 0`
- **Where**: NixOS default + router profile. Verified live:
  `rp_filter = 0`. Loose-mode reverse-path filtering disabled.
- **Fix**: Set `boot.kernel.sysctl."net.ipv4.conf.all.rp_filter" = 2`
  (loose mode tolerates asymmetric routing but rejects obviously
  spoofed traffic).
- **Status**: done in `profiles/router.nix` — set both
  `net.ipv4.conf.all.rp_filter` and `net.ipv4.conf.default.rp_filter`
  to 2 (loose mode).

### M7. MediaWiki `$wgUpgradeKey` is a hardcoded string
- **Where**: `apps/mediawiki/default.nix:158` — same value
  (`"377f1af203cdd10b"`) in every HomeFree deployment.
- **Impact**: The upgrade key gates web-installer reactivation; with
  a public value, anyone who knows it can re-trigger install if
  conditions allow. Mostly latent (web installer is only reachable
  with LocalSettings.php absent — which it isn't post-setup).
- **Fix**: Anchor via `lib/secrets-anchor.nix`, substitute into the
  LocalSettings.php template alongside the existing `WG_SECRET_KEY`
  pattern.
- **Status**: done in `apps/mediawiki/default.nix` — new anchored
  `wgUpgradeKey` (32 hex chars per `openssl rand -hex 16`), template
  placeholder `{{WG_UPGRADE_KEY}}` substituted by the same `sed` that
  injects MYSQL_PASSWORD and WG_SECRET_KEY.

### M8. `services/_mongo/default.nix:35` has hardcoded `"password"` literal
- **Where**: Inert (the `_` prefix disables auto-discovery), but the
  string `MONGO_INITDB_ROOT_PASSWORD = "password"` lives in source.
- **Fix**: Delete the module file or migrate to `secrets-anchor`
  before any re-enable.
- **Status**: done in `services/_mongo/default.nix` — replaced the
  literal `"password"` with an empty string (mongo runs without
  auth in that state, fine for the inert disabled module) plus a
  `@TODO` comment instructing the re-enabler to anchor via
  `lib/secrets-anchor.nix` before flipping the `_` prefix.

### M9. `/var/lib/homefree-secrets/` directory mode not explicitly set
- **Where**: `setup-state.nix` / `finish-setup-console.nix` `mkdir
  -p` the dir without chmod, defaulting to umask (`755`).
- **Impact**: World-readable directory listing. Contained files are
  600 so secrets themselves are safe, but the directory structure
  + filenames are enumerable by any local user.
- **Fix**: `chmod 700 /var/lib/homefree-secrets` in the activation
  script that creates the dir.
- **Status**: done in `modules/setup-state.nix` —
  `chmod 711 /var/lib/homefree-secrets` (NOT 700; see below) added in
  the homefree-setup-state oneshot's script AND in a
  `system.activationScripts` entry that always runs on every rebuild
  (belt-and-suspenders for the oneshot+RemainAfterExit non-restart
  quirk). Per-service subdirectories under here are intentionally NOT
  touched — they have their own mode/owner requirements (e.g.,
  headscale's needs 0750 root:headscale, per
  `feedback_no_dir_perm_clobber.md`).

  **Why 0711, not 0700**: a first iteration used 0700 and broke the
  admin UI. The dir contains two sentinel files (`.setup-complete`,
  `.sso-provisioned`) that non-root code paths stat-by-name —
  Caddy's CEL `file()` matcher (`caddy` user) gates the @sso_gate
  expression on them, and `/etc/profile`'s SSH login banner does
  `[ -e ${completeSentinel} ]`. Mode 0700 made the dir untraversable
  by non-root → `file()` silently false → @sso_gate failed →
  forward_auth didn't fire → no `X-Auth-Request-User` reached
  admin-api → "Failed to load configuration: missing X-Auth-Request-
  User" all over the admin UI. Mode 0711 (drwx--x--x) lets any user
  stat-by-name (sentinels work) while still blocking `ls`
  enumeration — which is the actual attack we cared about. Per-secret
  files inside stay 0600 root:root, so this is a no-op on
  confidentiality.

---

## LOW severity

| ID  | One-line | Status |
|---|---|---|
| L1 | No explicit CSP on admin-api responses | done — subsumed by M3's global Caddy CSP header (now landed) |
| L2 | 36/37 image pins use mutable tags, not digests | deferred — big-bang change for a low-probability threat; do opportunistically when bumping critical apps |
| L3 | B2 backup credential scope not documented | done — inline doc comment in `services/backup/default.nix` describing recommended app-key scope (bucket-scoped, capability-restricted, optional Object Lock) |
| L4 | NFS mounts (if used) accept default AUTH_UNIX | done — inline doc note in `modules/mounts.nix` near the NFS branch about `sec=` mount option |
| L5 | `services/unbound/default.nix` no `auto-trust-anchor-file` | done — added `auto-trust-anchor-file = "/var/lib/unbound/root.key"` so unbound bootstraps + maintains the IANA root key for full DNSSEC validation |
| L6 | `profiles/virtualisation.nix:7-24` echoes docker auth in cleartext during activation | deferred — opportunistic cleanup |
| L7 | `headscale` ACL marked `@TODO` — all members can reach all subnet routes | deferred — needs upstream-headscale ACL syntax investigation, not a quick fix |
| L8 | `unbound` listens on the headscale tailnet — trust-model assumption | accepted — operator-intentional (tailnet is operator-trusted-only by design) |

---

## Not a finding — verified during audit

Listed here so a future reader doesn't re-investigate:

- **Kernel sysctls** `tcp_syncookies`, `dmesg_restrict`, `kptr_restrict`,
  `accept_redirects`: NixOS defaults set these correctly (verified on
  live box). Only `rp_filter` is worth changing (M6).
- **SSH ciphers/KEX/MAC**: NixOS upstream defaults are curated; no
  override needed.
- **Disk + swap encryption**: Already done (disko + system-disk-
  encryption + TPM2 unlock).
- **fail2ban + nftables coverage**: Already covers Caddy + sshd; bans
  drop in both input and forward chains.
- **Reverse-proxy SSO gate**: `forward_auth` at top level verified;
  no bypasses.
- **install.py plaintext password file**: Intentional design — file
  is the OS-user-chosen password handed to Zitadel for first-boot
  admin-user bootstrap. PAM bridge syncs onwards. "Shred immediately"
  was considered and rejected because Zitadel needs the value at
  first boot.
- **Nextcloud `allow_local_remote_servers = true`**: Intentional —
  Nextcloud's HTTP client must reach the internal Zitadel OIDC
  discovery endpoint. Mitigation: don't install untrusted Nextcloud
  apps.
- **AppAPI gate**: Done in Phase 4 — defaults off.
- **PAM bridge password handling**: Password goes via jq stdin to
  curl, not exposed in `ps`/logs.
- **admin-api dev-mode bypass**: Gated by `HOMEFREE_DEVELOPMENT=1`
  env var; verified `=0` on box.
- **OIDC redirect URI allowlists**: Strict per-app, no wildcards.
- **admin-api request-log credential redaction**: Comprehensive.

---

## Out of scope

- **Rootless podman**: shelved as its own major workstream.
- **`--userns=auto`**: also shelved (idmap-mount complexity).
- **Deep application-layer review** of admin-api / admin-web /
  install.py: agents did a surface pass; no obvious red flags but
  not exhaustive.
- **Cryptographic review** of `lib/secrets-anchor.nix`.
- **Zitadel upstream defaults**: HomeFree-specific provisioning is
  in scope (no gaps found); upstream Zitadel itself is not.

## How to land a fix

1. Pick a finding, look at the `Where:` and `Fix:` lines.
2. The fix lands in shared code under `profiles/`, `services/`,
   `modules/`, `apps/`, `web-platform/`, or `lib/`. Per
   `feedback_shared_repo_generic_fixes.md`: never in `/etc/nixos`.
3. Update the `Status:` line in this doc to `done in <file>` once
   the fix is committed.
4. For options exposed via admin UI (H1, H2), follow the pattern in
   `apps/nextcloud/default.nix` (the AppAPI gate from Phase 4):
   `lib.mkOption` in `userOptions` + entry in
   `homefree.service-config.options-metadata`.
