{ config, lib, pkgs, ... }:

## Default username: zitadel-admin@zitadel.${config.homefree.system.domain}
## Default password: Password1!

let
  version = "v4.15.0";
  containerDataPath = "/var/lib/zitadel";
  port = 3241;

  preStart = ''
    mkdir -p ${containerDataPath}
  '';
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

    secrets = lib.mkOption {
      type = lib.types.attrsOf (lib.types.nullOr lib.types.path);
      default = {};
      description = "Secrets for Zitadel service";
    };
  };

  config = {
  virtualisation.oci-containers.containers = lib.optionalAttrs config.homefree.service-options.zitadel.enable {
    zitadel = {
      image = "ghcr.io/zitadel/zitadel:${version}";

      autoStart = true;

      extraOptions = [
        # "--pull=always"
      ];

      ports = [
        "0.0.0.0:${toString port}:8080"
      ];

      volumes = [
        "/etc/localtime:/etc/localtime:ro"
        "${containerDataPath}:/data"
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
        (config.homefree.service-options.zitadel.secrets.env != null)
        config.homefree.service-options.zitadel.secrets.env;
    };
  };

  systemd.services.podman-zitadel = lib.optionalAttrs config.homefree.service-options.zitadel.enable {
    after = [ "dns-ready.service" ];
    requires = [ "dns-ready.service" ];
    partOf =  [ "nftables.service" ];
    serviceConfig = {
      ExecStartPre = [ "!${pkgs.writeShellScript "zitadel-prestart" preStart}" ];
    };
  };

    homefree.service-config = [{
      inherit (config.homefree.service-options.zitadel) label name project-name;
      systemd-service-names = [
        "podman-zitadel"
      ];
      reverse-proxy = {
        enable = config.homefree.service-options.zitadel.enable;
        subdomains = [ "sso" "zitadel" ];
        http-domains = [ "homefree.lan" config.homefree.system.localDomain ];
        https-domains = [ config.homefree.system.domain ];
        host = config.homefree.network.lan-address;
        port = port;
        public = config.homefree.service-options.zitadel.public;
      };
      backup = {
        paths = [
          containerDataPath
        ];
        postgres-databases = [
          "zitadel"
        ];
      };
    }];
  };
}
