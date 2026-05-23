{ config, lib, pkgs, utils, ... }:

# Mounts the local btrfs data pools recorded in `homefree.storage.pools`
# (created imperatively by the Storage admin module; see
# web-platform/backend/services/storage_pool.py). This module is the
# DECLARATIVE half of "imperative-create once, declarative-manage forever":
# it never touches a disk, it only turns recorded pool identities into
# `fileSystems` entries. With an empty pool list it is a complete no-op.
#
# Recovery-surface note (see AGENTS.md rule 10): a data pool is never part
# of the boot-critical path, so every mount is `nofail` with a bounded
# device-timeout. A missing, unplugged, or degraded pool must NEVER fail the
# boot transaction or block multi-user.target — that would take down the
# admin UI, which is the only in-product way to repair the box.

let
  # Only enabled pools reach fileSystems. A disabled pool keeps its row in
  # homefree-config.json (so the admin UI can re-enable it) but produces no
  # kernel mount. Mirrors the filter in modules/mounts.nix.
  pools = lib.filter (p: p.enabled or true) config.homefree.storage.pools;

  # Parity volumes (raid5/raid6) are btrfs-on-mdadm: Linux md assembles the
  # array, btrfs sits single-profile on the resulting /dev/md device. md's
  # assembly machinery (boot.swraid) auto-assembles the array by homehost, and
  # the mount keys on the btrfs fs-uuid like any other volume. BUT udev does not
  # reliably probe the btrfs on a freshly-assembled md device — its
  # /dev/disk/by-uuid/<uuid> symlink never appears, so the nofail mount silently
  # fails. The homefree-storage-md-links service below fixes that (see there).
  # The `nofail` mount still guarantees a missing/degraded/resyncing array can
  # never block boot or the admin UI (rule 10).
  mdPools = lib.filter
    (p: (p.profile or "") == "raid5" || (p.profile or "") == "raid6")
    pools;

  # systemd mount-unit name for each parity volume's mountpoint (e.g.
  # /mnt/data → mnt-data.mount), so the link-prep service can be ordered
  # before exactly those mounts.
  mdMountUnits = map (p: "${utils.escapeSystemdPath p.mountpoint}.mount") mdPools;

  # Encrypted data pools (LUKS late-unlock) are a planned later phase. Until
  # that wiring lands and is verified on hardware, refuse to build a config
  # that references one — a clear eval-time failure (the box keeps running
  # its current generation) beats silently mounting a by-uuid device that
  # will never appear.
  encryptedPools = lib.filter (p: p.encrypted or false) pools;

  # btrfs assembles a multi-device filesystem from any present member, so we
  # mount by the filesystem UUID — stable across disk reorder/reseat — rather
  # than a device path. (by-id paths are only needed for LUKS backing
  # devices, which this phase does not create.)
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
in
{
  assertions = [
    {
      assertion = encryptedPools == [];
      message =
        "homefree.storage: encrypted data pools are not supported yet "
        + "(planned for a later phase). Offending pool(s): "
        + lib.concatMapStringsSep ", " (p: p.name) encryptedPools + ".";
    }
  ];

  fileSystems = builtins.listToAttrs (map mkFileSystem pools);

  # Install Linux md tooling + udev assembly rules whenever a parity volume
  # exists, so its array assembles automatically at boot. No effect (and no md
  # in the closure) when there are only btrfs-native volumes. We do NOT manage
  # mdadm.conf: HomeFree's OS root is btrfs (never md), and data arrays assemble
  # by homehost via the udev rules without an ARRAY line — avoiding any conflict
  # with an instance's own mdadm.conf.
  boot.swraid.enable = lib.mkIf (mdPools != []) true;

  # Make the btrfs-on-md by-uuid symlinks exist BEFORE the parity volumes mount.
  # udev doesn't reliably probe a kernel md device's btrfs after the array
  # assembles (the assembly uevent fires while array_state is still transitional
  # and no re-probe follows), so /dev/disk/by-uuid/<uuid> is missing and the
  # nofail mount fails. This oneshot does what a manual `btrfs device scan` +
  # `udevadm trigger --action=change` does, until the links appear. Because it's
  # `wantedBy` + `before` each parity mount, it runs both at boot AND during a
  # `nixos-rebuild switch` activation (the mount units are newly wanted) — so
  # creating/attaching a volume and clicking Apply just works, no reboot, no
  # manual step. Idempotent, fail-safe, and bounded so a genuinely-absent array
  # can't delay boot (the mount is nofail regardless).
  systemd.services."homefree-storage-md-links" = lib.mkIf (mdPools != []) {
    description = "Ensure btrfs-on-md storage volumes expose /dev/disk/by-uuid links before mounting";
    wantedBy = mdMountUnits;
    before = mdMountUnits;
    after = [ "systemd-udev-trigger.service" ];
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
        fi'') mdPools}
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
