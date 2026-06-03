{ config, lib, pkgs, ... }:
let
  userOptions = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "enable Screeenly preview generation service";
    };

    public = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Open to public on WAN port";
    };
  };

  containerDataPath = "/var/lib/screeenly";
  containerImageName = "hadogenes/screeenly";
  containerHash = "sha256:142211a830a1af83e796965ed5357788c21ffbd49c684704ab085c5a43bdba0f";
  port = config.homefree.allocPort "screeenly";
  enabled = config.homefree.service-options.screeenly.enable == true || config.homefree.services.nextcloud.enable == true;
  database-type = "mysql";
  database-name = "screeenly";
  database-user = "screeenly";
  database-host = config.homefree.network.lan-address;
  database-port = 3306;

  secretsDir = "/var/lib/homefree-secrets/screeenly";
  runtimeEnvFile = "${containerDataPath}/runtime.env";

  ## Anchors auto-generated secrets into encrypted /etc/nixos/secrets
  ## so they survive a restore — see lib/secrets-anchor.nix.
  anchor = import ../../lib/secrets-anchor.nix { inherit lib pkgs; };

  preStart = ''
    mkdir -p ${containerDataPath}
    mkdir -p ${secretsDir}

    if [ ! -e ${containerDataPath}/env.txt ]; then
      APP_KEY=$(${pkgs.podman}/bin/podman run --rm ${containerImageName}@${containerHash} php artisan key:generate --show | tail -n 1 | tr -d '\r')
      echo "APP_KEY=$APP_KEY" > "${containerDataPath}/env.txt"
    fi

    ${anchor.preamble}

    ## mysql-password — Screeenly was previously created without a
    ## password (CREATE USER without IDENTIFIED BY), so the MariaDB
    ## user had no credentials and the container connected without
    ## one. Phase 2 anchors a real password so MariaDB rejects
    ## unauthorised access. Stripped to [A-Za-z0-9] via `tr -d '/+='`
    ## so it survives unquoted in env-file values.
    ${anchor.anchorSecret {
      service = "screeenly";
      key = "mysql-password";
      dir = secretsDir;
      generate = "${pkgs.openssl}/bin/openssl rand -base64 32 | tr -d '/+=' | head -c 32";
    }}

    MYSQL_PASSWORD=$(cat ${secretsDir}/mysql-password)

    ## CREATE-if-absent then unconditional ALTER USER ... IDENTIFIED
    ## BY rotates passwordless boxes onto the anchored value and is a
    ## no-op once converged. GRANT scope already correct (database
    ## scoped, not *.*) — no Phase 4 fix needed for screeenly.
    ${pkgs.mariadb}/bin/mysql -e "CREATE USER IF NOT EXISTS '${database-user}'@'localhost'"
    ${pkgs.mariadb}/bin/mysql -e "ALTER USER '${database-user}'@'localhost' IDENTIFIED BY '$MYSQL_PASSWORD'"
    ${pkgs.mariadb}/bin/mysql -e "GRANT ALL PRIVILEGES ON ${database-name}.* TO '${database-user}'@'localhost'"
    ${pkgs.mariadb}/bin/mysql -e "CREATE USER IF NOT EXISTS '${database-user}'@'%'"
    ${pkgs.mariadb}/bin/mysql -e "ALTER USER '${database-user}'@'%' IDENTIFIED BY '$MYSQL_PASSWORD'"
    ${pkgs.mariadb}/bin/mysql -e "GRANT ALL PRIVILEGES ON ${database-name}.* TO '${database-user}'@'%'"

    ## runtime.env carries DB_PASSWORD for the container, anchored
    ## value substituted at runtime.
    install -m 600 /dev/null ${runtimeEnvFile}
    printf 'DB_PASSWORD=%s\n' "$MYSQL_PASSWORD" > ${runtimeEnvFile}
  '';
in
{
  options.homefree.services.screeenly = userOptions;
  options.homefree.service-options.screeenly = userOptions // {
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
        runtimeEnvFile
      ];
    };
  };

  systemd.services.podman-screeenly = lib.mkIf enabled {
    after = [ "dns-ready.service" "postgresql.service" ];
    wants = [ "dns-ready.service" ];
    serviceConfig = {
      ExecStartPre = [ "!${pkgs.writeShellScript "screeenly-prestart" preStart}" ];
    };
  };

  homefree.service-config = lib.optionals enabled [
    {
      inherit (config.homefree.service-options.screeenly) label name project-name;
      port-request = null;
      systemd-service-names = [
        "podman-screeenly"
      ];
      sso = {
        kind = "caddy_gated";
        ## Dev context (intentionally not surfaced in the admin UI):
        ## Outer gate admin-only. Screeenly is API-only — no inner
        ## login.
      };
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

