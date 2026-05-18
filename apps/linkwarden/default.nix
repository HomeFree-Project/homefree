{ config, lib, pkgs, ... }:
let
  version = "v2.14.1";
  version-meili = "v1.43.0";
  containerDataPath = "/var/lib/linkwarden-podman";
  secretsDir = "/var/lib/homefree-secrets/linkwarden";

  port = 3005;
  database-name = "linkwarden";
  database-user = "linkwarden";

  domain = config.homefree.system.domain;
  ssoEnvFile = "${containerDataPath}/sso.env";
  baseEnvFile = "${containerDataPath}/runtime.env";

  ## Linkwarden is a Next.js / NextAuth app. Its OIDC provider list
  ## is feature-flagged at build time via NEXT_PUBLIC_* env vars; the
  ## "Sign in with HomeFree SSO" button only renders when
  ## NEXT_PUBLIC_ZITADEL_ENABLED=true is in the env at container boot.
  ## Callback path is hardcoded by NextAuth: /api/v1/auth/callback/<provider>.
  ##
  ## Admin role propagation: Linkwarden has no OIDC->admin claim
  ## mapping. First-user-in-DB becomes admin; subsequent users are
  ## regular users. SSO authenticates identity only — same shape as
  ## Vaultwarden.
  preStart = ''
    mkdir -p ${containerDataPath}/linkwarden
    mkdir -p ${containerDataPath}/meili
    mkdir -p ${secretsDir}

    ## Synthesize combined CA bundle (Caddy local CA + system roots)
    ## so the Node.js HTTP client trusts sso.<domain> when fetching
    ## OIDC discovery. NODE_EXTRA_CA_CERTS appends to Node's bundled
    ## roots — the recommended way to extend trust without replacing
    ## the default Mozilla cert list.
    {
      cat /etc/ssl/certs/ca-certificates.crt
      if [ -r /var/lib/caddy/.local/share/caddy/pki/authorities/local/root.crt ]; then
        echo
        cat /var/lib/caddy/.local/share/caddy/pki/authorities/local/root.crt
      fi
    } > ${containerDataPath}/ca-bundle.crt
    chmod 644 ${containerDataPath}/ca-bundle.crt

    ## Auto-generate NEXTAUTH_SECRET on first boot. NextAuth uses this
    ## to sign session JWTs — rotating it logs every user out, so we
    ## persist it. 32 bytes of base64-encoded entropy is what NextAuth
    ## recommends.
    if [ ! -s ${secretsDir}/nextauth-secret ]; then
      ${pkgs.openssl}/bin/openssl rand -base64 32 \
        | tr -d '\n' > ${secretsDir}/nextauth-secret
      chmod 600 ${secretsDir}/nextauth-secret
    fi

    install -m 600 /dev/null ${baseEnvFile}
    {
      echo "NEXTAUTH_SECRET=$(cat ${secretsDir}/nextauth-secret)"
    } > ${baseEnvFile}

    ## OIDC env synthesized from zitadel-provision secrets. Empty file
    ## pre-provisioning so the container boots cleanly with only the
    ## local credentials flow visible until SSO is wired.
    install -m 600 /dev/null ${ssoEnvFile}
    if [ -s ${secretsDir}/oidc-client-id ] \
       && [ -s ${secretsDir}/oidc-client-secret ]; then
      CID=$(cat ${secretsDir}/oidc-client-id)
      CSEC=$(cat ${secretsDir}/oidc-client-secret)
      {
        echo "NEXT_PUBLIC_ZITADEL_ENABLED=true"
        echo "ZITADEL_CUSTOM_NAME=HomeFree SSO"
        echo "ZITADEL_ISSUER=https://sso.${domain}"
        echo "ZITADEL_CLIENT_ID=$CID"
        echo "ZITADEL_CLIENT_SECRET=$CSEC"
        ## Hide the email/password form. Only set when SSO secrets
        ## are present so first boot can still bootstrap the initial
        ## admin via local creds if needed.
        echo "NEXT_PUBLIC_CREDENTIALS_ENABLED=false"
        echo "NEXT_PUBLIC_DISABLE_REGISTRATION=true"
      } > ${ssoEnvFile}
    else
      : > ${ssoEnvFile}
    fi
    chmod 600 ${ssoEnvFile}
  '';

  userOptions = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "enable Linkwarden bookmarks service";
    };

    public = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Open to public on WAN port";
    };

    secrets = {
      environment = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = "Location of Linkwarden environment variables file. Should not be a file included in your source repo.";
      };
    };
  };
in
{
  options.homefree.services.linkwarden = userOptions;
  options.homefree.service-options.linkwarden = userOptions // {
    label = lib.mkOption {
      type = lib.types.str;
      default = "linkwarden";
      internal = true;
      description = "Service label";
    };

    name = lib.mkOption {
      type = lib.types.str;
      default = "linkwarden";
      internal = true;
      description = "Service display name";
    };

    project-name = lib.mkOption {
      type = lib.types.str;
      default = "linkwarden";
      internal = true;
      description = "Project name";
    };
  };

  config = {
  ## Copied from nixpkgs
  services.postgresql = lib.optionalAttrs config.homefree.service-options.linkwarden.enable {
    enable = true;
    ensureDatabases = [ database-name ];
    ensureUsers = [
      {
        name = database-user;
        ensureDBOwnership = true;
        ensureClauses.login = true;
      }
    ];
  };


  virtualisation.oci-containers.containers = lib.optionalAttrs config.homefree.service-options.linkwarden.enable {
    linkwarden = {
      image = "ghcr.io/linkwarden/linkwarden:${version}";

      dependsOn = [
        "meilisearch"
      ];

      autoStart = true;

      extraOptions = [
        # "--pull=always"
      ];

      ports = [
        "0.0.0.0:${toString port}:3000"
      ];

      volumes = [
        "/etc/localtime:/etc/localtime:ro"
        "${containerDataPath}/linkwarden:/data/data"
        "/run/postgresql:/run/postgresql"
        ## Mount the synthesized CA bundle (Caddy local CA + system
        ## roots) so Node's HTTP client trusts sso.<domain>.
        "${containerDataPath}/ca-bundle.crt:/etc/ssl/homefree-ca-bundle.crt:ro"
      ];

      environment = {
        TZ = config.homefree.system.timeZone;
        DATABASE_URL = "postgresql://${database-user}@${config.homefree.network.lan-address}:5432/${database-name}";
        ## NextAuth needs its absolute base URL to construct the
        ## redirect_uri it registers with Zitadel. /api/v1/auth is
        ## Linkwarden's NextAuth mount point — same for all providers.
        NEXTAUTH_URL = "https://linkwarden.${domain}/api/v1/auth";
        ## Caddy terminates TLS upstream of Linkwarden — the actual
        ## request to the container is plain HTTP. Without
        ## AUTH_TRUST_HOST=true, NextAuth ignores the
        ## X-Forwarded-Proto/Host headers Caddy sets and treats the
        ## incoming request as http://10.1.2.1:3005. That mismatch
        ## between what NextAuth thinks the origin is on the initial
        ## redirect (http) and what it thinks on the callback (also
        ## http but the browser is on https) breaks the __Secure-
        ## prefixed state cookie — the symptom is "State cookie was
        ## missing" + error=OAuthCallback on every SSO attempt.
        AUTH_TRUST_HOST = "true";
        ## Node honors NODE_EXTRA_CA_CERTS to append CAs to its
        ## bundled root store — required so OIDC discovery against
        ## Caddy's local-CA-issued sso.<domain> cert validates.
        NODE_EXTRA_CA_CERTS = "/etc/ssl/homefree-ca-bundle.crt";
      };

      ## runtime.env carries the persistent NEXTAUTH_SECRET; sso.env
      ## carries the Zitadel client + feature flags (empty until
      ## zitadel-provision lands the secrets).
      environmentFiles = [ baseEnvFile ssoEnvFile ]
        ++ lib.optional
          (config.homefree.service-options.linkwarden.secrets.environment or null != null)
          config.homefree.service-options.linkwarden.secrets.environment;
    };

    meilisearch = {
      image = "getmeili/meilisearch:${version-meili}";

      autoStart = true;

      extraOptions = [
        # "--pull=always"
      ];

      volumes = [
        "/etc/localtime:/etc/localtime:ro"
        "${containerDataPath}/meili:/meili_data"
      ];

      environment = {
        TZ = config.homefree.system.timeZone;
      };
    };

  };

  systemd.services.podman-linkwarden = lib.optionalAttrs config.homefree.service-options.linkwarden.enable {
    after = [ "dns-ready.service" ];
    requires = [ "dns-ready.service" ];
    serviceConfig = {
      ExecStartPre = [ "!${pkgs.writeShellScript "linkwarden-prestart" preStart}" ];
    };
  };

  systemd.services.podman-meilisearch = lib.optionalAttrs config.homefree.service-options.linkwarden.enable {
    after = [ "dns-ready.service" ];
    requires = [ "dns-ready.service" ];
    serviceConfig = {
      ExecStartPre = [ "!${pkgs.writeShellScript "meili-prestart" preStart}" ];
    };
  };

    homefree.service-config = [{
      inherit (config.homefree.service-options.linkwarden) label name project-name;
      systemd-service-names = [
        "podman-linkwarden"
        "podman-meilisearch"
        "postgresql"
      ];
      sso = {
        kind = "native_oidc";
        notes = "Native OIDC via NextAuth. No OIDC->admin role mapping: first user in DB is admin, subsequent SSO users are regular.";
      };
      reverse-proxy = {
        enable = config.homefree.service-options.linkwarden.enable;
        subdomains = [ "links" "linkwarden" ];
        http-domains = [ "homefree.lan" config.homefree.system.localDomain ];
        https-domains = [ config.homefree.system.domain ];
        host = config.homefree.network.lan-address;
        port = port;
        public = config.homefree.service-options.linkwarden.public;
        ## Workaround for linkwarden/linkwarden#1422: NextAuth's
        ## outgoing redirect_uri is built against /api/auth/callback/...
        ## (the NextAuth default base) and ignores Linkwarden's actual
        ## /api/v1/auth basePath. The no-v1 path is a 404 on the
        ## upstream — so the OAuth provider's callback redirect dead-
        ## ends. Rewrite inbound /api/auth/* to /api/v1/auth/* so the
        ## callback reaches the real NextAuth handler. Zitadel still
        ## sees the no-v1 URI as the registered redirect_uri (matches
        ## what the SDK emits).
        extraCaddyConfig = ''
          @nextauth_callback path /api/auth/*
          uri @nextauth_callback replace /api/auth/ /api/v1/auth/
        '';
      };
      backup = {
        paths = [
          "${containerDataPath}/linkwaren"
        ];
        postgres-databases = [
          database-name
        ];
      };
      options-metadata = [
        {
          path = "enable";
          type = "bool";
          default = false;
          description = "Enable Linkwarden bookmarks service";
        }
        {
          path = "public";
          type = "bool";
          default = false;
          description = "Make service accessible from WAN";
        }
      ];
    }];
  };
}
