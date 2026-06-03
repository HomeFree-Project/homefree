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

  port = config.homefree.allocPort "immich";
  port-machine-learning = 3003;
  port-redis = 6379;
  database-name = "immich";
  database-user = "immich";

  immichSecretsDir = "/var/lib/homefree-secrets/immich";
  domain = config.homefree.system.domain;

  ## Anchors auto-generated secrets into encrypted /etc/nixos/secrets
  ## so they survive a restore — see lib/secrets-anchor.nix.
  anchor = import ../../lib/secrets-anchor.nix { inherit lib pkgs; };
  adminUser = config.homefree.system.adminUsername;
  adminEmail = config.homefree.system.adminEmail or "${adminUser}@${domain}";

  preStart = ''
    mkdir -p ${containerDataPath}/backups
    mkdir -p ${containerDataPath}/encoded-video
    mkdir -p ${containerDataPath}/library
    mkdir -p ${containerDataPath}/profile
    mkdir -p ${containerDataPath}/thumbs
    mkdir -p ${containerDataPath}/upload
    mkdir -p /var/cache/immich
    mkdir -p ${immichSecretsDir}

    # Immich's startup verifies that the host volume is actually mounted by
    # reading a `.immich` sentinel file inside each of its known folders. If
    # any sentinel is missing (or returns ENOENT, e.g. because the bind mount
    # silently failed), the microservices worker exits with code 1 and the
    # podman unit goes into a restart loop — which is exactly what we hit
    # before adding these. See:
    #   https://docs.immich.app/administration/system-integrity#folder-checks
    for d in backups encoded-video library profile thumbs upload; do
      touch "${containerDataPath}/$d/.immich"
    done

    ## Auto-generate the bootstrap admin password on first boot.
    ## This is write-once garbage: we use it exactly once to call
    ## /api/auth/admin-sign-up and /api/auth/login, then disable
    ## password login entirely via passwordLogin.enabled=false.
    ## Stays on disk only so postStart can re-authenticate after
    ## restarts (until SSO is fully wired and the token survives).
    ## The end-user is never shown this password — they log in via
    ## Zitadel.
    ## Anchored into encrypted /etc/nixos/secrets so it survives a
    ## restore (lib/secrets-anchor.nix); postStart re-authenticates
    ## with it after restarts.
    ${anchor.preamble}
    ${anchor.anchorSecret {
      service = "immich";
      key = "admin-password";
      dir = immichSecretsDir;
      generate = "${pkgs.openssl}/bin/openssl rand -base64 24";
    }}

    ## DB password for the "immich" Postgres role on the
    ## postgres-vectorchord container. Today the immich-server container
    ## connects via the podman bridge under trust auth so the value is
    ## carried-but-not-enforced; Phase 2 swaps the vectorchord pg_hba
    ## to scram-sha-256 and the value goes live.
    ${anchor.anchorSecret {
      service = "immich";
      key = "db-password";
      dir = immichSecretsDir;
      generate = "${pkgs.openssl}/bin/openssl rand -base64 32 | tr -d '/+=' | head -c 32";
    }}

    ## Build a CA bundle the container can mount over its own
    ## /etc/ssl/certs/ca-certificates.crt so Immich's Node OIDC
    ## client can validate https://sso.<domain>/.well-known/
    ## openid-configuration. Caddy issues internal certs from a
    ## runtime-generated local CA that the stock node base image
    ## doesn't trust. Same pattern as netbird/forgejo.
    {
      cat /etc/ssl/certs/ca-certificates.crt
      if [ -r /var/lib/caddy/.local/share/caddy/pki/authorities/local/root.crt ]; then
        echo
        cat /var/lib/caddy/.local/share/caddy/pki/authorities/local/root.crt
      fi
    } > ${containerDataPath}/ca-bundle.crt
    chmod 644 ${containerDataPath}/ca-bundle.crt
  '';

  ## postStart bootstraps Immich into an SSO-only state. It runs in
  ## two phases:
  ##
  ##   1. Bootstrap a bare admin user via /api/auth/admin-sign-up
  ##      (Immich requires this for migrations to mark
  ##      `isInitialized=true`; without it the UI shows the signup
  ##      form). Idempotent — returns 400 if admin already exists.
  ##      The auto-generated password is never used again after
  ##      this; the user never sees it.
  ##
  ##   2. Update Immich's system_metadata table DIRECTLY via SQL
  ##      to enable OAuth and disable password login. We bypass
  ##      Immich's /api/system-config endpoint because that
  ##      requires admin authentication — and once
  ##      passwordLogin.enabled=false lands, we have no way to
  ##      log in to UPDATE config in future runs (e.g., when
  ##      zitadel-provision rotates the OIDC client_id). SQL
  ##      writes work even with passwordLogin disabled, so this
  ##      keeps the config converging across restarts.
  ##
  ## Pre-provisioning (no OIDC secrets on disk yet) the script
  ## skips step 2 — Immich's API is up but unauthenticated
  ## requests show the standard signup-already-done page until
  ## zitadel-provision lands the secrets and try-restarts us.
  postStart = pkgs.writeShellScript "immich-poststart" ''
    set -u

    API="http://127.0.0.1:${toString port}/api"
    ADMIN_EMAIL="${adminEmail}"
    ADMIN_NAME="${config.homefree.system.adminDescription or adminUser}"
    ADMIN_PASS=$(cat ${immichSecretsDir}/admin-password)
    ## postgres-vectorchord publishes 6432 on 0.0.0.0:6432 of the host,
    ## but its pg_hba.conf only accepts connections from the container's
    ## internal bridge subnet, NOT from lan-address (which the host
    ## reaches it via the published port but appears as a different
    ## source IP to Postgres). 127.0.0.1 works because the loopback
    ## interface bypasses the bridge IP mapping.
    DB_HOST="127.0.0.1"
    DB_PORT="6432"
    DB_NAME="${database-name}"
    DB_USER="postgres"
    ## Superuser password rotated and anchored by
    ## services/postgres-vectorchord/default.nix. Today the vectorchord
    ## pg_hba allows trust on 127.0.0.1 so this value is sent-but-ignored;
    ## Phase 2 swaps to scram-sha-256 and it goes live.
    DB_PASS=$(cat /var/lib/homefree-secrets/postgres-vectorchord/superuser-password)

    ## ── 1. Wait for Immich to come up ───────────────────────────
    for i in $(seq 1 60); do
      if ${pkgs.curl}/bin/curl -sf "$API/server/ping" >/dev/null 2>&1; then
        break
      fi
      [ "$i" = 60 ] && {
        echo "immich postStart: API not responsive after 120s" >&2
        exit 0
      }
      sleep 2
    done

    ## ── 2. Ensure admin user exists ─────────────────────────────
    ## admin-sign-up returns 201 the first time, 400 on subsequent
    ## calls. Either is fine. After this step the admin password
    ## is dead config — never used to log in again.
    ${pkgs.curl}/bin/curl -sS -o /dev/null \
      -H "Content-Type: application/json" \
      -X POST "$API/auth/admin-sign-up" \
      -d "$(${pkgs.jq}/bin/jq -nc \
        --arg e "$ADMIN_EMAIL" --arg p "$ADMIN_PASS" --arg n "$ADMIN_NAME" \
        '{email:$e, password:$p, name:$n}')" || true

    ## ── 3. SSO config via direct SQL ────────────────────────────
    if [ ! -s ${immichSecretsDir}/oidc-client-id ] \
       || [ ! -f ${immichSecretsDir}/oidc-client-secret ]; then
      echo "immich postStart: no OIDC secrets yet, skipping SSO config" >&2
      exit 0
    fi

    CID=$(cat ${immichSecretsDir}/oidc-client-id)
    ## clientSecret is intentionally empty: the Zitadel-side OIDC app
    ## is OIDC_APP_TYPE_NATIVE with AUTH_METHOD_NONE (PKCE-only), so
    ## the Android Immich app's custom-scheme redirect
    ## `app.immich:///oauth-callback` is accepted. NATIVE+NONE apps
    ## reject any client_secret on token exchange — Immich must do
    ## PKCE-only. Provisioning still mints a client-secret file (so
    ## the secret schema stays uniform across services) but we
    ## drop it on the floor here.
    CSEC=""
    ISSUER="https://sso.${domain}/.well-known/openid-configuration"

    ## Wait briefly for Immich's first-boot migrations to land
    ## the system_metadata table (a brand-new DB starts without
    ## it; the schema is applied during server bootstrap).
    for i in $(seq 1 30); do
      if PGPASSWORD="$DB_PASS" ${pkgs.postgresql}/bin/psql \
           -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" \
           -tc "SELECT 1 FROM information_schema.tables WHERE table_name='system_metadata';" \
           2>/dev/null | ${pkgs.gnugrep}/bin/grep -q 1; then
        break
      fi
      [ "$i" = 30 ] && {
        echo "immich postStart: system_metadata table never appeared" >&2
        exit 0
      }
      sleep 2
    done

    ## Build the JSON config. Use jsonb_build_object so the nested
    ## `oauth` and `passwordLogin` objects are constructed in one shot.
    ## (jsonb_set won't create intermediate parent objects on a path
    ## like `{oauth,enabled}` if `oauth` doesn't already exist —
    ## learned the hard way: it silently leaves the row at `{}`.)
    ##
    ## The merge `value || ...` preserves any unrelated keys the user
    ## or Immich itself wrote, then overwrites oauth + passwordLogin
    ## with our values.
    PGPASSWORD="$DB_PASS" ${pkgs.postgresql}/bin/psql \
      -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" \
      -v cid="$CID" -v csec="$CSEC" -v issuer="$ISSUER" \
      -v ON_ERROR_STOP=1 <<'SQL' 2>&1 | tail -3
    INSERT INTO system_metadata (key, value)
    VALUES ('system-config', '{}'::jsonb)
    ON CONFLICT (key) DO NOTHING;

    UPDATE system_metadata
    SET value = COALESCE(value, '{}'::jsonb) || jsonb_build_object(
      'oauth', jsonb_build_object(
        'enabled',      true,
        'issuerUrl',    :'issuer',
        'clientId',     :'cid',
        'clientSecret', :'csec',
        'scope',        'openid email profile urn:zitadel:iam:org:project:roles',
        'autoRegister', true,
        'autoLaunch',   true,
        'buttonText',   'Sign in with HomeFree SSO',
        'roleClaim',    'urn:zitadel:iam:org:project:roles',
        'adminRole',    'homefree-admin'
      ),
      'passwordLogin', jsonb_build_object('enabled', false)
    )
    WHERE key = 'system-config';
SQL

    echo "immich postStart: SSO config applied via SQL" >&2
  '';

  userOptions = {
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
  };
in
{
  options.homefree.services.immich = userOptions;
  options.homefree.service-options.immich = userOptions // {
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
        if ${pkgs.postgresql}/bin/psql -h 127.0.0.1 -p 6432 -U postgres -c "SELECT 1" &>/dev/null; then
          echo "Database is ready"
          break
        fi
        echo "Waiting for database to be ready... (attempt $i/30)"
        sleep 1
      done

      ## Anchor the immich-role password here as well as in immich's
      ## own prestart, because THIS script runs first (vectorchord's
      ## ExecStartPost fires before immich-server's ExecStartPre) and
      ## reads the value below. The anchor helper is idempotent — the
      ## immich prestart's call becomes a no-op on every boot after
      ## the first.
      ${anchor.preamble}
      ${anchor.anchorSecret {
        service = "immich";
        key = "db-password";
        dir = immichSecretsDir;
        generate = "${pkgs.openssl}/bin/openssl rand -base64 32 | tr -d '/+=' | head -c 32";
      }}

      IMMICH_DB_PASSWORD=$(cat ${immichSecretsDir}/db-password)

      ${pkgs.postgresql}/bin/psql -h 127.0.0.1 -p 6432 -U postgres << EOF
        DO
        \$do\$
        BEGIN
           IF EXISTS (
              SELECT FROM pg_catalog.pg_roles
              WHERE  rolname = '${database-user}') THEN

              RAISE NOTICE 'Role "${database-user}" already exists. Skipping.';
           ELSE
              BEGIN   -- nested block
                 CREATE ROLE "immich" WITH LOGIN PASSWORD '$IMMICH_DB_PASSWORD';
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
      ${pkgs.postgresql}/bin/psql -h 127.0.0.1 -p 6432 -U postgres \
        -c "ALTER ROLE \"${database-user}\" WITH PASSWORD '$IMMICH_DB_PASSWORD'"

      ${pkgs.postgresql}/bin/psql -h 127.0.0.1 -U postgres -p 6432 -tc "SELECT 1 FROM pg_database WHERE datname = '${database-name}'" | ${pkgs.gnugrep}/bin/grep -q 1 || ${pkgs.postgresql}/bin/psql -h 127.0.0.1 -p 6432 -U postgres -c "CREATE DATABASE \"${database-name}\" WITH OWNER \"${database-user}\" ENCODING 'UTF8' LOCALE 'C' TEMPLATE template0"

      ${pkgs.postgresql}/bin/psql -h 127.0.0.1 -p 6432 -X -U postgres << EOF
        DO
        \$do\$
        BEGIN
          GRANT ALL PRIVILEGES ON DATABASE "${database-name}" to "${database-user}";
        END
        \$do\$;
      EOF

      # Run the SQL extensions setup
      ${lib.getExe' config.services.postgresql.package "psql"} -h 127.0.0.1 -p 6432 -U postgres -d "${database-name}" -f "${sqlFile}"
    '';
    ## Immich v2.7+ uses the new pgvector + VectorChord extensions
    ## (NOT the older pgvecto.rs / `vectors`). The CASCADE on vchord
    ## pulls in `vector` automatically. Run as the postgres superuser
    ## inside the postgres-vectorchord-poststart script, then the
    ## extensions get owned by the cluster's superuser but become
    ## *usable* by the immich role via GRANT USAGE on schemas.
    ##
    ## The pg_vector_index_stat view exists on VectorChord 0.5+ and
    ## is used by Immich for index stats reporting; granting SELECT
    ## to the immich role keeps Immich's UI status panel populated.
    sqlFile = pkgs.writeText "immich-pgvector-setup.sql" ''
      CREATE EXTENSION IF NOT EXISTS unaccent;
      CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
      CREATE EXTENSION IF NOT EXISTS cube;
      CREATE EXTENSION IF NOT EXISTS earthdistance;
      CREATE EXTENSION IF NOT EXISTS pg_trgm;
      CREATE EXTENSION IF NOT EXISTS vchord CASCADE;

      ALTER SCHEMA public OWNER TO ${database-user};
    '';
  in
  lib.optionals config.homefree.service-options.immich.enable [ "!${postStartScript}" ];

  virtualisation.oci-containers.containers = lib.optionalAttrs config.homefree.service-options.immich.enable {
    immich-server = {
      image = "ghcr.io/immich-app/immich-server:${version}";

      autoStart = true;

      ## immich-server reaches its database, cache and ML service by
      ## container name (DB_HOSTNAME=postgres-vectorchord,
      ## REDIS_HOSTNAME=immich-redis, IMMICH_MACHINE_LEARNING_URL=
      ## http://immich-machine-learning). Those names only resolve via
      ## podman's internal DNS once the target container is running and
      ## registered on the shared network. Without an ordering
      ## dependency, immich-server starts first, Node crashes with
      ## `getaddrinfo ENOTFOUND postgres-vectorchord`, and the unit then
      ## limps through its 120s API-poll postStart before failing.
      ##
      ## dependsOn makes NixOS's oci-containers generate After=/Requires=
      ## podman-<dep>.service on the unit, so immich-server only starts
      ## once its dependencies' containers are up.
      dependsOn = [
        "postgres-vectorchord"
        "immich-redis"
        "immich-machine-learning"
      ];

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
        ## Mount our combined CA bundle so the OIDC discovery fetch
        ## from inside the Node runtime trusts Caddy's local cert.
        "${containerDataPath}/ca-bundle.crt:/etc/ssl/certs/ca-certificates.crt:ro"
      ];

      environment = {
        TZ = config.homefree.system.timeZone;

        ## Node.js doesn't read /etc/ssl/certs by default — point
        ## NODE_EXTRA_CA_CERTS at our bundle so the OIDC client's
        ## TLS handshake against https://sso.<domain> validates.
        NODE_EXTRA_CA_CERTS = "/etc/ssl/certs/ca-certificates.crt";

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

  systemd.services.podman-immich-server = lib.mkIf config.homefree.service-options.immich.enable {
    after = [ "dns-ready.service" ];
    wants = [ "dns-ready.service" ];
    serviceConfig = {
      ExecStartPre = [ "!${pkgs.writeShellScript "imimich-server-prestart" preStart}" ];
      ExecStartPost = [ "!${postStart}" ];
    };
  };

  systemd.services.podman-immich-machine-learning = lib.mkIf config.homefree.service-options.immich.enable {
    after = [ "dns-ready.service" ];
    wants = [ "dns-ready.service" ];
    serviceConfig = {
      # Ensure the ML cache dir exists before podman tries to bind-mount it.
      # Otherwise statfs fails → podman exits 125 → cascade into a failed-
      # dependency for immich-server (which Requires= this unit), even though
      # immich-server's preStart is what otherwise creates /var/cache/immich.
      # Fresh installs and restored boxes hit this first-boot.
      ExecStartPre = [ "!${pkgs.writeShellScript "immich-ml-prestart" ''
        mkdir -p /var/cache/immich
      ''}" ];
    };
  };

  systemd.services.podman-immich-redis = lib.mkIf config.homefree.service-options.immich.enable {
    after = [ "dns-ready.service" ];
    wants = [ "dns-ready.service" ];
  };

    homefree.service-config = [{
      inherit (config.homefree.service-options.immich) label name project-name;
      port-request = 2283;
      enable = config.homefree.service-options.immich.enable;
      release-tracking = {
        type = "github";
        project = "immich-app/immich";
      };
      systemd-service-names = [
        "podman-immich-server"
        "podman-immich-machine-learning"
        "podman-immich-redis"
        "podman-postgres-vectorchord"
      ];
      sso = {
        kind = "native_oidc";
        ## Dev context (intentionally not surfaced in the admin UI):
        ## Native OIDC; homefree-admin role maps to Immich admin via
        ## OAUTH_ADMIN_GROUP.
      };
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
