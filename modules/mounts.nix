{ config, lib, ... }:

let
  inherit (lib) mkIf;
  # Drop disabled rows before they reach fileSystems. A disabled entry
  # keeps its row in homefree-config.json (so the admin UI can re-enable
  # it later) but does not produce a kernel mount, and does not count
  # toward `anyNfs` — disabling every NFS row also turns off rpcbind.
  mounts = lib.filter (m: m.enabled or true) config.homefree.mounts;
  anyNfs = lib.any (m: m.fs-type == "nfs") mounts;

  # Every mount-points row gets `nofail` + a bounded device-timeout, so a
  # missing/unreachable device (unplugged USB drive, NFS server down, wrong
  # UUID after a hardware swap) can never block local-fs.target and drop the
  # box to emergency mode. Per AGENTS.md rule 10 the admin UI is the recovery
  # surface — a non-system mount must not be able to take it offline. Mirrors
  # the same guard storage-pools.nix already applies to storage pools.
  # User-supplied extra-options come AFTER, so an explicit
  # `x-systemd.device-timeout=...` overrides the default.
  mkMountOptions = m:
    let
      safetyOpts = [ "nofail" "x-systemd.device-timeout=15s" ];
      nfsOpts = lib.optional (m.fs-type == "nfs") "nfsvers=${m.nfs-version}";
      automountOpts = lib.optionals m.automount [
        "x-systemd.automount"
        "noauto"
        "x-systemd.idle-timeout=${m.idle-timeout}"
      ];
    in
      safetyOpts ++ nfsOpts ++ automountOpts ++ m.extra-options;

  mkFileSystem = m: {
    name = m.mount-point;
    value = {
      device = m.device;
      fsType = m.fs-type;
      options = mkMountOptions m;
    };
  };
in
{
  services.rpcbind.enable = mkIf anyNfs true;

  fileSystems = builtins.listToAttrs (map mkFileSystem mounts);
}
