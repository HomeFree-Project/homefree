{ config, lib, pkgs, ... }:

## Default username: zitadel-admin@zitadel.${config.homefree.system.domain}
## Default password: Password1!
##
## This module bundles Zitadel together with its companion oauth2-proxy.
## The two are always deployed as a pair — oauth2-proxy is the OIDC bridge
## that lets services that don't speak OIDC natively authenticate via
## Zitadel. Splitting them across files made cross-coupling (shared
## secrets, deploy-together gating) awkward, so they live together here.

let
  zitadelVersion = "v4.15.0";
  zitadelDataPath = "/var/lib/zitadel";
  zitadelPort = 3241;

  oauth2ProxyVersion = "v7.12.0";
  oauth2ProxyPort = 4180;
  oauth2ProxyEnvFile = "/var/lib/oauth2-proxy/env";

  zitadelPreStart = ''
    mkdir -p ${zitadelDataPath}
  '';

  # oauth2-proxy reads its three required secrets from per-secret files
  # under /var/lib/homefree-secrets/zitadel/ (written by the SOPS-managed
  # secrets pipeline driven by the admin UI's SSO entry). We synthesise
  # an env file at runtime rather than baking secrets into the unit.
  oauth2SecretsDir = "/var/lib/homefree-secrets/zitadel";
  oauth2ProxyPreStart = ''
    mkdir -p /var/lib/oauth2-proxy
    {
      if [ -s "${oauth2SecretsDir}/oauth2-cookie-secret" ]; then
        echo "OAUTH2_PROXY_COOKIE_SECRET=$(cat "${oauth2SecretsDir}/oauth2-cookie-secret")"
      fi
      if [ -s "${oauth2SecretsDir}/oauth2-client-id" ]; then
        echo "OAUTH2_PROXY_CLIENT_ID=$(cat "${oauth2SecretsDir}/oauth2-client-id")"
      fi
      if [ -s "${oauth2SecretsDir}/oauth2-client-secret" ]; then
        echo "OAUTH2_PROXY_CLIENT_SECRET=$(cat "${oauth2SecretsDir}/oauth2-client-secret")"
      fi
    } > "${oauth2ProxyEnvFile}"
    chmod 600 "${oauth2ProxyEnvFile}"
  '';

  zitadelEnabled = config.homefree.service-options.zitadel.enable;
  zitadelSecrets = config.homefree.service-options.zitadel.secrets;

  # Deploy oauth2-proxy only when zitadel is up AND all three OIDC
  # secrets are populated. Without the secrets the container exits
  # immediately with "missing setting: cookie-secret / client-id /
  # client-secret" and systemd loops it forever.
  oauth2ProxySecretsConfigured =
    (zitadelSecrets.oauth2-cookie-secret or null) != null
    && (zitadelSecrets.oauth2-client-id or null) != null
    && (zitadelSecrets.oauth2-client-secret or null) != null;
  deployOauth2Proxy = zitadelEnabled && oauth2ProxySecretsConfigured;
in
{
  options.homefree.service-options.zitadel = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "enable Zitadel service";
    };

    public = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Open to public on WAN port";
    };

    label = lib.mkOption {
      type = lib.types.str;
      default = "zitadel";
      internal = true;
      description = "Service label";
    };

    name = lib.mkOption {
      type = lib.types.str;
      default = "Single Sign-on (SSO)";
      internal = true;
      description = "Service display name";
    };

    project-name = lib.mkOption {
      type = lib.types.str;
      default = "Zitadel";
      internal = true;
      description = "Project name";
    };

    secrets = {
      env = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = "Path to env file with Zitadel master key (legacy).";
      };
      # OAuth2 Proxy secrets — surfaced under the SSO entry in the admin
      # UI. They live here (rather than under a separate oauth2-proxy
      # service-options namespace) because the two services are always
      # deployed together and the user shouldn't have to think about them
      # as separate config surfaces.
      oauth2-cookie-secret = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Random 32-byte secret used by OAuth2 Proxy to sign session cookies. Generate with: openssl rand -base64 32 | head -c 32";
      };
      oauth2-client-id = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "OAuth2 Proxy client ID (created in Zitadel as a confidential OIDC application).";
      };
      oauth2-client-secret = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "OAuth2 Proxy client secret (paired with the client ID above).";
      };
    };
  };

  config = {
    # ── Zitadel container ────────────────────────────────────────────────
    virtualisation.oci-containers.containers =
      (lib.optionalAttrs zitadelEnabled {
        zitadel = {
          image = "ghcr.io/zitadel/zitadel:${zitadelVersion}";

          autoStart = true;

          extraOptions = [
            # "--pull=always"
          ];

          ports = [
            "0.0.0.0:${toString zitadelPort}:8080"
          ];

          volumes = [
            "/etc/localtime:/etc/localtime:ro"
            "${zitadelDataPath}:/data"
          ];

          cmd = [
            "start-from-init"
            "--masterkeyFromEnv"
          ];

          environment = {
            TZ = config.homefree.system.timeZone;

            ZITADEL_DATABASE_POSTGRES_HOST = config.homefree.network.lan-address;
            ZITADEL_DATABASE_POSTGRES_PORT = "5432";
            ZITADEL_DATABASE_POSTGRES_DATABASE = "zitadel";
            ZITADEL_DATABASE_POSTGRES_USER_USERNAME = "zitadel";
            ZITADEL_DATABASE_POSTGRES_USER_PASSWORD = "zitadel";
            ZITADEL_DATABASE_POSTGRES_USER_SSL_MODE = "disable";
            ZITADEL_DATABASE_POSTGRES_ADMIN_USERNAME = "postgres";
            ZITADEL_DATABASE_POSTGRES_ADMIN_PASSWORD = "postgres";
            ZITADEL_DATABASE_POSTGRES_ADMIN_SSL_MODE = "disable";
            ZITADEL_FIRSTINSTANCE_ORG_HUMAN_USERNAME = "zitadel-admin@zitadel.${config.homefree.system.domain}";
            ZITADEL_FIRSTINSTANCE_ORG_HUMAN_PASSWORD = "Password1!";

            ZITADEL_EXTERNALDOMAIN = "sso.${config.homefree.system.domain}";
            ZITADEL_EXTERNALPORT = "443";
            ZITADEL_EXTERNALSECURE = "true";
            ZITADEL_TLS_ENABLED = "false";
          };

          environmentFiles = lib.optional
            (zitadelSecrets.env != null)
            zitadelSecrets.env;
        };
      })
      # ── OAuth2 Proxy container ──────────────────────────────────────
      // (lib.optionalAttrs deployOauth2Proxy {
        oauth2-proxy = {
          image = "oauth2-proxy/oauth2-proxy:${oauth2ProxyVersion}";

          autoStart = true;

          extraOptions = [
            # @TODO: Is host networking actually necessary?
            "--network=host"
          ];

          ports = [
            "0.0.0.0:${toString oauth2ProxyPort}:${toString oauth2ProxyPort}"
          ];

          volumes = [
            "/etc/localtime:/etc/localtime:ro"
          ];

          environment = {
            TZ = config.homefree.system.timeZone;
            OAUTH2_PROXY_PROVIDER = "oidc";
            OAUTH2_PROXY_OIDC_ISSUER_URL = "https://sso.${config.homefree.system.domain}";
            OAUTH2_PROXY_REDIRECT_URL = "https://auth.${config.homefree.system.domain}/oauth2/callback";
            OAUTH2_PROXY_EMAIL_DOMAINS = "*";
            OAUTH2_PROXY_COOKIE_DOMAINS = ".${config.homefree.system.domain}";
            OAUTH2_PROXY_WHITELIST_DOMAINS = ".${config.homefree.system.domain}";
            OAUTH2_PROXY_HTTP_ADDRESS = "0.0.0.0:${toString oauth2ProxyPort}";
            OAUTH2_PROXY_REVERSE_PROXY = "true";
            OAUTH2_PROXY_COOKIE_SECURE = "true";
            OAUTH2_PROXY_COOKIE_HTTPONLY = "true";
            OAUTH2_PROXY_SCOPE = "openid email profile";

            ## Needed to prevent Zitadel from blocking due to user-agent
            ## headers being different between proxy and upstream.
            OAUTH2_PROXY_PASS_USER_HEADERS = "true";
            OAUTH2_PROXY_SET_AUTHORIZATION_HEADER = "true";
          };

          # Env file is synthesised by the prestart from the SOPS-managed
          # secrets in /var/lib/homefree-secrets/zitadel/.
          environmentFiles = [ oauth2ProxyEnvFile ];
        };
      });

    # ── systemd unit overrides ───────────────────────────────────────────
    systemd.services.podman-zitadel = lib.optionalAttrs zitadelEnabled {
      after = [ "dns-ready.service" ];
      requires = [ "dns-ready.service" ];
      partOf = [ "nftables.service" ];
      serviceConfig = {
        ExecStartPre = [ "!${pkgs.writeShellScript "zitadel-prestart" zitadelPreStart}" ];
      };
    };

    systemd.services.podman-oauth2-proxy = lib.optionalAttrs deployOauth2Proxy {
      after = [ "dns-ready.service" ];
      requires = [ "dns-ready.service" ];
      partOf = [ "nftables.service" ];
      serviceConfig = {
        ExecStartPre = [ "!${pkgs.writeShellScript "oauth2-proxy-prestart" oauth2ProxyPreStart}" ];
      };
    };

    # ── service-config (admin UI surface) ────────────────────────────────
    # The SSO entry covers BOTH zitadel and oauth2-proxy units in its
    # systemd-service-names list. When oauth2-proxy is undeployed the UI
    # would otherwise mark SSO as Degraded (one missing unit), so we only
    # include oauth2-proxy in the watched list when we actually deployed
    # it. Reverse-proxy gets a separate entry per upstream subdomain.
    homefree.service-config = (lib.optionals zitadelEnabled [
      # User-facing SSO entry (Zitadel + the OAuth2 Proxy bundle).
      {
        inherit (config.homefree.service-options.zitadel) label name project-name;
        systemd-service-names = [ "podman-zitadel" ]
          ++ lib.optional deployOauth2Proxy "podman-oauth2-proxy";
        admin.show = true;
        reverse-proxy = {
          enable = zitadelEnabled;
          subdomains = [ "sso" "zitadel" ];
          http-domains = [ "homefree.lan" config.homefree.system.localDomain ];
          https-domains = [ config.homefree.system.domain ];
          host = config.homefree.network.lan-address;
          port = zitadelPort;
          public = config.homefree.service-options.zitadel.public;
        };
        backup = {
          paths = [ zitadelDataPath ];
          postgres-databases = [ "zitadel" ];
        };
        options-metadata = [
          {
            path = "enable";
            type = "bool";
            default = false;
            description = "Enable Zitadel auth service";
          }
          {
            path = "public";
            type = "bool";
            default = false;
            description = "Make service accessible from WAN";
          }
          {
            path = "secrets";
            type = "submodule";
            description = "OAuth2 Proxy credentials (paired with Zitadel for OIDC auth flows). All three must be set for the proxy to deploy.";
            sops-managed = true;
            submodule-fields = [
              {
                path = "oauth2-cookie-secret";
                type = "str";
                nullable = true;
                default = null;
                description = "Random 32-byte secret used by OAuth2 Proxy to sign session cookies. Generate with: openssl rand -base64 32 | head -c 32";
                sops-managed = true;
              }
              {
                path = "oauth2-client-id";
                type = "str";
                nullable = true;
                default = null;
                description = "OAuth2 Proxy client ID (created in Zitadel as a confidential OIDC application).";
                sops-managed = true;
              }
              {
                path = "oauth2-client-secret";
                type = "str";
                nullable = true;
                default = null;
                description = "OAuth2 Proxy client secret (paired with the client ID above).";
                sops-managed = true;
              }
            ];
          }
        ];
      }
    ]) ++ (lib.optionals deployOauth2Proxy [
      # Separate reverse-proxy entry for the auth.* subdomain — this is
      # plumbing, not a user-facing service row, so admin.show=false.
      {
        label = "oauth2proxy";
        name = "OAuth2 Proxy";
        project-name = "OAuth2 Proxy";
        systemd-service-names = [ "podman-oauth2-proxy" ];
        admin.show = false;
        reverse-proxy = {
          enable = true;
          subdomains = [ "auth" ];
          http-domains = [ "homefree.lan" config.homefree.system.localDomain ];
          https-domains = [ config.homefree.system.domain ];
          host = config.homefree.network.lan-address;
          port = oauth2ProxyPort;
          public = false;
        };
      }
    ]);
  };
}
