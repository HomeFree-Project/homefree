{ config, lib, pkgs, ... }:
let
  containerDataPath = "/var/lib/homebox-podman";
  secretsDir = "/var/lib/homefree-secrets/homebox";

  port = 7745;
  version = "0.25.0";

  domain = config.homefree.system.domain;
  ssoEnvFile = "${containerDataPath}/sso.env";

  ## preStart synthesizes Homebox's OIDC env file from the secrets
  ## zitadel-provision writes to disk. Homebox v0.25+ has native OIDC
  ## (HBOX_OIDC_AUTH_*). Same pattern as Ollama (services/ollama-
  ## podman.nix) — empty file pre-provisioning, populated once
  ## secrets land.
  ##
  ## Homebox doesn't have role propagation from OIDC claims, so we
  ## can't drive admin-vs-user from the homefree-admin role. All
  ## SSO-signed-in users are equal in Homebox; first user to sign in
  ## becomes the group owner, the rest join as regular members.
  preStart = ''
    mkdir -p ${containerDataPath}
    install -m 600 /dev/null ${ssoEnvFile}

    ## ── CA bundle for OIDC discovery ───────────────────────────────
    ## Homebox is a Go binary that fetches Zitadel's
    ## /.well-known/openid-configuration on startup. Caddy issues
    ## sso.<domain>'s cert from its internal local CA which the
    ## container's bundled trust store doesn't include. Same pattern
    ## as HA / Nextcloud / Forgejo / Immich: synthesize a combined
    ## bundle (system roots + Caddy's local root) and point Go at it
    ## via SSL_CERT_FILE.
    {
      cat /etc/ssl/certs/ca-certificates.crt
      if [ -r /var/lib/caddy/.local/share/caddy/pki/authorities/local/root.crt ]; then
        echo
        cat /var/lib/caddy/.local/share/caddy/pki/authorities/local/root.crt
      fi
    } > ${containerDataPath}/ca-bundle.crt
    chmod 644 ${containerDataPath}/ca-bundle.crt

    if [ -s ${secretsDir}/oidc-client-id ] \
       && [ -s ${secretsDir}/oidc-client-secret ]; then
      CID=$(cat ${secretsDir}/oidc-client-id)
      CSEC=$(cat ${secretsDir}/oidc-client-secret)
      ## Env var names per `homebox api --help` (HBOX_OIDC_*, NOT
      ## HBOX_OIDC_AUTH_*). Callback path is hardcoded by Homebox to
      ## /api/v1/users/oidc-callback — that's what we register in
      ## Zitadel below in services/zitadel-provision.nix.
      {
        echo "HBOX_OIDC_ENABLED=true"
        echo "HBOX_OIDC_CLIENT_ID=$CID"
        echo "HBOX_OIDC_CLIENT_SECRET=$CSEC"
        echo "HBOX_OIDC_ISSUER_URL=https://sso.${domain}"
        echo "HBOX_OIDC_BUTTON_TEXT=Sign in with HomeFree SSO"
        ## Zitadel emits roles under this namespaced claim, not the
        ## default `groups`.
        echo "HBOX_OIDC_GROUP_CLAIM=urn:zitadel:iam:org:project:roles"
        echo "HBOX_OIDC_SCOPE=openid profile email urn:zitadel:iam:org:project:roles"
        echo "HBOX_OIDC_NAME_CLAIM=name"
        echo "HBOX_OIDC_EMAIL_CLAIM=email"
        ## Hide Homebox's local username/password form. Only flipped
        ## ON here (inside the secrets-present branch) so a fresh
        ## install can still bootstrap via the local form before
        ## zitadel-provision lands. Once SSO is live, the local
        ## form would just confuse users.
        echo "HBOX_OPTIONS_ALLOW_LOCAL_LOGIN=false"
      } > ${ssoEnvFile}
    else
      ## Pre-provisioning: empty file so the container starts cleanly
      ## with only local-login enabled (HBOX_OIDC_ENABLED defaults
      ## false).
      : > ${ssoEnvFile}
    fi
    chmod 600 ${ssoEnvFile}
  '';

  userOptions = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "enable Homebox inventory management service";
    };

    disable-registration = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Disable user registration";
    };

    public = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Open to public on WAN port";
    };
  };
in
{
  options.homefree.services.homebox = userOptions;
  options.homefree.service-options.homebox = userOptions // {
    label = lib.mkOption {
      type = lib.types.str;
      default = "homebox";
      internal = true;
      description = "Service label";
    };

    name = lib.mkOption {
      type = lib.types.str;
      default = "Homebox";
      internal = true;
      description = "Service display name";
    };

    project-name = lib.mkOption {
      type = lib.types.str;
      default = "Homebox";
      internal = true;
      description = "Project name";
    };
  };

  config = {
    virtualisation.oci-containers.containers = lib.optionalAttrs config.homefree.service-options.homebox.enable {
    homebox = {
      image = "ghcr.io/sysadminsmedia/homebox:${version}";

      autoStart = true;

      extraOptions = [
        # "--pull=always"
      ];

      ports = [
        "0.0.0.0:${toString port}:7745"
      ];

      volumes = [
        "/etc/localtime:/etc/localtime:ro"
        "${containerDataPath}:/data"
        ## Mount our synthesized bundle (Caddy local CA + system
        ## roots) so the Go HTTP client trusts sso.<domain> when
        ## fetching OIDC discovery. Read-only.
        "${containerDataPath}/ca-bundle.crt:/etc/ssl/homefree-ca-bundle.crt:ro"
      ];

      environment = {
        TZ = config.homefree.system.timeZone;
        HBOX_WEB_MAX_FILE_UPLOAD = "50";
        HBOX_OPTIONS_ALLOW_ANALYTICS = "false";
        HBOX_OPTIONS_ALLOW_REGISTRATION = if config.homefree.service-options.homebox.disable-registration then "false" else "true";
        ## The public HOSTNAME (no scheme) Homebox uses when
        ## building its outgoing OIDC redirect_uri. Homebox prepends
        ## its own scheme — if we include `https://` here it'd
        ## render as `http://https://homebox.<domain>/...` which
        ## Zitadel rejects as unregistered.
        HBOX_OPTIONS_HOSTNAME = "homebox.${config.homefree.system.domain}";
        ## TRUST_PROXY=true makes Homebox honor X-Forwarded-Proto
        ## from Caddy when constructing its redirect_uri. Without
        ## this the redirect_uri scheme is hardcoded to http://.
        HBOX_OPTIONS_TRUST_PROXY = "true";
        ## Go honors SSL_CERT_FILE — point at our bundle so OIDC
        ## discovery against the Caddy-fronted Zitadel succeeds.
        SSL_CERT_FILE = "/etc/ssl/homefree-ca-bundle.crt";
      };
      ## OIDC env synthesized by preStart from Zitadel secrets.
      ## Empty file pre-provisioning; populated by zitadel-provision.
      environmentFiles = [ ssoEnvFile ];
    };
  };

  systemd.services.podman-homebox = lib.optionalAttrs config.homefree.service-options.homebox.enable {
    after = [ "dns-ready.service" ];
    wants = [ "dns-ready.service" ];
    serviceConfig = {
      ExecStartPre = [ "!${pkgs.writeShellScript "homebox-prestart" preStart}" ];
    };
  };

    homefree.service-config = [{
      inherit (config.homefree.service-options.homebox) label name project-name;
      systemd-service-names = [
        "podman-homebox"
      ];
      sso = {
        kind = "native_oidc";
        ## Dev context (intentionally not surfaced in the admin UI):
        ## Native OIDC. Homebox has no admin/user distinction — all
        ## SSO users are equal members.
      };
      reverse-proxy = {
        enable = config.homefree.service-options.homebox.enable;
        subdomains = [ "homebox" ];
        http-domains = [ "homefree.lan" config.homefree.system.localDomain ];
        https-domains = [ config.homefree.system.domain ];
        host = config.homefree.network.lan-address;
        port = port;
        public = config.homefree.service-options.homebox.public;
        ## Homebox v0.25+ has native OIDC (HBOX_OIDC_AUTH_* env
        ## vars synthesized by preStart from Zitadel secrets). Drop
        ## the Caddy outer gate so users see a single sign-in screen:
        ## Homebox's login page with a "Sign in with HomeFree SSO"
        ## button. Local login stays available (ALLOW_LOCAL=true)
        ## as an emergency escape hatch.
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
          description = "Enable Homebox inventory management";
        }
        {
          path = "public";
          type = "bool";
          default = false;
          description = "Make service accessible from WAN";
        }
        {
          path = "disable-registration";
          type = "bool";
          default = true;
          description = "Disable user registration";
        }
      ];
    }];
  };
}
