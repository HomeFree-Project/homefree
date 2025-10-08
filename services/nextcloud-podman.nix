{ config, lib, pkgs, ... }:
let
  version = "31.0.9";
  version-redis = "7-alpine";
  containerDataPath = "/var/lib/nextcloud-podman";

  port = 3010;
  port-redis = 6379; # Different from other Redis instances
  database-name = "nextcloud";
  database-user = "nextcloud";

  host = "nextcloud.${config.homefree.system.domain}";
  countryCode = config.homefree.system.countryCode;
  phoneRegion = if countryCode != null then (lib.toUpper countryCode) else null;

  # Database configuration - prefer postgres-vectorchord if available
  use-postgres-vectorchord = false; # Set to true to use postgres-vectorchord instead of local postgres
  postgres-host = if use-postgres-vectorchord then "postgres-vectorchord" else "/run/postgresql";
  postgres-port = if use-postgres-vectorchord then "6432" else "5432";

  # Nextcloud configuration file
  nextcloud-config = pkgs.writeText "nextcloud-config.php" ''
    <?php
    $CONFIG = array (
      'trusted_domains' =>
      array (
        0 => 'localhost',
        1 => '10.0.0.1:${toString port}',
        2 => '${host}',
      ),
      'trusted_proxies' =>
      array (
        0 => '10.0.0.0/16',
        1 => '10.88.0.0/16',
      ),
      'overwriteprotocol' => 'https',
      'overwritehost' => '${host}',
      'overwrite.cli.url' => 'https://${host}/',
      'default_phone_region' => '${if phoneRegion != null then phoneRegion else "US"}',
      'csrf.optout' =>
      array (
        '/Nextcloud-android/',
      ),
      'maintenance_window_start' => 2,
      'redis' =>
      array (
        'host' => 'nextcloud-redis',
        'port' => ${toString port-redis},
        'timeout' => 0.0,
      ),
      'memcache.local' => '\\OC\\Memcache\\APCu',
      'memcache.distributed' => '\\OC\\Memcache\\Redis',
      'memcache.locking' => '\\OC\\Memcache\\Redis',
    );
  '';

  preStart = ''
    mkdir -p ${containerDataPath}/html
    mkdir -p ${containerDataPath}/data
    mkdir -p ${containerDataPath}/config
    mkdir -p ${containerDataPath}/custom_apps
    mkdir -p ${containerDataPath}/themes

    # Copy config if needed
    if [ ! -f ${containerDataPath}/config/override.config.php ]; then
      cp ${nextcloud-config} ${containerDataPath}/config/override.config.php
    fi

    # Ensure proper permissions for www-data (uid 33)
    chown -R 33:33 ${containerDataPath}/data || true
    chown -R 33:33 ${containerDataPath}/config || true
    chown -R 33:33 ${containerDataPath}/custom_apps || true
    chown -R 33:33 ${containerDataPath}/themes || true

    # Database initialization for postgres-vectorchord if needed
    ${lib.optionalString use-postgres-vectorchord ''
      ${pkgs.postgresql}/bin/psql -h ${postgres-host} -p ${postgres-port} -U postgres << EOF
        DO
        \$do\$
        BEGIN
           IF EXISTS (
              SELECT FROM pg_catalog.pg_roles
              WHERE  rolname = '${database-user}') THEN

              RAISE NOTICE 'Role "${database-user}" already exists. Skipping.';
           ELSE
              BEGIN   -- nested block
                 CREATE ROLE "${database-user}" WITH LOGIN PASSWORD 'changeme';
              EXCEPTION
                 WHEN duplicate_object THEN
                    RAISE NOTICE 'Role "${database-user}" was just created by a concurrent transaction. Skipping.';
              END;
           END IF;
        END
        \$do\$;
      EOF

      ${pkgs.postgresql}/bin/psql -h ${postgres-host} -p ${postgres-port} -U postgres -tc "SELECT 1 FROM pg_database WHERE datname = '${database-name}'" | ${pkgs.gnugrep}/bin/grep -q 1 || ${pkgs.postgresql}/bin/psql -h ${postgres-host} -p ${postgres-port} -U postgres -c "CREATE DATABASE \"${database-name}\" WITH OWNER \"${database-user}\" ENCODING 'UTF8' LOCALE 'C' TEMPLATE template0"

      ${pkgs.postgresql}/bin/psql -h ${postgres-host} -p ${postgres-port} -X -U postgres << EOF
        DO
        \$do\$
        BEGIN
          GRANT ALL PRIVILEGES ON DATABASE "${database-name}" to "${database-user}";
        END
        \$do\$;
      EOF
    ''}
  '';

  postStart = ''
    # Wait for container to be ready
    sleep 10

    # Install/enable apps
    ${pkgs.podman}/bin/podman exec nextcloud php occ config:system:set appstoreenabled --value=true --type=boolean
    ${pkgs.podman}/bin/podman exec nextcloud php occ app:enable news || true
    ${pkgs.podman}/bin/podman exec nextcloud php occ app:enable contacts || true
    ${pkgs.podman}/bin/podman exec nextcloud php occ app:enable calendar || true
    ${pkgs.podman}/bin/podman exec nextcloud php occ app:enable tasks || true
    ${pkgs.podman}/bin/podman exec nextcloud php occ app:enable deck || true

    # Disable logreader app that causes issues
    ${pkgs.podman}/bin/podman exec nextcloud php occ app:disable logreader || true

    # Run maintenance tasks
    ${pkgs.podman}/bin/podman exec nextcloud php occ maintenance:repair --include-expensive || true
  '';
in
{
  # Database setup - only if using local postgres (not podman postgres)
  services.postgresql = if config.homefree.services.nextcloud.enable && !use-postgres-vectorchord then {
    ensureDatabases = [ database-name ];
    ensureUsers = [
      {
        name = database-user;
        ensureDBOwnership = true;
        ensureClauses.login = true;
      }
    ];
  } else {};

  virtualisation.oci-containers.containers = if config.homefree.services.nextcloud.enable then {
    nextcloud = {
      image = "nextcloud:${version}-apache";

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
        "${containerDataPath}/html:/var/www/html"
        # "${containerDataPath}/data:/var/www/html/data"
        # "${containerDataPath}/config:/var/www/html/config"
        # "${containerDataPath}/custom_apps:/var/www/html/custom_apps"
        # "${containerDataPath}/themes:/var/www/html/themes"
        "${nextcloud-config}:/var/www/html/config/override.config.php:ro"
      ];

      environment = {
        TZ = config.homefree.system.timeZone;

        # Database configuration
        POSTGRES_HOST = postgres-host;
        POSTGRES_PORT = postgres-port;
        POSTGRES_DB = database-name;
        POSTGRES_USER = database-user;

        # Redis configuration
        REDIS_HOST = "nextcloud-redis";
        REDIS_HOST_PORT = toString port-redis;

        # Nextcloud configuration
        NEXTCLOUD_ADMIN_USER = config.homefree.system.adminUsername;
        NEXTCLOUD_TRUSTED_DOMAINS = "${host} 10.0.0.1";
        NEXTCLOUD_UPDATE = "0"; # Disable auto-update
        OVERWRITEPROTOCOL = "https";
        OVERWRITEHOST = host;
        OVERWRITE_CLI_URL = "https://${host}";

        # PHP configuration
        PHP_MEMORY_LIMIT = "1024M";
        PHP_UPLOAD_LIMIT = "1024M";

        # Apache configuration
        APACHE_DISABLE_REWRITE_IP = "1";
      };

      ## @TODO: this shouldn't need to be exposed to user config
      environmentFiles = [
        config.homefree.services.nextcloud.secrets.env
      ];
    };

    nextcloud-redis = {
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

    # Cron container for background jobs
    nextcloud-cron = {
      image = "nextcloud:${version}-apache";

      autoStart = true;

      cmd = [ "/cron.sh" ];

      volumes = [
        "/etc/localtime:/etc/localtime:ro"
        "${containerDataPath}/html:/var/www/html"
        # "${containerDataPath}/data:/var/www/html/data"
        # "${containerDataPath}/config:/var/www/html/config"
        # "${containerDataPath}/custom_apps:/var/www/html/custom_apps"
        # "${containerDataPath}/themes:/var/www/html/themes"
      ];

      environment = {
        TZ = config.homefree.system.timeZone;

        # Database configuration (same as main container)
        POSTGRES_HOST = postgres-host;
        POSTGRES_PORT = postgres-port;
        POSTGRES_DB = database-name;
        POSTGRES_USER = database-user;

        # Redis configuration
        REDIS_HOST = "nextcloud-redis";
        REDIS_HOST_PORT = toString port-redis;
      };
    };
  } else {};

  systemd.services.podman-nextcloud = {
    after = [ "dns-ready.service" ] ++ lib.optional (!use-postgres-vectorchord) "postgresql.service"
                                      ++ lib.optional use-postgres-vectorchord "podman-postgres-vectorchord.service";
    requires = [ "dns-ready.service" ];
    wants = lib.optional (!use-postgres-vectorchord) "postgresql.service"
            ++ lib.optional use-postgres-vectorchord "podman-postgres-vectorchord.service";
    partOf = [ "nftables.service" ];
    serviceConfig = {
      ExecStartPre = [ "!${pkgs.writeShellScript "nextcloud-prestart" preStart}" ];
      ExecStartPost = [ "!${pkgs.writeShellScript "nextcloud-poststart" postStart}" ];
    };
  };

  systemd.services.podman-nextcloud-redis = {
    after = [ "dns-ready.service" ];
    requires = [ "dns-ready.service" ];
    partOf = [ "nftables.service" ];
  };

  systemd.services.podman-nextcloud-cron = {
    after = [ "podman-nextcloud.service" ];
    requires = [ "podman-nextcloud.service" ];
    partOf = [ "nftables.service" ];
  };

  homefree.service-config = if config.homefree.services.nextcloud.enable == true then [
    {
      label = "nextcloud";
      name = "Nextcloud";
      project-name = "Nextcloud";
      release-tracking = {
        type = "github";
        project = "nextcloud/server";
      };
      systemd-service-names = [
        "podman-nextcloud"
        "podman-nextcloud-redis"
        "podman-nextcloud-cron"
      ] ++ lib.optional (!use-postgres-vectorchord) "postgresql"
        ++ lib.optional use-postgres-vectorchord "podman-postgres-vectorchord";
      reverse-proxy = {
        enable = true;
        subdomains = [ "nextcloud" ];
        http-domains = [ "homefree.lan" config.homefree.system.localDomain ];
        https-domains = [ config.homefree.system.domain ];
        host = "10.0.0.1";
        port = port;
        public = config.homefree.services.nextcloud.public;
        extraCaddyConfig = ''
          # Nextcloud specific headers
          header {
            Strict-Transport-Security "max-age=31536000; includeSubDomains"
            X-Content-Type-Options "nosniff"
            X-Frame-Options "SAMEORIGIN"
            Referrer-Policy "no-referrer"
            X-XSS-Protection "1; mode=block"
            X-Permitted-Cross-Domain-Policies "none"
            X-Robots-Tag "none"
          }

          # CalDAV and CardDAV redirects
          redir /.well-known/carddav /remote.php/dav 301
          redir /.well-known/caldav /remote.php/dav 301

          # Security headers for DAV
          handle_path /remote.php/* {
            header {
              -X-Robots-Tag
            }
          }
        '';
      };
      backup = {
        paths = [
          "${containerDataPath}/data"
          "${containerDataPath}/config"
          "${containerDataPath}/custom_apps"
        ];
        postgres-databases = if (!use-postgres-vectorchord) then [
          database-name
        ] else [];
      };
    }
  ] else [];
}

