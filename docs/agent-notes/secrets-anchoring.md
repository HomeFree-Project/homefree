# Anchoring auto-generated secrets into the encrypted store

## The problem

The only backed-up location for secrets is `/etc/nixos/secrets`
(encrypted with sops; rides along with the `/etc/nixos` backup). The
intended flow is: secret encrypted in `/etc/nixos/secrets/secrets.yaml`
→ decrypted to `/var/lib/homefree-secrets/<svc>/<key>` at boot → service
reads the runtime copy.

Several services violate this: a `*-prepare-secrets` (or equivalent)
unit *generates* a secret at first boot directly into
`/var/lib/homefree-secrets` — which is **not** backed up. On a restore
to fresh hardware the generator runs again and produces a **new** value.
For a secret that encrypts persistent data this is catastrophic: the
backed-up database can no longer be decrypted.

## The fix

`lib/secrets-anchor.nix` — a helper that wraps secret generation so each
secret is encrypted into `secrets.yaml` at the moment it is generated,
and on every subsequent boot is decrypted *back out* of `secrets.yaml`
(the anchored copy is authoritative). It also self-heals existing boxes:
a secret already on disk but not yet anchored is adopted into
`secrets.yaml` on the next rebuild — **no separate migration script
needed**, the next `nixos-rebuild` fixes the box.

`adoptExisting = false` for any secret whose on-disk file goes stale
after first use (it is then anchored only when freshly generated).

### Concurrency — secrets.yaml is a single shared file

`secrets.yaml` is one file; many `*-prepare-secrets` units run in
PARALLEL at boot. Every anchor op is a read-modify-write of the whole
file (`sops --set` rewrites it) and `sops` does no locking. Concurrent
writers WILL interleave and corrupt the file (observed: a duplicated /
truncated `sops:` metadata trailer — `sops --decrypt` then fails for
EVERY key in the file). The helper serialises each check-and-anchor
critical section under an exclusive `flock` on `secrets.yaml.anchor-lock`.
Never call `sops --set` on `secrets.yaml` outside that lock.

If the file is ever corrupted this way: the encrypted data lines are
usually intact and only the trailing `sops:` block is doubled — recover
by truncating to the end of the first complete `sops:` block and
verifying `sops --decrypt` succeeds. Runtime copies in
`/var/lib/homefree-secrets` are unaffected, so services keep running.

Reference implementation: `apps/zitadel/default.nix`
(`zitadel-prepare-secrets`) — done.

## Remediation status

All `*-prepare-secrets` / preStart-generated secrets are now anchored
via `lib/secrets-anchor.nix`. Tiers = blast radius if the secret is
regenerated on a restore.

### Tier 1 — data-loss (regeneration orphans/destroys persistent data)

- [x] **zitadel** — `masterkey`, `oauth2-cookie-secret`,
      `admin-password` (`admin-password` uses `adoptExisting=false`).
      Verified live.
- [x] **matrix** — `homeserver-signing-key` (was stored only in the
      un-backed-up container data dir; now anchored under secretsDir,
      `install`-ed into the container path each boot via `extraInstall`,
      with a migration seed from the legacy path so an existing key is
      adopted not regenerated), `registration-shared-secret`,
      `admin-account-password`
- [x] **forgejo** — `secret-key`, `internal-token`, `admin-password`
- [x] **snipe-it** — `app-key`, `mysql-password` (only when not
      user-supplied)
- [x] **mediawiki** — `mysql-password`, `wgSecretKey` (on-disk file is
      `wg-secret-key` — `fileName` override; `mkdirMode=null` since the
      tmpfiles-managed state dir owns its mode)

### Tier 2 — auth breakage (recoverable once the secret is fixed)

- [x] **netbird** — `turn-secret`, `turn-password`, `relay-secret`
      (runtime copies kept in `/var/lib/netbird` where management.json
      synthesis reads them; `mkdirMode=null`)
- [x] **headscale** — `headplane-cookie-secret` (`mkdirMode=null` — the
      dir is deliberately 0750 root:headscale, must not be clobbered)

### Tier 3 — cosmetic (re-login / dropped sessions, no data loss)

- [x] **adguard** — `admin-password` (the derived `admin-password.bcrypt`
      is re-derived via `extraInstall`, not anchored — random salt)
- [x] **freshrss** — `oidc-crypto-key`
- [x] **home-assistant** — `admin-password`
- [x] **immich** — `admin-password`
- [x] **linkwarden** — `nextauth-secret`
- [x] **nextcloud** — `admin-password`

## Open follow-ups (NOT yet anchored)

- **netbird `setup-key`** — minted by `netbird-mint-setup-key` via SQL
  surgery into netbird's sqlite store; the plaintext-on-disk is the
  recovery anchor. The generate→anchor→materialize model does not fit
  (the value must be inserted into the DB in the same step). Anchor by
  storing the plaintext after minting, or make minting re-derive on
  restore.
- **nextcloud `harp-pw.txt` / `harp-env.txt`** — AppApi proxy shared
  key, generated into the container data dir only. Lower stakes (proxy
  auth) but still un-anchored.
- **provision-generated OIDC credentials** — `zitadel-provision.service`
  writes `oidc-client-id` / `oidc-client-secret` (and NetBird's
  `mgmt-machine-token`) into `/var/lib/homefree-secrets/<svc>/` for ~13
  services. Different code path (`apps/zitadel/provision.nix`). They are
  *derived* from Zitadel state — either anchor them, or make
  provisioning idempotent enough to re-derive on restore.
