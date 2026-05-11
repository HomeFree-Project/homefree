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
  adminDescription = config.homefree.system.adminDescription or adminUser;

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
      network:
        ## auth_oidc has its own httpx client and doesn't use the
        ## Python `ssl.create_default_context()` system trust. Point
        ## it at the bundle we synthesize in preStart so Caddy's
        ## local CA root is trusted.
        tls_ca_path: /config/ca-bundle.crt
  '';

  ## auth_oidc custom component package — official Nextcloud-style
  ## OIDC integration for HA. We symlink its `custom_components/auth_oidc`
  ## subtree into the HA config dir at preStart.
  authOidcPkg = pkgs.home-assistant-custom-components.auth_oidc;

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
    for f in automations.yaml scripts.yaml scenes.yaml groups.yaml; do
      [ -f "${containerDataPath}/config/$f" ] || \
        touch "${containerDataPath}/config/$f"
    done

    ## ── Bootstrap admin password ───────────────────────────────────
    ## Random, never shown. Used exactly once via the onboarding API
    ## in postStart to satisfy HA's "an admin must exist" requirement,
    ## then the user logs in via Zitadel and this password becomes
    ## dead config.
    if [ ! -s ${haSecretsDir}/admin-password ]; then
      ${pkgs.openssl}/bin/openssl rand -base64 24 \
        > ${haSecretsDir}/admin-password
      chmod 600 ${haSecretsDir}/admin-password
    fi

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

    ## ── 1. Wait for HA to come up ──────────────────────────────────
    for i in $(seq 1 60); do
      if ${pkgs.curl}/bin/curl -sf "$API/" >/dev/null 2>&1 \
         || ${pkgs.curl}/bin/curl -sf "$ONBOARD" >/dev/null 2>&1; then
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

    if [ "$USER_DONE" = "true" ]; then
      echo "ha postStart: onboarding already complete, nothing to do" >&2
      exit 0
    fi

    if [ ! -s ${haSecretsDir}/admin-password ]; then
      echo "ha postStart: admin-password not on disk; skipping onboarding" >&2
      exit 0
    fi
    ADMIN_PASS=$(cat ${haSecretsDir}/admin-password)

    echo "ha postStart: creating admin user '${adminUser}' via onboarding API" >&2
    RESP=$(${pkgs.curl}/bin/curl -sS -X POST "$ONBOARD/users" \
      -H "Content-Type: application/json" \
      -d "$(${pkgs.jq}/bin/jq -nc \
        --arg n "${adminDescription}" \
        --arg u "${adminUser}" \
        --arg p "$ADMIN_PASS" \
        '{client_id:"https://ha.${domain}/", name:$n, username:$u, password:$p, language:"en"}')") \
      || true

    if printf '%s' "$RESP" | ${pkgs.jq}/bin/jq -e '.auth_code // .access_token' >/dev/null 2>&1; then
      echo "ha postStart: admin user created" >&2
    else
      echo "ha postStart: onboarding user creation may have failed; response:" >&2
      printf '%s\n' "$RESP" >&2
    fi

    ## After user creation, HA wants the rest of onboarding marked
    ## done (core_config, integration, analytics). Each is a POST
    ## to /api/onboarding/<step> with an auth bearer token. For our
    ## headless-SSO purposes we don't strictly need to complete them
    ## — HA stays usable and the SSO path works the moment the user
    ## record exists. The wizard re-runs on next browser visit if
    ## these aren't marked done, but our Caddy redirect bypasses it.
  '';
in
{
  options.homefree.service-options.home-assistant = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "enable Home Assistant service";
    };

    public = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Open to public on WAN port";
    };

    label = lib.mkOption {
      type = lib.types.str;
      default = "homeassistant";
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
  virtualisation.oci-containers.containers = lib.optionalAttrs config.homefree.services.homeassistant.enable {
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

  systemd.services.podman-homeassistant = lib.optionalAttrs config.homefree.services.homeassistant.enable {
    after = [ "dns-ready.service" ];
    requires = [ "dns-ready.service" ];
    partOf =  [ "nftables.service" ];
    serviceConfig = {
      ExecStartPre = [ "!${pkgs.writeShellScript "homeassistant-prestart" preStart}" ];
      ExecStartPost = [ "!${postStart}" ];
    };
  };

  homefree.service-config = lib.optionals config.homefree.services.homeassistant.enable [
    {
      inherit (config.homefree.service-options.home-assistant) label name project-name;
      systemd-service-names = [
        "podman-homeassistant"
      ];
      reverse-proxy = {
        enable = config.homefree.service-options.home-assistant.enable;
        subdomains = [ "homeassistant" "ha" ];
        http-domains = [ "homefree.lan" config.homefree.system.localDomain ];
        https-domains = [ config.homefree.system.domain ];
        host = config.homefree.network.lan-address;
        port = port;
        public = config.homefree.services.homeassistant.public;
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
        extraCaddyConfig = ''
          @ha_login_paths path /onboarding.html /onboarding /auth/authorize
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
      ];
    }
  ];
  };
}
