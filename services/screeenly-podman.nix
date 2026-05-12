{ config, lib, pkgs, ... }:
let
  containerDataPath = "/var/lib/screeenly";
  containerImageName = "hadogenes/screeenly";
  containerHash = "sha256:142211a830a1af83e796965ed5357788c21ffbd49c684704ab085c5a43bdba0f";
  port = 4201;
  enabled = config.homefree.service-options.screeenly.enable == true || config.homefree.services.nextcloud.enable == true;
  database-type = "mysql";
  database-name = "screeenly";
  database-user = "screeenly";
  database-host = config.homefree.network.lan-address;
  database-port = 3306;

  preStart = ''
    mkdir -p ${containerDataPath}

    if [ ! -e ${containerDataPath}/env.txt ]; then
      APP_KEY=$(${pkgs.podman}/bin/podman run --rm ${containerImageName}@${containerHash} php artisan key:generate --show | tail -n 1 | tr -d '\r')
      echo "APP_KEY=$APP_KEY" > "${containerDataPath}/env.txt"
    fi

    ${pkgs.mariadb}/bin/mysql -e "CREATE USER IF NOT EXISTS '${database-user}'@'localhost'"
    ${pkgs.mariadb}/bin/mysql -e "GRANT ALL PRIVILEGES ON ${database-name}.* TO '${database-user}'@'localhost'"
    ${pkgs.mariadb}/bin/mysql -e "CREATE USER IF NOT EXISTS '${database-user}'@'%'"
    ${pkgs.mariadb}/bin/mysql -e "GRANT ALL PRIVILEGES ON ${database-name}.* TO '${database-user}'@'%'"
  '';
in
{
  options.homefree.service-options.screeenly = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "enable Screeenly service";
    };

    public = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Open to public on WAN port";
    };

    label = lib.mkOption {
      type = lib.types.str;
      default = "screeenly";
      internal = true;
      description = "Service label";
    };

    name = lib.mkOption {
      type = lib.types.str;
      default = "screeenly";
      internal = true;
      description = "Service display name";
    };

    project-name = lib.mkOption {
      type = lib.types.str;
      default = "Screeenly";
      internal = true;
      description = "Project name";
    };
  };

  config = {
  services.mysql = lib.optionalAttrs enabled {
    ensureDatabases = [ database-name ];
    ensureUsers = [
      {
        name = database-user;
        ensurePermissions = {
          "${database-name}.*" = "ALL PRIVILEGES";
        };
      }
    ];
  };

  ## Used by nextcloud for generating bookmark previews
  virtualisation.oci-containers.containers = lib.optionalAttrs enabled {
    screeenly = {
      image = "${containerImageName}@${containerHash}";

      autoStart = true;

      extraOptions = [
        # "--pull=always"
      ];

      ports = [
        "0.0.0.0:${toString port}:80"
      ];

      volumes = [
        "/etc/localtime:/etc/localtime:ro"
        "/run/postgresql:/run/postgresql"
      ];

      environment = {
        TZ = config.homefree.system.timeZone;
        DB_CONNECTION = database-type;
        DB_HOST = database-host;
        DB_PORT = toString database-port;
        DB_DATABASE = database-name;
        DB_USERNAME = database-user;

        # REDIS_HOST = "";
        # REDIS_PASSWORD = "null";
        # REDIS_PORT = "6379";
      };

      environmentFiles = [
        "${containerDataPath}/env.txt"
      ];
    };
  };

  systemd.services.podman-screeenly = lib.optionalAttrs enabled {
    after = [ "dns-ready.service" "postgresql.service" ];
    requires = [ "dns-ready.service" ];
    partOf =  [ "nftables.service" ];
    serviceConfig = {
      ExecStartPre = [ "!${pkgs.writeShellScript "screeenly-prestart" preStart}" ];
    };
  };

  homefree.service-config = lib.optionals enabled [
    {
      inherit (config.homefree.service-options.screeenly) label name project-name;
      systemd-service-names = [
        "podman-screeenly"
      ];
      reverse-proxy = {
        enable = config.homefree.service-options.screeenly.enable;
        subdomains = [ "screeenly" ];
        http-domains = [ "homefree.lan" config.homefree.system.localDomain ];
        https-domains = [ config.homefree.system.domain ];
        host = config.homefree.network.lan-address;
        port = port;
        public = config.homefree.service-options.screeenly.public;
        ## Screeenly is the screenshot API used by Nextcloud's
        ## preview-generator (if manually configured). Server-to-
        ## server callers (Nextcloud) should talk to it via the
        ## LAN address — http://<lan>:<port>/ — NOT through the
        ## public Caddy host, so gating the public URL admin-only
        ## doesn't break the integration. Mark the public host
        ## admin-only so only admins reach the UI / docs.
        oauth2 = config.homefree.sso.per-service.screeenly.enable or true;
        require-admin-role = config.homefree.sso.per-service.screeenly.enable or true;
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
          description = "Enable Screeenly preview generation service";
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

