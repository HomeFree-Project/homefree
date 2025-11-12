{ config, lib, pkgs, ... }:
let
  version = "15.0.1";
  containerDataPath = "/var/lib/forgejo";
  port = 3201;
  ssh-port = 3022;

  preStart = ''
    mkdir -p ${containerDataPath}
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

