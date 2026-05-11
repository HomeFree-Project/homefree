{ config, lib, pkgs, ... }:
let
  version = "15.0.1";
  containerDataPath = "/var/lib/forgejo";
  port = 3201;
  ssh-port = 3022;

  forgejoSecretsDir = "/var/lib/homefree-secrets/forgejo";
  domain = config.homefree.system.domain;

  preStart = ''
    mkdir -p ${containerDataPath}
  '';

  ## After Forgejo is up, register Zitadel as an OAuth auth source if
  ## both the OIDC secrets exist on disk AND there's no existing
  ## "Zitadel" auth source. Idempotent: re-runs are no-ops once the
  ## auth source is registered. The container ships `forgejo admin
  ## auth list-oauth` which we grep for the literal name.
  ##
  ## Runs as ExecStartPost in the systemd unit so it fires after
  ## every (re)start. zitadel-provision.service `restart`s
  ## podman-forgejo when it writes the OIDC secrets, which is what
  ## triggers the first-time registration.
  postStart = pkgs.writeShellScript "forgejo-poststart" ''
    set -u

    ## Bail quietly if SSO secrets aren't on disk yet — fresh install
    ## before zitadel-provision has run, or homefree.sso.per-service.
    ## forgejo.enable=false (in which case the secrets are gone after
    ## a wipe). Forgejo continues to serve unauthenticated traffic
    ## via its own login page.
    if [ ! -s "${forgejoSecretsDir}/oidc-client-id" ] \
       || [ ! -s "${forgejoSecretsDir}/oidc-client-secret" ]; then
      echo "forgejo postStart: no OIDC secrets yet, skipping Zitadel auth-source registration" >&2
      exit 0
    fi

    ## Wait up to 60s for forgejo to be ready inside the container.
    ## The auth CLI requires the app DB to be migrated.
    for i in $(seq 1 30); do
      if ${pkgs.podman}/bin/podman exec forgejo \
           forgejo admin auth list-oauth >/dev/null 2>&1; then
        break
      fi
      [ "$i" = 30 ] && {
        echo "forgejo postStart: forgejo CLI not responsive after 60s" >&2
        exit 0
      }
      sleep 2
    done

    ## Skip if the Zitadel auth source already exists.
    if ${pkgs.podman}/bin/podman exec forgejo \
         forgejo admin auth list-oauth 2>/dev/null \
         | ${pkgs.gnugrep}/bin/grep -qE '^[0-9]+[[:space:]]+Zitadel\b'; then
      echo "forgejo postStart: Zitadel auth source already registered, skipping" >&2
      exit 0
    fi

    CID=$(cat ${forgejoSecretsDir}/oidc-client-id)
    CSEC=$(cat ${forgejoSecretsDir}/oidc-client-secret)

    echo "forgejo postStart: registering Zitadel as OAuth source" >&2
    if ${pkgs.podman}/bin/podman exec forgejo \
         forgejo admin auth add-oauth \
           --provider openidConnect \
           --name Zitadel \
           --key "$CID" \
           --secret "$CSEC" \
           --auto-discover-url "https://sso.${domain}/.well-known/openid-configuration" \
           --scopes "openid email profile" \
           --group-claim-name groups; then
      echo "forgejo postStart: Zitadel auth source registered" >&2
    else
      echo "forgejo postStart: registration failed (non-fatal)" >&2
    fi
  '';
in
{
  options.homefree.service-options.forgejo = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "enable Forgejo git service";
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

    # Metadata - always available, not user-configurable
    label = lib.mkOption {
      type = lib.types.str;
      default = "forgejo";
      internal = true;
      description = "Service label";
    };

    name = lib.mkOption {
      type = lib.types.str;
      default = "Git";
      internal = true;
      description = "Service display name";
    };

    project-name = lib.mkOption {
      type = lib.types.str;
      default = "Forgejo";
      internal = true;
      description = "Project name";
    };
  };

  config = {
    environment.systemPackages = [
      ## Installs "forgejo" executable
      pkgs.forgejo
    ];

    virtualisation.oci-containers.containers = lib.optionalAttrs config.homefree.service-options.forgejo.enable {
    forgejo = {
      image = "codeberg.org/forgejo/forgejo:${version}";

      autoStart = true;

      extraOptions = [
        # "--pull=always"
      ];

      ports = [
        "0.0.0.0:${toString port}:${toString port}"
        "0.0.0.0:${toString ssh-port}:${toString ssh-port}"
      ];

      volumes = [
        "/etc/localtime:/etc/localtime:ro"
        "${containerDataPath}:/data"
      ];

      environment = {
        TZ = config.homefree.system.timeZone;

        ## app.ini server config
        FORGEJO__server__HTTP_PORT = toString port;
        FORGEJO__server__DOMAIN = "git.${config.homefree.system.domain}";
        FORGEJO__server__MINIMUM_KEY_SIZE_CHECK = "false";
        FORGEJO__server__START_SSH_SERVER = "true";
        ## Container internal port
        FORGEJO__server__SSH_LISTEN_PORT = toString ssh-port;
        ## External port
        FORGEJO__server__SSH_PORT = toString ssh-port;
        FORGEJO__server__ROOT_URL = "https://git.${config.homefree.system.domain}";

        ## app.ini service config
        FORGEJO__service__DISABLE_REGISTRATION = if config.homefree.service-options.forgejo.disable-registration == true then "true" else "false";

        ## app.ini migrations config
        FORGEJO__migrations__ALLOWED_DOMAINS = "*";
        FORGEJO__migrations__ALLOW_LOCALNETWORKS = "true";
        FORGEJO__migrations__SKIP_TLS_VERIFY = "true";

        ## app.ini actions config
        FORGEJO__actions__ENABLED = "true";
        FORGEJO__actions__DEFAULT_ACTIONS_URL = "github";

        ## app.ini mailer config
        # FORGEJO__mailer__ENABLED = "true";
        # FORGEJO__mailer__SMTP_ADDR = "mail.example.com";
        # FORGEJO__mailer__FROM = "noreply@${srv.DOMAIN}";
        # FORGEJO__mailer__USER = "noreply@${srv.DOMAIN}";

        ## Database config
        # FORGEJO__database__DB_TYPE = "postgres";
        # FORGEJO__database__HOST = "db:5432";
        # FORGEJO__database__NAME = "forgejo";
        # FORGEJO__database__USER = "forgejo";
        # FORGEJO__database__PASSWD = "forgejo";
      };
    };
  };

    systemd.services.podman-forgejo = lib.optionalAttrs config.homefree.service-options.forgejo.enable {
    after = [ "dns-ready.service" ];
    requires = [ "dns-ready.service" ];
    partOf =  [ "nftables.service" ];
    serviceConfig = {
      ExecStartPre = [ "!${pkgs.writeShellScript "forgejo-prestart" preStart}" ];
      ExecStartPost = [ "!${postStart}" ];
    };
  };

    homefree.service-config = [{
      inherit (config.homefree.service-options.forgejo) label name project-name;
      systemd-service-names = [
        "podman-forgejo"
      ];
      reverse-proxy = {
        enable = config.homefree.service-options.forgejo.enable;
        subdomains = [ "git" "forgejo" ];
        http-domains = [ "homefree.lan" config.homefree.system.localDomain ];
        https-domains = [ config.homefree.system.domain ];
        host = config.homefree.network.lan-address;
        port = port;
        public = config.homefree.service-options.forgejo.public;
      };
      firewall = {
        open-ports = {
          tcp = [ ssh-port ];
        };
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
          description = "Enable Forgejo git hosting service";
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

