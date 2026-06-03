{ config, lib, pkgs, ... }:
let
  userOptions = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "enable VectorChord PostgreSQL service";
    };

    public = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Open to public on WAN port";
    };
  };

  # image = "postgres";
  # version = "16.9";
  # image = "tensorchord/vchord-postgres";
  # version = "pg16-v0.3.0";
  image = "ghcr.io/immich-app/postgres";
  # update-check: pin
  ## Tag scheme: <pgmajor>-vectorchord<vchord-ver>-pgvector<pgvector-ver>
  ## Note the spelling: this is the NEW `pgvector` extension (singular)
  ## paired with VectorChord 0.5.x, which Immich v2.7+ requires for the
  ## new `CREATE EXTENSION vchord CASCADE` (which pulls in `vector`).
  ## The older `pgvectors` (plural, pgvecto.rs) is incompatible with
  ## current Immich. See:
  ##   https://github.com/immich-app/base-images/blob/main/postgres/versions.yaml
  ## When bumping Immich, check the destination version's expected
  ## extensions — Immich is mid-migration between the two ecosystems
  ## and their docker-compose.yml lags behind their server image.
  version = "18-vectorchord0.5.3-pgvector0.8.1";
  port = 6432;
  containerDataPath = "/var/lib/postgres-vectorchord-podman";
  containerDataPathInternal = "/var/lib/postgresql/data";
  secretsDir = "/var/lib/homefree-secrets/postgres-vectorchord";

  ## Anchors auto-generated secrets into encrypted /etc/nixos/secrets
  ## so they survive a restore — see lib/secrets-anchor.nix.
  anchor = import ../../lib/secrets-anchor.nix { inherit lib pkgs; };

  ## Phase 2: TCP entries use scram-sha-256. The only consumer is
  ## immich-server (DB_PASSWORD wired into runtime.env) and the
  ## host-side prestarts on this container, which export PGPASSWORD
  ## from /var/lib/homefree-secrets/postgres-vectorchord/superuser-password.
  ## Local socket stays trust — only root inside the container itself
  ## reaches it; nothing on the host uses the socket path.
  hba-file = pkgs.writeText "pg_hba.conf" ''
    #type database  DBuser  auth-method
    local all       all     trust

    #type database DBuser origin-address auth-method
    # ipv4
    host  all      all     127.0.0.1/32   scram-sha-256
    # host
    host  all      all     10.0.0.0/16    scram-sha-256
    # podman
    host  all      all     10.88.0.0/16   scram-sha-256
    # ipv6
    host all       all     ::1/128        scram-sha-256
    host all       all     fd00::/8       scram-sha-256
    # Allow replication connections from localhost, by a user with the
    # replication privilege. (Not currently used — keeping the entries
    # in place for future replica setups, with the same auth method.)
    local   replication     all                                     trust
    host    replication     all             127.0.0.1/32            scram-sha-256
    host    replication     all             10.0.0.0/16             scram-sha-256
    host    replication     all             10.88.0.0/16            scram-sha-256
    host    replication     all             ::1/128                 scram-sha-256
    host    replication     all             fd00::/8                 scram-sha-256
  '';

  ## Override config injected via the include_if_exists hook the
  ## image's stock /etc/postgresql/postgresql.conf already has:
  ##   include_if_exists '/etc/postgresql/postgresql.override.conf'
  ## We bind-mount our config there read-only, so it takes effect
  ## on the very first container start (before initdb has even
  ## run) — without this we'd hit the chicken-and-egg problem
  ## where the container starts on default port 5432 during init
  ## and our preStart-injected config only takes effect on the
  ## NEXT restart, leaving the host port mapping (6432:6432)
  ## pointing at nothing during the post-init startup window.
  ##
  ## hba_file is also overridden here so our pg_hba lives at a
  ## known path (no copy-into-pgdata needed). Keeps the host
  ## bind-mount surface to two well-known files instead of
  ## trying to mutate the data dir.
  config-override-file = pkgs.writeText "postgresql.override.conf" ''
    hba_file = '/etc/postgresql/pg_hba.conf'
    listen_addresses = '*'
    max_connections = 100
    port = ${toString port}
    shared_buffers = 128MB
    dynamic_shared_memory_type = posix
    max_wal_size = 1GB
    min_wal_size = 80MB
    datestyle = 'iso, mdy'
    timezone = '${config.homefree.system.timeZone}'
    lc_messages = 'en_US.utf8'              # locale for system error message
    lc_monetary = 'en_US.utf8'              # locale for monetary formatting
    lc_numeric = 'en_US.utf8'               # locale for number formatting
    lc_time = 'en_US.utf8'                  # locale for time formatting
    default_text_search_config = 'pg_catalog.english'
  '';

  preStart = ''
    mkdir -p ${containerDataPath}/pgdata
    mkdir -p ${secretsDir}

    ${anchor.preamble}

    ## Anchor the postgres superuser password. POSTGRES_PASSWORD in the
    ## upstream image is consulted only by initdb on a fresh data dir
    ## (an existing pgdata ignores it), so the runtime rotation happens
    ## via SQL in postStart below. Anchoring still matters for fresh
    ## installs and for backup→restore: the password baked into the
    ## restored pgdata must match what we hand to consumers.
    ${anchor.anchorSecret {
      service = "postgres-vectorchord";
      key = "superuser-password";
      dir = secretsDir;
      generate = "${pkgs.openssl}/bin/openssl rand -base64 32 | tr -d '/+=' | head -c 32";
    }}

    ## Synthesise the env file the container reads. The Postgres image
    ## consumes POSTGRES_PASSWORD at initdb time on fresh boxes; on
    ## existing boxes the value is irrelevant to the image but kept
    ## here as the single source of truth for the rotation script.
    install -m 600 /dev/null ${containerDataPath}/runtime.env
    printf 'POSTGRES_PASSWORD=%s\n' "$(cat ${secretsDir}/superuser-password)" \
      > ${containerDataPath}/runtime.env
  '';

  ## Runs AFTER the container is up. The image's POSTGRES_PASSWORD env
  ## is initdb-only — on a pre-existing pgdata the internal superuser
  ## password is whatever it was originally seeded with (likely the
  ## historical literal "changeme"). The only reliable rotation knob is
  ## an in-band ALTER USER. The script tries the new password first
  ## (post-rotation steady state) and falls back to "changeme" exactly
  ## once during the one-time upgrade. After one successful rebuild,
  ## the new-password branch wins forever.
  postStart = ''
    set -eu
    NEW=$(cat ${secretsDir}/superuser-password)

    ## Wait for the cluster to accept connections — the container is
    ## marked "up" before postgres finishes starting/recovering.
    for i in $(seq 1 60); do
      if ${pkgs.postgresql}/bin/pg_isready -h 127.0.0.1 -p ${toString port} -U postgres -q; then
        break
      fi
      sleep 1
    done

    if PGPASSWORD="$NEW" ${pkgs.postgresql}/bin/psql -h 127.0.0.1 -p ${toString port} \
         -U postgres -tAc "SELECT 1" >/dev/null 2>&1; then
      ## Already rotated; re-issue the ALTER idempotently so a fresh
      ## restore (where pgdata has the right hash) is a confirmed no-op.
      PGPASSWORD="$NEW" ${pkgs.postgresql}/bin/psql -h 127.0.0.1 -p ${toString port} \
        -U postgres -c "ALTER USER postgres WITH PASSWORD '$NEW'" >/dev/null
    elif PGPASSWORD=changeme ${pkgs.postgresql}/bin/psql -h 127.0.0.1 -p ${toString port} \
         -U postgres -tAc "SELECT 1" >/dev/null 2>&1; then
      ## One-time upgrade from the historical literal password.
      PGPASSWORD=changeme ${pkgs.postgresql}/bin/psql -h 127.0.0.1 -p ${toString port} \
        -U postgres -c "ALTER USER postgres WITH PASSWORD '$NEW'" >/dev/null
      echo "rotated postgres-vectorchord superuser password from literal to anchored value"
    else
      echo "FATAL: could not authenticate to postgres-vectorchord with either anchored or legacy password" >&2
      exit 1
    fi
  '';
in
{
  options.homefree.services.postgres-vectorchord = userOptions;
  options.homefree.service-options.postgres-vectorchord = userOptions // {
    label = lib.mkOption {
      type = lib.types.str;
      default = "postgres-vectorchord";
      internal = true;
      description = "Service label";
    };

    name = lib.mkOption {
      type = lib.types.str;
      default = "VectorChord PostgreSQL";
      internal = true;
      description = "Service display name";
    };

    project-name = lib.mkOption {
      type = lib.types.str;
      default = "VectorChord PostgreSQL";
      internal = true;
      description = "Project name";
    };
  };

  config = {
  virtualisation.oci-containers.containers = {
    postgres-vectorchord = {
      image = "${image}:${version}";

      autoStart = true;

      extraOptions = [
        # "--pull=always"
        "--shm-size=128M"
      ];

      ports = [
        "0.0.0.0:${toString port}:${toString port}"
      ];

      volumes = [
        "/etc/localtime:/etc/localtime:ro"
        "${containerDataPath}:${containerDataPathInternal}"
        ## Mounted via the image's stock include_if_exists hook so
        ## settings (including `port = 6432` and `hba_file = ...`)
        ## are in effect from the FIRST container start, not just
        ## after a restart. See the long comment in the let-binding.
        "${config-override-file}:/etc/postgresql/postgresql.override.conf:ro"
        "${hba-file}:/etc/postgresql/pg_hba.conf:ro"
      ];

      environment = {
        TZ = config.homefree.system.timeZone;
        PGDATA = "/var/lib/postgresql/data/pgdata";
      };

      ## POSTGRES_PASSWORD lives in runtime.env, anchored to
      ## /etc/nixos/secrets so it survives a backup→restore.
      environmentFiles = [ "${containerDataPath}/runtime.env" ];
    };
  };

  systemd.services.podman-postgres-vectorchord = {
    after = [ "dns-ready.service" ];
    wants = [ "dns-ready.service" ];
    serviceConfig = {
      ExecStartPre = [ "!${pkgs.writeShellScript "postgres-vectorchord-prestart" preStart}" ];
      ExecStartPost = [ "!${pkgs.writeShellScript "postgres-vectorchord-rotate-superuser" postStart}" ];
      # Add restart delay to prevent rapid restart loops
      RestartSec = 30;
    };
    # Limit restart attempts to prevent infinite loops
    startLimitBurst = 3;
    startLimitIntervalSec = 300;  # 5 minutes
  };

    homefree.service-config = [{
      inherit (config.homefree.service-options.postgres-vectorchord) label name project-name;
      sso = {
        kind = "infra";
        ## Dev context (intentionally not surfaced in the admin UI):
        ## PostgreSQL with VectorChord extension — internal database
        ## backing Open WebUI's RAG store. No user-facing surface;
        ## auth is by Postgres role only.
      };
      systemd-service-names = [
        "podman-postgres-vectorchord"
      ];
      reverse-proxy = {
        enable = false;
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
          description = "Enable VectorChord PostgreSQL service";
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
