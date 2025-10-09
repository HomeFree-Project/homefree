{ config, lib, pkgs, ... }:
let
  version = "32.0.0";
  version-redis = "7-alpine";
  version-appapi-harp = "v0.2.0";
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
  nextcloud-config = pkgs.writeText "override.config.php" ''
    <?php
    $CONFIG = array (
      'apps_paths' =>
      array (
        0 =>
        array (
          'path' => '/var/www/html/apps',
          'url' => '/apps',
          'writable' => false,
        ),
        1 =>
        array (
          'path' => '/var/www/html/custom_apps',
          'url' => '/custom_apps',
          'writable' => true,
        ),
      ),
      'app_install_overwrite' =>
      array (
        0 => 'tasks',
      ),
      'appstoreenabled' => true,
      'csrf' =>
      array (
        'optout' =>
        array (
          0 => '/Nextcloud-android/',
        ),
      ),
      'csrf.optout' =>
      array (
        '/Nextcloud-android/',
      ),
      'datadirectory' => '/var/www/html/data',
      'dbhost' => '/run/postgresql',
      'dbname' => 'nextcloud',
      'dbpassword' => "",
      'dbport' => "",
      'dbtableprefix' => 'oc_',
      'dbtype' => 'pgsql',
      'dbuser' => 'nextcloud',
      'default_phone_region' => '${if phoneRegion != null then phoneRegion else "US"}',
      'forwarded_for_headers' => array('HTTP_X_FORWARDED_FOR', 'HTTP_X_REAL_IP'),
      'htaccess' =>
      array (
        'RewriteBase' => "",
      ),
      'htaccess.RewriteBase' => '/',
      'log_type' => 'file',
      'loglevel' => 1,
      'memcache.local' => '\\OC\\Memcache\\APCu',
      'memcache.distributed' => '\\OC\\Memcache\\Redis',
      'memcache.locking' => '\\OC\\Memcache\\Redis',
      'oidc_login_auto_redirect' => true,
      'overwrite.cli.url' => 'https://${host}/',
      'overwritecondaddr' => '^10\\.0\\.0\\..*$',
      'overwritehost' => '${host}',
      'overwriteprotocol' => 'https',
      'overwritewebroot' => "",
      'maintenance_window_start' => 2,
      'profile.enabled' => true,
      'redis' =>
      array (
        'host' => 'nextcloud-redis',
        'port' => ${toString port-redis},
        'timeout' => 0.0,
      ),
      'skeletondirectory' => "",
      'social_login_auto_redirect' => true,
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
    );
  '';

  preStart = ''
    mkdir -p ${containerDataPath}/html

    # Copy override config
    cp -f ${nextcloud-config} ${containerDataPath}/config/override.config.php

    # Ensure proper permissions for www-data (uid 33)
    chown -R 33:33 ${containerDataPath}/data || true
    chown -R 33:33 ${containerDataPath}/config || true

    chmod o+rx ${containerDataPath}

    ## Create shared secret for AppApi proxy
    HARP_PASSWORD=$(${pkgs.coreutils}/bin/dd if=/dev/urandom bs=12 count=1 2>/dev/null | ${pkgs.coreutils}/bin/base64 | ${pkgs.coreutils}/bin/tr -d -- '\n' | ${pkgs.coreutils}/bin/tr -- '+/' '-_' ; echo)
    ## Password file used by postStart
    echo "$HARP_PASSWORD" > ${containerDataPath}/harp-pw.txt
    ## Env file used by app-api proxy docker container
    echo "HP_SHARED_KEY=$HARP_PASSWORD" > ${containerDataPath}/harp-env.txt

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

    # Enable pretty URLs (remove /index.php from URLs)
    ${pkgs.podman}/bin/podman exec nextcloud php occ config:system:set htaccess.RewriteBase --value='/'
    ${pkgs.podman}/bin/podman exec nextcloud php occ maintenance:update:htaccess

    HARP_PASSWORD=$(cat ${containerDataPath}/harp-pw.txt)

    ${pkgs.podman}/bin/podman exec nextcloud php occ app_api:daemon:unregister harp_proxy_host
    ${pkgs.podman}/bin/podman exec nextcloud php occ app_api:daemon:register \
      harp_proxy_host "HaRP Proxy (Host)" "docker-install" "http" \
      "nextcloud-appapi-harp:8780" "http://nextcloud" \
      --harp \
      --harp_frp_address "nextcloud-appapi-harp:8782" \
      --harp_shared_key "$HARP_PASSWORD" \
      --set-default

    # Install/enable apps
    ${pkgs.podman}/bin/podman exec nextcloud php occ config:system:set appstoreenabled --value=true --type=boolean

    ${pkgs.podman}/bin/podman exec nextcloud php occ app:enable news || true
    ${pkgs.podman}/bin/podman exec nextcloud php occ app:enable contacts || true
    ${pkgs.podman}/bin/podman exec nextcloud php occ app:enable calendar || true
    ${pkgs.podman}/bin/podman exec nextcloud php occ app:enable tasks || true
    ${pkgs.podman}/bin/podman exec nextcloud php occ app:enable deck || true
    ${pkgs.podman}/bin/podman exec nextcloud php occ app:enable logreader || true

    ## Disable logreader app that causes issues
    ## ${pkgs.podman}/bin/podman exec nextcloud php occ app:disable logreader || true

    # Run maintenance tasks
    ${pkgs.podman}/bin/podman exec nextcloud php occ maintenance:repair --include-expensive || true
    ${pkgs.podman}/bin/podman exec nextcloud php occ db:add-missing-indices
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

      ports = [
        "0.0.0.0:${toString port}:80"
      ];

      volumes = [
        "/etc/localtime:/etc/localtime:ro"
        "/run/postgresql:/run/postgresql"
        "${containerDataPath}/html:/var/www/html"
        "${containerDataPath}/config:/var/www/html/config"
        "${containerDataPath}/data:/var/www/html/data"
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

    nextcloud-appapi-harp = {
      image = "ghcr.io/nextcloud/nextcloud-appapi-harp:${version-appapi-harp}";

      autoStart = true;

      volumes = [
        "/etc/localtime:/etc/localtime:ro"
        "/run/podman/podman.sock:/var/run/docker.sock"
      ];

      environment = {
        TZ = config.homefree.system.timeZone;
        NC_INSTANCE_URL = "http://nextcloud";
      };

      environmentFiles = [
        "${containerDataPath}/harp-env.txt"
      ];
    };

    # Cron container for background jobs
    nextcloud-cron = {
      image = "nextcloud:${version}-apache";

      autoStart = true;

      cmd = [ "/cron.sh" ];

      volumes = [
        "/etc/localtime:/etc/localtime:ro"
        "/run/postgresql:/run/postgresql"
        "${containerDataPath}/html:/var/www/html"
        "${containerDataPath}/config:/var/www/html/config"
        "${containerDataPath}/data:/var/www/html/data"
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

  systemd.services.podman-nextcloud-appapi-harp = {
    after = [ "podman-nextcloud.service" ];
    requires = [ "podman-nextcloud.service" ];
    partOf = [ "podman-nextcloud.service" ];
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
        "podman-nextcloud-appapi-harp"
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
            # HTTP response headers borrowed from Nextcloud `.htaccess`
            Strict-Transport-Security "max-age=31536000; includeSubDomains"
            X-Content-Type-Options "nosniff"
            X-Frame-Options "SAMEORIGIN"
            Referrer-Policy "no-referrer"
            X-XSS-Protection "1; mode=block"
            X-Permitted-Cross-Domain-Policies "none"
            X-Robots-Tag "noindex,nofollow"
            X-Download-Options "noopen"
            Permissions-Policy "accelerometer=(), ambient-light-sensor=(), autoplay=(), battery=(), camera=(), cross-origin-isolated=(), display-capture=(), document-domain=(), encrypted-media=(), execution-while-not-rendered=(), execution-while-out-of-viewport=(), fullscreen=(), geolocation=(), gyroscope=(), keyboard-map=(), magnetometer=(), microphone=(), midi=(), navigation-override=(), payment=(), picture-in-picture=(), publickey-credentials-get=(), screen-wake-lock=(), sync-xhr=(), usb=(), web-share=(), xr-spatial-tracking=()"
          }

          request_body {
            max_size 10G
          }

          # Enable gzip but do not remove ETag headers
          encode {
            zstd
            gzip 4

            minimum_length 256

            match {
              header Content-Type application/atom+xml
              header Content-Type application/javascript
              header Content-Type application/json
              header Content-Type application/ld+json
              header Content-Type application/manifest+json
              header Content-Type application/rss+xml
              header Content-Type application/vnd.geo+json
              header Content-Type application/vnd.ms-fontobject
              header Content-Type application/wasm
              header Content-Type application/x-font-ttf
              header Content-Type application/x-web-app-manifest+json
              header Content-Type application/xhtml+xml
              header Content-Type application/xml
              header Content-Type font/opentype
              header Content-Type image/bmp
              header Content-Type image/svg+xml
              header Content-Type image/x-icon
              header Content-Type text/cache-manifest
              header Content-Type text/css
              header Content-Type text/plain
              header Content-Type text/vcard
              header Content-Type text/vnd.rim.location.xloc
              header Content-Type text/vtt
              header Content-Type text/x-component
              header Content-Type text/x-cross-domain-policy
            }
          }

          route /.well-known/* {
            redir /.well-known/carddav /remote.php/dav/ permanent
            redir /.well-known/caldav /remote.php/dav/ permanent
            redir /.well-known/webfinger /index.php/.well-known/webfinger permanent

            @well-known-static path \
              /.well-known/acme-challenge /.well-known/acme-challenge/* \
              /.well-known/pki-validation /.well-known/pki-validation/*
            route @well-known-static {
              try_files {path} {path}/ =404
            }

            redir * /index.php{path} permanent
          }
        '';
      };
      backup = {
        paths = [
          "${containerDataPath}/html/data"
          "${containerDataPath}/html/config"
        ];
        postgres-databases = if (!use-postgres-vectorchord) then [
          database-name
        ] else [];
      };
    }
  ] else [];
}

