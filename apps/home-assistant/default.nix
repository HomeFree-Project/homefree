## @TODOs
## - Look into HACS integration:
##   - https://community.home-assistant.io/t/installing-hacs-is-tricky-in-docker-but-the-documentation-is-very-straightforward-when-you-know-how-to-read/450283
## - Look into using packaged custom components:
##   - https://github.com/NixOS/nixpkgs/tree/nixos-24.11/pkgs/servers/home-assistant/custom-components
{ config, lib, pkgs, ... }:
let
  version = "2026.4";

  containerDataPath = "/var/lib/homeassistant";
  haSecretsDir = "/var/lib/homefree-secrets/home-assistant";
  port = 8123;
  domain = config.homefree.system.domain;
  adminUser = config.homefree.system.adminUsername;

  ## Anchors auto-generated secrets into encrypted /etc/nixos/secrets
  ## so they survive a restore — see lib/secrets-anchor.nix.
  anchor = import ../../lib/secrets-anchor.nix { inherit lib pkgs; };
  adminDescription = config.homefree.system.adminDescription or adminUser;

  ## ── Build the `homeassistant:` YAML block from homefree.system.*.
  ## Done in Nix (not in the heredoc) so the indentation of optional
  ## fields stays correct — HA's YAML parser is strict about 2-space
  ## indentation inside a top-level block and `lib.optionalString`
  ## inside a `''` heredoc loses leading whitespace.
  ##
  ## All of these are sourced from the system config the admin set
  ## during install (or later on the admin System page). HA reads
  ## this block on every restart and writes the values to
  ## .storage/core.config, so changing a value in admin → rebuild
  ## propagates to HA without any UI step.
  sys = config.homefree.system;
  cfg = config.homefree.service-options.home-assistant;
  haYamlLine = key: value: "  ${key}: ${value}";
  haOptionalLine = key: value:
    if value == null then "" else "  ${key}: ${value}\n";
  haCoreYaml = ''
    homeassistant:
    ${haYamlLine "time_zone" ''"${sys.timeZone}"''}
    ${haYamlLine "country" ''"${if sys.countryCode != null then sys.countryCode else "US"}"''}
    ${haYamlLine "unit_system" ''"${sys.unitSystem}"''}
  '' + haOptionalLine "latitude" (if sys.latitude != null then toString sys.latitude else null)
     + haOptionalLine "longitude" (if sys.longitude != null then toString sys.longitude else null)
     + haOptionalLine "elevation" (if sys.elevation != null then toString sys.elevation else null)
     + haOptionalLine "currency" (if sys.currency != null then ''"${sys.currency}"'' else null)
     + haOptionalLine "language" (if sys.language != null then ''"${sys.language}"'' else null);

  ## configuration.yaml shipped to the container as a template with
  ## placeholders. The auth_oidc client_id and client_secret are
  ## substituted at preStart from the on-disk OIDC creds written by
  ## zitadel-provision. Same pattern as netbird's management.json.tmpl.
  ##
  ## Sentinel-style placeholders (@@...@@) instead of `!secret` YAML
  ## refs because the auth_oidc component reads its config via voluptuous
  ## at integration-load time — the file must already contain the
  ## literal values, not !secret indirection.
  configTemplate = pkgs.writeText "configuration.yaml.tmpl" ''
    default_config:

    ## Core location/time settings, generated from homefree.system.*
    ## via `haCoreYaml` above. HA reads this on every restart and
    ## writes the resolved values into .storage/core.config.
    ${haCoreYaml}

    frontend:
      themes: !include_dir_merge_named themes

    automation: !include automations.yaml
    script: !include scripts.yaml
    scene: !include scenes.yaml
    group: !include groups.yaml

    http:
      use_x_forwarded_for: true
      ## HA expects trusted_proxies to be a YAML list, not a scalar.
      ## Caddy hits this container from the host's LAN IP. Without
      ## this, every X-Forwarded-For-bearing request gets 400.
      trusted_proxies:
        - ${config.homefree.network.lan-address}
      ## HA's inner brute-force protection is redundant when fronted
      ## by Caddy + Zitadel SSO (the only path to reach HA's auth
      ## endpoints), and it generates false-positive WARNING noise
      ## on every SSO login because auth_oidc's SPA opens a
      ## WebSocket before the bearer token is fully wired through,
      ## HA rejects the first WS hello, the SPA retries with a valid
      ## token. Each rejection logs a "ban" warning regardless of
      ## whether an actual ban triggered. Disabling stops the noise.
      ## Caddy + Zitadel remain the real defense.
      ip_ban_enabled: false

    ## SSO via the auth_oidc custom component
    ## (pkgs.home-assistant-custom-components.auth_oidc). Does a full
    ## OIDC dance from inside HA against Zitadel — no upstream-proxy
    ## header trust needed.
    ##
    ## Endpoints exposed by the component (relative to ROOT_URL):
    ##   GET /auth/oidc/redirect → bounce to Zitadel
    ##   GET /auth/oidc/callback → Zitadel returns the user here
    ##   GET /auth/oidc/welcome  → click-through "Sign in" page
    ##                             (we bypass via Caddy redirect)
    ##
    ## Caddy redirects `/`, `/onboarding.html`, and `/auth/authorize`
    ## to `/auth/oidc/redirect` when the request has no HA session
    ## cookie — see extraCaddyConfig in service-config below. End
    ## result: visiting ha.<domain> as a logged-out user bounces
    ## straight to Zitadel.
    auth_oidc:
      client_id: "@@OIDC_CLIENT_ID@@"
      client_secret: "@@OIDC_CLIENT_SECRET@@"
      discovery_url: "https://sso.${domain}/.well-known/openid-configuration"
      display_name: "HomeFree SSO"
      features:
        automatic_user_linking: true
        automatic_person_creation: true
        ## Skip the auth_oidc welcome page when other auth providers
        ## exist (HA's built-in homeassistant provider always does).
        ## With this, /auth/oidc/welcome sets the state cookie and
        ## immediately redirects to /auth/oidc/redirect → Zitadel.
        default_redirect: true
      claims:
        ## Zitadel sends `preferred_username` as the bare username
        ## (matches the OS account), `name` as the full display
        ## name, and `email` is standard.
        username: preferred_username
        display_name: name
      ## Role/group sync from Zitadel is intentionally NOT wired up.
      ## Zitadel's `urn:zitadel:iam:org:project:roles` claim is an
      ## object ({role: {org_id: org_domain}}) — auth_oidc requires
      ## a flat list and silently uses [] otherwise. Same Zitadel
      ## claim-shape gap that's blocking Forgejo group sync. Until
      ## a flat-list claim is published (via Zitadel Actions in
      ## the ID token, see TODOs), every SSO user lands as a
      ## regular HA user; admin is the OS-bootstrapped account
      ## created in postStart.
      network:
        ## auth_oidc has its own httpx client and doesn't use the
        ## Python `ssl.create_default_context()` system trust. Point
        ## it at the bundle we synthesize in preStart so Caddy's
        ## local CA root is trusted.
        tls_ca_path: /config/ca-bundle.crt

    ## Instance-provided YAML, e.g. household-specific integrations
    ## (opnsense, wake_on_lan, custom sensors). Inserted at column 0
    ## of the YAML output thanks to Nix indent-stripping; instance
    ## should provide top-level keys at column 0 in their own string.
    ${cfg.extraConfigYaml}
  '';

  ## auth_oidc custom component package — official Nextcloud-style
  ## OIDC integration for HA. We symlink its `custom_components/auth_oidc`
  ## subtree into the HA config dir at preStart.
  authOidcPkg = pkgs.home-assistant-custom-components.auth_oidc;

  ## HACS custom component (optional, gated by enable-hacs). Vendored
  ## locally because nixpkgs doesn't ship it. Once symlinked into
  ## /config/custom_components/hacs/, users add it via Settings →
  ## Devices → Add Integration → HACS to get a UI for installing
  ## community integrations and frontend cards.
  hacsPkg = pkgs.callPackage ./hacs.nix {};

  ## Strict-overlay YAML merger. Used by preStart to keep the entries
  ## declared in cfg.defaults always in sync with /nix/store/<x>/, while
  ## preserving any additional entries the user creates via HA's UI.
  ## See merge-ha-yaml.py for semantics. PyYAML is the only runtime
  ## dep; the script is small enough to keep as a writeShellScript
  ## wrapper around python3 + pyyaml on PATH.
  mergeYamlPython = pkgs.python3.withPackages (ps: [ ps.pyyaml ]);
  mergeYamlScript = pkgs.writeShellScript "merge-ha-yaml" ''
    set -eu
    exec ${mergeYamlPython}/bin/python3 ${./merge-ha-yaml.py} "$@"
  '';

  preStart = ''
    set -eu
    mkdir -p ${containerDataPath}/config
    mkdir -p ${containerDataPath}/config/custom_components
    mkdir -p ${haSecretsDir}

    ## ── Custom component symlink ───────────────────────────────────
    ## auth_oidc lives at <pkg>/custom_components/auth_oidc/. HA reads
    ## any /config/custom_components/<name>/ at startup, so symlinking
    ## the store path is enough.
    ln -sfn ${authOidcPkg}/custom_components/auth_oidc \
      ${containerDataPath}/config/custom_components/auth_oidc

    ## HACS: opt-in via enable-hacs. When the toggle flips to false,
    ## the symlink is removed; the dynamic state HACS wrote (downloaded
    ## integrations under /config/custom_components/<x>/, frontend
    ## cards under /config/www/community/) is left alone for the user
    ## to clean up if they want.
    ${if cfg.enable-hacs then ''
      ln -sfn ${hacsPkg}/custom_components/hacs \
        ${containerDataPath}/config/custom_components/hacs
    '' else ''
      [ -L ${containerDataPath}/config/custom_components/hacs ] && \
        rm -f ${containerDataPath}/config/custom_components/hacs
      true
    ''}

    ## Instance-provided custom_components packages. Each package
    ## exposes one or more <pkg>/custom_components/<domain>/ subtrees;
    ## symlink each one into /config/custom_components/<domain>/.
    ${lib.concatMapStringsSep "\n" (pkg: ''
      if [ -d "${pkg}/custom_components" ]; then
        for d in ${pkg}/custom_components/*; do
          n=$(basename "$d")
          ln -sfn "$d" ${containerDataPath}/config/custom_components/"$n"
        done
      fi
    '') cfg.customComponentPackages}

    ## ── configuration.yaml from template ───────────────────────────
    ## auth_oidc requires non-empty client_id/client_secret values; if
    ## the secret files aren't on disk yet (fresh install pre-
    ## zitadel-provision), use placeholder strings so HA still starts
    ## (auth_oidc init will log an error but won't crash HA). Once
    ## zitadel-provision lands the secrets and try-restarts us, the
    ## next start gets the real values.
    CID="PLACEHOLDER_AWAITING_PROVISION"
    CSEC="PLACEHOLDER_AWAITING_PROVISION"
    if [ -s ${haSecretsDir}/oidc-client-id ] \
       && [ -s ${haSecretsDir}/oidc-client-secret ]; then
      CID=$(cat ${haSecretsDir}/oidc-client-id)
      CSEC=$(cat ${haSecretsDir}/oidc-client-secret)
    fi
    ${pkgs.gnused}/bin/sed \
      -e "s|@@OIDC_CLIENT_ID@@|$CID|g" \
      -e "s|@@OIDC_CLIENT_SECRET@@|$CSEC|g" \
      ${configTemplate} \
      > ${containerDataPath}/config/configuration.yaml

    ## ── Include-file targets ───────────────────────────────────────
    ## configuration.yaml uses `!include` for these. If any are
    ## missing, HA fails YAML parsing and falls back to "recovery
    ## mode" (no trusted_proxies → all proxied requests get 400).
    ## Empty files = "no entries", which is what a fresh install
    ## wants anyway.
    ##
    ## Instance-provided `defaults`: strict-overlay merge of declarative
    ## entries into HA's UI-writable files. The merger replaces entries
    ## (by `id` for lists, by key for dicts) that exist in both defaults
    ## and target with the defaults' version. Target-only entries are
    ## preserved. First install (target doesn't exist) just copies the
    ## defaults straight in. Rule of thumb for users: if an automation
    ## (script, scene, group, device alias) lives in Nix, Nix owns it
    ## fully — UI edits to that entry get overwritten on rebuild. Move
    ## the entry out of Nix to make it UI-owned.
    ${lib.concatMapStringsSep "\n" (name: ''
      target="${containerDataPath}/config/${name}"
      defaults="${cfg.defaults.${name}}"
      if [ ! -e "$target" ]; then
        cp "$defaults" "$target"
        chmod u+w "$target"
      else
        tmp="$target.merge.$$"
        if ${mergeYamlScript} --target "$target" --defaults "$defaults" --output "$tmp"; then
          mv "$tmp" "$target"
          chmod u+w "$target"
        else
          rm -f "$tmp"
          echo "preStart: merge failed for ${name}, leaving target unchanged" >&2
        fi
      fi
    '') (lib.attrNames cfg.defaults)}

    for f in automations.yaml scripts.yaml scenes.yaml groups.yaml; do
      [ -f "${containerDataPath}/config/$f" ] || \
        touch "${containerDataPath}/config/$f"
    done

    ## ── Bootstrap admin password ───────────────────────────────────
    ## Random, never shown. Used via the onboarding API in postStart to
    ## satisfy HA's "an admin must exist" requirement and to re-auth
    ## after restarts; the user logs in via Zitadel. HA never mutates
    ## this file, so it is anchored into encrypted /etc/nixos/secrets
    ## (lib/secrets-anchor.nix) and re-materialized on restore.
    ${anchor.preamble}
    ${anchor.anchorSecret {
      service = "home-assistant";
      key = "admin-password";
      dir = haSecretsDir;
      generate = "${pkgs.openssl}/bin/openssl rand -base64 24";
    }}

    ${lib.optionalString cfg.enableSecretsFile ''
      ## ── secrets.yaml from on-disk secret files ────────────────────
      ## Generate /config/secrets.yaml from ${haSecretsDir}/secrets/
      ## (one file per secret key). HA's native `!secret <key>` syntax
      ## then resolves to these values inside any YAML (including the
      ## extraConfigYaml block). auth_oidc CANNOT use !secret — see the
      ## comment above the auth_oidc block — so it keeps the @@...@@
      ## sed pattern. Everything else (opnsense API keys, ilo password,
      ## etc.) should use !secret.
      secrets_dir=${haSecretsDir}/secrets
      if [ -d "$secrets_dir" ]; then
        : > ${containerDataPath}/config/secrets.yaml
        chmod 600 ${containerDataPath}/config/secrets.yaml
        for f in "$secrets_dir"/*; do
          [ -f "$f" ] || continue
          k=$(basename "$f")
          v=$(cat "$f")
          ## Quote the scalar; escape embedded double-quotes so
          ## values with " survive YAML parsing.
          printf '%s: "%s"\n' "$k" "''${v//\"/\\\"}" \
            >> ${containerDataPath}/config/secrets.yaml
        done
      fi
    ''}

    ## ── CA bundle for auth_oidc's HTTPS discovery fetch ────────────
    ## Caddy issues internal certs from a runtime-generated local CA
    ## that the HA container's Python doesn't trust. Same pattern as
    ## netbird/forgejo/immich.
    {
      cat /etc/ssl/certs/ca-certificates.crt
      if [ -r /var/lib/caddy/.local/share/caddy/pki/authorities/local/root.crt ]; then
        echo
        cat /var/lib/caddy/.local/share/caddy/pki/authorities/local/root.crt
      fi
    } > ${containerDataPath}/config/ca-bundle.crt
    chmod 644 ${containerDataPath}/config/ca-bundle.crt

    ## Instance-provided static directories (themes, blueprints,
    ## www/community for HACS-style frontend cards). On every rebuild
    ## we rm the target and re-copy from the Nix store source so the
    ## tree stays declarative. We COPY rather than symlink because
    ## HA's frontend uses aiohttp StaticResource with follow_symlinks
    ## off + a "stay within configured root" check; a symlink to
    ## /nix/store/<x>/<dir>/ resolves outside /config/www/ and aiohttp
    ## returns 404 even though the file is readable.
    ${lib.concatMapStringsSep "\n" (rel: ''
      mkdir -p "$(dirname ${containerDataPath}/config/${rel})"
      rm -rf "${containerDataPath}/config/${rel}"
      cp -aL "${cfg.staticDirs.${rel}}" "${containerDataPath}/config/${rel}"
      chmod -R u+w "${containerDataPath}/config/${rel}"
    '') (lib.attrNames cfg.staticDirs)}
  '';

  ## postStart bootstraps HA into a state where SSO is the ONLY login
  ## path. Two phases:
  ##
  ##   1. Wait for HA's API to be reachable.
  ##   2. If HA's onboarding flow hasn't been completed (no admin
  ##      exists in auth/data), drive it programmatically via the
  ##      onboarding API: create the admin user with the auto-
  ##      generated password, satisfy the "create person" step,
  ##      mark onboarding complete. After this HA is fully
  ##      initialized — auth_oidc-driven logins now create+link
  ##      new users automatically (features.automatic_user_linking).
  ##
  ## The local admin password is never shown to the user; it lives
  ## only on disk for emergency CLI recovery
  ## (`podman exec homeassistant python -m homeassistant ...`).
  postStart = pkgs.writeShellScript "homeassistant-poststart" ''
    set -u

    API="http://127.0.0.1:${toString port}/api"
    ONBOARD="http://127.0.0.1:${toString port}/api/onboarding"
    STORAGE_ONBOARDING="${containerDataPath}/config/.storage/onboarding"

    ## ── 0. Fast path: skip if onboarding already complete on disk ─
    ## HA persists onboarding state in .storage/onboarding as
    ##   {"data":{"done":["user","core_config","analytics","integration"]}}
    ## once each step finishes. If all four are present we have
    ## nothing to do — and crucially, no reason to do an HTTP
    ## handshake at all. Avoiding the HTTP path here is a 30-90s
    ## speedup on every rebuild after first install.
    if [ -s "$STORAGE_ONBOARDING" ] \
       && ${pkgs.jq}/bin/jq -e '
            .data.done as $d
            | ["user","core_config","analytics","integration"]
            | all(. as $s | $d | index($s))
          ' "$STORAGE_ONBOARDING" >/dev/null 2>&1; then
      echo "ha postStart: onboarding already complete on disk; skipping" >&2
      exit 0
    fi

    ## ── 1. Wait for HA to come up ──────────────────────────────────
    ## Only probe /api/onboarding (unauthenticated, returns 200 with a
    ## JSON list as soon as the HTTP server is up). The previous loop
    ## also probed /api/, which returns 401 unauthenticated — and HA's
    ## ban-on-failed-auth counter treats every 401 as a malicious
    ## attempt. After ~5 401s in quick succession HA banned 127.0.0.1
    ## and stopped responding to ANY endpoint, including this loop's
    ## onboarding probe, leading to a 120s timeout.
    for i in $(seq 1 60); do
      if ${pkgs.curl}/bin/curl -sf "$ONBOARD" >/dev/null 2>&1; then
        break
      fi
      [ "$i" = 60 ] && {
        echo "ha postStart: API not responsive after 120s" >&2
        exit 0
      }
      sleep 2
    done

    ## ── 2. Drive the onboarding flow if needed ─────────────────────
    ## /api/onboarding returns a list of steps with `done: true|false`.
    ## If all are done, skip. If `user` isn't done, POST to
    ## /api/onboarding/users with the auto-gen admin creds.
    STATE=$(${pkgs.curl}/bin/curl -sS "$ONBOARD" 2>/dev/null) || true
    USER_DONE=$(printf '%s' "''${STATE:-}" \
      | ${pkgs.jq}/bin/jq -r '.[] | select(.step=="user") | .done' 2>/dev/null \
      || echo "")

    ALL_DONE=$(printf '%s' "''${STATE:-}" \
      | ${pkgs.jq}/bin/jq -r 'all(.done)' 2>/dev/null || echo "")
    if [ "$ALL_DONE" = "true" ]; then
      echo "ha postStart: onboarding fully complete, nothing to do" >&2
      exit 0
    fi

    if [ ! -s ${haSecretsDir}/admin-password ]; then
      echo "ha postStart: admin-password not on disk; skipping onboarding" >&2
      exit 0
    fi
    ADMIN_PASS=$(cat ${haSecretsDir}/admin-password)

    ## Need an access_token. If the admin user is already created
    ## from a previous run, we can't replay /api/onboarding/users —
    ## that returns HTTP 403 once user step is done. Use the standard
    ## auth flow with the stored admin password instead.
    if [ "$USER_DONE" = "true" ]; then
      echo "ha postStart: user step already done; logging in to complete remaining steps" >&2
      FLOW=$(${pkgs.curl}/bin/curl -sS -X POST "http://127.0.0.1:${toString port}/auth/login_flow" \
        -H "Content-Type: application/json" \
        -d "$(${pkgs.jq}/bin/jq -nc '{client_id:"https://ha.${domain}/", handler:["homeassistant",null], redirect_uri:"https://ha.${domain}/"}')") || true
      FLOW_ID=$(printf '%s' "$FLOW" | ${pkgs.jq}/bin/jq -r '.flow_id // empty')
      if [ -z "$FLOW_ID" ]; then
        echo "ha postStart: failed to start login_flow; response: $FLOW" >&2
        exit 0
      fi
      LOGIN_RESP=$(${pkgs.curl}/bin/curl -sS -X POST "http://127.0.0.1:${toString port}/auth/login_flow/$FLOW_ID" \
        -H "Content-Type: application/json" \
        -d "$(${pkgs.jq}/bin/jq -nc \
          --arg c "https://ha.${domain}/" \
          --arg u "${adminUser}" \
          --arg p "$ADMIN_PASS" \
          '{client_id:$c, username:$u, password:$p}')") || true
      AUTH_CODE=$(printf '%s' "$LOGIN_RESP" | ${pkgs.jq}/bin/jq -r '.result // empty')
      if [ -z "$AUTH_CODE" ]; then
        echo "ha postStart: login_flow failed; response: $LOGIN_RESP" >&2
        exit 0
      fi
      ## Now exchange and mark remaining steps (jump to the exchange block below)
      RESP="{\"auth_code\":\"$AUTH_CODE\"}"
    else

    echo "ha postStart: creating admin user '${adminUser}' via onboarding API" >&2
    RESP=$(${pkgs.curl}/bin/curl -sS -X POST "$ONBOARD/users" \
      -H "Content-Type: application/json" \
      -d "$(${pkgs.jq}/bin/jq -nc \
        --arg n "${adminDescription}" \
        --arg u "${adminUser}" \
        --arg p "$ADMIN_PASS" \
        '{client_id:"https://ha.${domain}/", name:$n, username:$u, password:$p, language:"en"}')") \
      || true

    if ! printf '%s' "$RESP" | ${pkgs.jq}/bin/jq -e '.auth_code // .access_token' >/dev/null 2>&1; then
      echo "ha postStart: onboarding user creation may have failed; response:" >&2
      printf '%s\n' "$RESP" >&2
      exit 0
    fi
    echo "ha postStart: admin user created" >&2
    fi

    ## After user creation, HA wants the rest of onboarding marked
    ## done (core_config, integration, analytics). If we leave them
    ## undone, HA redirects every browser visit on / to
    ## /onboarding.html, breaking SSO. Need to mark them all done.
    ##
    ## /api/onboarding/users returns an auth_code; we exchange it for
    ## a bearer access_token via /auth/token, then POST each remaining
    ## step (which are all parameterless).
    AUTH_CODE=$(printf '%s' "$RESP" | ${pkgs.jq}/bin/jq -r '.auth_code // empty')
    if [ -z "$AUTH_CODE" ]; then
      echo "ha postStart: no auth_code in onboarding/users response; skipping remaining steps" >&2
      exit 0
    fi

    TOKEN_RESP=$(${pkgs.curl}/bin/curl -sS -X POST "http://127.0.0.1:${toString port}/auth/token" \
      -H "Content-Type: application/x-www-form-urlencoded" \
      --data-urlencode "client_id=https://ha.${domain}/" \
      --data-urlencode "grant_type=authorization_code" \
      --data-urlencode "code=$AUTH_CODE") || true
    ACCESS_TOKEN=$(printf '%s' "$TOKEN_RESP" | ${pkgs.jq}/bin/jq -r '.access_token // empty')
    if [ -z "$ACCESS_TOKEN" ]; then
      echo "ha postStart: failed to exchange auth_code for access_token; response:" >&2
      printf '%s\n' "$TOKEN_RESP" >&2
      exit 0
    fi

    for STEP in core_config analytics integration; do
      STEP_DONE=$(printf '%s' "''${STATE:-}" \
        | ${pkgs.jq}/bin/jq -r --arg s "$STEP" '.[] | select(.step==$s) | .done' 2>/dev/null \
        || echo "")
      if [ "$STEP_DONE" = "true" ]; then
        continue
      fi
      ## `integration` requires client_id + redirect_uri so HA can mint
      ## a fresh auth_code for the SPA. core_config and analytics take
      ## an empty body.
      case "$STEP" in
        integration)
          BODY='{"client_id":"https://ha.${domain}/","redirect_uri":"https://ha.${domain}/"}'
          ;;
        *)
          BODY='{}'
          ;;
      esac
      echo "ha postStart: marking onboarding step '$STEP' done" >&2
      ${pkgs.curl}/bin/curl -sS -o /dev/null -X POST "$ONBOARD/$STEP" \
        -H "Authorization: Bearer $ACCESS_TOKEN" \
        -H "Content-Type: application/json" \
        -d "$BODY" || echo "ha postStart: failed to mark $STEP" >&2
    done
    echo "ha postStart: all onboarding steps complete" >&2
  '';
  userOptions = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "enable Home Assistant Home Automation";
    };

    public = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Open to public on WAN port";
    };

    enable-hacs = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Install HACS (Home Assistant Community Store) for installing community integrations from the HA UI";
    };

    ## Extension points for instance configs. The base repo has no
    ## opinion on what specific integrations, automations, or custom
    ## components a household uses — instance config supplies all of
    ## those via these options.

    extraConfigYaml = lib.mkOption {
      type = lib.types.lines;
      default = "";
      description = ''
        Extra YAML appended verbatim to the generated configuration.yaml.
        Use this to declare integrations specific to this household
        (e.g. an opnsense block with !secret references, template
        sensors with hardware-specific entity_ids). Top-level YAML keys
        should start at column 0 in your string — the value is inserted
        at column 0 of the configuration.yaml after the standard core,
        frontend, http, and auth_oidc blocks.

        Secret values: use HA's native `!secret <key>` syntax. The
        `enableSecretsFile` option (default true) generates the
        backing secrets.yaml from /var/lib/homefree-secrets/home-assistant/secrets/.
      '';
    };

    customComponentPackages = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = [ ];
      description = ''
        List of Nix packages, each exposing one or more
        `custom_components/<domain>/` subtrees. preStart symlinks each
        domain directory into /var/lib/homeassistant/config/custom_components/<domain>/.

        For packages in nixpkgs, use
        `pkgs.home-assistant-custom-components.<name>`. For unpackaged
        components, write a local derivation that fetches the source
        and copies the relevant subtree (see auth_oidc as a template).
      '';
    };

    defaults = lib.mkOption {
      type = lib.types.attrsOf lib.types.path;
      default = { };
      description = ''
        Map of filename (relative to /config/) to a YAML defaults file.
        preStart strict-overlay-merges the defaults into the writable
        target on every rebuild:

        - First install (target missing): defaults copied verbatim.
        - Subsequent rebuilds: entries declared in defaults are
          re-asserted (replacing same-id/same-key entries in the
          target). Entries that exist only in the target are
          preserved.

        Use this for entries you want declaratively managed in Nix
        while still allowing HA's UI editors to add/remove other
        entries in the same file.

        Merge keys depend on file shape (auto-detected):
        - List of dicts with `id` (automations.yaml, scenes.yaml):
          matched by `id`.
        - Dict (scripts.yaml, groups.yaml, known_devices.yaml,
          customize.yaml): matched by top-level key.

        Rule of thumb for users: if an entry is declared in defaults,
        Nix owns it — UI edits to that exact entry get overwritten
        on the next rebuild. Move the entry out of defaults to make
        it UI-owned.
      '';
    };

    staticDirs = lib.mkOption {
      type = lib.types.attrsOf lib.types.path;
      default = { };
      description = ''
        Map of relative path (under /config/) to source directory path.
        preStart symlinks each entry into /config/<rel>/. Replaces any
        existing dir at the target on every rebuild — these are owned
        declaratively.

        Typical keys: "themes", "blueprints", "www/community" (for
        HACS-style frontend cards).
      '';
    };

    enableSecretsFile = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        If true, preStart writes /config/secrets.yaml from the contents
        of /var/lib/homefree-secrets/home-assistant/secrets/ — one file
        per secret key. HA's `!secret <key>` syntax then resolves to
        those values inside any YAML. (auth_oidc still requires the
        @@PLACEHOLDER@@ sed substitution pattern — see the auth_oidc
        comment above.)
      '';
    };
  };
in
{
  options.homefree.services.home-assistant = userOptions;
  options.homefree.service-options.home-assistant = userOptions // {
    label = lib.mkOption {
      type = lib.types.str;
      default = "home-assistant";
      internal = true;
      description = "Service label";
    };

    name = lib.mkOption {
      type = lib.types.str;
      default = "Home Assistant";
      internal = true;
      description = "Service display name";
    };

    project-name = lib.mkOption {
      type = lib.types.str;
      default = "Home Assistant";
      internal = true;
      description = "Project name";
    };
  };

  config = {
  virtualisation.oci-containers.containers = lib.optionalAttrs config.homefree.services.home-assistant.enable {
    homeassistant = {
      image = "ghcr.io/home-assistant/home-assistant:${version}";

      autoStart = true;

      extraOptions = [
        # "--pull=always"
        "--network=host"
        "--privileged"
      ];

      volumes = [
        "/etc/localtime:/etc/localtime:ro"
        "${containerDataPath}/config:/config"
        "/run/dbus:/run/dbus:ro"
        ## auth_oidc is symlinked from /config/custom_components/auth_oidc
        ## into the Nix store. Without /nix/store mounted, the symlink
        ## target is unreachable inside the container and Python can't
        ## import the module — `/auth/oidc/redirect` returns 404 and SSO
        ## silently doesn't work. Read-only mount is fine; the container
        ## just reads Python source files out of it.
        "/nix/store:/nix/store:ro"
      ];

      environment = {
        TZ = config.homefree.system.timeZone;
      };
    };
  };

  systemd.services.podman-homeassistant = lib.optionalAttrs config.homefree.services.home-assistant.enable {
    ## When Z-Wave JS UI is also enabled, prefer to start it first.
    ## `wants` (not `requires`) so HA still boots if Z-Wave is disabled
    ## or its container fails — HA's zwave_js config entry will retry
    ## once the WS server comes up.
    after = [ "dns-ready.service" ]
      ++ lib.optional (config.homefree.services.zwave-js-ui.enable or false) "podman-zwave-js-ui.service";
    wants = [ "dns-ready.service" ]
      ++ lib.optional (config.homefree.services.zwave-js-ui.enable or false) "podman-zwave-js-ui.service";
    serviceConfig = {
      ExecStartPre = [ "!${pkgs.writeShellScript "homeassistant-prestart" preStart}" ];
      ExecStartPost = [ "!${postStart}" ];
    };
  };

  homefree.service-config = lib.optionals config.homefree.services.home-assistant.enable [
    {
      inherit (config.homefree.service-options.home-assistant) label name project-name;
      systemd-service-names = [
        "podman-homeassistant"
      ];
      sso = {
        kind = "native_oidc";
        ## Dev context (intentionally not surfaced in the admin UI):
        ## Native OIDC via auth_oidc custom component.
        secrets-dir = "home-assistant";
      };
      reverse-proxy = {
        enable = config.homefree.service-options.home-assistant.enable;
        subdomains = [ "homeassistant" "ha" ];
        http-domains = [ "homefree.lan" config.homefree.system.localDomain ];
        https-domains = [ config.homefree.system.domain ];
        host = config.homefree.network.lan-address;
        port = port;
        public = config.homefree.services.home-assistant.public;
        ## Zero-click SSO redirect. Visiting ha.<domain> without an HA
        ## session lands on /onboarding.html (fresh install) or on
        ## HA's frontend SPA which then renders its own login form.
        ## Both paths get short-circuited to /auth/oidc/redirect which
        ## immediately bounces to Zitadel.
        ##
        ## Path-matchers are explicit (no /* glob) so static assets
        ## like /static/icons/favicon.ico don't get caught. After
        ## the OIDC dance lands the user back at /, HA's frontend
        ## takes over with a valid session cookie and these matchers
        ## don't fire (HA serves the SPA shell for both paths once
        ## authenticated).
        ##
        ## NOTE: top-level `redir` (not wrapped in route/handle) so
        ## Caddy's directive ordering puts it BEFORE the catch-all
        ## reverse_proxy handler. See feedback_caddy_ordering.md
        ## (homefree memory) for the lesson behind this — we hit
        ## the same trap on Forgejo's /user/login redirect.
        ## Only short-circuit the onboarding paths. DO NOT add
        ## /auth/authorize here — auth_oidc registers its own handler
        ## at /auth/authorize that base64-encodes the full HA-internal
        ## OAuth URL (client_id, redirect_uri, state) and forwards it
        ## to welcome via the `?redirect_uri=...` query param. The
        ## finish POST relies on that encoded redirect_uri to land the
        ## browser back in HA's first-party OAuth flow, where the
        ## session token gets minted. Bypassing the handler with a
        ## Caddy redir strips the OAuth params; welcome falls back to
        ## /?storeToken=true; finish redirects to /?storeToken=true&
        ## skip_oidc_redirect=true which doesn't trigger HA's auth
        ## flow → user lands on / with no session → frontend re-opens
        ## the auth dialog → /auth/authorize → injected handler runs
        ## (correctly this time, with proper params) → welcome → ...
        ## In other words: skipping the redir lets auth_oidc do its
        ## job once and the flow completes; adding the redir creates
        ## a loop because finish-time redirect_uri is wrong.
        extraCaddyConfig = ''
          @ha_login_paths path /onboarding.html /onboarding
          redir @ha_login_paths /auth/oidc/welcome 302
        '';
      };
      backup = {
        paths = [
          containerDataPath
        ];
      };
      options-metadata = [
        {
          path = "enable";
          type = "bool";
          default = false;
          description = "Enable Home Assistant Home Automation";
        }
        {
          path = "public";
          type = "bool";
          default = false;
          description = "Make service accessible from WAN";
        }
        {
          path = "enable-hacs";
          type = "bool";
          default = false;
          description = "Install HACS (Home Assistant Community Store) for installing community integrations from the HA UI";
        }
      ];
    }
  ];
  };
}
