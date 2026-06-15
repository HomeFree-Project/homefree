{ config, lib, pkgs, ... }:
let
  containerDataPath = "/var/lib/homebox-podman";
  secretsDir = "/var/lib/homefree-secrets/homebox";

  ## Anchor the generated API-key pepper into /etc/nixos/secrets so it
  ## survives a restore (rotating it invalidates all issued API keys).
  anchor = import ../../lib/secrets-anchor.nix { inherit lib pkgs; };

  port = config.homefree.allocPort "homebox";
  version = "0.26.2";

  domain = config.homefree.system.domain;
  ssoEnvFile = "${containerDataPath}/sso.env";

  ## Homebox is a single Go binary listening on 7745 (non-privileged).
  ## No CAP_NET_BIND_SERVICE required.
  homeboxUid = 807;
  homeboxGid = 807;

  enable = config.homefree.service-options.homebox.enable;

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
    ## OIDC client descriptor — unconditional, consumed by
    ## apps/zitadel/provision.nix via homefree.sso.resolved-clients.
    homefree.sso.clients = [{
      svc = "homebox";
      internal_name = "homefree-homebox";
      ## Homebox v0.25+ confidential OIDC client (server-side Go app).
      app_type = "OIDC_APP_TYPE_WEB";
      auth_method = "OIDC_AUTH_METHOD_TYPE_POST";
      response_types = [ "OIDC_RESPONSE_TYPE_CODE" ];
      grant_types = [ "OIDC_GRANT_TYPE_AUTHORIZATION_CODE" "OIDC_GRANT_TYPE_REFRESH_TOKEN" ];
      ## Homebox hardcodes its OIDC callback path. Confirmed
      ## empirically: clicking "Sign in" produces a redirect_uri of
      ## /api/v1/users/login/oidc/callback (not the
      ## /api/v1/users/oidc-callback I initially guessed from a
      ## `homebox api --help` that doesn't expose a --redirect-url
      ## option).
      redirect_uris = [ "https://homebox.${domain}/api/v1/users/login/oidc/callback" ];
      post_logout_uris = [ "https://homebox.${domain}/" ];
      needs_pat = false;
      post_restart_units = [ "podman-homebox.service" ];
    }];

    ## Container workload via the app-platform primitive
    ## (modules/app-platform.nix). The chown-marker, CA-bundle synthesis,
    ## podman dns-ready unit, and the dedicated system user/group are all
    ## generated; this declares only the homebox-specific data.
    homefree.containers.homebox = lib.mkIf enable {
      image = "docker.io/sysadminsmedia/homebox:${version}";

      ## Single Go binary, non-privileged port — drop root.
      runAs = { mode = "rootless"; uid = homeboxUid; gid = homeboxGid; };
      dataDir = containerDataPath;

      ## Homebox (Go) fetches Zitadel's OIDC discovery over Caddy's local CA.
      caBundle = true;

      ports = [
        "0.0.0.0:${toString port}:7745"
      ];

      volumes = [
        "/etc/localtime:/etc/localtime:ro"
        "${containerDataPath}:/data"
        ## (the synthesized CA bundle mount is appended by caBundle = true)
      ];

      environment = {
        TZ = config.homefree.system.timeZone;
        HBOX_WEB_MAX_FILE_UPLOAD = "50";
        HBOX_OPTIONS_ALLOW_ANALYTICS = "false";
        HBOX_OPTIONS_ALLOW_REGISTRATION = if config.homefree.service-options.homebox.disable-registration then "false" else "true";
        ## The public HOSTNAME (no scheme) Homebox uses when building its
        ## outgoing OIDC redirect_uri. Homebox prepends its own scheme — if we
        ## include `https://` it'd render `http://https://homebox.<domain>/...`
        ## which Zitadel rejects as unregistered.
        HBOX_OPTIONS_HOSTNAME = "homebox.${config.homefree.system.domain}";
        ## TRUST_PROXY honors X-Forwarded-Proto from Caddy when building the
        ## redirect_uri (else the scheme is hardcoded http://).
        HBOX_OPTIONS_TRUST_PROXY = "true";
        ## (SSL_CERT_FILE pointing at the CA bundle is added by caBundle = true)
      };
      ## OIDC env synthesized by preStartFinal from Zitadel secrets.
      ## Empty file pre-provisioning; populated by zitadel-provision.
      environmentFiles = [ ssoEnvFile ];

      ## Create the env file before the marker chown so it is owned by the
      ## app uid (same as the hand-written module's ordering), then
      ## generate + anchor the mandatory API-key pepper (Homebox 0.26+
      ## refuses to start without HBOX_AUTH_API_KEY_PEPPER >= 32 chars).
      preStartInit = ''
        install -m 600 /dev/null ${ssoEnvFile}

        ${anchor.preamble}

        ## api-key-pepper — Homebox hashes API keys with this pepper;
        ## rotating it invalidates every issued key, so it must be
        ## generated once and persisted (anchored). base64-of-48 is 64
        ## chars (> the 32-char minimum); / + = are safe unquoted in an
        ## env-file value (split on the first =).
        ${anchor.anchorSecret {
          service = "homebox";
          key = "api-key-pepper";
          dir = secretsDir;
          generate = "${pkgs.openssl}/bin/openssl rand -base64 48";
        }}
      '';

      ## Synthesize Homebox's OIDC env file from the secrets zitadel-provision
      ## writes. Homebox v0.25+ has native OIDC (HBOX_OIDC_*). Empty file
      ## pre-provisioning, populated once secrets land. Homebox has no role
      ## propagation from OIDC claims — all SSO users are equal; first to sign
      ## in becomes group owner, rest join as members.
      preStartFinal = ''
        ## The API-key pepper is mandatory in every branch — Homebox 0.26+
        ## panics on startup without it. preStartFinal rewrites sso.env,
        ## so emit the pepper line in BOTH the OIDC and pre-provisioning
        ## branches.
        PEPPER=$(cat ${secretsDir}/api-key-pepper)

        if [ -s ${secretsDir}/oidc-client-id ] \
           && [ -s ${secretsDir}/oidc-client-secret ]; then
          CID=$(cat ${secretsDir}/oidc-client-id)
          CSEC=$(cat ${secretsDir}/oidc-client-secret)
          ## Env var names per `homebox api --help` (HBOX_OIDC_*, NOT
          ## HBOX_OIDC_AUTH_*). Callback path is hardcoded by Homebox to
          ## /api/v1/users/oidc-callback — registered in zitadel-provision.
          {
            echo "HBOX_AUTH_API_KEY_PEPPER=$PEPPER"
            echo "HBOX_OIDC_ENABLED=true"
            echo "HBOX_OIDC_CLIENT_ID=$CID"
            echo "HBOX_OIDC_CLIENT_SECRET=$CSEC"
            echo "HBOX_OIDC_ISSUER_URL=https://sso.${domain}"
            echo "HBOX_OIDC_BUTTON_TEXT=Sign in with HomeFree SSO"
            ## Zitadel emits roles under this namespaced claim, not `groups`.
            echo "HBOX_OIDC_GROUP_CLAIM=urn:zitadel:iam:org:project:roles"
            echo "HBOX_OIDC_SCOPE=openid profile email urn:zitadel:iam:org:project:roles"
            echo "HBOX_OIDC_NAME_CLAIM=name"
            echo "HBOX_OIDC_EMAIL_CLAIM=email"
            ## Hide Homebox's local login once SSO is live. Only flipped on in
            ## the secrets-present branch so a fresh install can still bootstrap
            ## via the local form before zitadel-provision lands.
            echo "HBOX_OPTIONS_ALLOW_LOCAL_LOGIN=false"
          } > ${ssoEnvFile}
        else
          ## Pre-provisioning: only the mandatory pepper so the container
          ## starts cleanly with local-login (HBOX_OIDC_ENABLED defaults false).
          printf 'HBOX_AUTH_API_KEY_PEPPER=%s\n' "$PEPPER" > ${ssoEnvFile}
        fi
        chmod 600 ${ssoEnvFile}
      '';
    };

    homefree.service-config = [{
      inherit (config.homefree.service-options.homebox) label name project-name;
      port-request = null;
      enable = config.homefree.service-options.homebox.enable;
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
