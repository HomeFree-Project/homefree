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
##   - nomad-redis  — Redis 8 (queue/cache)
##
## The Command Center manages CONTENT services (Kiwix, Kolibri, Qdrant,
## Ollama, ProtoMaps, CyberChef, FlatNotes) by talking to the host's
## container API directly — it bind-mounts the podman docker-compat socket
## (same pattern as nextcloud's HaRP container). Containers it spawns are
## OUTSIDE Nix management by design and publish FIXED host ports straight
## on the LAN (per upstream's service_seeder.ts): 8090 (Kiwix), 6333/6334
## (Qdrant), 11434 (Ollama), 8100 (CyberChef), 8200 (FlatNotes), 8300
## (Kolibri); ProtoMaps is served by the admin itself.
##
## NETWORK. The admin HARDCODES the docker network it attaches spawned
## containers to: 'project-nomad_default' (docker_service.ts
## NOMAD_NETWORK — the name docker-compose derives from upstream's
## `-p project-nomad`; no env override). Spawn fails with "network not
## found" without it. In production the admin also reaches spawned
## services BY CONTAINER NAME over that network (getServiceURL →
## http://nomad_qdrant:6333), so all three managed containers join it
## too (container-name DNS is on by default for netavark custom
## networks — that also covers admin→nomad-mysql/nomad-redis). The
## nomad-network oneshot below creates it idempotently.
##
## Two consequences of the spawned-container model:
##   - If the HomeFree ollama app is also enabled, NOMAD's "AI Assistant"
##     service will fail to start (host port 11434 is taken). Use one or
##     the other.
##   - The content services are unauthenticated on raw LAN ports (upstream
##     design — offline LAN appliance). They are NOT reachable from WAN
##     (only Caddy's 443 is exposed); the Command Center itself is SSO-gated.
##     The browser-facing ones additionally get SSO-gated HTTPS vhosts
##     (contentServices below) and NOMAD's tiles are pointed at those by
##     the nomad-ui-links oneshot — required because the platform HSTS
##     (includeSubdomains) breaks plain-HTTP port links on the same domain.
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
## the content containers it spawns. NOTE: set storage-path BEFORE first
## enabling the app. NOMAD's service seeder runs at every admin start but
## is INSERT-ONLY (service_seeder.ts filters out existing rows), so the
## path is frozen into the seeded service rows at FIRST boot and a later
## storage-path change is never picked up — not even by the UI's
## force-reinstall, which reuses the stored container config. Recovering
## from a late change means moving the content dir, then resetting the
## Command Center DB (stop podman-nomad*, remove <stateDir>/mysql,
## restart) so it re-seeds with the new path; downloaded content is
## re-indexed from disk, but Command Center settings/history are lost.
let
  version = "1.32.1";
  ## Sidecar image pins MUST go through a let-binding (never a hardcoded
  ## literal tag) so the App Versions page can detect + one-click bump them
  ## — the source-pin parser only rewrites tags that reference a ${var}.
  ## See AGENTS.md "App version pins + the updater".
  version-redis = "8.8.0-alpine";
  version-mysql = "8.4.10";
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

  ## Hardcoded in upstream's docker_service.ts (NOMAD_NETWORK) — the
  ## compose-derived network name spawned content containers attach to.
  nomadNetwork = "project-nomad_default";

  ## Browser-facing content services NOMAD spawns, each fronted by an
  ## HTTPS vhost (https://<subdomain>.<domain> → the FIXED host port the
  ## spawned container publishes, per upstream's service_seeder.ts).
  ## Without these, the home-page tiles link to http://nomad.<domain>:<port>
  ## — and the platform HSTS header (includeSubdomains) makes the browser
  ## force https onto that plain-HTTP port, which dies with an SSL
  ## record-length error. The nomad-ui-links oneshot below points NOMAD's
  ## `ui_location` rows at these vhosts (its getServiceLink passes a full
  ## URL through verbatim; the port form is only a fallback).
  ## Qdrant/Ollama are deliberately ABSENT: they are backend APIs whose
  ## ui_location feeds getServiceURL on the SERVER side — a vhost URL
  ## there would route the admin's own API calls into the SSO gate.
  contentServices = [
    { label = "nomad-kiwix"; cname = "Information Library (Kiwix)";
      project = "Kiwix"; subdomain = "kiwix"; port = 8090;
      svc = "nomad_kiwix_server"; }
    { label = "nomad-kolibri"; cname = "Education Platform (Kolibri)";
      project = "Kolibri"; subdomain = "kolibri"; port = 8300;
      svc = "nomad_kolibri"; }
    { label = "nomad-cyberchef"; cname = "CyberChef";
      project = "CyberChef"; subdomain = "cyberchef"; port = 8100;
      svc = "nomad_cyberchef"; }
    { label = "nomad-flatnotes"; cname = "FlatNotes";
      project = "FlatNotes"; subdomain = "flatnotes"; port = 8200;
      svc = "nomad_flatnotes"; }
  ];

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
    ## ── project-nomad_default network ─────────────────────────────────
    ## Declarative-in-effect: NixOS has no first-class podman-network
    ## resource, so the app declares this idempotent oneshot
    ## (`--ignore` = no-op when the network already exists) and the three
    ## podman units order/require it below. Re-asserted on every start
    ## request (no RemainAfterExit, per the repo's oneshot-bootstrap
    ## pattern), so a pruned network heals on the next container start.
    systemd.services.nomad-network = lib.mkIf enable {
      description = "Create the ${nomadNetwork} podman network for Project NOMAD";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${pkgs.podman}/bin/podman network create --ignore ${nomadNetwork}";
      };
    };

    ## Escape-hatch merges onto the generated podman units (snapshot-
    ## invisible): the network must exist before any of the three
    ## containers start with --network=${nomadNetwork}.
    systemd.services.podman-nomad = lib.mkIf enable {
      after = [ "nomad-network.service" ];
      requires = [ "nomad-network.service" ];
    };
    systemd.services.podman-nomad-mysql = lib.mkIf enable {
      after = [ "nomad-network.service" ];
      requires = [ "nomad-network.service" ];
    };
    systemd.services.podman-nomad-redis = lib.mkIf enable {
      after = [ "nomad-network.service" ];
      requires = [ "nomad-network.service" ];
    };

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
      ## service URLs that point back at the host) + the shared network
      ## the admin reaches spawned content services on (see header).
      extraOptions = [
        "--add-host=host.docker.internal:host-gateway"
        "--network=${nomadNetwork}"
      ];

      ## Ordering only — NOT readiness (mysql's first-boot init runs well
      ## past unit-active). dependsOn + the bounded gate in preStartFinal
      ## below cover startup; the global Restart=always policy remains the
      ## safety net for anything past the gate's timeout.
      dependsOn = [ "nomad-mysql" "nomad-redis" ];

      ## Bounded readiness gate (~60s, then fall through): don't launch
      ## the admin until MySQL and Redis actually ACCEPT connections.
      ## AdonisJS exits hard when its DB/Redis are unreachable at boot, so
      ## an admin started the instant the mysql UNIT is up (first-boot
      ## init still running) or before a switch's nftables reload lands
      ## fails the unit — and a unit failing DURING a switch fails the
      ## whole rebuild (status 4), with all the skipped-restart fallout
      ## that entails. Same pattern as the oauth2-proxy OIDC readiness
      ## gate: probe the dependency SERVING, not merely started. Probes
      ## use bash /dev/tcp against the containers' current IPs on the
      ## shared network (no published ports to probe instead).
      preStartFinal = ''
        for _i in $(seq 1 30); do
          MYSQL_IP=$(${pkgs.podman}/bin/podman inspect nomad-mysql \
            --format '{{(index .NetworkSettings.Networks "${nomadNetwork}").IPAddress}}' 2>/dev/null || true)
          REDIS_IP=$(${pkgs.podman}/bin/podman inspect nomad-redis \
            --format '{{(index .NetworkSettings.Networks "${nomadNetwork}").IPAddress}}' 2>/dev/null || true)
          if [ -n "$MYSQL_IP" ] && [ -n "$REDIS_IP" ] \
            && timeout 1 ${pkgs.bash}/bin/bash -c "exec 3<>/dev/tcp/$MYSQL_IP/3306" 2>/dev/null \
            && timeout 1 ${pkgs.bash}/bin/bash -c "exec 3<>/dev/tcp/$REDIS_IP/6379" 2>/dev/null; then
            break
          fi
          sleep 2
        done
      '';
    };

    ## ── MySQL ─────────────────────────────────────────────────────────
    homefree.containers.nomad-mysql = lib.mkIf enable {
      image = "docker.io/library/mysql:${version-mysql}";

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

      ## No published ports — reachable only as nomad-mysql on the shared
      ## network (upstream publishes nothing either).
      extraOptions = [ "--network=${nomadNetwork}" ];
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
      image = "docker.io/library/redis:${version-redis}";

      ## Single process, only writes /data — drops root cleanly.
      runAs = { mode = "rootless"; uid = nomadRedisUid; gid = nomadRedisGid; };
      dataDir = "${stateDir}/redis";

      ## No published ports — reachable only as nomad-redis on the shared
      ## network. Unauthenticated (upstream default), but only the NOMAD
      ## stack and its spawned content containers share that network.
      extraOptions = [ "--network=${nomadNetwork}" ];
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
    }]
    ## HTTPS vhosts for the spawned content services (see contentServices).
    ## Vhost-only entries: no containers/units of their own (the workloads
    ## are NOMAD-managed), hidden from the HomeFree admin catalog, and the
    ## fixed upstream port is PINNED as the port-request so the allocator
    ## reserves it instead of shifting the auto-allocation pool.
    ++ (map (cs: {
      label = cs.label;
      name = cs.cname;
      project-name = cs.project;
      port-request = cs.port;
      enable = enable;
      systemd-service-names = [ ];
      admin.show = false;
      sso = {
        kind = "caddy_gated";
        ## Dev context: the spawned services ship zero auth (see the
        ## header) — the Caddy gate is the only auth layer on the vhost.
        ## The raw LAN port stays open underneath (NOMAD owns it).
      };
      reverse-proxy = {
        enable = enable;
        subdomains = [ cs.subdomain ];
        http-domains = [ "homefree.lan" config.homefree.system.localDomain ];
        https-domains = [ config.homefree.system.domain ];
        host = config.homefree.network.lan-address;
        port = cs.port;
        public = config.homefree.service-options.nomad.public;
        oauth2 = config.homefree.sso.per-service.nomad.enable or true;
      };
      backup = { paths = [ ]; };
    }) contentServices);

    ## ── nomad-ui-links — point NOMAD's tiles at the HTTPS vhosts ──────
    ## NOMAD's service rows carry ui_location (seeded as a bare port,
    ## insert-only — never refreshed). The frontend's getServiceLink uses
    ## a full URL verbatim, so converge each browser-facing row onto its
    ## vhost URL. Idempotent and conservative: only rewrites a value that
    ## is still the seeded bare port or one of OUR previous vhost URLs
    ## (domain changes converge; an operator's custom value is preserved).
    ## Bounded wait: rows appear only after the admin container seeds its
    ## DB on first start; if that hasn't happened within ~3 min, exit
    ## cleanly — partOf podman-nomad re-runs this on the next restart.
    systemd.services.nomad-ui-links = lib.mkIf enable {
      description = "Point NOMAD service tiles at the HTTPS vhosts";
      after = [ "podman-nomad.service" ];
      partOf = [ "podman-nomad.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${pkgs.writeShellScript "nomad-ui-links" ''
          set -eu
          MYSQL_PWD=$(cat ${secretsDir}/mysql-password)
          run_sql() {
            ${pkgs.podman}/bin/podman exec -e MYSQL_PWD="$MYSQL_PWD" nomad-mysql \
              mysql -u nomad_user -N -B nomad -e "$1"
          }
          for _i in $(seq 1 36); do
            if n=$(run_sql "SELECT COUNT(*) FROM services;" 2>/dev/null) && [ "''${n:-0}" -gt 0 ]; then
              ${lib.concatMapStringsSep "\n" (cs: ''
                run_sql "UPDATE services SET ui_location='https://${cs.subdomain}.${domain}' WHERE service_name='${cs.svc}' AND ui_location <> 'https://${cs.subdomain}.${domain}' AND (ui_location REGEXP '^[0-9]+$' OR ui_location LIKE 'https://${cs.subdomain}.%');"
              '') contentServices}
              echo "nomad-ui-links: service tile URLs converged."
              exit 0
            fi
            sleep 5
          done
          echo "nomad-ui-links: NOMAD service table not seeded yet; will retry on next podman-nomad restart." >&2
          exit 0
        ''}";
      };
    };

    ## ── nomad-content-autostart — restart spawned content after reboot ─
    ## NOMAD spawns its content containers (nomad_kiwix_server,
    ## nomad_kolibri, nomad_cyberchef, nomad_qdrant, ...) through the
    ## podman socket, OUTSIDE Nix/systemd management, with
    ## restart=unless-stopped. Two things then leave them DOWN after a
    ## reboot, returning 502 on kiwix.<domain>/kolibri.<domain>:
    ##   1. HomeFree's reboot wrapper (services/podman-shutdown-wrapper)
    ##      runs `podman stop -a` before every wrapped reboot — stopping
    ##      them cleanly (and an explicit stop disqualifies them from any
    ##      unless-stopped auto-restart even where one exists).
    ##   2. podman is daemonless: nothing restarts a stopped container at
    ##      boot. The three Nix-managed units (nomad/-mysql/-redis) come
    ##      back via their systemd units; the socket-spawned content
    ##      containers have no unit. podman-restart.service is not enabled
    ##      here, and even when it is it only starts restart=always — not
    ##      unless-stopped.
    ## So HomeFree owns this seam without trying to manage their lifecycle:
    ## a boot-time oneshot that `podman start`s every existing nomad_*
    ## container. The underscore prefix is upstream's content-service
    ## naming and never matches the hyphenated Nix-managed nomad-* units.
    ## Idempotent (start on a running container is a no-op) and it ALWAYS
    ## exits 0, so a failure can never fail a switch (status 4). Mirrors
    ## nomad-ui-links: after+partOf podman-nomad re-runs it whenever the
    ## admin restarts; wantedBy multi-user.target runs it at boot. Empty
    ## when no content is installed yet (no nomad_* containers exist).
    systemd.services.nomad-content-autostart = lib.mkIf enable {
      description = "Start NOMAD-spawned content containers left stopped by a reboot";
      after = [ "nomad-network.service" "podman-nomad.service" ];
      partOf = [ "podman-nomad.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${pkgs.writeShellScript "nomad-content-autostart" ''
          set -u
          for c in $(${pkgs.podman}/bin/podman ps -a --filter 'name=^nomad_' --format '{{.Names}}'); do
            if ${pkgs.podman}/bin/podman start "$c" >/dev/null 2>&1; then
              echo "nomad-content-autostart: started $c"
            else
              echo "nomad-content-autostart: could not start $c (skipping)" >&2
            fi
          done
          exit 0
        ''}";
      };
    };
  };
}
