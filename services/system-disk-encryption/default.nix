{ config, lib, pkgs, ... }:

## System-disk LUKS + TPM2 first-boot auto-unlock.
##
## What this module owns:
##   - Switches the initrd to systemd (required for TPM2 unlocking).
##   - Adds tpm2-tools + cryptsetup to the system environment.
##   - Runs ONE-TIME first-boot service that enrolls a TPM2 keyslot
##     (bound to PCR 7) on every system-disk LUKS container, then
##     shreds the install-time keyfile. Subsequent boots unlock
##     unattended via TPM2; the recovery passphrase keyslot remains
##     as the admin's safety net.
##
## Scope: SYSTEM disks only (root + swap created by disko at install
## time). Data pools (homefree.storage.pools) are unrelated — they
## unlock LATE via /etc/crypttab after the system is up, see
## docs/agent-notes/storage-encryption.md.
##
## Partition discovery: every disko layout (single / mirrored /
## striped, ± swap) names its LUKS partitions deterministically as
## `disk-d<N>-root` / `disk-d<N>-swap` (see
## web-platform/backend/services/disko_builder.py — `root_partlabels`
## and `swap_partlabels`). The enrollment script globs those at
## runtime, so it picks up whatever the install actually produced
## without per-install substitution.
##
## Opt-in: gated on homefree.system-disk-encryption.enable. The installer
## flips it on via homefree-config.json when the user opts into LUKS
## at install time. Default-off so non-encrypted boxes don't pull in
## initrd-systemd or the TPM2 packages.

let
  cfg = config.homefree.system-disk-encryption;

  ## Install-time keyfile. Disko's `passwordFile` writes the LUKS
  ## containers against this path at install time, and the recovery
  ## passphrase is added as a second keyslot before first reboot —
  ## both done by web-platform/backend/services/install.py. The TPM2
  ## enrollment uses this keyfile to authorize itself, then shreds
  ## it. Path is constant across all installs.
  luksKeyfile = "/etc/nixos/secrets/luks.key";
in
{
  options.homefree.system-disk-encryption = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Enable system-disk LUKS support: initrd-systemd and the
        first-boot TPM2 keyslot enrollment service. Set to true by
        the installer when the user opts into disk encryption at
        install time; leave false on plaintext installs.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    boot.initrd.systemd.enable = true;

    environment.systemPackages = with pkgs; [ tpm2-tools cryptsetup ];

    systemd.services.homefree-tpm2-enroll = {
      description = "Enroll TPM2 keyslot for LUKS auto-unlock";
      wantedBy = [ "multi-user.target" ];
      after = [ "multi-user.target" ];
      unitConfig.ConditionPathExists = "!/var/lib/homefree/tpm2-enrolled";
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      path = with pkgs; [ tpm2-tools cryptsetup systemd coreutils ];
      script = ''
        set -eu
        mkdir -p /var/lib/homefree

        # No TPM2 -> leave passphrase-only unlock in place and record it.
        if [ ! -e /dev/tpmrm0 ] && [ ! -e /dev/tpm0 ]; then
          echo "No TPM2 device found; keeping passphrase unlock."
          echo "no-tpm2" > /var/lib/homefree/encryption-status
          exit 0
        fi

        KEYFILE="${luksKeyfile}"
        if [ ! -r "$KEYFILE" ]; then
          echo "Keyfile $KEYFILE missing; cannot enroll TPM2." >&2
          echo "error-no-keyfile" > /var/lib/homefree/encryption-status
          exit 0
        fi

        # Glob handles every supported disko layout: single, mirrored,
        # striped; with or without swap. Loop body is a no-op for any
        # glob that matches nothing.
        for part in /dev/disk/by-partlabel/disk-d*-root /dev/disk/by-partlabel/disk-d*-swap; do
          [ -e "$part" ] || continue
          echo "Enrolling TPM2 keyslot on $part"
          systemd-cryptenroll --unlock-key-file="$KEYFILE" \
            --tpm2-device=auto --tpm2-pcrs=7 "$part"
        done

        # The keyfile slot is no longer needed for unattended boot; the
        # recovery passphrase slot remains as the admin's safety net.
        shred -u "$KEYFILE" || rm -f "$KEYFILE"
        echo "tpm2-enrolled" > /var/lib/homefree/encryption-status
        touch /var/lib/homefree/tpm2-enrolled
      '';
    };
  };
}
