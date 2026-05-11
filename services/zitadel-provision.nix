{ config, lib, pkgs, ... }:

## zitadel-provision.service — first-boot oneshot that takes a freshly
## initialised Zitadel instance and turns it into a fully working SSO
## backend for every HomeFree service that wants OIDC. Eliminates the
## "log into Zitadel UI and click around" step that used to be required
## before any other service could authenticate.
##
## What it does, in order:
##   1. Wait for Zitadel /debug/healthz to return 200.
##   2. Read the FirstInstance machine PAT from
##      /var/lib/zitadel/pat-bootstrap (created by Zitadel on first init
##      via ZITADEL_FIRSTINSTANCE_PATPATH — see services/zitadel-podman.nix).
##   3. Disable the org's `userLoginMustBeDomain` policy so users log
##      in as bare "<adminUsername>" instead of
##      "<adminUsername>@<orgdomain>".
##   4. Ensure a "homefree" project exists (idempotent).
##   5. For each service in the SERVICES table: create an OIDC
##      application if it doesn't exist, write client_id +
##      client_secret to /var/lib/homefree-secrets/<svc>/.
##   6. For services flagged needs_pat (NetBird): create a machine user
##      "<svc>-mgmt" with ORG_OWNER and write its PAT to the same dir.
##   7. Mint the homefree-pam-sync machine user + PAT for the PAM
##      password bridge (Phase 3 consumer).
##   8. Restart any units that were waiting on the new secrets.
##   9. Touch /var/lib/homefree-secrets/.sso-provisioned as the global
##      sentinel that other Nix modules use to flip oauth2 routing on.
##
## Idempotency: every step checks for existing state first (List + match
## by name). Re-running the unit is safe and a no-op when nothing has
## changed. Per-service errors are non-fatal — one bad app doesn't
## prevent the others from being provisioned.
##
## Failure modes:
##   - PAT file missing → exit 1, Restart=on-failure picks up next boot
##   - Zitadel unreachable → wait loop times out at 5 min, exit 1
##   - 4xx on a single service → log + skip, continue with others
##   - 5xx on a single service → retry up to 3× with backoff, then skip

let
  cfg = config.homefree;
  zitadelEnabled = cfg.service-options.zitadel.enable;
  domain = cfg.system.domain;

  ## We talk to Zitadel directly on its container port, not via Caddy.
  ## Two reasons: (1) Caddy serves a cert from "Caddy Local Authority"
  ## which isn't in the system trust store, so curl needs --insecure
  ## or a custom CA bundle to talk to https://sso.<domain>; (2) avoids
  ## a DNS round-trip to resolve sso.<domain> back to ourselves.
  ##
  ## Zitadel still validates the Host header against ZITADEL_EXTERNAL-
  ## DOMAIN, so we always set "Host: sso.<domain>" on every request.
  ## ssoHost is what we put in that header AND in OIDC issuer URLs we
  ## emit downstream; ssoOrigin is the actual origin we connect to.
  zitadelLanAddr = cfg.network.lan-address;
  zitadelPort = 3241;
  ssoHost = "sso.${domain}";
  ssoUrl = "http://${zitadelLanAddr}:${toString zitadelPort}";

  zitadelDataPath = "/var/lib/zitadel";
  patBootstrapFile = "${zitadelDataPath}/pat-bootstrap";
  secretsRoot = "/var/lib/homefree-secrets";
  zitadelSecretsDir = "${secretsRoot}/zitadel";
  pamSecretsDir = "${secretsRoot}/zitadel-pam";
  globalSentinel = "${secretsRoot}/.sso-provisioned";

  ## Service catalog — each entry produces one OIDC application in
  ## Zitadel and writes client_id/client_secret to that service's
  ## secrets dir. Entries with needs_pat=true also get a machine user
  ## with an ORG_OWNER PAT written to mgmt-machine-token.
  ##
  ## redirect_uris is rendered as a JSON array in the script.
  ##
  ## post_restart_units is the list of systemd units that should be
  ## try-restarted after their secrets are written so they pick up the
  ## new files. Using try-restart (not restart) means units that aren't
  ## currently running stay down — which is what we want when a service
  ## is disabled in the user's config.
  services = [
    {
      svc = "zitadel";
      internal_name = "homefree-oauth2proxy";
      app_type = "OIDC_APP_TYPE_WEB";
      auth_method = "OIDC_AUTH_METHOD_TYPE_POST";
      response_types = [ "OIDC_RESPONSE_TYPE_CODE" ];
      grant_types = [ "OIDC_GRANT_TYPE_AUTHORIZATION_CODE" "OIDC_GRANT_TYPE_REFRESH_TOKEN" ];
      redirect_uris = [ "https://auth.${domain}/oauth2/callback" ];
      post_logout_uris = [ "https://auth.${domain}/" ];
      needs_pat = false;
      post_restart_units = [ "podman-oauth2-proxy.service" ];
    }
    {
      svc = "headscale";
      internal_name = "homefree-headplane";
      app_type = "OIDC_APP_TYPE_WEB";
      auth_method = "OIDC_AUTH_METHOD_TYPE_POST";
      response_types = [ "OIDC_RESPONSE_TYPE_CODE" ];
      grant_types = [ "OIDC_GRANT_TYPE_AUTHORIZATION_CODE" "OIDC_GRANT_TYPE_REFRESH_TOKEN" ];
      redirect_uris = [ "https://vpn.${domain}/admin/oidc/callback" ];
      post_logout_uris = [ "https://vpn.${domain}/admin" ];
      needs_pat = false;
      post_restart_units = [ "headplane.service" ];
    }
    {
      svc = "netbird";
      internal_name = "homefree-netbird";
      ## NetBird dashboard is a SPA — Native/User-Agent app with PKCE,
      ## no client secret in the browser.
      app_type = "OIDC_APP_TYPE_USER_AGENT";
      auth_method = "OIDC_AUTH_METHOD_TYPE_NONE";
      response_types = [ "OIDC_RESPONSE_TYPE_CODE" ];
      grant_types = [ "OIDC_GRANT_TYPE_AUTHORIZATION_CODE" "OIDC_GRANT_TYPE_REFRESH_TOKEN" ];
      redirect_uris = [
        "https://netbird.${domain}/auth"
        "https://netbird.${domain}/silent-auth"
      ];
      post_logout_uris = [ "https://netbird.${domain}/" ];
      needs_pat = true;        # mgmt machine user for org/group reads
      post_restart_units = [ "podman-netbird-management.service" ];
    }
    {
      svc = "immich";
      internal_name = "homefree-immich";
      app_type = "OIDC_APP_TYPE_WEB";
      auth_method = "OIDC_AUTH_METHOD_TYPE_POST";
      response_types = [ "OIDC_RESPONSE_TYPE_CODE" ];
      grant_types = [ "OIDC_GRANT_TYPE_AUTHORIZATION_CODE" "OIDC_GRANT_TYPE_REFRESH_TOKEN" ];
      redirect_uris = [
        "https://photos.${domain}/auth/login"
        "https://immich.${domain}/auth/login"
        "app.immich:///oauth-callback"
      ];
      post_logout_uris = [ "https://photos.${domain}/" ];
      needs_pat = false;
      ## Immich applies OIDC config via its own admin REST API after the
      ## OIDC app exists. Restarting the container is harmless but not
      ## strictly required. The post-hook is invoked separately by
      ## services/immich-podman.nix in Phase 5.3.
      post_restart_units = [ ];
    }
    {
      svc = "nextcloud";
      internal_name = "homefree-nextcloud";
      app_type = "OIDC_APP_TYPE_WEB";
      auth_method = "OIDC_AUTH_METHOD_TYPE_POST";
      response_types = [ "OIDC_RESPONSE_TYPE_CODE" ];
      grant_types = [ "OIDC_GRANT_TYPE_AUTHORIZATION_CODE" "OIDC_GRANT_TYPE_REFRESH_TOKEN" ];
      redirect_uris = [ "https://nextcloud.${domain}/apps/user_oidc/code" ];
      post_logout_uris = [ "https://nextcloud.${domain}/" ];
      needs_pat = false;
      post_restart_units = [ "podman-nextcloud.service" ];
    }
    {
      svc = "forgejo";
      internal_name = "homefree-forgejo";
      app_type = "OIDC_APP_TYPE_WEB";
      auth_method = "OIDC_AUTH_METHOD_TYPE_POST";
      response_types = [ "OIDC_RESPONSE_TYPE_CODE" ];
      grant_types = [ "OIDC_GRANT_TYPE_AUTHORIZATION_CODE" "OIDC_GRANT_TYPE_REFRESH_TOKEN" ];
      redirect_uris = [ "https://git.${domain}/user/oauth2/Zitadel/callback" ];
      post_logout_uris = [ "https://git.${domain}/" ];
      needs_pat = false;
      post_restart_units = [ "podman-forgejo.service" ];
    }
  ];

  ## Render the services table as newline-delimited records. Each
  ## record is a "|"-separated tuple of fields; array-valued fields
  ## are joined with ";;" (a sequence that doesn't appear in any URL,
  ## app name, or Zitadel grant type identifier).
  ##
  ## Field order:
  ##   svc | internal_name | app_type | auth_method
  ##   | response_types (;;-joined) | grant_types | redirect_uris
  ##   | post_logout_uris | needs_pat (true/false)
  ##   | post_restart_units (;;-joined)
  joinUS = items: lib.concatStringsSep ";;" items;
  serviceRecord = s: lib.concatStringsSep "|" [
    s.svc
    s.internal_name
    s.app_type
    s.auth_method
    (joinUS s.response_types)
    (joinUS s.grant_types)
    (joinUS s.redirect_uris)
    (joinUS s.post_logout_uris)
    (if s.needs_pat then "true" else "false")
    (joinUS s.post_restart_units)
  ];
  serviceRecords = lib.concatStringsSep "\n" (map serviceRecord services);

  provisionScript = pkgs.writeShellApplication {
    name = "zitadel-provision";
    runtimeInputs = with pkgs; [
      curl jq coreutils gnused systemd openssl
    ];
    text = ''
      set -uo pipefail

      ## Internal endpoint we actually connect to (no TLS, no DNS).
      SSO_URL="${ssoUrl}"
      ## Host header value Zitadel validates against ZITADEL_EXTERNAL-
      ## DOMAIN. Must be set on every request.
      SSO_HOST="${ssoHost}"
      ## Public issuer (https://sso.<domain>) is baked into downstream
      ## OIDC client config in Phase 5; not referenced in this script
      ## yet, so we don't bind it as a shell var (shellcheck would flag
      ## SC2034 unused).
      PAT_BOOTSTRAP="${patBootstrapFile}"
      SECRETS_ROOT="${secretsRoot}"
      PAM_SECRETS="${pamSecretsDir}"
      GLOBAL_SENTINEL="${globalSentinel}"

      log() { printf '[zitadel-provision] %s\n' "$*" >&2; }
      die() { log "FATAL: $*"; exit 1; }
      warn() { log "WARN: $*"; }

      ## ── 1. Wait for Zitadel to be ready ────────────────────────────
      ## /debug/healthz returns 200 once the HTTP server + DB are up
      ## AND first-instance setup has completed. Cap the wait at 5 min
      ## (60 attempts × 5s) — beyond that something is genuinely wrong
      ## and we want systemd's Restart=on-failure to surface it.
      log "Waiting for Zitadel at $SSO_URL/debug/healthz (Host: $SSO_HOST) ..."
      for i in $(seq 1 60); do
        if curl -fsS -o /dev/null --max-time 5 \
             -H "Host: $SSO_HOST" \
             "$SSO_URL/debug/healthz"; then
          log "Zitadel is healthy (after $i attempt(s))"
          break
        fi
        if [ "$i" -eq 60 ]; then
          die "Zitadel did not become healthy within 5 minutes"
        fi
        sleep 5
      done

      ## ── 2. Read the FirstInstance machine PAT ──────────────────────
      ## Written by Zitadel on first init via ZITADEL_FIRSTINSTANCE_PATPATH.
      ## If absent the most likely cause is that the FirstInstance setup
      ## hasn't actually run yet (db wiped + masterkey rotated — see
      ## /var/lib/zitadel/) — exit 1 so systemd retries.
      if [ ! -s "$PAT_BOOTSTRAP" ]; then
        die "PAT bootstrap file missing or empty at $PAT_BOOTSTRAP — Zitadel may not have completed first-instance setup. Will retry."
      fi
      PAT="$(tr -d '[:space:]' < "$PAT_BOOTSTRAP")"
      [ -n "$PAT" ] || die "PAT bootstrap file is empty"

      ## Helper: call a Zitadel API endpoint with the bootstrap PAT.
      ## Args: METHOD, PATH (without leading slash), [JSON_BODY]
      ## Echoes the response body on success, returns non-zero on 4xx.
      ## Retries 5xx up to 3× with linear backoff. All retries / failures
      ## are logged.
      zit_api() {
        local method="$1" path="$2" body="''${3-}"
        local url="$SSO_URL/$path"
        local attempt http_code tmp
        tmp=$(mktemp)
        for attempt in 1 2 3; do
          if [ -n "$body" ]; then
            http_code=$(curl -sS -o "$tmp" -w '%{http_code}' \
              -X "$method" \
              -H "Host: $SSO_HOST" \
              -H "Authorization: Bearer $PAT" \
              -H "Content-Type: application/json" \
              --data-raw "$body" \
              "$url" || echo "000")
          else
            http_code=$(curl -sS -o "$tmp" -w '%{http_code}' \
              -X "$method" \
              -H "Host: $SSO_HOST" \
              -H "Authorization: Bearer $PAT" \
              "$url" || echo "000")
          fi
          if [ "$http_code" -ge 200 ] && [ "$http_code" -lt 300 ]; then
            cat "$tmp"
            rm -f "$tmp"
            return 0
          fi
          if [ "$http_code" -ge 400 ] && [ "$http_code" -lt 500 ]; then
            warn "$method $path → $http_code: $(head -c 500 "$tmp")"
            rm -f "$tmp"
            return 1
          fi
          warn "$method $path → $http_code (attempt $attempt/3), retrying ..."
          sleep $((attempt * 2))
        done
        rm -f "$tmp"
        return 1
      }

      ## Helper: idempotent file write with mode 0400. The provision
      ## script runs as root, so written files are owned by root.
      write_secret() {
        local path="$1" value="$2"
        install -m 600 -D /dev/null "$path"
        printf '%s' "$value" > "$path"
        chmod 400 "$path"
      }

      ## ── 3. Disable userLoginMustBeDomain ──────────────────────────
      ## So users log in as bare "<adminUsername>" instead of
      ## "<adminUsername>@<orgdomain>". The instance-default policy in
      ## v4.x already has these fields set to false out of the box;
      ## the PUT here is belt-and-suspenders for older versions and
      ## for explicitness. Zitadel returns 400 + "not changed" when
      ## the values are already the desired ones — that's a no-op
      ## success, NOT a failure. We swallow it.
      log "Setting domain policy: userLoginMustBeDomain=false"
      ## Use a manual curl here (instead of zit_api) so we can inspect
      ## the response body for the "not changed" sentinel before
      ## deciding whether to log a real warning.
      pol_body='{"userLoginMustBeDomain": false, "validateOrgDomains": false, "smtpSenderAddressMatchesInstanceDomain": false}'
      pol_tmp=$(mktemp)
      pol_code=$(curl -sS -o "$pol_tmp" -w '%{http_code}' \
        -X PUT \
        -H "Host: $SSO_HOST" \
        -H "Authorization: Bearer $PAT" \
        -H "Content-Type: application/json" \
        --data-raw "$pol_body" \
        "$SSO_URL/admin/v1/policies/domain" || echo "000")
      pol_resp=$(cat "$pol_tmp")
      rm -f "$pol_tmp"
      case "$pol_code" in
        2*)
          log "Domain policy updated"
          ;;
        400)
          ## v4.x signals "this would be a no-op" with the literal
          ## word "changed" in a "no/not …" context. Variants seen
          ## in the wild: "Organization Domain Policy has not been
          ## changed", "Domain Policy has not been changed",
          ## "Username not changed". Match both forms with a regex.
          if printf '%s' "$pol_resp" | grep -qiE "not (been )?changed"; then
            log "Domain policy already in desired state (no-op)"
          else
            warn "Domain policy update returned 400: $pol_resp"
            warn "Bare-username login may not work."
          fi
          ;;
        *)
          warn "Domain policy update returned $pol_code: $pol_resp"
          warn "Bare-username login may not work."
          ;;
      esac

      ## ── 3b. Rename the FirstInstance human user to bare username ──
      ## Belt-and-suspenders: even with DEFAULTINSTANCE_DOMAINPOLICY
      ## set, older Zitadel versions (and fresh-install timing
      ## quirks) can leave the FirstInstance user with a suffixed
      ## userName like "<adminUser>@<orgPrimaryDomain>". Detect and
      ## rename to bare. Idempotent — if it's already bare we skip.
      ADMIN_USER="${cfg.system.adminUsername}"
      log "Checking admin user '$ADMIN_USER' has bare-name login"

      ## Search for ANY user whose userName starts with "<admin>@" OR
      ## equals exactly "<admin>". Use a CONTAINS query because we
      ## don't know the exact suffix in advance (depends on the
      ## org's primary domain, which depends on the org name).
      admin_search=$(zit_api POST management/v1/users/_search "$(jq -nc \
        --arg u "$ADMIN_USER" '{
          queries:[{userNameQuery:{userName:$u,method:"TEXT_QUERY_METHOD_CONTAINS"}}]
        }')") || warn "Could not search for admin user"
      ## Pick the human user that matches. Skip machine users (they
      ## might have similar names).
      admin_id=$(printf '%s' "''${admin_search:-}" \
        | jq -r --arg u "$ADMIN_USER" '
            .result[]?
            | select(.userName == $u or (.userName | startswith($u + "@")))
            | select(.human != null)
            | .id' \
        | head -n1)
      admin_current_name=$(printf '%s' "''${admin_search:-}" \
        | jq -r --arg u "$ADMIN_USER" '
            .result[]?
            | select(.userName == $u or (.userName | startswith($u + "@")))
            | select(.human != null)
            | .userName' \
        | head -n1)

      if [ -z "$admin_id" ]; then
        warn "No human user matching '$ADMIN_USER' found in Zitadel."
        warn "PAM password sync will be a no-op until a user is created."
      elif [ "$admin_current_name" = "$ADMIN_USER" ]; then
        log "Admin user already has bare userName ($ADMIN_USER)"
      else
        log "Renaming admin user $admin_id from '$admin_current_name' to '$ADMIN_USER'"
        rename_tmp=$(mktemp)
        rename_code=$(curl -sS -o "$rename_tmp" -w '%{http_code}' \
          -X PUT \
          -H "Host: $SSO_HOST" \
          -H "Authorization: Bearer $PAT" \
          -H "Content-Type: application/json" \
          --data-raw "$(jq -nc --arg u "$ADMIN_USER" '{userName:$u}')" \
          "$SSO_URL/management/v1/users/$admin_id/username" || echo "000")
        case "$rename_code" in
          2*)
            log "Admin user renamed to bare '$ADMIN_USER'"
            ;;
          400)
            ## Same no-op-as-error pattern as the domain policy. See
            ## the comment in step 3 for the regex rationale.
            if grep -qiE "not (been )?changed|already" "$rename_tmp"; then
              log "Admin userName already '$ADMIN_USER' (no-op)"
            else
              warn "Username rename returned 400: $(cat "$rename_tmp")"
            fi
            ;;
          *)
            warn "Username rename returned $rename_code: $(cat "$rename_tmp")"
            ;;
        esac
        rm -f "$rename_tmp"
      fi

      ## ── 3c. Sync admin display name to homefree.system.adminDescription ──
      ## FirstInstance can leave the user with bootstrap defaults
      ## ("ZITADEL Admin") if the FIRSTNAME/LASTNAME env vars weren't
      ## set when the instance was first created (older deploys, or
      ## anyone who upgraded into the SSO branch). Patch it now so
      ## the OIDC `name` claim — which downstream services like
      ## Nextcloud, Forgejo, Immich use as the display name — matches
      ## what the user typed into the installer.
      ##
      ## Idempotent: we GET the profile first and skip the PUT if
      ## the current names already match the target.
      if [ -n "''${admin_id:-}" ]; then
        ADMIN_FIRST="${
          let
            desc = cfg.system.adminDescription;
            parts = lib.splitString " " desc;
          in
            if desc == "" then "Admin" else lib.head parts
        }"
        ADMIN_LAST="${
          let
            desc = cfg.system.adminDescription;
            parts = lib.splitString " " desc;
          in
            if (builtins.length parts) > 1
            then lib.concatStringsSep " " (lib.tail parts)
            else "Admin"
        }"
        ADMIN_DISPLAY="${cfg.system.adminDescription}"
        ## Empty adminDescription → fall back to the username.
        [ -z "$ADMIN_DISPLAY" ] && ADMIN_DISPLAY="$ADMIN_USER"

        profile_get=$(zit_api GET "management/v1/users/$admin_id" "" 2>/dev/null) || true
        cur_first=$(printf '%s' "''${profile_get:-}" | jq -r '.user.human.profile.firstName // ""')
        cur_last=$(printf '%s' "''${profile_get:-}" | jq -r '.user.human.profile.lastName // ""')

        if [ "$cur_first" = "$ADMIN_FIRST" ] && [ "$cur_last" = "$ADMIN_LAST" ]; then
          log "Admin profile already matches ('$ADMIN_FIRST $ADMIN_LAST')"
        else
          log "Updating admin profile: '$cur_first $cur_last' → '$ADMIN_FIRST $ADMIN_LAST'"
          profile_tmp=$(mktemp)
          profile_code=$(curl -sS -o "$profile_tmp" -w '%{http_code}' \
            -X PUT \
            -H "Host: $SSO_HOST" \
            -H "Authorization: Bearer $PAT" \
            -H "Content-Type: application/json" \
            --data-raw "$(jq -nc \
              --arg f "$ADMIN_FIRST" \
              --arg l "$ADMIN_LAST" \
              --arg d "$ADMIN_DISPLAY" \
              '{firstName:$f, lastName:$l, displayName:$d}')" \
            "$SSO_URL/management/v1/users/$admin_id/profile" || echo "000")
          case "$profile_code" in
            2*) log "Admin profile updated" ;;
            400)
              if grep -qiE "not (been )?changed|already" "$profile_tmp"; then
                log "Admin profile already up-to-date (no-op)"
              else
                warn "Profile update returned 400: $(cat "$profile_tmp")"
              fi
              ;;
            *) warn "Profile update returned $profile_code: $(cat "$profile_tmp")" ;;
          esac
          rm -f "$profile_tmp"
        fi
      fi

      ## ── 4. Ensure "homefree" project exists ───────────────────────
      log "Ensuring 'homefree' project exists"
      project_search=$(zit_api POST management/v1/projects/_search '{
        "queries": [
          {"nameQuery": {"name": "homefree", "method": "TEXT_QUERY_METHOD_EQUALS"}}
        ]
      }') || die "Failed to search for project"

      project_id=$(printf '%s' "$project_search" | jq -r '.result[0].id // empty')
      if [ -z "$project_id" ]; then
        log "Creating 'homefree' project"
        create_resp=$(zit_api POST management/v1/projects '{
          "name": "homefree",
          "projectRoleAssertion": false,
          "projectRoleCheck": false,
          "hasProjectCheck": false
        }') || die "Failed to create project"
        project_id=$(printf '%s' "$create_resp" | jq -r '.id')
      fi
      [ -n "$project_id" ] || die "Could not resolve project ID"
      log "Project ID: $project_id"

      ## ── 5. Provision per-service OIDC apps ────────────────────────
      ## The services table is hardcoded below as one record per line.
      ## Field separator: "|"; array fields are joined with ";;".
      services_table=$(cat <<'EOF'
${serviceRecords}
EOF
)

      ## Convert ";;"-joined string to a compact JSON array literal.
      ## Empty input produces "[]". sed handles the multi-char split
      ## reliably across mawk/gawk variants.
      to_json_array() {
        local joined="$1"
        if [ -z "$joined" ]; then
          echo "[]"
          return
        fi
        printf '%s' "$joined" \
          | sed 's/;;/\n/g' \
          | jq -R . \
          | jq -sc 'map(select(length>0))'
      }

      while IFS='|' read -r svc internal_name app_type auth_method \
                            resp_types_raw grant_types_raw \
                            redirect_uris_raw post_logout_raw \
                            needs_pat post_restart_raw; do
        [ -n "$svc" ] || continue

        log "──── $svc ($internal_name) ────"
        secrets_dir="$SECRETS_ROOT/$svc"
        mkdir -p "$secrets_dir"
        chmod 700 "$secrets_dir"

        ## (a) List existing apps in the project; reuse if present.
        app_search=$(zit_api POST "management/v1/projects/$project_id/apps/_search" '{
          "queries": [
            {"nameQuery": {"name": "'"$internal_name"'", "method": "TEXT_QUERY_METHOD_EQUALS"}}
          ]
        }') || { warn "$svc: app search failed, skipping"; continue; }

        app_id=$(printf '%s' "$app_search" | jq -r '.result[0].id // empty')
        client_id=$(printf '%s' "$app_search" | jq -r '.result[0].oidcConfig.clientId // empty')

        if [ -z "$app_id" ]; then
          ## Create the app.
          resp_types=$(to_json_array "$resp_types_raw")
          grant_types=$(to_json_array "$grant_types_raw")
          redirect_uris=$(to_json_array "$redirect_uris_raw")
          post_logout=$(to_json_array "$post_logout_raw")

          body=$(jq -nc \
            --arg name "$internal_name" \
            --arg appType "$app_type" \
            --arg authMethod "$auth_method" \
            --argjson redirectUris "$redirect_uris" \
            --argjson postLogoutUris "$post_logout" \
            --argjson responseTypes "$resp_types" \
            --argjson grantTypes "$grant_types" \
            '{
              name: $name,
              redirectUris: $redirectUris,
              postLogoutRedirectUris: $postLogoutUris,
              responseTypes: $responseTypes,
              grantTypes: $grantTypes,
              appType: $appType,
              authMethodType: $authMethod,
              version: "OIDC_VERSION_1_0",
              devMode: false,
              accessTokenType: "OIDC_TOKEN_TYPE_BEARER",
              accessTokenRoleAssertion: true,
              idTokenRoleAssertion: true,
              idTokenUserinfoAssertion: true
            }')

          create_resp=$(zit_api POST \
            "management/v1/projects/$project_id/apps/oidc" \
            "$body") || { warn "$svc: app create failed, skipping"; continue; }

          app_id=$(printf '%s' "$create_resp" | jq -r '.appId // .id')
          client_id=$(printf '%s' "$create_resp" | jq -r '.clientId // empty')
          client_secret=$(printf '%s' "$create_resp" | jq -r '.clientSecret // empty')
          log "$svc: created app $app_id (client_id=$client_id)"
        else
          log "$svc: app $app_id exists (client_id=$client_id)"
          ## Need a client_secret? Only if our on-disk copy is missing
          ## AND the app uses a confidential auth method. PKCE/native
          ## apps (NONE auth method) have no secret — that's expected.
          client_secret=""
          if [ "$auth_method" != "OIDC_AUTH_METHOD_TYPE_NONE" ] \
             && [ ! -s "$secrets_dir/oidc-client-secret" ]; then
            log "$svc: regenerating client_secret (no on-disk copy)"
            regen_resp=$(zit_api POST \
              "management/v1/projects/$project_id/apps/$app_id/oidc_config/_generate_client_secret" \
              '{}') || { warn "$svc: secret regen failed"; continue; }
            client_secret=$(printf '%s' "$regen_resp" | jq -r '.clientSecret // empty')
          fi
        fi

        ## (b) Persist client_id (always) and client_secret (if applicable).
        if [ -n "$client_id" ]; then
          write_secret "$secrets_dir/oidc-client-id" "$client_id"
        else
          warn "$svc: no client_id available, skipping write"
        fi

        if [ -n "$client_secret" ]; then
          write_secret "$secrets_dir/oidc-client-secret" "$client_secret"
        elif [ "$auth_method" = "OIDC_AUTH_METHOD_TYPE_NONE" ]; then
          ## Public client — write an empty file as a marker so consumers
          ## relying on `[ -f oidc-client-secret ]` still see "configured".
          write_secret "$secrets_dir/oidc-client-secret" ""
        fi

        ## (c) Machine user + PAT for services that need to read users/
        ## groups out of Zitadel (e.g. NetBird). Idempotent: skip if a
        ## token file already exists.
        if [ "$needs_pat" = "true" ] && [ ! -s "$secrets_dir/mgmt-machine-token" ]; then
          mu_name="$svc-mgmt"
          log "$svc: creating machine user '$mu_name' + PAT"

          mu_search=$(zit_api POST management/v1/users/_search "$(jq -nc \
            --arg u "$mu_name" \
            '{queries:[{userNameQuery:{userName:$u,method:"TEXT_QUERY_METHOD_EQUALS"}}]}')") \
            || { warn "$svc: machine-user search failed"; continue; }
          mu_id=$(printf '%s' "$mu_search" | jq -r '.result[0].id // empty')

          if [ -z "$mu_id" ]; then
            mu_create=$(zit_api POST management/v1/users/machine "$(jq -nc \
              --arg u "$mu_name" \
              '{userName:$u,name:$u,description:"HomeFree provision: \($u)",accessTokenType:"ACCESS_TOKEN_TYPE_BEARER"}')") \
              || { warn "$svc: machine-user create failed"; continue; }
            mu_id=$(printf '%s' "$mu_create" | jq -r '.userId')
          fi

          ## Add as ORG_OWNER (NetBird needs to enumerate users/groups).
          zit_api POST management/v1/orgs/me/members "$(jq -nc \
            --arg uid "$mu_id" \
            '{userId:$uid,roles:["ORG_OWNER"]}')" \
            >/dev/null 2>&1 || true   ## "already a member" is fine

          ## Mint PAT (long-lived).
          pat_resp=$(zit_api POST "management/v1/users/$mu_id/pats" '{
            "expirationDate": "2099-12-31T23:59:59Z"
          }') || { warn "$svc: PAT create failed"; continue; }
          mu_token=$(printf '%s' "$pat_resp" | jq -r '.token')
          [ -n "$mu_token" ] || { warn "$svc: PAT response had no token"; continue; }
          write_secret "$secrets_dir/mgmt-machine-token" "$mu_token"
          log "$svc: PAT written"
        fi

        ## (d) Service-specific extras
        if [ "$svc" = "netbird" ] \
           && [ ! -s "$secrets_dir/data-store-encryption-key" ]; then
          ## NetBird's at-rest encryption key isn't a Zitadel artifact;
          ## generate locally so management.json template substitution
          ## doesn't fail with an unset placeholder.
          write_secret "$secrets_dir/data-store-encryption-key" \
            "$(openssl rand -base64 32)"
        fi

        ## (e) Mark provisioned + (re)start consumers.
        ## We use `restart` (not `try-restart`) so units that were
        ## NEVER started (e.g. oauth2-proxy, which is rendered with
        ## autoStart=false and an ExecStartPre secrets check) come
        ## up the moment the secrets land. `restart` no-ops on
        ## already-stopped optional services because the unit doesn't
        ## exist (we swallow the resulting exit-5 error below).
        ##
        ## NOTE: `printf '%s\n'` (not '%s') is critical — `read`
        ## requires a newline to terminate the final record, so a
        ## single-element list silently drops the only entry without
        ## the trailing newline.
        touch "$secrets_dir/.provisioned"
        if [ -n "$post_restart_raw" ]; then
          while IFS= read -r unit; do
            [ -n "$unit" ] || continue
            log "$svc: restart $unit"
            systemctl restart "$unit" || \
              warn "$svc: restart $unit failed (unit may be disabled or not yet rendered)"
          done < <(printf '%s\n' "$post_restart_raw" | sed 's/;;/\n/g')
        fi

      done <<< "$services_table"

      ## ── 7. PAM password bridge machine user ───────────────────────
      ## A separate machine user with users.write scope so the PAM
      ## hook can update the OS admin user's password in Zitadel
      ## whenever they run `passwd`.
      if [ ! -s "$PAM_SECRETS/pat" ]; then
        log "Creating homefree-pam-sync machine user + PAT"
        mkdir -p "$PAM_SECRETS"
        chmod 700 "$PAM_SECRETS"

        mu_search=$(zit_api POST management/v1/users/_search '{
          "queries":[{"userNameQuery":{"userName":"homefree-pam-sync","method":"TEXT_QUERY_METHOD_EQUALS"}}]
        }') || warn "PAM-sync machine-user search failed"
        mu_id=$(printf '%s' "''${mu_search:-}" | jq -r '.result[0].id // empty')

        if [ -z "$mu_id" ]; then
          mu_create=$(zit_api POST management/v1/users/machine '{
            "userName":"homefree-pam-sync",
            "name":"homefree-pam-sync",
            "description":"HomeFree PAM password bridge",
            "accessTokenType":"ACCESS_TOKEN_TYPE_BEARER"
          }') || warn "PAM-sync machine-user create failed"
          mu_id=$(printf '%s' "''${mu_create:-}" | jq -r '.userId // empty')
        fi

        if [ -n "$mu_id" ]; then
          ## ORG_OWNER is broader than strictly needed (we only want
          ## users.write) but it's the simplest pre-defined role that
          ## includes user-password updates. A finer-grained role would
          ## need to be created via management/v1/projects/grants.
          zit_api POST management/v1/orgs/me/members "$(jq -nc \
            --arg uid "$mu_id" \
            '{userId:$uid,roles:["ORG_OWNER"]}')" >/dev/null 2>&1 || true

          pat_resp=$(zit_api POST "management/v1/users/$mu_id/pats" '{
            "expirationDate": "2099-12-31T23:59:59Z"
          }') || warn "PAM-sync PAT create failed"
          mu_token=$(printf '%s' "''${pat_resp:-}" | jq -r '.token // empty')
          if [ -n "$mu_token" ]; then
            write_secret "$PAM_SECRETS/pat" "$mu_token"
            log "PAM-sync PAT written to $PAM_SECRETS/pat"
          fi
        fi
      fi

      ## Stash the OS admin username so the PAM hook can scope itself
      ## to just that account (avoid reaching into Zitadel for `root`,
      ## `nobody`, etc.).
      mkdir -p /var/lib/homefree-admin
      printf '%s\n' "${cfg.system.adminUsername}" \
        > /var/lib/homefree-admin/admin-username
      chmod 644 /var/lib/homefree-admin/admin-username

      ## ── 9. Global sentinel ────────────────────────────────────────
      ## Phase 4 + Phase 6 nix modules read this file via
      ## builtins.pathExists to flip the admin UI's oauth2 gate on.
      ## Touched LAST so a partially-failed run doesn't enable SSO
      ## across all the services.
      touch "$GLOBAL_SENTINEL"
      log "Provisioning complete — sentinel: $GLOBAL_SENTINEL"
    '';
  };

in {
  config = lib.mkIf zitadelEnabled {
    systemd.services.zitadel-provision = {
      description = "Provision OIDC apps + machine users in Zitadel for HomeFree services";
      after = [ "podman-zitadel.service" "network-online.target" ];
      requires = [ "podman-zitadel.service" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${provisionScript}/bin/zitadel-provision";
        Restart = "on-failure";
        RestartSec = "30s";
        ## Cap retries: if Zitadel is fundamentally broken we don't
        ## want this unit eating CPU forever. After 5 failures within
        ## 10 minutes it stays down until manual intervention or reboot.
        StartLimitBurst = 5;
        StartLimitIntervalSec = 600;
      };
    };

    homefree.service-config = [
      {
        label = "zitadel-provision";
        name = "Zitadel Provisioning";
        project-name = "HomeFree";
        systemd-service-names = [ "zitadel-provision" ];
        admin.show = false;   # plumbing, not user-facing
        reverse-proxy.enable = false;
      }
    ];
  };
}
