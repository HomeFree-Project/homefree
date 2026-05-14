{ config, lib, pkgs, ... }:
let
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

  hba-file = pkgs.writeText "pg_hba.conf" ''
    #type database  DBuser  auth-method
    local all       all     trust

    #type database DBuser origin-address auth-method
    # ipv4
    host  all      all     127.0.0.1/32   trust
    # host
    host  all      all     10.0.0.0/16   trust
    # podman
    host  all      all     10.88.0.0/16   trust
    # ipv6
    host all       all     ::1/128        trust
    host all       all     fd00::/8       trust
    # Allow replication connections from localhost, by a user with the
    # replication privilege.
    local   replication     all                                     trust
    host    replication     all             127.0.0.1/32            trust
    host    replication     all             10.0.0.0/16             trust
    host    replication     all             10.88.0.0/16            trust
    host    replication     all             ::1/128                 trust
    host    replication     all             fd00::/8                 trust
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
  '';
in
{
  options.homefree.service-options.postgres-vectorchord = {
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
        POSTGRES_PASSWORD = "changeme";
      };
    };
  };

  systemd.services.podman-postgres-vectorchord = {
    after = [ "dns-ready.service" ];
    requires = [ "dns-ready.service" ];
    serviceConfig = {
      ExecStartPre = [ "!${pkgs.writeShellScript "postgres-vectorchord-prestart" preStart}" ];
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
        notes = "PostgreSQL with VectorChord extension — internal database backing Open WebUI's RAG store. No user-facing surface; auth is by Postgres role only.";
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
