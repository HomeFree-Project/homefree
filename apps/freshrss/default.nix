{ config, lib, pkgs, ... }:
let
  containerDataPath = "/var/lib/freshrss-podman";
  secretsDir = "/var/lib/homefree-secrets/freshrss";

  ## Anchors auto-generated secrets into encrypted /etc/nixos/secrets
  ## so they survive a restore — see lib/secrets-anchor.nix.
  anchor = import ../../lib/secrets-anchor.nix { inherit lib pkgs; };

  # image = "lscr.io/linuxserver/freshrss";
  image = "freshrss/freshrss";
  version = "1.29.1";

  port = config.homefree.allocPort "freshrss";

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

  ## Initial admin email — comes from the instance config (set by the
  ## installer's "Email" field). Falls back to <admin>@<domain> only
  ## when no email is configured. Same pattern used by Zitadel and
  ## Immich; replaces a previously hardcoded address that was an
  ## instance-specific leak in shared code (rule 1 violation).
  ADMIN_EMAIL =
    if (config.homefree.system.adminEmail or "") != ""
    then config.homefree.system.adminEmail
    else "${adminUsername}@${domain}";

  ## ADMIN_PASSWORD / ADMIN_API_PASSWORD are anchored to
  ## /var/lib/homefree-secrets/freshrss by preStart and folded into
  ## FRESHRSS_INSTALL / FRESHRSS_USER via runtime.env. The FreshRSS
  ## image consumes these env vars ONLY during first-time install
  ## (after install they're baked into config.php and ignored); the
  ## anchored values matter for fresh installs and as a documented
  ## SSO-down recovery credential.
  runtimeEnvFile = "${containerDataPath}/runtime.env";

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

    ## oidc-crypto-key — Apache mod_auth_openidc state-cookie
    ## passphrase. Anchored into encrypted /etc/nixos/secrets so it
    ## survives a restore (lib/secrets-anchor.nix); regenerating it
    ## breaks in-flight logins.
    ${anchor.preamble}
    ${anchor.anchorSecret {
      service = "freshrss";
      key = "oidc-crypto-key";
      dir = secretsDir;
      generate = "${pkgs.openssl}/bin/openssl rand -hex 32";
    }}

    ## admin-password — local FreshRSS admin login password. Consumed
    ## by --password in FRESHRSS_USER on first install; after install
    ## it's baked into config.php and the env var is ignored. Carried
    ## as a documented SSO-down recovery credential.
    ${anchor.anchorSecret {
      service = "freshrss";
      key = "admin-password";
      dir = secretsDir;
      generate = "${pkgs.openssl}/bin/openssl rand -base64 24 | tr -d '/+=' | head -c 24";
    }}

    ## admin-api-password — Fever API password for mobile clients.
    ## Same one-shot install lifecycle as admin-password.
    ${anchor.anchorSecret {
      service = "freshrss";
      key = "admin-api-password";
      dir = secretsDir;
      generate = "${pkgs.openssl}/bin/openssl rand -base64 24 | tr -d '/+=' | head -c 24";
    }}

    ## Synthesise runtime.env with FRESHRSS_INSTALL and FRESHRSS_USER
    ## as single-line values carrying the anchored passwords. FreshRSS
    ## tokenises these via `set $FRESHRSS_INSTALL` and only consults
    ## them on the very first install — rebuilds after install have no
    ## effect on the live FreshRSS user, but the values are kept in
    ## sync so a fresh install always uses the anchored credentials.
    ##
    ## CRITICAL: every value option uses the `--opt=value` form, NOT the
    ## space-separated `--opt value`. The image entrypoint expands these
    ## via `eval echo "$FRESHRSS_INSTALL"` then word-splits the result.
    ## DB_PASSWORD is empty (local postgres, peer auth over the socket),
    ## so the old `--db-password "%s"` rendered `--db-password ""`; eval
    ## collapses the empty quotes to nothing, leaving a DANGLING
    ## `--db-password` that swallows the next token (`--db-type`) as its
    ## value. That shifts every following option, ultimately starving
    ## `--default-user`, and do-install.php aborts with
    ## "default-user cannot be empty". The `=` form makes each option
    ## self-delimiting — `--db-password=` is an explicit empty value that
    ## can never consume the next token. (FreshRSS's own README still
    ## shows the space form; it is unsafe whenever any value is empty.)
    FRESHRSS_ADMIN_PASSWORD=$(cat ${secretsDir}/admin-password)
    FRESHRSS_ADMIN_API_PASSWORD=$(cat ${secretsDir}/admin-api-password)
    install -m 600 /dev/null ${runtimeEnvFile}
    {
      printf 'FRESHRSS_INSTALL=--api-enabled --base-url=%s --db-base=%s --db-host=%s --db-password=%s --db-type=pgsql --db-user=%s --default-user=%s --language=en\n' \
        "${BASE_URL}" "${DB_BASE}" "${DB_HOST}" "${DB_PASSWORD}" "${DB_USER}" "${adminUsername}"
      printf 'FRESHRSS_USER=--api-password=%s --email=%s --language=en --password=%s --user=%s\n' \
        "$FRESHRSS_ADMIN_API_PASSWORD" "${ADMIN_EMAIL}" "$FRESHRSS_ADMIN_PASSWORD" "${adminUsername}"
    } > ${runtimeEnvFile}

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
    ## FRESH-INSTALL RACE: on the very first start the in-container
    ## entrypoint runs do-install.php (which writes config.php)
    ## CONCURRENTLY with this ExecStartPost. Bailing the instant
    ## config.php is absent means the first install never gets auth_type
    ## flipped to 'http_auth', so SSO stays off and FreshRSS shows its
    ## native form login until the container happens to restart (e.g. the
    ## next rebuild) — which is exactly why a freshly-installed box looks
    ## broken while an older one works. Poll for config.php so the SSO
    ## migration runs on the first install too. Bounded (~60s) so an
    ## uninstalled / failing container still exits cleanly; the unit's
    ## TimeoutStartSec is infinity so blocking here is safe. On an
    ## already-installed restart config.php exists immediately and the
    ## loop breaks on the first iteration.
    for _ in $(seq 1 60); do
      [ -s "$CFG" ] && break
      sleep 1
    done
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

  userOptions = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "enable FreshRSS news reader API";
    };

    public = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Open to public on WAN port";
    };
  };
in
{
  options.homefree.services.freshrss = userOptions;

  options.homefree.service-options.freshrss = userOptions // {
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
    ## OIDC client descriptor — unconditional per modules/sso-clients.nix.
    homefree.sso.clients = [{
      svc = "freshrss";
      internal_name = "homefree-freshrss";
      ## FreshRSS uses Apache mod_auth_openidc — server-side
      ## confidential client (authcode + secret).
      app_type = "OIDC_APP_TYPE_WEB";
      auth_method = "OIDC_AUTH_METHOD_TYPE_POST";
      response_types = [ "OIDC_RESPONSE_TYPE_CODE" ];
      grant_types = [ "OIDC_GRANT_TYPE_AUTHORIZATION_CODE" "OIDC_GRANT_TYPE_REFRESH_TOKEN" ];
      ## Callback path hardcoded by the FreshRSS image's Apache
      ## config: OIDCRedirectURI /i/oidc/. Trailing slash is part of
      ## the path mod_auth_openidc serves, so register it as-is.
      redirect_uris = [ "https://freshrss.${domain}/i/oidc/" ];
      post_logout_uris = [ "https://freshrss.${domain}/" ];
      needs_pat = false;
      post_restart_units = [ "podman-freshrss.service" ];
    }];

    ## Container via the app-platform primitive (modules/app-platform.nix).
    ## The dns-ready podman unit is generated. The CA bundle is mounted manually
    ## (over the Debian system path /etc/ssl/certs/ca-certificates.crt, not the
    ## default homefree path) so caBundle=false and the full preStart goes in
    ## preStartInit. The ExecStartPost (SSO migration) and postgresql ordering
    ## stay in a separate systemd.services.podman-freshrss merge below.
    homefree.containers.freshrss = lib.mkIf config.homefree.service-options.freshrss.enable {
      ## SKIPPED Phase 3 non-root pass: the FreshRSS image's
      ## entrypoint does extensive root-only setup on every start —
      ## writes /etc/localtime + /etc/timezone, sed-edits the PHP
      ## ini files under /etc/php/, runs a2enmod for
      ## mod_auth_openidc, drops a cron PID file under /var/run,
      ## and runs `chown` over /var/www/FreshRSS. As a non-root UID
      ## every one of those fails and the container exits 1. The
      ## image is fundamentally root-in-container; making it
      ## non-root requires either a custom image build or
      ## --userns=keep-id with a host-side UID matching the
      ## image's expected www-data uid.
      runAs = { mode = "root"; reason = "image entrypoint does root-only Apache/PHP setup and chowns /var/www/FreshRSS; non-root uid breaks startup"; };
      image = "${image}:${version}";

      ## dataDir=null + caBundle=false: the CA bundle is written into
      ## containerDataPath/ca-bundle.crt by preStartInit and mounted over
      ## /etc/ssl/certs/ca-certificates.crt (the Debian system bundle path
      ## that mod_auth_openidc's libcurl reads). The standard homefree CA-bundle
      ## path + SSL_CERT_FILE env would not reach libcurl.
      dataDir = null;
      caBundle = false;

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
        ## FRESHRSS_INSTALL and FRESHRSS_USER are synthesised into
        ## runtime.env by preStart, carrying the anchored admin
        ## password + Fever API password. They are consumed by the
        ## FreshRSS image's first-install code path only (after
        ## install, FreshRSS reads config.php and ignores them).
        ## See the let-binding ADMIN_EMAIL above for how the email
        ## comes from instance config.
      };

      ## runtime.env: FRESHRSS_INSTALL + FRESHRSS_USER (anchored
      ## passwords). ssoEnvFile: OIDC_* synthesized when Zitadel
      ## has provisioned the OIDC client. Pre-provisioning,
      ## ssoEnvFile is empty so OIDC_ENABLED defaults to undefined
      ## and the Apache <IfDefine OIDC_ENABLED> block is inert.
      environmentFiles = [ runtimeEnvFile ssoEnvFile ];

      ## Full preStart body: mkdir, postgres bootstrap, CA-bundle synthesis,
      ## secret anchoring, runtime.env + sso.env synthesis. All handled here
      ## since caBundle=false (non-standard mount path) and dataDir=null.
      preStartInit = preStart;
    };

    ## PostgreSQL ordering + ExecStartPost (SSO migration). These MERGE
    ## with the dns-ready after/wants the app-platform generates for
    ## podman-freshrss. The ExecStartPost is NOT part of homefree.containers
    ## (the platform only generates ExecStartPre); it stays here so the
    ## service-restart-policy module and the platform-generated unit both see
    ## it merged into the same podman-freshrss unit.
    systemd.services.podman-freshrss = lib.mkIf config.homefree.service-options.freshrss.enable {
      ## FreshRSS connects to PostgreSQL over the host's
      ## /run/postgresql socket, bind-mounted into the container. A
      ## bind mount pins the directory inode at container-start time,
      ## so when PostgreSQL restarts it recreates the socket in a dir
      ## the running container can no longer see — every DB query then
      ## fails with "No such file or directory". `partOf` makes a
      ## PostgreSQL restart cascade a FreshRSS restart, re-binding the
      ## current /run/postgresql.
      after = [ "postgresql.service" ];
      requires = [ "postgresql.service" ];
      partOf = [ "postgresql.service" ];
      serviceConfig = {
        ExecStartPost = [ "!${pkgs.writeShellScript "freshrss-poststart" postStart}" ];
      };
    };

    homefree.service-config = [{
      inherit (config.homefree.service-options.freshrss) label name project-name;
      port-request = null;
      enable = config.homefree.service-options.freshrss.enable;
      systemd-service-names = [
        "podman-freshrss"
      ];
      sso = {
        kind = "native_oidc";
        ## Dev context (intentionally not surfaced in the admin UI):
        ## Apache mod_auth_openidc + http_auth mode. Admin is whichever
        ## user matches FreshRSS's default_user (must equal Zitadel
        ## preferred_username).
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

