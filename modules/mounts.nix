{ config, lib, ... }:

let
  inherit (lib) mkIf;
  mounts = config.homefree.mounts;
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
