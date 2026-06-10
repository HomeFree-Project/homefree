{ config, lib, pkgs, ... }:

## Project N.O.M.A.D. — offline knowledge server (https://www.projectnomad.us/,
## https://github.com/Crosstalk-Solutions/project-nomad). A "Command Center"
## web UI (AdonisJS) through which the operator downloads offline content
## (Wikipedia/Kiwix ZIMs, Kolibri courses, offline maps, CyberChef, FlatNotes,
## optional local-LLM AI) and manages the content services that serve it.
##
## ARCHITECTURE (mirrors upstream's install/management_compose.yaml):
##   - nomad        — the Command Center admin/portal UI (port 8080 inside)
##   - nomad-mysql  — MySQL 8.0 (Command Center state: service catalog,
##                    install status, settings, RAG chats)
##   - nomad-redis  — Redis 7 (queue/cache)
##
## The Command Center manages CONTENT services (Kiwix, Kolibri, Qdrant,
## Ollama, ProtoMaps, CyberChef, FlatNotes) by talking to the host's
## container API directly — it bind-mounts the podman docker-compat socket
## (same pattern as nextcloud's HaRP container). Containers it spawns are
## OUTSIDE Nix management by design and publish FIXED host ports straight
## on the LAN: 8090 (Kiwix), 6333/6334 (Qdrant), 11434 (Ollama), 8100
## (ProtoMaps), 8200 (CyberChef), 8300 (FlatNotes). Two consequences:
##   - If the HomeFree ollama app is also enabled, NOMAD's "AI Assistant"
##     service will fail to start (host port 11434 is taken). Use one or
##     the other.
##   - The content services are unauthenticated on raw LAN ports (upstream
##     design — offline LAN appliance). They are NOT reachable from WAN
##     (only Caddy's 443 is exposed); the Command Center itself is SSO-gated.
##
## Upstream compose services deliberately NOT shipped:
##   - dozzle          — a second unauthenticated web UI with socket access,
##                       only for container log viewing; logs are in journald.
##   - updater sidecar — in-UI self-update rewrites a compose file we don't
##                       have; the admin image version is owned by Nix (the
##                       App Versions page / version-tracking below).
##   - disk-collector  — wants the ENTIRE host filesystem bind-mounted
##                       (/:/host:ro), including /etc/nixos/secrets. Not
##                       acceptable; the UI just lacks its disk-usage widget
##                       (HomeFree's Hardware page covers that).
##
## STORAGE. `storage-path` (admin-UI directory picker) is where all
## downloaded content lands (ZIMs/maps/courses can run to hundreds of GB —
## point it at a data pool). It is both bind-mounted into the Command
## Center (/app/storage) and exported as NOMAD_STORAGE_PATH, the
## HOST-absolute prefix the Command Center bakes into the bind mounts of
## the content containers it spawns. NOTE: the path is baked into NOMAD's
## seeded service rows on first boot — changing it after content services
## are installed requires reinstalling them from NOMAD's UI (and moving
## the data).
let
  version = "1.32.1";
  port = config.homefree.allocPort "nomad";
  domain = config.homefree.system.domain;

  stateDir = "/var/lib/nomad";
  storagePath = if config.homefree.service-options.nomad.storage-path != null
    then config.homefree.service-options.nomad.storage-path
    else "${stateDir}/storage";

  secretsDir = "/var/lib/homefree-secrets/nomad";
  adminEnvFile = "${stateDir}/admin.env";
  mysqlEnvFile = "${stateDir}/mysql.env";

  nomadRedisUid = 813;
  nomadRedisGid = 813;

  enable = config.homefree.service-options.nomad.enable;

  ## Anchors auto-generated secrets into encrypted /etc/nixos/secrets
  ## so they survive a restore — see lib/secrets-anchor.nix.
  anchor = import ../../lib/secrets-anchor.nix { inherit lib pkgs; };

  ## 32 alphanumeric chars — APP_KEY must be ≥16 chars or the admin
  ## container fails validation at startup; stripped of '/+=' so the
  ## value survives unquoted in env-file lines.
  generateSecret = "${pkgs.openssl}/bin/openssl rand -base64 32 | tr -d '/+=' | head -c 32";

  userOptions = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "enable Project NOMAD offline knowledge server";
    };

    public = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Open to public on WAN port";
    };

    storage-path = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Location of downloaded offline content (ZIM files, maps, courses)";
    };

    enable-backup-content = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Whether to backup downloaded offline content (can be hundreds of GB; it is re-downloadable)";
    };
  };
in
{
  options.homefree.services.nomad = userOptions;
  options.homefree.service-options.nomad = userOptions // {
    label = lib.mkOption {
      type = lib.types.str;
      default = "nomad";
      internal = true;
      description = "Service label";
    };

    name = lib.mkOption {
      type = lib.types.str;
      default = "Project NOMAD Offline Knowledge Server";
      internal = true;
      description = "Service display name";
    };

    project-name = lib.mkOption {
      type = lib.types.str;
      default = "Project N.O.M.A.D.";
      internal = true;
      description = "Project name";
    };
  };

  config = {
    ## ── Command Center (admin/portal UI) ─────────────────────────────
    homefree.containers.nomad = lib.mkIf enable {
      image = "ghcr.io/crosstalk-solutions/project-nomad:${version}";

      ## SKIPPED non-root: the image declares no USER (runs as root
      ## internally), and the service's whole job is driving the host's
      ## container API through the bind-mounted podman socket — which is
      ## root-equivalent regardless of the client process's uid (same
      ## documented trade-off as nextcloud's HaRP container).
      runAs = {
        mode = "root";
        reason = "drives the podman docker-compat socket to manage content containers; socket access is root-equivalent regardless of in-container uid";
      };

      ## Several dirs (state, storage, update-shared) — own the mkdirs in
      ## preStartInit instead of a single generated dataDir.
      preStartInit = ''
        mkdir -p ${stateDir}
        mkdir -p ${stateDir}/update-shared
        mkdir -p ${storagePath}
        mkdir -p ${secretsDir}

        ${anchor.preamble}

        ${anchor.anchorSecret {
          service = "nomad";
          key = "app-key";
          dir = secretsDir;
          generate = generateSecret;
        }}

        ${anchor.anchorSecret {
          service = "nomad";
          key = "mysql-password";
          dir = secretsDir;
          generate = generateSecret;
        }}

        APP_KEY=$(cat ${secretsDir}/app-key)
        DB_PASSWORD=$(cat ${secretsDir}/mysql-password)

        install -m 600 /dev/null ${adminEnvFile}
        {
          printf 'APP_KEY=%s\n' "$APP_KEY"
          printf 'DB_PASSWORD=%s\n' "$DB_PASSWORD"
        } > ${adminEnvFile}
      '';

      ports = [
        "0.0.0.0:${toString port}:8080"
      ];

      volumes = [
        "/etc/localtime:/etc/localtime:ro"
        "${storagePath}:/app/storage"
        ## The host's container-management API socket — root-equivalent.
        ## NOMAD creates/starts/stops its content containers through it
        ## (podman's docker-compat API; ports/Binds/RestartPolicy all
        ## supported). Same pattern as nextcloud's HaRP proxy.
        "/run/podman/podman.sock:/var/run/docker.sock"
        ## Self-update IPC dir shared with upstream's updater sidecar; the
        ## sidecar is intentionally not shipped (Nix owns the version), so
        ## this just gives the admin a writable stub instead of an error.
        "${stateDir}/update-shared:/app/update-shared"
      ];

      environment = {
        TZ = config.homefree.system.timeZone;
        NODE_ENV = "production";
        ## Container-internal listen port/iface — fixed by the image.
        PORT = "8080";
        HOST = "0.0.0.0";
        LOG_LEVEL = "info";
        ## Public URL the Command Center is reached at (absolute-URL base).
        URL = "https://nomad.${domain}";
        ## HOST-absolute storage prefix NOMAD bakes into the bind mounts of
        ## the content containers it spawns via the socket (defaults to
        ## /opt/project-nomad/storage upstream). MUST match the host side
        ## of the /app/storage mount above.
        NOMAD_STORAGE_PATH = storagePath;
        DB_HOST = "nomad-mysql";
        DB_PORT = "3306";
        DB_DATABASE = "nomad";
        DB_USER = "nomad_user";
        DB_NAME = "nomad";
        DB_SSL = "false";
        REDIS_HOST = "nomad-redis";
        REDIS_PORT = "6379";
        ## Caddy skips re-compressing already-compressed responses, so
        ## leaving the admin's gzip on is a net win (upstream default).
        DISABLE_COMPRESSION = "false";
      };
      ## APP_KEY + DB_PASSWORD synthesized from anchored secrets above.
      environmentFiles = [ adminEnvFile ];

      ## Upstream's host.docker.internal alias (used for user-entered
      ## service URLs that point back at the host).
      extraOptions = [
        "--add-host=host.docker.internal:host-gateway"
      ];

      ## Ordering only — NOT readiness. On first boot mysql's init takes a
      ## while after the unit is up; the admin retries (and the global
      ## Restart=always policy re-runs it) until the DB accepts connections.
      dependsOn = [ "nomad-mysql" "nomad-redis" ];
    };

    ## ── MySQL ─────────────────────────────────────────────────────────
    homefree.containers.nomad-mysql = lib.mkIf enable {
      image = "docker.io/library/mysql:8.0";

      ## SKIPPED non-root: the official mysql entrypoint must start as root
      ## to initialize/chown the datadir and its /var/run/mysqld socket dir
      ## (owned by the image-internal uid 999), then drops to that internal
      ## mysql user itself. A podman user= override breaks the socket-dir
      ## setup on first init.
      runAs = {
        mode = "root";
        reason = "official mysql entrypoint needs root to init the datadir and socket dir, then drops to the internal mysql uid itself";
      };
      dataDir = "${stateDir}/mysql";

      ## No published ports — reachable only as nomad-mysql on the podman
      ## network (upstream publishes nothing either).
      volumes = [
        "/etc/localtime:/etc/localtime:ro"
        "${stateDir}/mysql:/var/lib/mysql"
      ];

      environment = {
        TZ = config.homefree.system.timeZone;
        MYSQL_DATABASE = "nomad";
        MYSQL_USER = "nomad_user";
      };
      environmentFiles = [ mysqlEnvFile ];

      ## This unit starts BEFORE the admin (dependsOn ordering), so the
      ## anchored secrets land here first; the admin's preStart then reuses
      ## the same values (anchorSecret is idempotent and flock-serialised).
      preStartInit = ''
        mkdir -p ${stateDir}
        mkdir -p ${secretsDir}

        ${anchor.preamble}

        ${anchor.anchorSecret {
          service = "nomad";
          key = "mysql-root-password";
          dir = secretsDir;
          generate = generateSecret;
        }}

        ${anchor.anchorSecret {
          service = "nomad";
          key = "mysql-password";
          dir = secretsDir;
          generate = generateSecret;
        }}

        MYSQL_ROOT_PASSWORD=$(cat ${secretsDir}/mysql-root-password)
        MYSQL_PASSWORD=$(cat ${secretsDir}/mysql-password)

        install -m 600 /dev/null ${mysqlEnvFile}
        {
          printf 'MYSQL_ROOT_PASSWORD=%s\n' "$MYSQL_ROOT_PASSWORD"
          printf 'MYSQL_PASSWORD=%s\n' "$MYSQL_PASSWORD"
        } > ${mysqlEnvFile}
      '';
    };

    ## ── Redis ─────────────────────────────────────────────────────────
    homefree.containers.nomad-redis = lib.mkIf enable {
      image = "docker.io/library/redis:7-alpine";

      ## Single process, only writes /data — drops root cleanly.
      runAs = { mode = "rootless"; uid = nomadRedisUid; gid = nomadRedisGid; };
      dataDir = "${stateDir}/redis";

      ## No published ports — reachable only as nomad-redis on the podman
      ## network. Unauthenticated (upstream default), but only other
      ## HomeFree-managed containers share that bridge.
      volumes = [
        "/etc/localtime:/etc/localtime:ro"
        "${stateDir}/redis:/data"
      ];

      environment = {
        TZ = config.homefree.system.timeZone;
      };
    };

    homefree.service-config = [{
      inherit (config.homefree.service-options.nomad) label name project-name;
      port-request = null;
      enable = config.homefree.service-options.nomad.enable;
      version-tracking = {
        strategy = "github-releases";
        repo = "Crosstalk-Solutions/project-nomad";
        current-version = version;
      };
      systemd-service-names = [
        "podman-nomad"
        "podman-nomad-mysql"
        "podman-nomad-redis"
      ];
      sso = {
        kind = "caddy_gated";
        ## Dev context (intentionally not surfaced in the admin UI):
        ## NOMAD ships ZERO internal auth (upstream: LAN appliance).
        ## Caddy's SSO gate (oauth2-proxy + Zitadel) is the only auth
        ## layer on the Command Center. NOMAD has no RBAC, so any SSO
        ## user past the gate can also manage/install content services
        ## — the Command Center doubles as the household content portal,
        ## so it is deliberately NOT admin-only. The content services it
        ## spawns (Kiwix etc.) listen on raw LAN ports with no auth at
        ## all (see header comment) — LAN-only, never WAN-exposed.
      };
      reverse-proxy = {
        enable = config.homefree.service-options.nomad.enable;
        subdomains = [ "nomad" ];
        http-domains = [ "homefree.lan" config.homefree.system.localDomain ];
        https-domains = [ config.homefree.system.domain ];
        host = config.homefree.network.lan-address;
        port = port;
        public = config.homefree.service-options.nomad.public;
        oauth2 = config.homefree.sso.per-service.nomad.enable or true;
      };
      backup = {
        ## Command Center state only (the mysql datadir copy is
        ## crash-consistent; NOMAD's DB is small metadata). Content
        ## storage is opt-in — it is re-downloadable and can run to
        ## hundreds of GB.
        paths = [
          "${stateDir}/mysql"
          "${stateDir}/redis"
        ] ++ lib.optionals config.homefree.service-options.nomad.enable-backup-content [
          storagePath
        ];
      };
      options-metadata = [
        {
          path = "enable";
          type = "bool";
          default = false;
          description = "Enable Project NOMAD offline knowledge server";
        }
        {
          path = "public";
          type = "bool";
          default = false;
          description = "Make service accessible from WAN";
        }
        {
          path = "storage-path";
          type = "path";
          nullable = true;
          default = null;
          description = "Location of downloaded offline content (ZIM files, maps, courses). Point at a data pool — content can run to hundreds of GB.";
          ui-hint = "directory-picker";
        }
        {
          path = "enable-backup-content";
          type = "bool";
          default = false;
          description = "Whether to backup downloaded offline content (re-downloadable; can be hundreds of GB)";
        }
      ];
    }];
  };
}
