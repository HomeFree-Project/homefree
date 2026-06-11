## On-rebuild migration — fold every authorized SSH key into the encrypted
## secrets store (/etc/nixos/secrets/secrets.yaml) as a NATIVE age ssh recipient.
##
## BACKGROUND. Secrets are encrypted to the host key AND the user's authorized
## key, but the user key used to be converted with `ssh-to-age`, which only
## handles ed25519 — a user RSA key was silently skipped, leaving secrets
## host-key-only. The host key is NOT backed up, so a backup of such a box could
## not have its secrets recovered on fresh hardware. age itself supports native
## `ssh-rsa`/`ssh-ed25519` recipients, so SecretsManager now records the user
## recipient as the raw ssh key. This migration brings ALREADY-deployed boxes'
## secrets.yaml up to that scheme.
##
## It is an idempotent activation-time migration (AGENTS rule 11): every box
## applies it on `nixos-rebuild`, it no-ops once converged, and it can never
## brick a box — it keeps the host recipient unchanged (so boot decryption is
## untouched) and verifies the host key still decrypts the re-keyed file before
## swapping it in. Runs under the same flock the per-service anchor units use
## (lib/secrets-anchor.nix) so it never races a concurrent write of secrets.yaml.
##
## The migration logic lives in ./secrets-recipient-migrate.py (kept in sync with
## SecretsManager._build_age_recipients). Both this file and the .py must be
## git-tracked or the flake's path import silently excludes them (AGENTS rule 2).
{ config, lib, pkgs, ... }:

let
  py = pkgs.python3.withPackages (ps: [ ps.pyyaml ]);

  rekeyScript = pkgs.writeScript "homefree-secrets-recipient-migrate" ''
    #!${py}/bin/python3
    ${builtins.readFile ./secrets-recipient-migrate.py}
  '';

  # The python shells out to `sops` and `ssh-to-age` by bare name; an activation
  # script has a minimal PATH, so make them resolvable. `flock`/`timeout` guard
  # against a concurrent writer and against any hang stalling the switch/boot.
  runtimePath = lib.makeBinPath [ pkgs.sops pkgs.ssh-to-age pkgs.coreutils pkgs.util-linux ];
in
{
  system.activationScripts.homefreeSecretsRecipientMigrate = {
    # Run after the secrets dir is guaranteed to exist (profiles/secrets.nix).
    deps = [ "createSecretsDir" ];
    text = ''
      if [ -f /etc/nixos/secrets/secrets.yaml ] && [ -f /etc/ssh/ssh_host_ed25519_key ]; then
        PATH=${runtimePath}:$PATH \
          ${pkgs.coreutils}/bin/timeout 120 \
          ${pkgs.util-linux}/bin/flock /etc/nixos/secrets/secrets.yaml.anchor-lock \
          ${rekeyScript} \
          || echo "secrets-recipient-migrate: non-fatal error (secrets.yaml left unchanged)"
      fi
    '';
  };
}
