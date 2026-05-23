{ config, lib, pkgs, ... }:

# Scheduled btrfs timeline snapshots via snapper (Phase 4 of Storage & NAS).
# Opt-in everywhere and OFF by default, so this module is a complete no-op
# until homefree.snapshots.system.enable or a volume's snapshots = true.
#
# What snapshots are (and aren't): a fast, local, copy-on-write point-in-time
# copy for "oops" recovery (deleted/overwrote a file). It lives on the SAME
# filesystem, so it is NOT a backup (a failed drive loses the snapshots too —
# restic covers offsite) and NOT system rollback (NixOS generations boot a
# previous config). Local file recovery only.
#
# The .snapshots subvolume: snapper requires <subvolume>/.snapshots to exist,
# and the nixpkgs-25.05 snapper module does NOT create it. We do:
#   - OS root (/ and /home): always mounted, so systemd-tmpfiles `v` (create
#     subvolume) is safe and reliable.
#   - Volumes: mount `nofail` and may be ABSENT. A plain tmpfiles rule would
#     create .snapshots on the ROOT fs under an unmounted mountpoint, which the
#     real volume would then shadow. So each volume gets a mount-guarded
#     oneshot that creates .snapshots ONLY when the volume is actually mounted
#     (RequiresMountsFor + a mountpoint check) — fail-safe: an absent volume
#     simply does nothing, never writing to the root stub.

let
  inherit (lib) mkIf;
  cfg = config.homefree.snapshots;
  r = cfg.retention;

  # Volumes with snapshots enabled (and themselves enabled).
  snapVols = lib.filter
    (p: (p.enabled or true) && (p.snapshots or false))
    config.homefree.storage.pools;

  # snapper timeline config for `subvol`, thinned to the shared retention.
  snapperCfg = subvol: {
    SUBVOLUME = subvol;
    TIMELINE_CREATE = true;
    TIMELINE_CLEANUP = true;
    TIMELINE_MIN_AGE = 1800;
    TIMELINE_LIMIT_HOURLY = r.hourly;
    TIMELINE_LIMIT_DAILY = r.daily;
    TIMELINE_LIMIT_WEEKLY = r.weekly;
    TIMELINE_LIMIT_MONTHLY = r.monthly;
    TIMELINE_LIMIT_QUARTERLY = 0;
    TIMELINE_LIMIT_YEARLY = 0;
  };

  osConfigs = lib.optionalAttrs cfg.system.enable {
    root = snapperCfg "/";
    home = snapperCfg "/home";
  };

  volConfigs = lib.listToAttrs (map
    (p: lib.nameValuePair "vol-${p.name}" (snapperCfg p.mountpoint))
    snapVols);

  anySnap = cfg.system.enable || snapVols != [];

  # Fail-safe per-volume .snapshots creator (see header note).
  mkVolInit = p: lib.nameValuePair "homefree-snapshots-init-${p.name}" {
    description = "Create .snapshots subvolume for storage volume ${p.name}";
    wantedBy = [ "multi-user.target" ];
    before = [ "snapper-timeline.service" ];
    unitConfig.RequiresMountsFor = [ p.mountpoint ];
    serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
    path = [ pkgs.btrfs-progs pkgs.util-linux ];
    script = ''
      if ${pkgs.util-linux}/bin/mountpoint -q ${lib.escapeShellArg p.mountpoint} \
         && [ ! -d ${lib.escapeShellArg (p.mountpoint + "/.snapshots")} ]; then
        ${pkgs.btrfs-progs}/bin/btrfs subvolume create ${lib.escapeShellArg (p.mountpoint + "/.snapshots")}
      fi
    '';
  };
in
{
  services.snapper.configs = mkIf anySnap (osConfigs // volConfigs);

  # OS root .snapshots — always mounted, so tmpfiles can create the subvolume.
  systemd.tmpfiles.rules = mkIf cfg.system.enable [
    "v /.snapshots 0750 root root -"
    "v /home/.snapshots 0750 root root -"
  ];

  systemd.services = lib.listToAttrs (map mkVolInit snapVols);
}
