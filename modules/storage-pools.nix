{ config, lib, pkgs, utils, ... }:

# Mounts the local btrfs data pools recorded in `homefree.storage.pools`
# (created imperatively by the Storage admin module; see
# web-platform/backend/services/storage_pool.py). This module is the
# DECLARATIVE half of "imperative-create once, declarative-manage forever":
# it never touches a disk, it only turns recorded pool identities into
# `fileSystems` entries (and, for encrypted pools, `/etc/crypttab` lines).
# With an empty pool list it is a complete no-op.
#
# Recovery-surface note (see AGENTS.md rule 10): a data pool is never part
# of the boot-critical path, so every mount is `nofail` with a bounded
# device-timeout, and every encrypted-pool LUKS container unlocks LATE via
# /etc/crypttab (post-root) — never in the initrd. A missing, unplugged,
# degraded, or unable-to-unlock pool must NEVER fail the boot transaction
# or block multi-user.target — that would take down the admin UI, which is
# the only in-product way to repair the box.

let
  # Only enabled pools reach fileSystems. A disabled pool keeps its row in
  # homefree-config.json (so the admin UI can re-enable it) but produces no
  # kernel mount. Mirrors the filter in modules/mounts.nix.
  pools = lib.filter (p: p.enabled or true) config.homefree.storage.pools;

  # Parity volumes (raid5/raid6) are btrfs-on-mdadm: Linux md assembles the
  # array, btrfs sits single-profile on the resulting /dev/md device. md's
  # assembly machinery (boot.swraid) auto-assembles the array by homehost, and
  # the mount keys on the btrfs fs-uuid like any other volume.
  mdPools = lib.filter
    (p: (p.profile or "") == "raid5" || (p.profile or "") == "raid6")
    pools;

  # Encrypted pools: every member is wrapped in a LUKS container. Two layouts:
  #   - btrfs-native (single/raid0/raid1/raid10): per-disk LUKS — btrfs spans
  #     the resulting /dev/mapper devices. luks-mappers has one entry per disk.
  #   - parity (raid5/raid6): LUKS-on-md — mdadm assembles the raw disks, then
  #     ONE LUKS sits on /dev/md. luks-mappers has a single entry whose by-id
  #     is the md-uuid-<X> symlink. Header is striped + parity-protected.
  # All unlock paths go through /etc/crypttab BELOW (late stage, post-root,
  # nofail) — never the initrd.
  encryptedPools = lib.filter (p: p.encrypted or false) pools;
  encryptedMappers = lib.concatMap (p: p.luks-mappers) encryptedPools;

  # The link-prep oneshot covers any pool where udev doesn't reliably probe
  # the multi-device btrfs after the backing layer comes up:
  #   - parity pools (btrfs on a freshly-assembled md device — known gap)
  #   - encrypted multi-device btrfs-native pools (btrfs spans N mappers; the
  #     by-uuid only appears once btrfs has SEEN every mapper via a scan)
  # Single-device or unencrypted-native pools don't need it.
  isMdProfile = p: (p.profile or "") == "raid5" || (p.profile or "") == "raid6";
  needsLinkPrep = p:
    isMdProfile p
    || ((p.encrypted or false) && (lib.length (p.members or [])) > 1);
  mdLinkPools = lib.filter needsLinkPrep pools;
  mdLinkMountUnits =
    map (p: "${utils.escapeSystemdPath p.mountpoint}.mount") mdLinkPools;

  # btrfs assembles a multi-device filesystem from any present member, so we
  # mount by the filesystem UUID — stable across disk reorder/reseat — rather
  # than a device path. For encrypted pools the UUID still points at the btrfs;
  # systemd's mount unit waits on the cryptsetup units to surface the mappers
  # via /dev/disk/by-uuid as usual.
  mkPoolDevice = p: "/dev/disk/by-uuid/${p.fs-uuid}";

  # nofail + bounded device-timeout first, then the pool's btrfs options.
  mkMountOptions = p:
    [ "nofail" "x-systemd.device-timeout=${p.device-timeout}" ] ++ p.mount-options;

  mkFileSystem = p: {
    name = p.mountpoint;
    value = {
      device = mkPoolDevice p;
      fsType = "btrfs";
      options = mkMountOptions p;
    };
  };

  # Late-unlock crypttab line for one LUKS mapper.
  #
  # Field-3 (keyfile path) is set from `m.keyfile`:
  #   - empty  → `none`  (no per-volume keyfile; rely on TPM/prompt)
  #   - non-empty → the saved-key path (foreign-keyed volume adopted via the
  #     unlock flow)
  #
  # The `tpm2-device=auto,tpm2-pcrs=7` opts are emitted ONLY when the LUKS
  # actually has a TPM2-bound keyslot (`m.tpm2-enrolled`). This is critical:
  # passing `tpm2-device=auto` against a LUKS with NO TPM2 slot causes
  # systemd-cryptsetup to SEGFAULT inside `tpm2_unseal` instead of falling
  # back to the keyfile / prompt — boot fails with `core-dump`, observed on
  # systemd 260. So omit the opts for foreign-keyed volumes that haven't had
  # the master adopted (tpm2-enrolled defaults true for legacy records that
  # came from the master-keyed create flow, which DOES enroll a TPM slot).
  #
  # `nofail` makes a missing backing device (e.g. pulled disk) non-fatal —
  # systemd skips the unit and boot continues; the admin UI flags the volume.
  # `discard` propagates fstrim through the LUKS layer (matches the system
  # disk's `allowDiscards=true`).
  mkCrypttabLine = m:
    let
      keyfileField = if m.keyfile == "" then "none" else m.keyfile;
      tpmOpts = if (m.tpm2-enrolled or true)
                then "tpm2-device=auto,tpm2-pcrs=7,"
                else "";
    in
    "${m.mapper} /dev/disk/by-id/${m.by-id} ${keyfileField} "
    + "${tpmOpts}nofail,x-systemd.device-timeout=15s,luks,discard";
in
{
  fileSystems = builtins.listToAttrs (map mkFileSystem pools);

  # /etc/crypttab is parsed by systemd-cryptsetup-generator, which builds one
  # `systemd-cryptsetup@<mapper>.service` per line. Those units run under
  # `cryptsetup.target` (post-root, before `local-fs.target`) — exactly what
  # rule 10 wants for data. The initrd `boot.initrd.luks.devices` set is
  # untouched, so the system disk still unlocks the same way it always has.
  environment.etc.crypttab = lib.mkIf (encryptedMappers != []) {
    text = (lib.concatMapStringsSep "\n" mkCrypttabLine encryptedMappers) + "\n";
    mode = "0600";
  };

  # Install Linux md tooling + udev assembly rules whenever a parity volume
  # exists, so its array assembles automatically at boot. No effect (and no md
  # in the closure) when there are only btrfs-native volumes. We do NOT manage
  # mdadm.conf: HomeFree's OS root is btrfs (never md), and data arrays assemble
  # by homehost via the udev rules without an ARRAY line — avoiding any conflict
  # with an instance's own mdadm.conf.
  boot.swraid.enable = lib.mkIf (mdPools != []) true;

  # NixOS's mdadm udev rules assemble arrays but DON'T reliably create the
  # `/dev/disk/by-id/md-uuid-<X>` and `/dev/disk/by-uuid/<luks-uuid>`
  # symlinks after assembly. An explicit `udevadm trigger --action=change
  # /dev/md<N>` makes udev re-probe and produces every expected symlink.
  # Without this, `/etc/crypttab` lines for LUKS-on-md (which reference the
  # md-uuid by-id path) fail with `dependency` at boot, the cryptsetup
  # unit core-dumps (older systemd) or just never starts (newer), and the
  # mount unit sits inactive forever — the UI then reads "Drive(s) not
  # present". This oneshot prods udev for every parity volume's md device
  # BEFORE cryptsetup.target activates, so the symlinks exist by the time
  # the cryptsetup units try to look them up.
  systemd.services."homefree-storage-md-trigger" = lib.mkIf (mdPools != []) {
    description = "Trigger udev on assembled md devices so by-id/by-uuid symlinks exist before cryptsetup";
    wantedBy = [ "cryptsetup.target" ];
    before = [ "cryptsetup.target" ];
    after = [ "systemd-udev-trigger.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      TimeoutStartSec = "30s";
    };
    script = ''
${lib.concatMapStringsSep "\n" (p: ''
      if [ -e /dev/${p.md-device} ]; then
        ${config.systemd.package}/bin/udevadm trigger --action=change /dev/${p.md-device} || true
      fi'') mdPools}
      ${config.systemd.package}/bin/udevadm settle --timeout=15 || true
    '';
  };

  # Switch-to-configuration counterpart of homefree-storage-md-trigger:
  # at boot the systemd service above fires before cryptsetup.target, but
  # during a `nixos-rebuild switch` cryptsetup.target is already active so
  # the service isn't re-triggered. Without this activation hook a
  # freshly-Promoted encrypted parity volume requires a reboot before its
  # cryptsetup unit can find /dev/disk/by-id/md-uuid-<X> — the user
  # rightfully complains. The hook (a) prods udev so the symlinks exist
  # NOW, (b) explicitly starts each encrypted pool's cryptsetup unit, and
  # (c) starts the mount unit. Each step is idempotent; failures are
  # swallowed so a broken volume can't block the whole Apply.
  system.activationScripts.homefreeStorageMdTrigger = lib.mkIf (encryptedPools != []) {
    text = ''
${lib.concatMapStringsSep "\n" (p: ''
      if [ -e /dev/${p.md-device} ]; then
        ${config.systemd.package}/bin/udevadm trigger --action=change /dev/${p.md-device} || true
      fi'') (lib.filter (p: p.md-device != "") encryptedPools)}
      ${config.systemd.package}/bin/udevadm settle --timeout=15 || true
${lib.concatMapStringsSep "\n" (m: ''
      esc=$(${config.systemd.package}/bin/systemd-escape "${m.mapper}")
      ${config.systemd.package}/bin/systemctl start "systemd-cryptsetup@$esc.service" 2>/dev/null || true'') encryptedMappers}
${lib.concatMapStringsSep "\n" (p: ''
      ${config.systemd.package}/bin/systemctl start "${utils.escapeSystemdPath p.mountpoint}.mount" 2>/dev/null || true'') encryptedPools}
    '';
    deps = [ "etc" ];
  };

  # cryptsetup must be available before the FIRST encrypted pool is created
  # (the closure is computed BEFORE that pool's record exists, so we cannot
  # gate this on `encryptedPools != []`). Negligible closure-size cost; lets
  # the admin UI's "create encrypted volume" wizard work on any box. On
  # boxes with system-disk encryption it's already pulled in by install.py's
  # generated encryption module.
  environment.systemPackages = with pkgs; [ cryptsetup ];

  # Make the btrfs by-uuid symlinks exist BEFORE the mount fires, for pools
  # whose backing layer udev doesn't reliably re-probe:
  #   - parity (btrfs-on-md): assembly uevent fires while array_state is still
  #     transitional; no re-probe follows.
  #   - encrypted multi-device btrfs-native: after cryptsetup opens N mappers,
  #     the per-mapper btrfs members are visible but the MULTI-DEVICE by-uuid
  #     only appears once btrfs has "seen" every member via a device scan.
  # This oneshot replays a manual `btrfs device scan` + `udevadm trigger
  # --action=change` until the link appears. `wantedBy` + `before` each
  # eligible mount unit means it runs at boot AND during `nixos-rebuild
  # switch` (the mount units are newly wanted) — create/attach+Apply just
  # works without a reboot. Idempotent, fail-safe, bounded (a genuinely-
  # absent pool can't delay boot; the mount is nofail regardless).
  systemd.services."homefree-storage-md-links" = lib.mkIf (mdLinkPools != []) {
    description = "Ensure storage volumes expose /dev/disk/by-uuid links before mounting";
    wantedBy = mdLinkMountUnits;
    before = mdLinkMountUnits;
    after = [ "systemd-udev-trigger.service" "cryptsetup.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      TimeoutStartSec = "45s";
    };
    script = ''
      for _ in $(seq 1 20); do
        ${pkgs.btrfs-progs}/bin/btrfs device scan >/dev/null 2>&1 || true
        missing=
${lib.concatMapStringsSep "\n" (p: ''
        if [ ! -e /dev/disk/by-uuid/${p.fs-uuid} ]; then
          dev=$(${pkgs.util-linux}/bin/blkid -U ${lib.escapeShellArg p.fs-uuid} 2>/dev/null || true)
          [ -n "$dev" ] && ${config.systemd.package}/bin/udevadm trigger --action=change "$dev" >/dev/null 2>&1 || true
          [ -e /dev/disk/by-uuid/${p.fs-uuid} ] || missing=1
        fi'') mdLinkPools}
        [ -z "$missing" ] && break
        sleep 1
      done
      ${config.systemd.package}/bin/udevadm settle >/dev/null 2>&1 || true
    '';
  };

  # Add each volume to the system-wide monthly btrfs scrub (enabled in the base
  # profile profiles/common.nix, which also scrubs the OS root). We contribute
  # only the fileSystems LIST here — not enable/interval — so it merges with
  # the base definition (lists concatenate; a second enable/interval would be a
  # conflicting scalar). On raid1/raid10 the scrub repairs bitrot from the
  # redundant copy. Inert when no volumes exist; an unmounted (nofail) volume
  # just logs a failed scrub that month — harmless, no boot/recovery impact.
  services.btrfs.autoScrub.fileSystems =
    lib.mkIf (pools != []) (map (p: p.mountpoint) pools);
}
