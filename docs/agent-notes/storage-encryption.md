# Storage volume encryption (data-pool LUKS)

The Storage feature optionally LUKS-encrypts data volumes. The system disk
has its own encryption story (handled by the installer + disko +
`homefree-tpm2-enroll`); this note covers ONLY data pools and the
cross-cutting bits that aren't obvious from reading any single file.

## The master key

ONE master passphrase across the box: the LUKS **recovery passphrase**.

- File: `/etc/nixos/secrets/recovery-passphrase.txt` (chmod 600,
  in chmod 700 dir, backed up with /etc/nixos)
- Same value the user types at the boot prompt to unlock the system disk's
  recovery slot, and the same value every data-pool LUKS container is bound to.
- On installs with `use_encryption=true` the file is seeded by the installer
  (`install.py:_copy_secrets_to_target`).
- On installs without encryption the file is absent — the admin UI offers a
  "set up master key" wizard before the first encrypted pool can be created.

## Trailing-newline gotcha — the recurring class

cryptsetup binds a LUKS keyslot to the bytes the user TYPES at the boot
prompt, which `systemd-cryptsetup` reads with passphrase semantics (one line,
trailing newline stripped). The same value, when handed to cryptsetup via
`--key-file <path>` or `--unlock-key-file <path>`, is read with KEYFILE
semantics (raw bytes to EOF).

If the on-disk file has a trailing newline, the two views see different bytes
and the slot won't authorize. The slot was bound to "X"; the keyfile view
sees "X\n".

The on-disk file is now written WITHOUT a trailing newline (install.py's
`_copy_secrets_to_target`, encryption_master_key.py's `_write_passphrase`).
Pre-feature files have a newline; ALL runtime readers MUST `rstrip(b"\n")`
once — currently done in:

- `storage_pool.py::_materialize_master_passphrase` — strips before
  writing the per-job tempfile that's handed to cryptsetup.
- `encryption_master_key.py::_read_pp_bytes` — strips before any
  `is_configured()` / display check.

A new caller that reads the file MUST strip too. Test by: bind a slot via
stdin (passphrase semantics), then open with `--key-file` against the
file's raw bytes — exit 2 = the newline got included.

## Late-unlock — NEVER initrd for data

Data pools are excluded from the boot-critical path (AGENTS.md rule 10).
Their LUKS unlock goes through `/etc/crypttab` (emitted by
`modules/storage-pools.nix` via `environment.etc.crypttab`):

```
cryptd-<pool>-<i>  /dev/disk/by-id/<X>  none  tpm2-device=auto,tpm2-pcrs=7,nofail,x-systemd.device-timeout=15s,luks,discard
```

`systemd-cryptsetup-generator` builds one `systemd-cryptsetup@<mapper>.service`
per line; they run under `cryptsetup.target` (post-root, before
`local-fs.target`). `nofail` means a missing disk / failed TPM unlock is
non-fatal and boot continues to multi-user.target — the admin UI is always
reachable. **Do not move data-pool LUKS into `boot.initrd.luks.devices`** —
that would put TPM-binding mismatches at the initrd passphrase prompt and
break the recovery surface.

## Two layouts; one schema

Schema: `module.nix` → `homefree.storage.pools[*].luks-mappers` =
`listOf submodule { mapper, by-id, luks-uuid }`.

- **btrfs-native (single/raid0/raid1/raid10)**: per-disk LUKS. One mapper
  per member; btrfs spans the mapper devices. `by-id` is the disk by-id.
- **Parity (raid5/raid6)**: LUKS-on-md. mdadm assembles raw disks first,
  then ONE LUKS sits on `/dev/md`; btrfs runs on the single mapper.
  `by-id` of the single entry is `md-uuid-<X>` (the udev-created symlink
  to the assembled array).

Mapper naming: `cryptd-<pool>-<i>` for native, `cryptd-<pool>` for parity.
`module.nix` enforces the count match via `validation.py`
(`len(luks-mappers) == 1` for parity, `== len(members)` for native).

## Reclaim must close mappers FIRST

`storage_reclaim.py` walks `/sys/block/<dev>/holders/` to find any open
LUKS mapper sitting on a target disk or array (`_crypt_mappers_on`), and
closes them BEFORE `vgchange -an` / `mdadm --stop` / wipe. An open mapper
holds its backing device — without this step the array stop refuses with
"device in use" and the user is stuck.

## PCR 7 invalidation blast radius

Every per-pool TPM2 enrollment binds to PCR 7 (Secure Boot policy).
A single PCR-7 change (firmware update, Secure Boot key change, TPM clear)
invalidates EVERY TPM slot — system disk AND every data pool — simultaneously.
The recovery passphrase fallback always works; the admin types it once per
locked container at the boot prompt.

**This self-heals automatically — system disk AND data pools.** The
`homefree-tpm2-enroll` service (`services/system-disk-encryption`) is a
per-boot reconciler. For each TPM2-managed container it records the PCR-7
value it last enrolled against under `/var/lib/homefree/tpm2-pcr7.d/<dev>`
(per-device, not one global marker — so a pool that was detached when the
firmware changed still heals the next time it is present). When the current
PCR 7 differs from a container's recorded value, or the container is missing
its TPM2 slot, it wipes the stale slot and re-enrolls against the *current*
PCR 7, authorized by the recovery-passphrase file on the now-unlocked root.

Containers are discovered two ways: the system root/swap via disko's
`disk-d<N>-root|swap` partlabels, and every data pool via its `tpm2-pcrs`
line in `/etc/crypttab` (data-pool reconcile runs only when the recovery
passphrase is the authorizer, since pool slots are bound to it). Net effect:
a firmware update costs the admin at most ONE system-disk boot-passphrase
prompt; data-pool late-unlock may fail once (`nofail`, so boot continues and
the UI stays reachable), and by the next reboot every container is back to
unattended TPM2 unlock with no manual `systemd-cryptenroll`.

The UI warns when the user opts into encryption while Secure Boot enrollment
is still pending (`/var/lib/homefree/secureboot-status` reads
`setup-mode-unavailable`) — enroll SB first, or accept re-locking every
TPM slot when SB enrollment runs.

## Atomic rollback on create failure

`storage_pool.py::_run_create` tracks `opened_mappers` and `formatted_devs`.
On ANY exception (raised explicitly inside the try block), the except branch:

1. Reverses the mapper opens: `cryptsetup close <mapper>`.
2. Erases LUKS headers: `cryptsetup erase -q` + `wipefs -a`.
3. Shreds the `/run/hf-luks-*` master-passphrase tempfile in `finally`.

This guarantees that a failed create leaves the disks in a state a retry can
reuse — without rollback, the second `cryptsetup luksFormat` would fail
("device is mapped") or be silently confused by leftover LUKS2 secondary
headers at the disk tail.

If you ADD a new failure path inside `_run_create`, raise an exception
(don't `return _error()` after LUKS state was created — the rollback only
fires on exceptions).

## Rotation is deferred

The pool record stores only mapper IDENTITY (`mapper`/`by-id`/`luks-uuid`),
never the passphrase value. Rotation would be a per-pool `cryptsetup
luksChangeKey` loop + rewrite of `/etc/nixos/secrets/recovery-passphrase.txt`.
The master-key setup endpoints (`/api/storage/encryption/master-key/{generate,set}`)
deliberately REFUSE if a key is already configured — fail-loud, not
silently-overwrite.

## Master-key setup verifies against the system disk

For boxes installed with LUKS but BEFORE the master-key file existed (e.g.
`/etc/nixos/secrets/recovery-passphrase.txt` is missing because the install
predates this feature), the admin pastes the recovery passphrase they saved
at install. Two safety checks live in `encryption_master_key.py` so a typo
doesn't silently diverge:

- **`set_user_value` verifies the pasted value against an existing system
  LUKS slot** via `cryptsetup open --test-passphrase --key-file <tempfile>
  /dev/disk/by-partlabel/disk-d<N>-root` (disko's partlabel convention; try
  d1..d8 — `_find_system_luks_partition`). Exit 2 = no slot matches = reject
  the paste with a clear error. Exit 0 = save. Other non-zero or missing
  cryptsetup = log + fail-open (don't lock the admin out over a transient
  tooling glitch). Skipped on unencrypted-system boxes (no partlabel exists
  to test against — `system_is_encrypted()` returns False).
- **`generate` refuses on a system-encrypted box** (`system_is_encrypted()`
  is True). A freshly-generated random value would NOT match the system
  disk's LUKS slot, splitting "the unlock passphrase" silently into two
  values. The endpoint returns 409 with a message pointing the admin to
  the paste-in flow. The UI also reads `system_encrypted` from
  `get_status()` and defaults the setup modal to the Paste tab + disables
  the Generate tab on such boxes.

Both checks are non-destructive (`--test-passphrase` does not activate the
device; both run on a /run tempfile that's shredded after).

## In-place encryption is unsupported

The UI doesn't offer "encrypt this existing unencrypted volume." A LUKS
header has to go on the bare disk, which destroys whatever's on it; the
supported flow is back-up + Reclaim & erase + Create new (encrypted).
Importing an externally LUKS-encrypted volume is also out of scope —
`list_importable` doesn't detect LUKS signatures; the user must
`cryptsetup luksOpen` manually and then Attach the opened btrfs.
