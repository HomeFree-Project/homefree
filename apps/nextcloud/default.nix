{ config, lib, pkgs, ... }:
let
  version = "33.0.5";
  version-redis = "8.8.0";
  version-appapi-harp = "v0.4.0";
  containerDataPath = "/var/lib/nextcloud-podman";

  ## Anchors auto-generated secrets into encrypted /etc/nixos/secrets
  ## so they survive a restore — see lib/secrets-anchor.nix.
  anchor = import ../../lib/secrets-anchor.nix { inherit lib pkgs; };

  port = config.homefree.allocPort "nextcloud";
  port-redis = 6379; # Different from other Redis instances
  database-name = "nextcloud";
  database-user = "nextcloud";

  host = "nextcloud.${config.homefree.system.domain}";
  countryCode = config.homefree.system.countryCode;
  phoneRegion = if countryCode != null then (lib.toUpper countryCode) else null;

  postgres-host = "/run/postgresql";
  postgres-port = 5432;

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
      ## Nextcloud's HTTP client (Guzzle + DnsPinMiddleware) blocks
      ## outbound requests to RFC1918 / link-local IPs by default
      ## (SSRF guard). Our Zitadel runs on the same host at the LAN
      ## address, so user_oidc's discovery fetch to
      ## https://sso.<domain>/ resolves to a private IP and gets
      ## refused with "violates local access rules". This switch
      ## permits same-host / LAN service-to-service calls — required
      ## for any internal-IdP OIDC setup.
      'allow_local_remote_servers' => true,
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
      'loglevel' => 2,         // 0: debug, 1: info, 2: warn, 3: error, 4: fatal. Default: warn
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
        1 => '${config.homefree.network.lan-address}:${toString port}',
        2 => '${host}',
      ),
      'trusted_proxies' =>
      array (
        ## The Caddy reverse proxy lives on the LAN address. When it
        ## proxies into the nextcloud container the request appears
        ## to come from this IP — Nextcloud only honors X-Forwarded-*
        ## headers (including X-Forwarded-Proto, which is what
        ## convinces user_oidc the connection is HTTPS) when the
        ## remote IP is in this list. Without it, OIDC bails with
        ## "You must access Nextcloud with HTTPS to use OpenID
        ## Connect" because PHP sees a plain-HTTP upstream call.
        0 => '${config.homefree.network.lan-address}',
        ## Podman default network — covers any same-host container
        ## that talks to Nextcloud directly (e.g., HaRP proxy).
        1 => '10.88.0.0/16',
      ),
    );
  '';

  preStart = ''
    mkdir -p ${containerDataPath}/html
    mkdir -p ${containerDataPath}/config
    mkdir -p ${containerDataPath}/data
    mkdir -p /var/lib/homefree-secrets/nextcloud

    # Copy override config
    cp -f ${nextcloud-config} ${containerDataPath}/config/override.config.php

    # Ensure proper permissions for www-data (uid 33)
    chown -R 33:33 ${containerDataPath}/data || true
    chown -R 33:33 ${containerDataPath}/config || true

    chmod o+rx ${containerDataPath}

    ## Create shared secret for AppApi proxy (only if it doesn't exist)
    if [ ! -f ${containerDataPath}/harp-pw.txt ]; then
      HARP_PASSWORD=$(${pkgs.coreutils}/bin/dd if=/dev/urandom bs=12 count=1 2>/dev/null | ${pkgs.coreutils}/bin/base64 | ${pkgs.coreutils}/bin/tr -d -- '\n' | ${pkgs.coreutils}/bin/tr -- '+/' '-_' ; echo)
      ## Password file used by postStart
      echo "$HARP_PASSWORD" > ${containerDataPath}/harp-pw.txt
      ## Env file used by app-api proxy docker container
      echo "HP_SHARED_KEY=$HARP_PASSWORD" > ${containerDataPath}/harp-env.txt
    fi

    ## Note: an earlier iteration synthesised a system-CA bundle
    ## here and bind-mounted it over /etc/ssl/certs/ca-certificates.crt
    ## inside the container. That doesn't help Nextcloud — the
    ## official PHP HTTP client (Guzzle in OC\Http\Client\Client)
    ## ignores the system bundle and uses its own bundled cert
    ## list at /var/www/html/resources/config/ca-bundle.crt. The
    ## supported way to extend trust is `occ security:certificates:
    ## import` (writes to data/files_external/rootcerts.crt which
    ## Nextcloud loads in addition to the bundled certs). That
    ## happens in postStart below; nothing to do here at preStart.
    ##
    ## Nextcloud admin password — the install wizard bootstraps the
    ## admin user with it; afterwards it's an emergency escape hatch
    ## (users log in via Zitadel). Anchored into encrypted
    ## /etc/nixos/secrets so it survives a restore (lib/secrets-anchor.nix).
    ${anchor.preamble}
    ${anchor.anchorSecret {
      service = "nextcloud";
      key = "admin-password";
      dir = "/var/lib/homefree-secrets/nextcloud";
      generate = "${pkgs.openssl}/bin/openssl rand -base64 24";
    }}

    ## DB password for the "nextcloud" Postgres role. Today the
    ## container connects via the bind-mounted /run/postgresql socket
    ## under trust auth (services/postgres pg_hba), so the value is
    ## carried-but-not-enforced. Anchoring it now lets Phase 2 swap
    ## the host pg_hba from trust → scram-sha-256 without changing
    ## anything in this module.
    ${anchor.anchorSecret {
      service = "nextcloud";
      key = "db-password";
      dir = "/var/lib/homefree-secrets/nextcloud";
      generate = "${pkgs.openssl}/bin/openssl rand -base64 32 | tr -d '/+=' | head -c 32";
    }}

    ## Synthesise the env file the container reads. POSTGRES_PASSWORD
    ## is kept in sync with the role's password — the role-creation
    ## DO-block below reads the same anchored file. NEXTCLOUD_ADMIN_PASSWORD
    ## is what the install wizard uses to provision the initial admin
    ## user named after homefree.system.adminUsername (set via
    ## NEXTCLOUD_ADMIN_USER in the container env).
    install -m 600 /dev/null ${containerDataPath}/runtime.env
    {
      echo "POSTGRES_PASSWORD=$(cat /var/lib/homefree-secrets/nextcloud/db-password)"
      echo "NEXTCLOUD_ADMIN_PASSWORD=$(cat /var/lib/homefree-secrets/nextcloud/admin-password)"
    } > ${containerDataPath}/runtime.env

    # Database initialization for the host postgres
    ${''
      NEXTCLOUD_DB_PASSWORD=$(cat /var/lib/homefree-secrets/nextcloud/db-password)

      ${pkgs.postgresql}/bin/psql -h ${postgres-host} -p ${toString postgres-port} -U postgres << EOF
        DO
        \$do\$
        BEGIN
           IF EXISTS (
              SELECT FROM pg_catalog.pg_roles
              WHERE  rolname = '${database-user}') THEN

              RAISE NOTICE 'Role "${database-user}" already exists. Skipping.';
           ELSE
              BEGIN   -- nested block
                 CREATE ROLE "${database-user}" WITH LOGIN PASSWORD '$NEXTCLOUD_DB_PASSWORD';
              EXCEPTION
                 WHEN duplicate_object THEN
                    RAISE NOTICE 'Role "${database-user}" was just created by a concurrent transaction. Skipping.';
              END;
           END IF;
        END
        \$do\$;
      EOF

      ## Unconditional rotation: idempotent ALTER. On a pre-anchoring
      ## box this swaps the historical literal "changeme" for the
      ## anchored value; subsequent rebuilds set it to itself.
      ${pkgs.postgresql}/bin/psql -h ${postgres-host} -p ${toString postgres-port} -U postgres \
        -c "ALTER ROLE \"${database-user}\" WITH PASSWORD '$NEXTCLOUD_DB_PASSWORD'"

      ${pkgs.postgresql}/bin/psql -h ${postgres-host} -p ${toString postgres-port} -U postgres -tc "SELECT 1 FROM pg_database WHERE datname = '${database-name}'" | ${pkgs.gnugrep}/bin/grep -q 1 || ${pkgs.postgresql}/bin/psql -h ${postgres-host} -p ${toString postgres-port} -U postgres -c "CREATE DATABASE \"${database-name}\" WITH OWNER \"${database-user}\" ENCODING 'UTF8' LOCALE 'C' TEMPLATE template0"

      ${pkgs.postgresql}/bin/psql -h ${postgres-host} -p ${toString postgres-port} -X -U postgres << EOF
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

    # Check if Nextcloud is installed
    if ! ${pkgs.podman}/bin/podman exec nextcloud php occ status 2>/dev/null | grep -q "installed: true"; then
      echo "Nextcloud is not installed yet. Skipping post-start configuration."
      echo "Please run the Nextcloud installation wizard or use occ maintenance:install"
      exit 0
    fi

    # Enable pretty URLs (remove /index.php from URLs)
    ${pkgs.podman}/bin/podman exec nextcloud php occ config:system:set htaccess.RewriteBase --value='/'
    ${pkgs.podman}/bin/podman exec nextcloud php occ maintenance:update:htaccess

    ${lib.optionalString config.homefree.service-options.nextcloud.appapi ''
      ## AppAPI HaRP daemon registration. Only fires when the appapi
      ## option is on — otherwise the daemon would point at a
      ## non-existent container and silently break sidecar-app
      ## installs from the Nextcloud UI.
      HARP_PASSWORD=$(cat ${containerDataPath}/harp-pw.txt)

      ${pkgs.podman}/bin/podman exec nextcloud php occ app_api:daemon:unregister harp_proxy_host
      ${pkgs.podman}/bin/podman exec nextcloud php occ app_api:daemon:register \
        harp_proxy_host "HaRP Proxy (Host)" "docker-install" "http" \
        "nextcloud-appapi-harp:8780" "http://nextcloud" \
        --harp \
        --harp_frp_address "nextcloud-appapi-harp:8782" \
        --harp_shared_key "$HARP_PASSWORD" \
        --set-default
    ''}

    # Install/enable apps
    ${pkgs.podman}/bin/podman exec nextcloud php occ config:system:set appstoreenabled --value=true --type=boolean

    ${pkgs.podman}/bin/podman exec nextcloud php occ app:enable bookmarks || true
    ${pkgs.podman}/bin/podman exec nextcloud php occ app:enable calendar || true
    ${pkgs.podman}/bin/podman exec nextcloud php occ app:enable contacts || true
    ${pkgs.podman}/bin/podman exec nextcloud php occ app:enable deck || true
    ${pkgs.podman}/bin/podman exec nextcloud php occ app:enable logreader || true
    ${pkgs.podman}/bin/podman exec nextcloud php occ app:enable news || true
    ${pkgs.podman}/bin/podman exec nextcloud php occ app:enable sociallogin || true
    ${pkgs.podman}/bin/podman exec nextcloud php occ app:enable tasks || true

    ## Disable logreader app that causes issues
    ## ${pkgs.podman}/bin/podman exec nextcloud php occ app:disable logreader || true

    # Run maintenance tasks
    ${pkgs.podman}/bin/podman exec nextcloud php occ maintenance:repair --include-expensive || true
    ${pkgs.podman}/bin/podman exec nextcloud php occ db:add-missing-indices

    ## Register Zitadel as a user_oidc provider once the OIDC secrets
    ## have been written by zitadel-provision.service. Idempotent: if
    ## "Zitadel" already appears in `occ user_oidc:provider`, skip the
    ## upsert. Pre-provisioning the secrets are absent, so we just
    ## leave the existing local-account login flow in place.
    if [ -s /var/lib/homefree-secrets/nextcloud/oidc-client-id ] \
       && [ -s /var/lib/homefree-secrets/nextcloud/oidc-client-secret ]; then
      ${pkgs.podman}/bin/podman exec nextcloud php occ app:install user_oidc 2>/dev/null || true
      ${pkgs.podman}/bin/podman exec nextcloud php occ app:enable user_oidc || true

      ## Trust Caddy's local CA inside Nextcloud. user_oidc fetches
      ## the discovery URL via Nextcloud's Guzzle client, which uses
      ## its own bundle at /var/www/html/resources/config/ca-bundle.crt
      ## (NOT the system /etc/ssl/certs bundle). The supported way to
      ## extend trust is `occ security:certificates:import` — it
      ## appends to data/files_external/rootcerts.crt, which Nextcloud
      ## loads in addition to its bundled certs and survives upgrades.
      ## Idempotent: importing the same cert twice is a no-op.
      if [ -r /var/lib/caddy/.local/share/caddy/pki/authorities/local/root.crt ]; then
        ${pkgs.podman}/bin/podman cp \
          /var/lib/caddy/.local/share/caddy/pki/authorities/local/root.crt \
          nextcloud:/tmp/caddy-local-root.crt 2>/dev/null || true
        ## podman cp preserves the source file's 0600 root:root mode,
        ## but `occ` runs as www-data inside the container — without
        ## a chmod here `security:certificates:import` fails with
        ## "Certificate could not get parsed" (it can't even open
        ## the file). Verified manually: with 0644 the import
        ## succeeds and the discovery endpoint validates.
        ${pkgs.podman}/bin/podman exec nextcloud chmod 644 /tmp/caddy-local-root.crt 2>/dev/null || true
        ${pkgs.podman}/bin/podman exec nextcloud php occ \
          security:certificates:import /tmp/caddy-local-root.crt 2>&1 \
          | ${pkgs.gnugrep}/bin/grep -v "already exists" || true
        ${pkgs.podman}/bin/podman exec nextcloud rm -f /tmp/caddy-local-root.crt 2>/dev/null || true
      fi

      ## Register or update the Zitadel provider. The `user_oidc:provider`
      ## subcommand creates if absent and updates if present (same
      ## invocation), so we run it every postStart to keep the
      ## scope / mapping fields in sync with whatever this Nix
      ## module declares.
      CID=$(cat /var/lib/homefree-secrets/nextcloud/oidc-client-id)
      CSEC=$(cat /var/lib/homefree-secrets/nextcloud/oidc-client-secret)
      ## Zitadel emits project roles under the namespaced claim
      ## `urn:zitadel:iam:org:project:roles`. user_oidc supports a
      ## --mapping-groups flag pointing at the claim that lists the
      ## user's groups. Combined with the `admin_group` config below,
      ## Nextcloud grants the `admin` system group to any user whose
      ## token includes `homefree-admin` in that claim.
      ${pkgs.podman}/bin/podman exec nextcloud php occ user_oidc:provider Zitadel \
        --clientid="$CID" \
        --clientsecret="$CSEC" \
        --discoveryuri="https://sso.${config.homefree.system.domain}/.well-known/openid-configuration" \
        --scope="openid email profile urn:zitadel:iam:org:project:roles" \
        --mapping-display-name=name \
        --mapping-email=email \
        --mapping-uid=preferred_username \
        --mapping-groups=urn:zitadel:iam:org:project:roles \
        --group-provisioning=1 \
        --unique-uid=0 \
        || echo "nextcloud postStart: user_oidc:provider registration failed (non-fatal)" >&2

      ## Map `homefree-admin` (the only project role we mint) to
      ## Nextcloud's built-in `admin` group. user_oidc reads this
      ## list to decide which OIDC groups grant admin powers.
      ${pkgs.podman}/bin/podman exec nextcloud php occ \
        config:app:set --type=string --value='["homefree-admin"]' \
        user_oidc admin_groups \
        || echo "nextcloud postStart: admin_groups set failed (non-fatal)" >&2

      ## Force auto-redirect to Zitadel on every unauthenticated visit
      ## by disabling Nextcloud's other login backends. The README
      ## (https://github.com/nextcloud/user_oidc#disable-other-login-methods)
      ## documents this exact behavior: with a single OIDC provider
      ## configured AND allow_multiple_user_backends=0, the standard
      ## login form is never shown — visiting nextcloud.<domain>
      ## bounces straight to Zitadel.
      ##
      ## Emergency escape hatch: append `?direct=1` to the login URL
      ## (https://nextcloud.<domain>/login?direct=1) to reach the
      ## local password form for the auto-generated admin user (see
      ## /var/lib/homefree-secrets/nextcloud/admin-password). Keep
      ## this in mind if SSO breaks — without ?direct=1 you'll be
      ## stuck in a redirect loop to a broken Zitadel.
      ${pkgs.podman}/bin/podman exec nextcloud php occ \
        config:app:set --type=string --value=0 user_oidc allow_multiple_user_backends \
        || echo "nextcloud postStart: failed to set allow_multiple_user_backends (non-fatal)" >&2
    fi
  '';

  userOptions = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "enable Nextcloud media server";
    };

    public = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Open to public on WAN port";
    };

    appapi = lib.mkOption {
      type = lib.types.bool;
      ## Default-off security posture. An earlier iteration tried an
      ## upgrade-shim — `builtins.pathExists
      ## "/var/lib/nextcloud-podman/harp-pw.txt"` to preserve existing
      ## AppAPI users — but flake evaluation runs in pure mode and
      ## refuses to inspect host paths outside the flake source, so
      ## pathExists always returns false in this codebase. Hardcoded
      ## false is honest about the actual behaviour: every box gets
      ## AppAPI off unless the operator explicitly opts in.
      ##
      ## The bind-mount of /run/podman/podman.sock that this container
      ## requires is functionally equivalent to root on the host — see
      ## the description below for the threat model.
      default = false;
      description = ''
        Enable the Nextcloud AppAPI HaRP proxy container. Required
        for Nextcloud-managed sidecar apps (Whiteboard, Talk
        Recording, Speech-to-text, Assistant, OCR, LibreTranslate,
        etc.) — they are installed via the Nextcloud Apps UI under
        "External Apps" and orchestrated through this container.

        Default: false. AppAPI is opt-in security-by-default because
        the container bind-mounts /run/podman/podman.sock, which is
        the host's container-management API socket. Any code reaching
        that socket — through a vulnerability in HaRP itself, a
        compromised External App, or an exploit in Nextcloud's
        AppAPI registration endpoints — can spawn a new container
        that mounts the host filesystem and gains root on the host.

        Leave off unless you actively use External Apps. Enabling is
        a one-line change in homefree-config.json
        (`homefree.services.nextcloud.appapi = true`) or a toggle on
        the Nextcloud service config page in the admin UI.
      '';
    };
  };
in
{
  options.homefree.services.nextcloud = userOptions;
  options.homefree.service-options.nextcloud = userOptions // {
    # Metadata - always available, not user-configurable
    label = lib.mkOption {
      type = lib.types.str;
      default = "nextcloud";
      internal = true;
      description = "Service label";
    };

    name = lib.mkOption {
      type = lib.types.str;
      default = "Personal Cloud Service Suite";
      internal = true;
      description = "Service display name";
    };

    project-name = lib.mkOption {
      type = lib.types.str;
      default = "Nextcloud";
      internal = true;
      description = "Project name";
    };
  };

  config = {
    # Database setup - only if using local postgres (not podman postgres)
    services.postgresql = lib.optionalAttrs config.homefree.service-options.nextcloud.enable {
    ensureDatabases = [ database-name ];
    ensureUsers = [
      {
        name = database-user;
        ensureDBOwnership = true;
        ensureClauses.login = true;
      }
    ];
  };

  ## Four containers via the app-platform primitive (modules/app-platform.nix):
  ## the podman dns-ready units are generated. All run as ROOT (the upstream
  ## nextcloud/redis/appapi-harp images run as root / expose no rootless uid),
  ## so no chown marker is emitted. The nextcloud container's bespoke preStart
  ## (mkdirs, override.config.php copy, www-data chown, HaRP secret, secret
  ## anchoring, runtime.env + host-postgres role/db init) is reproduced verbatim
  ## via dataDir=null + caBundle=false + preStartInit (the radicle/linkwarden
  ## fallback); its occ postStart and the postgres/cron/appapi ordering stay as
  ## separate systemd.services merges below.
  homefree.containers.nextcloud = lib.mkIf config.homefree.service-options.nextcloud.enable {
    image = "nextcloud:${version}-apache";
    runAs = { mode = "root"; reason = "upstream nextcloud-apache image runs as root; data is chowned to www-data (33) in preStart"; };
    dataDir = null;
    caBundle = false;

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
      POSTGRES_PORT = toString postgres-port;
      POSTGRES_DB = database-name;
      POSTGRES_USER = database-user;

      # Redis configuration
      REDIS_HOST = "nextcloud-redis";
      REDIS_HOST_PORT = toString port-redis;

      # Nextcloud configuration
      NEXTCLOUD_ADMIN_USER = config.homefree.system.adminUsername;
      NEXTCLOUD_TRUSTED_DOMAINS = "${host} ${config.homefree.network.lan-address}";
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

    ## runtime.env is synthesised by preStart from the on-disk
    ## admin-password (auto-generated on first boot) plus the
    ## hardcoded postgres password.
    environmentFiles = [
      "${containerDataPath}/runtime.env"
    ];

    ## Whole bespoke preStart, reproduced verbatim (mkdirs, override config
    ## copy, www-data chown, HaRP secret, secret anchoring, runtime.env, and
    ## the host-postgres role/database init).
    preStartInit = preStart;
  };

  homefree.containers.nextcloud-redis = lib.mkIf config.homefree.service-options.nextcloud.enable {
    image = "redis:${version-redis}";
    runAs = { mode = "root"; reason = "redis image exposes no uid option for rootless pinning"; };
    dataDir = null;
    caBundle = false;

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
  homefree.containers.nextcloud-cron = lib.mkIf config.homefree.service-options.nextcloud.enable {
    image = "nextcloud:${version}-apache";
    runAs = { mode = "root"; reason = "upstream nextcloud-apache image runs as root; shares the nextcloud data dirs"; };
    dataDir = null;
    caBundle = false;

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
      POSTGRES_PORT = toString postgres-port;
      POSTGRES_DB = database-name;
      POSTGRES_USER = database-user;

      # Redis configuration
      REDIS_HOST = "nextcloud-redis";
      REDIS_HOST_PORT = toString port-redis;

      # Nextcloud configuration
      NEXTCLOUD_ADMIN_USER = config.homefree.system.adminUsername;
      NEXTCLOUD_TRUSTED_DOMAINS = "${host} ${config.homefree.network.lan-address}";
      NEXTCLOUD_UPDATE = "0"; # Disable auto-update
      OVERWRITEPROTOCOL = "https";
      OVERWRITEHOST = host;
      OVERWRITE_CLI_URL = "https://${host}";

      # PHP configuration
      PHP_MEMORY_LIMIT = "1024M";
      PHP_UPLOAD_LIMIT = "1024M";
    };

    ## Same runtime.env as the main container — POSTGRES_PASSWORD
    ## is needed for the cron container's DB queries.
    environmentFiles = [
      "${containerDataPath}/runtime.env"
    ];
  };

  ## AppAPI HaRP proxy — opt-in, gates the podman.sock bind-mount
  ## behind an explicit option. See the comment on the option in
  ## userOptions for the security trade-off. Only emitted when
  ## appapi=true, so it stays absent on default deployments.
  homefree.containers.nextcloud-appapi-harp = lib.mkIf
    (config.homefree.service-options.nextcloud.enable
     && config.homefree.service-options.nextcloud.appapi) {
    image = "ghcr.io/nextcloud/nextcloud-appapi-harp:${version-appapi-harp}";
    runAs = { mode = "root"; reason = "HaRP proxy image runs as root and bind-mounts the podman socket"; };
    dataDir = null;
    caBundle = false;

    volumes = [
      "/etc/localtime:/etc/localtime:ro"
      ## Bind-mounts the host podman socket — this is the docker-
      ## compatible API AppAPI uses to spawn sidecar apps. It is
      ## also the container-escape surface that gates this whole
      ## entry behind `homefree.services.nextcloud.appapi`.
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

  ## nextcloud's bespoke occ postStart + the postgres ordering, merged onto the
  ## app-platform-generated unit (the dns-ready after/wants and the ExecStartPre
  ## come from the primitive).
  systemd.services.podman-nextcloud = lib.mkIf config.homefree.service-options.nextcloud.enable {
    after = [ "postgresql.service" ];
    wants = [ "postgresql.service" ];
    ## The container bind-mounts the host's /run/postgresql (a per-boot
    ## tmpfs that postgresql.service owns via RuntimeDirectory). When
    ## Postgres restarts it recreates that directory with a fresh
    ## inode, orphaning the container's existing mount — the container
    ## then sees an empty dir and "connection to socket failed".
    ## partOf makes a Postgres restart propagate a restart here so the
    ## bind mount is re-established against the live directory.
    partOf = [ "postgresql.service" ];
    serviceConfig = {
      ExecStartPost = [ "!${pkgs.writeShellScript "nextcloud-poststart" postStart}" ];
      # Add restart delay to prevent rapid restart loops
      RestartSec = 30;
    };
    # Limit restart attempts to prevent infinite loops
    startLimitBurst = 3;
    startLimitIntervalSec = 300;  # 5 minutes
  };

  systemd.services.podman-nextcloud-appapi-harp = lib.mkIf
    (config.homefree.service-options.nextcloud.enable
     && config.homefree.service-options.nextcloud.appapi) {
    after = [ "podman-nextcloud.service" ];
    requires = [ "podman-nextcloud.service" ];
    partOf = [ "podman-nextcloud.service" ];
  };

  systemd.services.podman-nextcloud-cron = lib.mkIf config.homefree.service-options.nextcloud.enable {
    after = [ "podman-nextcloud.service" ];
    requires = [ "podman-nextcloud.service" ];
  };

    homefree.service-config = [{
      inherit (config.homefree.service-options.nextcloud) label name project-name;
      port-request = null;
      enable = config.homefree.service-options.nextcloud.enable;
      release-tracking = {
        type = "github";
        project = "nextcloud/server";
      };
      systemd-service-names = [
        "podman-nextcloud"
        "podman-nextcloud-redis"
        "podman-nextcloud-cron"
        "postgresql"
      ] ++ lib.optional config.homefree.service-options.nextcloud.appapi
        "podman-nextcloud-appapi-harp";
      sso = {
        kind = "native_oidc";
        ## Dev context (intentionally not surfaced in the admin UI):
        ## user_oidc provider; homefree-admin role maps to Nextcloud
        ## admin group. Emergency escape hatch: /login?direct=1 for
        ## local password fallback.
      };
      reverse-proxy = {
        enable = config.homefree.service-options.nextcloud.enable;
        subdomains = [ "nextcloud" ];
        http-domains = [ "homefree.lan" config.homefree.system.localDomain ];
        https-domains = [ config.homefree.system.domain ];
        host = config.homefree.network.lan-address;
        port = port;
        public = config.homefree.service-options.nextcloud.public;
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
        postgres-databases = [
          database-name
        ];
      };
      options-metadata = [
        {
          path = "enable";
          type = "bool";
          default = false;
          description = "Enable Nextcloud media server";
        }
        {
          path = "public";
          type = "bool";
          default = false;
          description = "Make service accessible from WAN";
        }
        {
          path = "appapi";
          type = "bool";
          default = false;
          description = ''
            Enable AppAPI sidecar apps (Whiteboard, Talk Recording, Speech-to-text, OCR, etc.).
            Security note: AppAPI requires bind-mounting the host podman socket into a container.
            That socket grants effective root on the host to anything that can reach it — a
            vulnerability in HaRP, a compromised External App, or an exploit in Nextcloud's
            AppAPI endpoints could escape to the host. Leave off unless you actually install
            External Apps from the Nextcloud Apps UI.
          '';
        }
      ];
    }];
  };
}

