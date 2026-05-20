{ config, lib, ... }:

let
  inherit (lib) mkIf;
  # Drop disabled rows before they reach fileSystems. A disabled entry
  # keeps its row in homefree-config.json (so the admin UI can re-enable
  # it later) but does not produce a kernel mount, and does not count
  # toward `anyNfs` — disabling every NFS row also turns off rpcbind.
  mounts = lib.filter (m: m.enabled or true) config.homefree.mounts;
  anyNfs = lib.any (m: m.fs-type == "nfs") mounts;

  mkMountOptions = m:
    let
      nfsOpts = lib.optional (m.fs-type == "nfs") "nfsvers=${m.nfs-version}";
      automountOpts = lib.optionals m.automount [
        "x-systemd.automount"
        "noauto"
        "x-systemd.idle-timeout=${m.idle-timeout}"
      ];
      computed = nfsOpts ++ automountOpts ++ m.extra-options;
    in
      if computed == [] then [ "defaults" ] else computed;

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
