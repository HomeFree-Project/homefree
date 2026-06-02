{ config, lib, pkgs, ... }:

# Boot-mirror hook for RAID1 installs.
#
# When the installer chose raid='raid1', disko provisions a second ESP
# on disk 2 mounted at /boot2 (see web-platform/backend/services/disko_builder.py).
# systemd-boot itself only installs into /boot — without this rsync hook
# /boot2 stays empty and disk 2 cannot boot the system if disk 1 dies.
# NixOS has no mirroredBoots option for systemd-boot (only for grub and
# extlinux), so the mirror is implemented as a post-install rsync.
#
# Gated on homefree.system.bootMirror (set from homefree-config.json by
# modules/homefree-config-loader.nix), so single-disk installs that have
# no /boot2 don't get the hook. Currently mirrors to a single hardcoded
# /boot2 target — matches disko_builder, which only provisions a second
# ESP on disk index 1.

let
  cfg = config.homefree.system;
in
{
  config = lib.mkIf cfg.bootMirror {
    boot.loader.systemd-boot.extraInstallCommands = ''
      ${pkgs.rsync}/bin/rsync -a --delete /boot/ /boot2/
    '';
  };
}
