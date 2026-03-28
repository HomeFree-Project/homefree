## Restore from backup:
## cp /var/lib/immich/backups/immich-db-backup-1738144800006.sql.gz ~/
## cd ~/
## gzip -d immich-db-backup-1738144800006.sql.gz
## psql -U postgres
## drop database immich;
## exit
## sudo systemctl restart postgres # adds immich database back
## psql -f immich-db-backup-1738144800006.sql -U postgres -d immich


## Migration from Nix service to podman. Docker container has hard coded path.

## double quotes are used for db identifiers, single quotes for strings
## If any special characters or upper case, must surround with double quotes

## update asset_files set path = replace(path, '/var/lib/immich', '/usr/src/app/upload');
## update assets set "originalPath" = replace("originalPath", '/var/lib/immich', '/usr/src/app/upload');
## update person set "thumbnailPath" = replace("thumbnailPath", '/var/lib/immich', '/usr/src/app/upload');
{ config, lib, pkgs, ... }:
let
  version = "v2.7.5";
  version-redis = "8.6-alpine";
  containerDataPath = "/var/lib/immich";
  # Seems to be hard coded in docker container, so can't override
  uploadLocation = "/usr/src/app/upload";

  port = 2283;
  port-machine-learning = 3003;
  port-redis = 6379;
  database-name = "immich";
  database-user = "immich";

  preStart = ''
    mkdir -p ${containerDataPath}/backups
    mkdir -p ${containerDataPath}/encoded-video
    mkdir -p ${containerDataPath}/library
    mkdir -p ${containerDataPath}/profile
    mkdir -p ${containerDataPath}/thumbs
    mkdir -p ${containerDataPath}/upload
    mkdir -p /var/cache/immich
  '';
in
{
  options.homefree.service-options.immich = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "enable Immich photo management service";
    };

    public = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Open to public on WAN port";
    };

    # Metadata - always available, not user-configurable
    label = lib.mkOption {
      type = lib.types.str;
      default = "immich";
      internal = true;
      description = "Service label";
    };

    name = lib.mkOption {
      type = lib.types.str;
      default = "Photos";
      internal = true;
      description = "Service display name";
    };

    project-name = lib.mkOption {
      type = lib.types.str;
      default = "Immich";
      internal = true;
      description = "Project name";
    };
  };

  config = {
    ## @TODO: Move to scripts run from containers
    environment.systemPackages = lib.optionals config.homefree.service-options.immich.enable [
      pkgs.immich-cli
      pkgs.immich-go
    ];

  # ## Copied from nixpkgs
  # services.postgresql = if config.homefree.service-options.immich.enable then {
  #   enable = true;
  #   ensureDatabases = [ database-name ];
  #   ensureUsers = [
  #     {
  #       name = database-user;
  #       ensureDBOwnership = true;
  #       ensureClauses.login = true;
  #     }
  #   ];
  #   extensions = ps: with ps; [ pgvecto-rs ];
  #   settings = {
  #     shared_preload_libraries = [ "vectors.so" ];
  #     search_path = "\"$user\", public, vectors";
  #   };
  # } else {};

  ## @TODO: Currently disabled - try fresh install to see if it's even needed
  systemd.services.podman-postgres-vectorchord.serviceConfig.ExecStartPost =
  let
    postStartScript = pkgs.writeShellScript "postgres-vectorchord-poststart" ''
      # Wait for database to be ready (max 30 seconds)
      for i in {1..30}; do
        if ${pkgs.postgresql}/bin/psql -h postgres-vectorchord -p 6432 -U postgres -c "SELECT 1" &>/dev/null; then
          echo "Database is ready"
          break
        fi
        echo "Waiting for database to be ready... (attempt $i/30)"
        sleep 1
      done

      ${pkgs.postgresql}/bin/psql -h postgres-vectorchord -p 6432 -U postgres << EOF
        DO
        \$do\$
        BEGIN
           IF EXISTS (
              SELECT FROM pg_catalog.pg_roles
              WHERE  rolname = '${database-user}') THEN

              RAISE NOTICE 'Role "${database-user}" already exists. Skipping.';
           ELSE
              BEGIN   -- nested block
                 CREATE ROLE "immich" WITH LOGIN PASSWORD 'changeme';
              EXCEPTION
                 WHEN duplicate_object THEN
                    RAISE NOTICE 'Role "${database-user}" was just created by a concurrent transaction. Skipping.';
              END;
           END IF;
        END
        \$do\$;
      EOF

      ${pkgs.postgresql}/bin/psql -h postgres-vectorchord -U postgres -p 6432 -tc "SELECT 1 FROM pg_database WHERE datname = '${database-name}'" | ${pkgs.gnugrep}/bin/grep -q 1 || ${pkgs.postgresql}/bin/psql -h postgres-vectorchord -p 6432 -U postgres -c "CREATE DATABASE \"${database-name}\" WITH OWNER \"${database-user}\" ENCODING 'UTF8' LOCALE 'C' TEMPLATE template0"

      ${pkgs.postgresql}/bin/psql -h postgres-vectorchord -p 6432 -X -U postgres << EOF
        DO
        \$do\$
        BEGIN
          GRANT ALL PRIVILEGES ON DATABASE "${database-name}" to "${database-user}";
        END
        \$do\$;
      EOF

      # Run the SQL extensions setup
      ${lib.getExe' config.services.postgresql.package "psql"} -h postgres-vectorchord -p 6432 -U postgres -d "${database-name}" -f "${sqlFile}"
    '';
    sqlFile = pkgs.writeText "immich-pgvectors-setup.sql" ''
      CREATE EXTENSION IF NOT EXISTS unaccent;
      CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
      CREATE EXTENSION IF NOT EXISTS vectors;
      CREATE EXTENSION IF NOT EXISTS cube;
      CREATE EXTENSION IF NOT EXISTS earthdistance;
      CREATE EXTENSION IF NOT EXISTS pg_trgm;

      ALTER SCHEMA public OWNER TO ${database-user};
      ALTER SCHEMA vectors OWNER TO ${database-user};
      GRANT SELECT ON TABLE pg_vector_index_stat TO ${database-user};

      ALTER EXTENSION vectors UPDATE;
    '';
  in
  lib.optionals config.homefree.service-options.immich.enable [ "!${postStartScript}" ];

  virtualisation.oci-containers.containers = lib.optionalAttrs config.homefree.service-options.immich.enable {
    immich-server = {
      image = "ghcr.io/immich-app/immich-server:${version}";

      autoStart = true;

      extraOptions = [
        # "--pull=always"
      ];

      ports = [
        "0.0.0.0:${toString port}:2283"
      ];

      volumes = [
        "/etc/localtime:/etc/localtime:ro"
        "${containerDataPath}:${uploadLocation}"
        "/run/postgresql:/run/postgresql"
      ];

      environment = {
        TZ = config.homefree.system.timeZone;

        # IMMICH_LOG_LEVEL = "verbose";
        UPLOAD_LOCATION = "${uploadLocation}";
        THUMB_LOCATION = "${uploadLocation}/thumbs";
        ENCODED_VIDEO_LOCATION = "${uploadLocation}/encoded-video";
        PROFILE_LOCATION = "${uploadLocation}/profile";
        BACKUP_LOCATION = "${uploadLocation}/backups";
        # DB_HOSTNAME = "/run/postgresql";
        # DB_PORT = "5432";
        DB_HOSTNAME = "postgres-vectorchord";
        DB_PORT = "6432";
        DB_DATABASE_NAME = database-name;
        DB_USERNAME = database-user;
        REDIS_HOSTNAME = "immich-redis";
        REDIS_PORT = toString port-redis;
        IMMICH_MACHINE_LEARNING_URL = "http://immich-machine-learning:${toString port-machine-learning}";
        PUBLIC_IMMICH_SERVER_URL = "https://photos.${config.homefree.system.domain}";
        IMMICH_HOST = "0.0.0.0";
        IMMICH_PORT = toString port;
      };
    };

    immich-machine-learning = {
      image = "ghcr.io/immich-app/immich-machine-learning:${version}";

      autoStart = true;

      extraOptions = [
        # "--pull=always"
        ## 1GB of memory, reduces SSD/SD Card wear
        "--mount=type=tmpfs,target=/tmp/cache,tmpfs-size=1000000000"
        "--device=/dev/bus/usb:/dev/bus/usb"  # Passes the USB Coral, needs to be modified for other versions
        "--device=/dev/dri:/dev/dri" # For intel hwaccel, needs to be updated for your hardware
        "--cap-add=CAP_PERFMON" # For GPU statistics
        "--privileged"
      ];

      volumes = [
        "/etc/localtime:/etc/localtime:ro"
        "${containerDataPath}:${uploadLocation}"
        "/var/cache/immich:/var/cache/immich"
      ];

      environment = {
        TZ = config.homefree.system.timeZone;

        MACHINE_LEARNING_WORKERS = "2";
        MACHINE_LEARNING_WORKER_TIMEOUT = "120";
        MACHINE_LEARNING_CACHE_FOLDER = "/var/cache/immich";
        IMMICH_HOST = "0.0.0.0";
        IMMICH_PORT = toString port-machine-learning;
      };
    };

    immich-redis = {
      image = "redis:${version-redis}";

      autoStart = true;

      extraOptions = [
        # "--pull=always"
        "--health-cmd=redis-cli ping || exit 1"
      ];

      volumes = [
        "/etc/localtime:/etc/localtime:ro"
      ];

      environment = {
        TZ = config.homefree.system.timeZone;
      };
    };
  };

  systemd.services.podman-immich-server = lib.optionalAttrs config.homefree.service-options.immich.enable {
    after = [ "dns-ready.service" ];
    requires = [ "dns-ready.service" ];
    partOf =  [ "nftables.service" ];
    serviceConfig = {
      ExecStartPre = [ "!${pkgs.writeShellScript "imimich-server-prestart" preStart}" ];
    };
  };

  systemd.services.podman-immich-machine-learning = lib.optionalAttrs config.homefree.service-options.immich.enable {
    after = [ "dns-ready.service" ];
    requires = [ "dns-ready.service" ];
    partOf =  [ "nftables.service" ];
  };

  systemd.services.podman-immich-redis = lib.optionalAttrs config.homefree.service-options.immich.enable {
    after = [ "dns-ready.service" ];
    requires = [ "dns-ready.service" ];
    partOf =  [ "nftables.service" ];
  };

    homefree.service-config = [{
      inherit (config.homefree.service-options.immich) label name project-name;
      release-tracking = {
        type = "github";
        project = "immich-app/immich";
      };
      systemd-service-names = [
        "podman-immich-server"
        "podman-immich-machine-learning"
        "podman-immich-redis"
        "podman-postgresql-vectorchord"
      ];
      reverse-proxy = {
        enable = config.homefree.service-options.immich.enable;
        subdomains = [ "photos" "immich" ];
        http-domains = [ "homefree.lan" config.homefree.system.localDomain ];
        https-domains = [ config.homefree.system.domain ];
        host = config.homefree.network.lan-address;
        port = port;
        public = config.homefree.service-options.immich.public;
      };
      backup = {
        paths = [
          containerDataPath
        ];
        # postgres-databases = [
        #   database-name
        # ];
      };
      options-metadata = [
        {
          path = "enable";
          type = "bool";
          default = false;
          description = "Enable Immich photo management service";
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
