{ config, lib, ... }:

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
}
