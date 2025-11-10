{ config, lib, pkgs, ... }:
let
  containerDataPath = "/var/lib/freshrss-podman";

  preStart = ''
    mkdir -p ${containerDataPath}/data
    mkdir -p ${containerDataPath}/extensions
  '';

  # image = "lscr.io/linuxserver/freshrss";
  image = "freshrss/freshrss";
  version = "1.28.1";

  port = 3028;

  BASE_URL = "/";
  DB_BASE = "freshrss";
  DB_HOST = "${config.homefree.network.lan-address}";
  DB_PASSWORD = "changeme";
  DB_USER = "postgres";
  ADMIN_API_PASSWORD = "changeme";
  ADMIN_EMAIL = "ellis@rahh.al";
  ADMIN_PASSWORD = "changeme";
in
{
  options.homefree.service-options.freshrss = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "enable FreshRSS service";
    };

    public = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Open to public on WAN port";
    };

    # Metadata - always available, not user-configurable
    label = lib.mkOption {
      type = lib.types.str;
      default = "freshrss";
      internal = true;
      description = "Service label";
    };

    name = lib.mkOption {
      type = lib.types.str;
      default = "FreshRSS";
      internal = true;
      description = "Service display name";
    };

    project-name = lib.mkOption {
      type = lib.types.str;
      default = "FreshRSS";
      internal = true;
      description = "Project name";
    };
  };

  config = {
    virtualisation.oci-containers.containers = lib.optionalAttrs config.homefree.service-options.freshrss.enable {
    freshrss = {
      image = "${image}:${version}";

      autoStart = true;

      extraOptions = [
        # "--pull=always"
      ];

      ports = [
        "0.0.0.0:${toString port}:80"
      ];

      volumes = [
        "/etc/localtime:/etc/localtime:ro"
        "${containerDataPath}/data:/var/www/FreshRSS/data"
        "${containerDataPath}/extensions:/var/www/FreshRSS/extensions"
      ];

      environment = {
        TZ = config.homefree.system.timeZone;
        FRESHRSS_ENV = "development";
        SERVER_DNS = "freshrss.${config.homefree.system.domain}";
        CRON_MIN = "1,31";
        # Optional parameter, set to 1 to enable OpenID Connect (only available in our Debian image)
        # Requires more environment variables. See https://freshrss.github.io/FreshRSS/en/admins/16_OpenID-Connect.html
        OIDC_ENABLED = "0";
        # Optional auto-install parameters (the Web interface install is recommended instead):
        # ⚠️ Parameters below are only used at the very first run (so far).
        # So if changes are made (or in .env file), first delete the service and volumes.
        # ℹ️ All the --db-* parameters can be omitted if using built-in SQLite database.
        FRESHRSS_INSTALL = ''
          --api-enabled
          --base-url ${BASE_URL}
          --db-base ${DB_BASE}
          --db-host ${DB_HOST}
          --db-password ${DB_PASSWORD}
          --db-type pgsql
          --db-user ${DB_USER}
          --default-user admin
          --language en
        '';
        FRESHRSS_USER = ''
          --api-password ${ADMIN_API_PASSWORD}
          --email ${ADMIN_EMAIL}
          --language en
          --password ${ADMIN_PASSWORD}
          --user admin
        '';
      };
    };
  };

  systemd.services.podman-freshrss = lib.optionalAttrs config.homefree.service-options.freshrss.enable {
    after = [ "dns-ready.service" ];
    requires = [ "dns-ready.service" ];
    partOf =  [ "nftables.service" ];
    serviceConfig = {
      ExecStartPre = [ "!${pkgs.writeShellScript "freshrss-prestart" preStart}" ];
    };
  };

    homefree.service-config = [{
      inherit (config.homefree.service-options.freshrss) label name project-name;
      systemd-service-names = [
        "podman-freshrss"
      ];
      reverse-proxy = {
        enable = config.homefree.service-options.freshrss.enable;
        subdomains = [ "freshrss" ];
        http-domains = [ "homefree.lan" config.homefree.system.localDomain ];
        https-domains = [ config.homefree.system.domain ];
        host = config.homefree.network.lan-address;
        port = port;
        public = config.homefree.service-options.freshrss.public;
      };
      backup = {
        paths = [
          containerDataPath
        ];
        postgres-databases = [
          DB_BASE
        ];
      };
    }];
  };
}

