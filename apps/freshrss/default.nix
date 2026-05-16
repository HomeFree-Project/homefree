{ config, lib, pkgs, ... }:
let
  containerDataPath = "/var/lib/freshrss-podman";
  secretsDir = "/var/lib/homefree-secrets/freshrss";

  # image = "lscr.io/linuxserver/freshrss";
  image = "freshrss/freshrss";
  version = "1.28.1";

  port = 3028;

  domain = config.homefree.system.domain;
  ssoEnvFile = "${containerDataPath}/sso.env";

  ## FreshRSS's "default user" must match the Zitadel preferred_username
  ## of the homefree admin — otherwise the user authenticated by OIDC
  ## auto-creates as a regular user and there's no admin in the system.
  ## Using config.homefree.system.adminUsername here so a fresh install
  ## creates the right initial user.
  adminUsername = config.homefree.system.adminUsername;

  BASE_URL = "/";
  DB_BASE = "freshrss";
  ## libpq treats a host beginning with `/` as a unix socket directory.
  ## The host's /run/postgresql is bind-mounted into the container, so
  ## FreshRSS connects via the socket as the dedicated freshrss role.
  ## Bypasses HBA's TCP rules entirely (no more 'no pg_hba.conf entry
  ## for host 10.0.0.x' errors), matches the Nextcloud/MediaWiki
  ## pattern in this repo, and removes the need to grant the
  ## `postgres` superuser any TCP access from podman containers.
  DB_HOST = "/run/postgresql";
  DB_PASSWORD = "";
  DB_USER = "freshrss";
  ADMIN_API_PASSWORD = "changeme";
  ADMIN_EMAIL = "ellis@rahh.al";
  ADMIN_PASSWORD = "changeme";

  ## preStart synthesizes:
  ##   * ca-bundle.crt — system roots + Caddy local CA, mounted over
  ##     the Debian system bundle so mod_auth_openidc's libcurl trusts
  ##     sso.<domain> on discovery fetch.
  ##   * oidc-crypto-key — persistent random passphrase for
  ##     OIDC_CLIENT_CRYPTO_KEY (mod_auth_openidc uses it to encrypt
  ##     the OIDC state cookie; rotating it invalidates in-flight
  ##     logins, so we persist).
  ##   * sso.env — OIDC_* env vars built from Zitadel secrets. Empty
  ##     pre-provisioning so first boot proceeds with OIDC_ENABLED=0
  ##     and the local form/installer works.
  preStart = ''
    mkdir -p ${containerDataPath}/data
    mkdir -p ${containerDataPath}/extensions
    mkdir -p ${secretsDir}

    ## Postgres role/db bootstrap. Idempotent — re-running on every
    ## boot is fine. Uses unix-socket `local trust` HBA so no
    ## password handshake is needed.
    ${pkgs.postgresql}/bin/psql -h /run/postgresql -U postgres <<'PGEOF' || true
      DO $$
      BEGIN
        IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'freshrss') THEN
          CREATE ROLE freshrss LOGIN;
        END IF;
      END
      $$;
PGEOF
    ${pkgs.postgresql}/bin/psql -h /run/postgresql -U postgres -tc \
      "SELECT 1 FROM pg_database WHERE datname = 'freshrss'" \
      | ${pkgs.gnugrep}/bin/grep -q 1 \
      || ${pkgs.postgresql}/bin/psql -h /run/postgresql -U postgres \
           -c "CREATE DATABASE freshrss WITH OWNER freshrss ENCODING 'UTF8' TEMPLATE template0"
    ## If the freshrss DB was originally created when DB_USER was
    ## `postgres`, ownership stays with `postgres` and `freshrss` can
    ## connect but can't ALTER/INSERT. Reassign ownership and grant
    ## all on existing objects so an in-place migration just works.
    ${pkgs.postgresql}/bin/psql -h /run/postgresql -U postgres -d freshrss <<'PGEOF' || true
      ALTER DATABASE freshrss OWNER TO freshrss;
      REASSIGN OWNED BY postgres TO freshrss;
      GRANT ALL PRIVILEGES ON DATABASE freshrss TO freshrss;
      GRANT ALL ON SCHEMA public TO freshrss;
      GRANT ALL ON ALL TABLES IN SCHEMA public TO freshrss;
      GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO freshrss;
PGEOF

    {
      cat /etc/ssl/certs/ca-certificates.crt
      if [ -r /var/lib/caddy/.local/share/caddy/pki/authorities/local/root.crt ]; then
        echo
        cat /var/lib/caddy/.local/share/caddy/pki/authorities/local/root.crt
      fi
    } > ${containerDataPath}/ca-bundle.crt
    chmod 644 ${containerDataPath}/ca-bundle.crt

    if [ ! -s ${secretsDir}/oidc-crypto-key ]; then
      ${pkgs.openssl}/bin/openssl rand -hex 32 > ${secretsDir}/oidc-crypto-key
      chmod 600 ${secretsDir}/oidc-crypto-key
    fi

    install -m 600 /dev/null ${ssoEnvFile}
    if [ -s ${secretsDir}/oidc-client-id ] \
       && [ -s ${secretsDir}/oidc-client-secret ]; then
      CID=$(cat ${secretsDir}/oidc-client-id)
      CSEC=$(cat ${secretsDir}/oidc-client-secret)
      KEY=$(cat ${secretsDir}/oidc-crypto-key)
      {
        ## Apache mod_auth_openidc directives, templated by the
        ## FreshRSS image (see /etc/apache2/sites-available/
        ## FreshRSS.Apache.conf — OIDC_ENABLED gates the block).
        echo "OIDC_ENABLED=1"
        echo "OIDC_PROVIDER_METADATA_URL=https://sso.${domain}/.well-known/openid-configuration"
        echo "OIDC_CLIENT_ID=$CID"
        echo "OIDC_CLIENT_SECRET=$CSEC"
        echo "OIDC_CLIENT_CRYPTO_KEY=$KEY"
        ## Zitadel emits preferred_username — match it as the
        ## FreshRSS username (default already, set explicitly).
        echo "OIDC_REMOTE_USER_CLAIM=preferred_username"
        echo "OIDC_SCOPES=openid profile email"
        ## Caddy sends X-Forwarded-Host and X-Forwarded-Proto, NOT
        ## X-Forwarded-Port. Listing X-Forwarded-Port here makes
        ## mod_auth_openidc log warnings every request. Stick to
        ## the two Caddy actually emits.
        echo "OIDC_X_FORWARDED_HEADERS=X-Forwarded-Host X-Forwarded-Proto"
      } > ${ssoEnvFile}
    else
      : > ${ssoEnvFile}
    fi
    chmod 600 ${ssoEnvFile}
  '';

  ## postStart finishes the FreshRSS SSO migration once the install
  ## wizard has run and OIDC secrets are present. Three jobs:
  ##
  ##   1. Force auth_type to 'http_auth' (mod_auth_openidc populates
  ##      REMOTE_USER, FreshRSS reads it under http_auth mode and
  ##      auto-creates users on first login).
  ##   2. Force default_user to the homefree adminUsername (this is
  ##      who FreshRSS treats as the admin).
  ##   3. Rename a pre-existing 'admin' user to the homefree
  ##      adminUsername if (a) such a user exists and (b)
  ##      adminUsername != 'admin'. Otherwise the legacy 'admin' is
  ##      orphaned and the SSO sign-in creates a NEW non-admin user.
  ##
  ## Idempotent. Best-effort: any sub-step that fails (no container,
  ## DB not ready, user missing) is non-fatal.
  postStart = ''
    CFG=${containerDataPath}/data/config.php
    if [ ! -s "$CFG" ]; then
      exit 0
    fi

    ## (0) DB connection — migrate any older install that pointed at
    ## the postgres superuser over TCP. The new socket-based config
    ## requires DB user=freshrss, host=/run/postgresql, empty
    ## password. Idempotent: rerunning on an already-migrated config
    ## leaves it untouched.
    ${pkgs.gnused}/bin/sed -i \
      -E \
      -e "s|('host'[[:space:]]*=>[[:space:]]*)'[^']*'|\\1'/run/postgresql'|" \
      -e "s|('user'[[:space:]]*=>[[:space:]]*)'[^']*'|\\1'freshrss'|" \
      -e "s|('password'[[:space:]]*=>[[:space:]]*)'[^']*'|\\1'''|" \
      "$CFG"

    if ! [ -s ${secretsDir}/oidc-client-id ]; then
      exit 0
    fi

    ## (1) auth_type — replace if present, append if missing.
    if ${pkgs.gnugrep}/bin/grep -qE "'auth_type'[[:space:]]*=>" "$CFG"; then
      ${pkgs.gnused}/bin/sed -i \
        -E "s/('auth_type'[[:space:]]*=>[[:space:]]*)'[^']*'/\\1'http_auth'/" \
        "$CFG"
    else
      ## Append before the closing `);`. The file ends with `);`
      ## (PHP array close + EOF) per FreshRSS's var_export output.
      ${pkgs.gnused}/bin/sed -i \
        -E "s/^([[:space:]]*)\\);[[:space:]]*$/\\1  'auth_type' => 'http_auth',\n\\1);/" \
        "$CFG"
    fi

    ## (2) default_user — point at the homefree admin.
    if ${pkgs.gnugrep}/bin/grep -qE "'default_user'[[:space:]]*=>" "$CFG"; then
      ${pkgs.gnused}/bin/sed -i \
        -E "s/('default_user'[[:space:]]*=>[[:space:]]*)'[^']*'/\\1'${adminUsername}'/" \
        "$CFG"
    fi

    ## (3) Migrate a leftover 'admin' user to the SSO username, when
    ## they differ. Skip silently if the container isn't running or
    ## the source/target users don't exist.
    ${lib.optionalString (adminUsername != "admin") ''
      if ${pkgs.podman}/bin/podman exec freshrss ls /var/www/FreshRSS/data/users/admin >/dev/null 2>&1; then
        if ! ${pkgs.podman}/bin/podman exec freshrss ls /var/www/FreshRSS/data/users/${adminUsername} >/dev/null 2>&1; then
          echo "freshrss postStart: renaming legacy 'admin' user to '${adminUsername}'"
          ## FreshRSS user data lives in data/users/<username>; rename
          ## the directory + the PostgreSQL row identifying its tables.
          ## Below the CLI runs as www-data inside the container.
          ${pkgs.podman}/bin/podman exec -u www-data freshrss \
            php /var/www/FreshRSS/cli/rename-user.php \
            --user admin --new-user ${adminUsername} \
            || echo "freshrss postStart: rename-user.php failed (non-fatal)"
        fi
      fi
    ''}
  '';
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
          ## Bind-mount the host's postgres socket so FreshRSS can
          ## connect as unix:/run/postgresql instead of TCP. Avoids
          ## the missing pg_hba entry for the container's veth IP.
          "/run/postgresql:/run/postgresql"
          ## mod_auth_openidc uses libcurl, which on Debian honors
          ## /etc/ssl/certs/ca-certificates.crt — mount our combined
          ## bundle (system + Caddy local CA) on top so OIDC discovery
          ## against sso.<domain> validates.
          "${containerDataPath}/ca-bundle.crt:/etc/ssl/certs/ca-certificates.crt:ro"
        ];

        environment = {
          TZ = config.homefree.system.timeZone;
          FRESHRSS_ENV = "development";
          SERVER_DNS = "freshrss.${domain}";
          CRON_MIN = "1,31";
          # Optional auto-install parameters (the Web interface install is recommended instead):
          # ⚠️ Parameters below are only used at the very first run (so far).
          # So if changes are made (or in .env file), first delete the service and volumes.
          # ℹ️ All the --db-* parameters can be omitted if using built-in SQLite database.
          ## --default-user must match the Zitadel preferred_username
          ## of the homefree admin so the first OIDC sign-in lands on
          ## an admin account (FreshRSS's admin == the user whose name
          ## matches default-user). adminUsername comes from
          ## homefree.system.adminUsername.
          FRESHRSS_INSTALL = ''
            --api-enabled
            --base-url ${BASE_URL}
            --db-base ${DB_BASE}
            --db-host ${DB_HOST}
            --db-password ${DB_PASSWORD}
            --db-type pgsql
            --db-user ${DB_USER}
            --default-user ${adminUsername}
            --language en
          '';
          FRESHRSS_USER = ''
            --api-password ${ADMIN_API_PASSWORD}
            --email ${ADMIN_EMAIL}
            --language en
            --password ${ADMIN_PASSWORD}
            --user ${adminUsername}
          '';
        };

        ## OIDC_* env synthesized by preStart. Empty file pre-
        ## provisioning so OIDC_ENABLED defaults to undefined and the
        ## Apache <IfDefine OIDC_ENABLED> block is inert.
        environmentFiles = [ ssoEnvFile ];
      };
    };

    systemd.services.podman-freshrss = lib.optionalAttrs config.homefree.service-options.freshrss.enable {
      ## FreshRSS connects to PostgreSQL over the host's
      ## /run/postgresql socket, bind-mounted into the container. A
      ## bind mount pins the directory inode at container-start time,
      ## so when PostgreSQL restarts it recreates the socket in a dir
      ## the running container can no longer see — every DB query then
      ## fails with "No such file or directory". `partOf` makes a
      ## PostgreSQL restart cascade a FreshRSS restart, re-binding the
      ## current /run/postgresql.
      after = [ "dns-ready.service" "postgresql.service" ];
      requires = [ "dns-ready.service" "postgresql.service" ];
      partOf = [ "postgresql.service" ];
      serviceConfig = {
        ExecStartPre = [ "!${pkgs.writeShellScript "freshrss-prestart" preStart}" ];
        ExecStartPost = [ "!${pkgs.writeShellScript "freshrss-poststart" postStart}" ];
      };
    };

    homefree.service-config = [{
      inherit (config.homefree.service-options.freshrss) label name project-name;
      systemd-service-names = [
        "podman-freshrss"
      ];
      sso = {
        kind = "native_oidc";
        notes = "Apache mod_auth_openidc + http_auth mode. Admin is whichever user matches FreshRSS's default_user (must equal Zitadel preferred_username).";
      };
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
      options-metadata = [
        {
          path = "enable";
          type = "bool";
          default = false;
          description = "Enable FreshRSS news reader API";
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

