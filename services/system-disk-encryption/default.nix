{ config, lib, pkgs, ... }:

## LUKS + TPM2 auto-unlock, self-healing across firmware updates.
##
## What this module owns:
##   - Switches the initrd to systemd (required for TPM2 unlocking).
##   - Adds tpm2-tools + cryptsetup to the system environment.
##   - Runs a per-boot reconciler that keeps a PCR-7-bound TPM2 keyslot
##     enrolled on every TPM2-managed LUKS container — the system disk
##     (root + swap) AND every data pool. Subsequent boots unlock
##     unattended via TPM2; the recovery passphrase keyslot remains as
##     the admin's safety net.
##
## Why per-boot, not once (the firmware-update problem):
##   The TPM2 slot is sealed to PCR 7 (Secure Boot policy). A firmware
##   update / Secure Boot key change MOVES PCR 7, so the TPM refuses to
##   release the key and the box falls back to the passphrase prompt
##   (boot prompt for the system disk; failed late-unlock for data
##   pools) — forever, under the old run-once design. This service
##   instead re-checks PCR 7 every boot: when it has moved (or a
##   container is missing its slot), it wipes the stale TPM2 slot and
##   re-enrolls against the *current* PCR 7. Net effect: a firmware
##   update costs the admin at most ONE system-disk passphrase prompt,
##   then every container self-heals back to unattended unlock.
##
## How re-enrollment authorizes itself:
##   systemd-cryptenroll needs an already-valid keyslot to add a new one.
##   We use the box-wide recovery passphrase
##   (/etc/nixos/secrets/recovery-passphrase.txt) — the same value the
##   system disk's recovery slot AND every data pool are bound to. It
##   lives ONLY on the already-unlocked encrypted root, so an attacker
##   with a powered-off disk never sees it. This is also why the
##   reconciler is safe: it only runs AFTER the root is unlocked (post
##   multi-user.target), which itself required either a working TPM2
##   release or the admin typing the passphrase. An attacker who tampers
##   with the boot chain faces the passphrase prompt and cannot reach the
##   re-enroll path. (Pre-feature installs may lack the recovery file; we
##   fall back to the install keyfile for the SYSTEM disk while it is
##   still present, and skip data pools, which only exist once the
##   recovery-passphrase master key has been set.)
##
## Staleness detection is per-device. We record, per container, the PCR-7
## value it was last enrolled against under /var/lib/homefree/tpm2-pcr7.d/.
## A data pool that was detached when the firmware changed therefore still
## heals the next time it is present, instead of a single global marker
## "using up" the change signal before the pool reappears. On a normal
## boot (PCR unchanged, slots present) the reconciler writes no LUKS
## headers.
##
## Discovery:
##   - System disk: disko names its LUKS partitions deterministically as
##     `disk-d<N>-root` / `disk-d<N>-swap` (see
##     web-platform/backend/services/disko_builder.py); we glob those.
##   - Data pools: every TPM2-managed pool container appears in
##     /etc/crypttab with `tpm2-pcrs=7` opts (emitted by
##     modules/storage-pools.nix); we parse those lines. Containers whose
##     device node is absent this boot (pool detached) are skipped and
##     retried whenever they next appear.
##
## Scope note: data pools unlock LATE via /etc/crypttab with `nofail`, so
## a failed/stale TPM2 unlock is non-fatal and the admin UI stays
## reachable — see docs/agent-notes/storage-encryption.md. We never move
## them into the initrd.
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
  ## both done by web-platform/backend/services/install.py. Used as the
  ## re-enroll authorizer only on legacy installs that lack the recovery
  ## passphrase file; otherwise shredded once that durable authorizer is
  ## confirmed present. Path is constant across all installs.
  luksKeyfile = "/etc/nixos/secrets/luks.key";

  ## Box-wide master key, seeded by the installer and kept on the
  ## encrypted root. Same value bound to the system disk's recovery slot
  ## and every data pool. Used to authorize TPM2 re-enrollment.
  recoveryFile = "/etc/nixos/secrets/recovery-passphrase.txt";
in
{
  options.homefree.system-disk-encryption = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Enable LUKS + TPM2 support: initrd-systemd and the self-healing
        TPM2 keyslot reconciler (system disk + data pools). Set to true
        by the installer when the user opts into disk encryption at
        install time; leave false on plaintext installs.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    boot.initrd.systemd.enable = true;

    environment.systemPackages = with pkgs; [ tpm2-tools cryptsetup ];

    systemd.services.homefree-tpm2-enroll = {
      description = "Reconcile TPM2 keyslots for LUKS auto-unlock";
      wantedBy = [ "multi-user.target" ];
      after = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      path = with pkgs; [ tpm2-tools cryptsetup systemd coreutils gnugrep ];
      script = ''
        set -u
        STATE=/var/lib/homefree
        PCRDIR="$STATE/tpm2-pcr7.d"
        mkdir -p "$PCRDIR"

        # No TPM2 -> passphrase-only unlock; nothing to maintain.
        if [ ! -e /dev/tpmrm0 ] && [ ! -e /dev/tpm0 ]; then
          echo "No TPM2 device found; keeping passphrase unlock."
          echo "no-tpm2" > "$STATE/encryption-status"
          exit 0
        fi
        TPMDEV=/dev/tpmrm0
        [ -e "$TPMDEV" ] || TPMDEV=/dev/tpm0

        # Pick a durable authorizer that lives ONLY on the already-unlocked
        # encrypted root. Prefer the recovery passphrase (the box-wide
        # master key); fall back to the install keyfile on legacy installs.
        # HAVE_RECOVERY gates data-pool reconcile: pool slots are bound to
        # the recovery passphrase, never to the install keyfile.
        UNLOCK=""
        TMPKEY=""
        HAVE_RECOVERY=0
        cleanup() { [ -n "$TMPKEY" ] && shred -u "$TMPKEY" 2>/dev/null; return 0; }
        trap cleanup EXIT

        if [ -r "${recoveryFile}" ]; then
          # The recovery slot was bound with PASSPHRASE semantics (one
          # line, trailing newline stripped). Match it byte-for-byte;
          # pre-feature files carry a trailing newline (see
          # docs/agent-notes/storage-encryption.md). --unlock-key-file
          # reads raw bytes to EOF, so strip the newline first.
          TMPKEY=$(mktemp /run/hf-tpm2-unlock.XXXXXX)
          chmod 600 "$TMPKEY"
          tr -d '\n' < "${recoveryFile}" > "$TMPKEY"
          UNLOCK="$TMPKEY"
          HAVE_RECOVERY=1
        elif [ -r "${luksKeyfile}" ]; then
          # Installer writes the keyfile WITHOUT a trailing newline, so it
          # is byte-exact for --unlock-key-file as-is.
          UNLOCK="${luksKeyfile}"
        fi

        if [ -z "$UNLOCK" ]; then
          echo "No recovery passphrase or keyfile available; cannot maintain TPM2 enrollment." >&2
          echo "error-no-authorizer" > "$STATE/encryption-status"
          exit 0
        fi

        # Current PCR 7 (Secure Boot policy). A firmware / Secure Boot
        # change moves this; that is exactly what invalidates sealed slots.
        # Pass the device explicitly so we don't depend on tpm2-abrmd.
        CUR=$(tpm2_pcrread -T "device:$TPMDEV" sha256:7 2>/dev/null \
              | grep -oiE '0x[0-9a-f]+' | head -n1)

        # Reconcile ONE container: (re)enroll a PCR-7-bound TPM2 slot only
        # when it is missing or sealed to a stale PCR 7. No-op otherwise.
        # Returns non-zero only on an actual enroll failure.
        reconcile_dev() {
          dev=$1
          [ -e "$dev" ] || return 0

          has=0
          cryptsetup luksDump "$dev" 2>/dev/null | grep -q systemd-tpm2 && has=1

          if [ -z "$CUR" ]; then
            # Couldn't read PCR 7: can't judge staleness. Only act when
            # there is no TPM2 slot at all; leave an existing one alone.
            [ "$has" = 1 ] && return 0
          else
            key=$(printf '%s' "$dev" | tr '/' '_')
            rec="$PCRDIR/$key"
            prev=""
            [ -r "$rec" ] && prev=$(cat "$rec")
            # Slot present and already sealed to the current PCR 7 -> done.
            [ "$has" = 1 ] && [ "$prev" = "$CUR" ] && return 0
          fi

          wipe=""
          [ "$has" = 1 ] && wipe="--wipe-slot=tpm2"
          echo "Enrolling TPM2 keyslot on $dev (PCR7=$CUR)"
          if systemd-cryptenroll --unlock-key-file="$UNLOCK" $wipe \
               --tpm2-device=auto --tpm2-pcrs=7 "$dev"; then
            if [ -n "$CUR" ]; then
              key=$(printf '%s' "$dev" | tr '/' '_')
              printf '%s' "$CUR" > "$PCRDIR/$key"
            fi
            return 0
          fi
          echo "WARNING: TPM2 enroll failed on $dev; passphrase unlock still works." >&2
          return 1
        }

        overall_ok=1

        # --- System disk (root + swap) -----------------------------------
        # Glob handles every disko layout: single / mirrored / striped,
        # with or without swap.
        any_sys=0
        for part in /dev/disk/by-partlabel/disk-d*-root /dev/disk/by-partlabel/disk-d*-swap; do
          [ -e "$part" ] || continue
          any_sys=1
          reconcile_dev "$part" || overall_ok=0
        done
        if [ "$any_sys" = 0 ]; then
          echo "No system LUKS partitions found." >&2
          echo "error-no-partitions" > "$STATE/encryption-status"
          exit 0
        fi

        # --- Data pools --------------------------------------------------
        # Every TPM2-managed pool container appears in /etc/crypttab with
        # tpm2-pcrs opts (modules/storage-pools.nix). They are bound to the
        # recovery passphrase, so only reconcile them when that is our
        # authorizer. Field 2 is the backing device; skip if it is not
        # present this boot (pool detached -> retried when it reappears).
        if [ "$HAVE_RECOVERY" = 1 ] && [ -r /etc/crypttab ]; then
          while read -r ct_name ct_dev ct_key ct_opts ct_rest || [ -n "$ct_name" ]; do
            [ -z "$ct_name" ] && continue
            case "$ct_name" in \#*) continue ;; esac
            case "$ct_opts" in *tpm2-pcrs*) ;; *) continue ;; esac
            [ -n "$ct_dev" ] || continue
            if [ ! -e "$ct_dev" ]; then
              echo "Data-pool device $ct_dev ($ct_name) not present; skipping."
              continue
            fi
            reconcile_dev "$ct_dev" || overall_ok=0
          done < /etc/crypttab
        fi

        if [ "$overall_ok" = 1 ]; then
          echo "tpm2-enrolled" > "$STATE/encryption-status"
        else
          echo "tpm2-enroll-partial" > "$STATE/encryption-status"
        fi

        # One-time cleanup: once the durable recovery-passphrase authorizer
        # is in place, drop the install keyfile so the artifact doesn't
        # linger (matches the original design's intent). Only when we are
        # NOT relying on the keyfile as our authorizer.
        if [ -r "${recoveryFile}" ] && [ -e "${luksKeyfile}" ]; then
          shred -u "${luksKeyfile}" 2>/dev/null || rm -f "${luksKeyfile}"
        fi
      '';
    };
  };
}
