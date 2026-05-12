{ config, lib, pkgs, ... }:
let
  containerDataPath = "/var/lib/ollama-webui";
  secretsDir = "/var/lib/homefree-secrets/ollama";

  port-internal = 8254;
  port = 3014;

  domain = config.homefree.system.domain;
  ssoEnvFile = "${containerDataPath}/sso.env";

  ## preStart: synthesize Open WebUI's OIDC env file from the OIDC
  ## secrets zitadel-provision wrote to disk. Gated on the secrets
  ## existing so pre-provisioning (fresh install) the container still
  ## starts in local-login mode.
  ##
  ## Open WebUI reads OAUTH_CLIENT_ID/SECRET, OPENID_PROVIDER_URL +
  ## ENABLE_OAUTH_SIGNUP/ROLE_MANAGEMENT to bootstrap an OIDC button
  ## on its login page. The role-management vars map a JSON-path
  ## claim onto Open WebUI's role enum:
  ##   OAUTH_ROLES_CLAIM -> the JSON key (Zitadel's namespaced
  ##     project-roles claim — which Open WebUI handles as an object
  ##     whose keys ARE the role names, unlike oauth2-proxy).
  ##   OAUTH_ADMIN_ROLES=homefree-admin -> presence of that key flips
  ##     the new user to admin; absence makes them a regular user.
  preStart = ''
    mkdir -p ${containerDataPath}
    install -m 600 /dev/null ${ssoEnvFile}
    if [ -s ${secretsDir}/oidc-client-id ] \
       && [ -s ${secretsDir}/oidc-client-secret ]; then
      CID=$(cat ${secretsDir}/oidc-client-id)
      CSEC=$(cat ${secretsDir}/oidc-client-secret)
      {
        echo "ENABLE_OAUTH_SIGNUP=true"
        echo "OAUTH_MERGE_ACCOUNTS_BY_EMAIL=true"
        echo "OAUTH_PROVIDER_NAME=HomeFree SSO"
        echo "OAUTH_CLIENT_ID=$CID"
        echo "OAUTH_CLIENT_SECRET=$CSEC"
        echo "OPENID_PROVIDER_URL=https://sso.${domain}/.well-known/openid-configuration"
        echo "OPENID_REDIRECT_URI=https://ollama.${domain}/oauth/oidc/callback"
        echo "OAUTH_SCOPES=openid email profile urn:zitadel:iam:org:project:roles"
        echo "OAUTH_USERNAME_CLAIM=preferred_username"
        echo "OAUTH_EMAIL_CLAIM=email"
        echo "OAUTH_PICTURE_CLAIM=picture"
        echo "ENABLE_OAUTH_ROLE_MANAGEMENT=true"
        echo "OAUTH_ROLES_CLAIM=urn:zitadel:iam:org:project:roles"
        echo "OAUTH_ADMIN_ROLES=homefree-admin"
        ## Open WebUI by default assigns first-user as admin and
        ## subsequent users as pending. With role management on we
        ## want a sane default for users WITHOUT homefree-admin: let
        ## them in as regular users (not pending).
        echo "OAUTH_ALLOWED_ROLES=homefree-admin,user"
        echo "DEFAULT_USER_ROLE=user"
      } > ${ssoEnvFile}
    else
      ## Pre-provisioning: write the env file empty so the container's
      ## EnvironmentFile directive doesn't fail. Open WebUI falls back
      ## to its built-in local login until secrets land.
      : > ${ssoEnvFile}
    fi
    chmod 600 ${ssoEnvFile}
  '';
in
{
  options.homefree.service-options.ollama = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "enable Ollama service";
    };

    public = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Open to public on WAN port";
    };

    label = lib.mkOption {
      type = lib.types.str;
      default = "ollama";
      internal = true;
      description = "Service label";
    };

    name = lib.mkOption {
      type = lib.types.str;
      default = "Ollama";
      internal = true;
      description = "Service display name";
    };

    project-name = lib.mkOption {
      type = lib.types.str;
      default = "Ollama";
      internal = true;
      description = "Project name";
    };
  };

  config = {
  environment.systemPackages = lib.optionals config.homefree.service-options.ollama.enable [
    pkgs.ollama
  ];

  services.ollama = lib.optionalAttrs config.homefree.service-options.ollama.enable {
    enable = true;
    ## Default: 11434
    port = 11434;
    host = "[::]";
    loadModels = [
      "deepseek-r1:7b"
    ];
  };

  virtualisation.oci-containers.containers = lib.optionalAttrs config.homefree.service-options.ollama.enable {
    ollama-webui = {
      image = "ghcr.io/open-webui/open-webui:main";

      autoStart = true;

      extraOptions = [
        # "--pull=always"
        "--add-host=host.docker.internal:host-gateway"
      ];

      ports = [
        "0.0.0.0:${toString port}:${toString port-internal}"
      ];

      volumes = [
      "/etc/localtime:/etc/localtime:ro"
        "${containerDataPath}:/app/backend/data"
      ];

      environment = {
        TZ = config.homefree.system.timeZone;
        PORT = toString port-internal;
        WEBUI_URL = "https://ollama.${config.homefree.system.domain}";
        OLLAMA_BASE_URL = "http://${config.homefree.network.lan-address}:${toString config.services.ollama.port}";
        ## @TODOS
        # WEBUI_SECRET_KEY
        # DEFAULT_LOCALE
        # DEFAULT_PROMPT_SUGGESTIONS
        # CORS_ALLOW_ORIGIN (defualt is *)
        # USER_AGENT
        ## Single user mode (can't change after first run)
        # WEBUI_AUTH=False
      };

      ## OIDC env synthesized by preStart from Zitadel secrets.
      ## Empty file pre-provisioning; populated once
      ## zitadel-provision.service writes the OIDC client.
      environmentFiles = [ ssoEnvFile ];
    };
  };

  systemd.services.podman-ollama-webui = lib.optionalAttrs config.homefree.service-options.ollama.enable {
    after = [ "dns-ready.service" ];
    requires = [ "dns-ready.service" ];
    serviceConfig = {
      ExecStartPre = [ "!${pkgs.writeShellScript "ollama-webui-prestart" preStart}" ];
    };
  };

    homefree.service-config = [{
      inherit (config.homefree.service-options.ollama) label name project-name;
      ## @TODO: Why is this not a list?
      systemd-service-names = [
        "ollama"
        "podman-ollama-webui"
      ];
      sso = {
        kind = "native_oidc";
        notes = "Open WebUI native OIDC; homefree-admin Zitadel role maps to WebUI admin via OAUTH_ADMIN_ROLES.";
      };
      reverse-proxy = {
        enable = config.homefree.service-options.ollama.enable;
        subdomains = [ "ollama" ];
        http-domains = [ "homefree.lan" config.homefree.system.localDomain ];
        https-domains = [ config.homefree.system.domain ];
        host = config.homefree.network.lan-address;
        port = port;
        public = config.homefree.service-options.ollama.public;
        ## ollama.<domain> serves Open WebUI (the chat UI), NOT the
        ## raw Ollama API. Open WebUI talks to Ollama directly over
        ## the LAN address (see OLLAMA_BASE_URL above).
        ##
        ## Open WebUI has native OIDC support — see the preStart
        ## block that writes ${ssoEnvFile} from Zitadel secrets.
        ## So we do NOT gate at Caddy: any visitor sees Open WebUI's
        ## own login page with a "Sign in with HomeFree SSO" button.
        ## Open WebUI maps the homefree-admin role onto its own
        ## admin/user enum (OAUTH_ROLES_CLAIM + OAUTH_ADMIN_ROLES in
        ## the env file). Non-admin users come through as regular
        ## users via DEFAULT_USER_ROLE=user.
        ##
        ## Pre-provisioning (no OIDC secrets yet) Open WebUI falls
        ## back to its first-user-as-admin local-login flow — same
        ## behavior as a fresh install of Open WebUI standalone.
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
          description = "Enable Ollama GenAI service";
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
