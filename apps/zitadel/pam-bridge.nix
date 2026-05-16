{ config, lib, pkgs, ... }:

## Mirror local password changes to Zitadel via PAM.
##
## When the OS admin user runs `passwd` (or any other tool that
## triggers the system password-change PAM stack), this hook captures
## the new plaintext authtok and POSTs it to Zitadel's Management API
## so the same user's Zitadel password stays in sync. The OS admin can
## therefore log into Zitadel (and any OIDC-integrated service) with
## the same credentials they use for SSH/sudo, without ever touching
## the Zitadel UI.
##
## Prior art: pam_exec(8) with the `expose_authtok` option — used by
## NIS, Samba, and similar systems for cross-store password sync.
##
## Failure semantics: this rule is `optional` and runs BEFORE pam_unix
## in the password stack. That means:
##   - Zitadel down → script fails silently (logged to syslog),
##     pam_unix still updates /etc/shadow normally.
##   - Script succeeds but pam_unix fails → user gets a normal local
##     failure message; Zitadel-side update is "ahead" but harmless.
##   - We deliberately do NOT use `required` — locking users out of
##     `passwd` because Zitadel hiccupped would be a bad day.
##
## Scope: only fires for the OS admin user (whose name is stashed at
## /var/lib/homefree-admin/admin-username by zitadel-provision). Avoids
## the script trying to look up `root`, `nobody`, etc. in Zitadel.
##
## Why before pam_unix and not after: pam_unix in the default NixOS
## passwd stack is `sufficient`, which short-circuits subsequent modules
## on success. An "after pam_unix" rule would never run on the happy
## path. Placing ours before keeps the order-of-effects intuitive:
## the new password is pushed to Zitadel first, then committed locally.

let
  cfg = config.homefree;
  ## Phase 6 will add `homefree.sso.enable-pam-sync`. For now read
  ## defensively so this module evaluates standalone.
  enabled =
    cfg.service-options.zitadel.enable
    && (cfg.sso.enable-pam-sync or true);

  domain = cfg.system.domain;
  pamSecretsDir = "/var/lib/homefree-secrets/zitadel-pam";
  adminUsernameFile = "/var/lib/homefree-admin/admin-username";

  passwdToZitadel = pkgs.writeShellApplication {
    name = "passwd-to-zitadel";
    runtimeInputs = with pkgs; [ curl jq coreutils util-linux ];
    text = ''
      set -uo pipefail

      ## pam_exec contract:
      ##   - PAM_TYPE is one of {auth, account, password, session_open,
      ##     session_close}; we care about "password" (which fires on
      ##     both prelim_check and update phases).
      ##   - PAM_USER is the target username.
      ##   - With `expose_authtok`, the new password is written to
      ##     stdin as a single chunk (NOT newline-terminated).

      logp() {
        ## Tag log lines so they are easy to grep:
        ##   journalctl -t zitadel-pam-sync
        printf '%s\n' "$*" | logger -t zitadel-pam-sync
      }

      ## Only act on password updates, not auth/account/session.
      if [ "''${PAM_TYPE:-}" != "password" ]; then
        exit 0
      fi

      ## pam_exec calls the helper twice for password changes:
      ##   1. prelim phase  (PAM_AUTHTOK_TYPE=PAM_AUTHTOK_TYPE_PRELIM)
      ##   2. update phase  (no env var, or PAM_AUTHTOK)
      ## To avoid pushing the password twice (and racing), only act on
      ## the second call. PAM_AUTHTOK is set during the actual update
      ## phase — its presence is the cleanest signal.
      ##
      ## Reference: man 8 pam_exec, "PAM_AUTHTOK" section.
      if [ -z "''${PAM_AUTHTOK:-}" ] && [ "''${PAM_AUTHTOK_TYPE:-}" = "PAM_PRELIM_CHECK" ]; then
        exit 0
      fi

      USER="''${PAM_USER:-}"
      if [ -z "$USER" ]; then
        logp "no PAM_USER set, skipping"
        exit 0
      fi

      ## Scope to just the configured admin user. Skips root/nobody/etc.
      ADMIN_USER=""
      if [ -r "${adminUsernameFile}" ]; then
        ADMIN_USER=$(tr -d '[:space:]' < "${adminUsernameFile}")
      fi
      if [ -z "$ADMIN_USER" ] || [ "$USER" != "$ADMIN_USER" ]; then
        ## Not the admin user — silently no-op. Don't log; lots of
        ## password changes happen for system accounts and we'd spam
        ## syslog otherwise.
        exit 0
      fi

      ## Read the new password from stdin, capped at 4096 bytes
      ## (PAM authtok is documented as ≤ PAM_MAX_RESP_SIZE = 512 by
      ## default but we allow more for safety). head -c is binary-safe.
      NEW_PASS=$(head -c 4096)
      if [ -z "$NEW_PASS" ]; then
        logp "empty authtok received, skipping (perhaps prelim phase)"
        exit 0
      fi

      ## Read the long-lived PAT minted by zitadel-provision.service.
      ## If absent, the SSO bridge isn't fully provisioned yet — log
      ## and exit 0 so the local password change still succeeds.
      PAT_FILE="${pamSecretsDir}/pat"
      if [ ! -s "$PAT_FILE" ]; then
        logp "Zitadel PAT not provisioned at $PAT_FILE; skipping push for $USER"
        exit 0
      fi
      PAT=$(tr -d '[:space:]' < "$PAT_FILE")
      if [ -z "$PAT" ]; then
        logp "Zitadel PAT file is empty; skipping"
        exit 0
      fi

      SSO_URL="https://sso.${domain}"

      ## Look up the Zitadel user ID for $USER. With the
      ## userLoginMustBeDomain policy disabled (see
      ## services/zitadel-provision.nix step 3), the userName field
      ## matches the bare admin username.
      USER_LOOKUP=$(curl -fsS --max-time 10 \
        -H "Authorization: Bearer $PAT" \
        -H "Content-Type: application/json" \
        -X POST "$SSO_URL/management/v1/users/_search" \
        --data-raw "$(jq -nc --arg u "$USER" '{
          queries:[{userNameQuery:{userName:$u,method:"TEXT_QUERY_METHOD_EQUALS"}}]
        }')" 2>/dev/null)

      USER_ID=$(printf '%s' "''${USER_LOOKUP:-}" | jq -r '.result[0].id // empty' 2>/dev/null)
      if [ -z "$USER_ID" ]; then
        logp "Zitadel user lookup for '$USER' returned no match; skipping"
        exit 0
      fi

      ## Push the new password. Server-side hashes; we never persist
      ## the plaintext (this script's stdin is the only ephemeral copy).
      ##
      ## We pass the password via jq so newlines / quotes / shell
      ## metacharacters in the password don't blow up the JSON.
      HTTP_CODE=$(curl -sS --max-time 10 \
        -H "Authorization: Bearer $PAT" \
        -H "Content-Type: application/json" \
        -o /dev/null -w '%{http_code}' \
        -X POST "$SSO_URL/management/v1/users/$USER_ID/password" \
        --data-raw "$(jq -nc --arg p "$NEW_PASS" '{password:$p}')" \
        2>/dev/null || echo "000")

      if [ "$HTTP_CODE" -ge 200 ] && [ "$HTTP_CODE" -lt 300 ]; then
        logp "Zitadel password updated for $USER"
      else
        logp "Zitadel password update for $USER failed (HTTP $HTTP_CODE) — non-fatal"
      fi

      exit 0
    '';
  };
in
{
  options.homefree.sso.enable-pam-sync = lib.mkOption {
    type = lib.types.bool;
    default = true;
    description = ''
      Mirror local `passwd` changes to Zitadel via a PAM hook
      (pam_exec) so the OS admin user can use the same credentials for
      both shell login and SSO across all integrated services.

      Disable to keep the OS and Zitadel password stores independent.
    '';
  };

  config = lib.mkIf enabled {
    ## Insert our hook into the PAM password stack BEFORE pam_unix.
    ##
    ## pam_unix in the default NixOS passwd stack is `sufficient`, so a
    ## rule placed AFTER it would be skipped on success. Putting ours
    ## first guarantees it always runs. `optional` means a failure
    ## (Zitadel down, network partition, expired PAT) does not block
    ## the local password change — which is intentional.
    security.pam.services.passwd.rules.password.zitadel-sync = {
      control = "optional";
      modulePath = "${pkgs.pam}/lib/security/pam_exec.so";
      order =
        config.security.pam.services.passwd.rules.password.unix.order - 100;
      args = [
        "expose_authtok"
        "quiet"
        "${passwdToZitadel}/bin/passwd-to-zitadel"
      ];
    };

    ## /var/lib/homefree-admin already exists (admin-web.nix uses it
    ## via StateDirectory), but ensure it's there even when the admin
    ## backend is disabled in some weird config. Owned by root so the
    ## PAM hook (which runs as the original user via setuid passwd)
    ## can read it.
    systemd.tmpfiles.rules = [
      "d /var/lib/homefree-admin 0755 root root -"
    ];
  };
}
