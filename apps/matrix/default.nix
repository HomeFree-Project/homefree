{ config, lib, pkgs, ... }:
let
  ## Synapse v1.152.x — the oldest tag still on Docker Hub (Hub
  ## reaps older minors). Live runs v1.130.0 on NixOS-native; the
  ## live DB will auto-migrate forward on first start under v1.152.
  version = "v1.152.1";
  image = "matrixdotorg/synapse";

  containerDataPath = "/var/lib/matrix-synapse-podman";
  secretsDir = "/var/lib/homefree-secrets/matrix";

  ## Anchors auto-generated secrets into encrypted /etc/nixos/secrets
  ## so they survive a restore — see lib/secrets-anchor.nix.
  anchor = import ../../lib/secrets-anchor.nix { inherit lib pkgs; };

  port = config.homefree.allocPort "matrix";
  database-name = "matrix-synapse";
  database-user = "matrix-synapse";

  domain = config.homefree.system.domain;
  adminUser = config.homefree.service-options.matrix.admin-account;

  ## Matrix homeserver identity. server_name is BAKED INTO every
  ## stored event, user_id, room_id, and the signing key. Migrating
  ## a server to a new server_name is unsupported by Synapse — the
  ## startup check `Found users in database not native to <name>`
  ## refuses to proceed. So for boxes inheriting an existing Matrix
  ## DB (e.g. the homefree.host → slacktopia.org dev migration), the
  ## option below lets the operator keep the original identity even
  ## when homefree.system.domain has been re-pointed. Federation
  ## resumes when whichever IP `<serverName>` resolves to is this
  ## box.
  serverName =
    if config.homefree.service-options.matrix.server-name != null
    then config.homefree.service-options.matrix.server-name
    else domain;

  ## Synapse config. Mirrors live's homeserver.yaml almost verbatim;
  ## only differences are container-relative paths and the new domain.
  homeserverSettings = {
    server_name = serverName;
    public_baseurl = "https://matrix.${serverName}";
    serve_server_wellknown = true;

    federation_domain_whitelist =
      if config.homefree.service-options.matrix.enable-federation == false
      then []
      else config.homefree.service-options.matrix.federation-domain-whitelist;

    extra_well_known_server_content = {
      m.homeserver.base_url = "https://matrix.${serverName}";
    };
    extra_well_known_client_content = {
      m.homeserver.base_url = "https://matrix.${serverName}";
    };

    listeners = [{
      port = port;
      bind_addresses = [ "0.0.0.0" ];
      type = "http";
      tls = false;
      x_forwarded = true;
      resources = [{
        names = [ "client" "federation" ];
        compress = true;
      }];
    }];

    ## psycopg2 reads from a Unix socket mounted into the container
    ## at /run/postgresql. Same pattern Linkwarden uses for the host
    ## Postgres. Synapse runs as uid 991 inside the container; the
    ## host postgres allows peer auth for matching uids.
    database = {
      name = "psycopg2";
      args = {
        database = database-name;
        user = database-user;
        host = "/run/postgresql";
        cp_min = 5;
        cp_max = 10;
      };
    };

    media_store_path = "/data/media_store";
    signing_key_path = "/data/homeserver.signing.key";
    registration_shared_secret_path = "/data/registration-shared-secret";

    report_stats = false;
    enable_registration = false;
    trusted_key_servers = [{ server_name = "matrix.org"; }];

    rc_message = { per_second = 0.2; burst_count = 10; };
    rc_federation = {
      window_size = 1000;
      sleep_limit = 10;
      sleep_delay = 500;
      reject_limit = 50;
      concurrent = 3;
    };

    compress_state_on_startup = true;
    retention = {
      enabled = true;
      default_policy = {
        min_lifetime = "1d";
        max_lifetime = "365d";
      };
    };

    url_preview_enabled = true;
    ## Mandatory when url_preview_enabled=true. Default RFC-1918 +
    ## special-use ranges so the preview fetcher can't be tricked
    ## into hitting internal services.
    url_preview_ip_range_blacklist = [
      "127.0.0.0/8" "10.0.0.0/8" "172.16.0.0/12" "192.168.0.0/16"
      "100.64.0.0/10" "169.254.0.0/16" "192.0.0.0/24" "192.0.2.0/24"
      "192.88.99.0/24" "198.18.0.0/15" "198.51.100.0/24" "203.0.113.0/24"
      "224.0.0.0/4"
      "::1/128" "fe80::/10" "fc00::/7" "fec0::/10" "ff00::/8"
      "2001:db8::/32"
    ];
    max_upload_size = "50M";
    max_image_pixels = "32M";
  };

  homeserverYaml = (pkgs.formats.yaml {}).generate "homeserver.yaml" homeserverSettings;

  ## Generator for the ed25519 signing key, in the line format synapse
  ## expects: `ed25519 <key_id> <base64_data>`. A multi-line shell
  ## body — wrapped in `sh -c` so anchorSecret's `generate` (a single
  ## command whose stdout is the value) sees it as one command.
  signingKeyGen = pkgs.writeShellScript "matrix-signing-key-gen" ''
    KEY_ID="a_$(${pkgs.openssl}/bin/openssl rand -hex 3)"
    KEY_B64=$(${pkgs.openssl}/bin/openssl genpkey -algorithm ed25519 -outform DER \
      | tail -c 32 | ${pkgs.coreutils}/bin/base64 -w0 | tr -d '=')
    echo "ed25519 $KEY_ID $KEY_B64"
  '';

  preStart = ''
    mkdir -p ${containerDataPath}/media_store
    mkdir -p ${secretsDir}

    ${anchor.preamble}

    ## registration_shared_secret — Synapse needs it for
    ## `register_new_matrix_user`. Anchored so existing tokens stay
    ## valid across a restore. Also installed into the container data
    ## dir where synapse reads it.
    ${anchor.anchorSecret {
      service = "matrix";
      key = "registration-shared-secret";
      dir = secretsDir;
      generate = "${pkgs.openssl}/bin/openssl rand -hex 32";
      extraInstall = ''
        install -m 600 "$ANCHOR_SECRET_FILE" \
          ${containerDataPath}/registration-shared-secret
      '';
    }}

    ${anchor.anchorSecret {
      service = "matrix";
      key = "admin-account-password";
      dir = secretsDir;
      generate = "${pkgs.openssl}/bin/openssl rand -base64 24 | tr -d '\\n'";
    }}

    ## homeserver signing key — the homeserver's federation identity.
    ## Regenerating it on a restore would permanently break federation,
    ## so it MUST be anchored. Previously stored only in the (un-backed-
    ## up) container data dir; now anchored under secretsDir and
    ## installed into the container path on every boot.
    ##
    ## MIGRATION: an existing box has the key only in the container
    ## data dir. Seed the secretsDir copy from there BEFORE anchoring,
    ## so the anchor adopts the EXISTING key rather than generating a
    ## new one (which would break federation).
    if [ ! -s ${secretsDir}/homeserver-signing-key ] \
       && [ -s ${containerDataPath}/homeserver.signing.key ]; then
      install -m 600 ${containerDataPath}/homeserver.signing.key \
        ${secretsDir}/homeserver-signing-key
    fi
    ${anchor.anchorSecret {
      service = "matrix";
      key = "homeserver-signing-key";
      dir = secretsDir;
      generate = "${signingKeyGen}";
      extraInstall = ''
        install -m 600 "$ANCHOR_SECRET_FILE" \
          ${containerDataPath}/homeserver.signing.key
      '';
    }}

    ## Ensure container's synapse user (uid 991) owns its data.
    ## Use ID 991 to match Docker image default (UID = 991, GID = 991
    ## per matrixdotorg/synapse Dockerfile).
    chown -R 991:991 ${containerDataPath}

    ## DB + role bootstrap. The host postgres allows peer auth for
    ## the matrix-synapse OS user; create the role with that name so
    ## the in-container peer-auth via the bind-mounted /run/postgresql
    ## socket works.
    ${pkgs.postgresql}/bin/psql -X -U postgres <<'EOF'
      DO $do$ BEGIN
        IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'matrix-synapse') THEN
          CREATE ROLE "matrix-synapse" WITH LOGIN;
        END IF;
      END $do$;
    EOF

    ${pkgs.postgresql}/bin/psql -U postgres \
      -tc "SELECT 1 FROM pg_database WHERE datname = 'matrix-synapse'" \
      | ${pkgs.gnugrep}/bin/grep -q 1 \
      || ${pkgs.postgresql}/bin/psql -U postgres -c \
        "CREATE DATABASE \"matrix-synapse\" WITH OWNER \"matrix-synapse\" ENCODING 'UTF8' LOCALE 'C' TEMPLATE template0"

    ${pkgs.postgresql}/bin/psql -U postgres -c \
      'GRANT ALL PRIVILEGES ON DATABASE "matrix-synapse" TO "matrix-synapse"'
  '';

  postStart = pkgs.writeShellScript "matrix-synapse-poststart" ''
    set -u
    ## Register the admin account once Synapse is responsive. The
    ## register_new_matrix_user script uses registration_shared_secret
    ## to talk to /_synapse/admin/v1/register. `--exists-ok` makes
    ## this idempotent across restarts.
    ${lib.optionalString (adminUser != null) ''
      for i in $(seq 1 60); do
        if ${pkgs.curl}/bin/curl -sf "http://127.0.0.1:${toString port}/health" >/dev/null 2>&1; then
          break
        fi
        [ "$i" = 60 ] && { echo "matrix postStart: synapse never came up"; exit 0; }
        sleep 2
      done

      ${pkgs.podman}/bin/podman exec matrix-synapse \
        register_new_matrix_user \
          --user ${adminUser} \
          --password "$(cat ${secretsDir}/admin-account-password)" \
          --admin --exists-ok \
          -c /data/homeserver.yaml \
          http://127.0.0.1:${toString port} 2>&1 | tail -3 || true
    ''}
  '';

  userOptions = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "enable Matrix chat service";
    };

    enable-federation = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "enable Matrix federation";
    };

    federation-domain-whitelist = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "matrix.org" "nixos.org" "homefree.host" "rycee.net" "gnome.org" ];
    };

    public = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Open to public on WAN port";
    };

    admin-account = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Admin user for matrix synapse server (localpart only)";
    };

    server-name = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Override Matrix server_name. Defaults to homefree.system.domain.";
    };

    secrets = lib.mkOption {
      type = lib.types.attrsOf (lib.types.nullOr lib.types.path);
      default = {};
      description = "Secrets for Matrix service";
    };
  };
in
{
  options.homefree.services.matrix = userOptions;
  options.homefree.service-options.matrix = userOptions // {
    label = lib.mkOption {
      type = lib.types.str;
      default = "matrix";
      internal = true;
      description = "Service label";
    };

    name = lib.mkOption {
      type = lib.types.str;
      default = "Matrix";
      internal = true;
      description = "Service display name";
    };

    project-name = lib.mkOption {
      type = lib.types.str;
      default = "Matrix-Synapse";
      internal = true;
      description = "Project name";
    };
  };

  config = {
    ## Container via the app-platform primitive (modules/app-platform.nix).
    ## The dns-ready podman unit is generated. Synapse has NO OIDC discovery
    ## fetch, so no CA bundle (caBundle=false). dataDir=null: the preStart does
    ## its own mkdir + chown to the image's uid 991 (not a HomeFree 800-899
    ## uid), so it goes verbatim into preStartInit with no generated mkdir/chown.
    ## The postgresql ordering/partOf + ExecStartPost (admin registration) stay
    ## in a separate systemd.services.podman-matrix-synapse merge below.
    homefree.containers.matrix-synapse = lib.mkIf config.homefree.service-options.matrix.enable {
      ## SKIPPED Phase 3 non-root: synapse runs as the image's uid 991
      ## (matrixdotorg/synapse default), chowned by preStart — not a
      ## HomeFree-managed 800-899 uid. dataDir=null so no generated
      ## mkdir/chown; the preStart owns both.
      runAs = { mode = "root"; reason = "synapse runs as image-default uid 991 (chowned in preStart), not a HomeFree 800-899 uid"; };
      image = "${image}:${version}";

      dataDir = null;
      caBundle = false;

      ports = [
        "0.0.0.0:${toString port}:${toString port}"
      ];

      volumes = [
        "/etc/localtime:/etc/localtime:ro"
        "${containerDataPath}:/data"
        "${homeserverYaml}:/data/homeserver.yaml:ro"
        ## Bind-mount host's postgres socket. Synapse uses
        ## host=/run/postgresql in homeserver.yaml; this puts the
        ## socket at the same path inside the container so peer
        ## auth as the `matrix-synapse` role works.
        "/run/postgresql:/run/postgresql"
      ];

      environment = {
        TZ = config.homefree.system.timeZone;
        SYNAPSE_CONFIG_DIR = "/data";
        SYNAPSE_CONFIG_PATH = "/data/homeserver.yaml";
        SYNAPSE_DATA_DIR = "/data";
      };

      ## Full preStart body: mkdir media_store + secrets dir, anchor the
      ## registration secret / admin password / signing key, chown the data
      ## dir to uid 991, bootstrap the postgres role + DB. All handled here
      ## (caBundle=false, dataDir=null).
      preStartInit = preStart;
    };

    ## PostgreSQL ordering/partOf + ExecStartPost (admin registration). These
    ## MERGE with the dns-ready after/wants the app-platform generates for
    ## podman-matrix-synapse. The ExecStartPost is NOT part of homefree.containers
    ## (the platform only generates ExecStartPre); it stays here so the
    ## service-restart-policy module and the platform-generated unit both see it
    ## merged into the same podman-matrix-synapse unit.
    systemd.services.podman-matrix-synapse = lib.mkIf config.homefree.service-options.matrix.enable {
      after = [ "postgresql.service" ];
      requires = [ "postgresql.service" ];
      ## Re-bind /run/postgresql when postgres restarts — without
      ## partOf the container's existing mount is orphaned and DB
      ## queries fail with ENOENT. Same pattern as nextcloud/freshrss.
      partOf = [ "postgresql.service" ];
      serviceConfig = {
        ExecStartPost = [ "!${postStart}" ];
      };
    };

    services.postgresql = lib.optionalAttrs config.homefree.service-options.matrix.enable {
      enable = true;
    };

    homefree.service-config = lib.optionals config.homefree.service-options.matrix.enable [{
      inherit (config.homefree.service-options.matrix) label name project-name;
      port-request = null;
      systemd-service-names = [
        "podman-matrix-synapse"
        "postgresql"
      ];
      sso = {
        kind = "none";
        ## Dev context (intentionally not surfaced in the admin UI):
        ## Matrix clients (Element, etc.) authenticate to Synapse over
        ## the Matrix CS API with their own access tokens — they don't
        ## speak OIDC at the HTTP gateway. Synapse supports OIDC
        ## natively for new account creation; wiring that is a separate
        ## effort, so SSO here is pending rather than not-applicable.
      };
      reverse-proxy = {
        enable = true;
        subdomains = [ "matrix" ];
        http-domains = [ "homefree.lan" config.homefree.system.localDomain ];
        https-domains = [ config.homefree.system.domain ];
        host = config.homefree.network.lan-address;
        port = port;
        public = config.homefree.service-options.matrix.public;
        extraCaddyConfig = ''
          # Matrix Synapse settings: respond to .well-known/matrix/server
          # for the homeserver's server_name so federating peers find
          # us. NOTE: ${serverName} may differ from the box's primary
          # domain when migrating an existing homeserver (see the
          # serverName comment above).
          respond /.well-known/matrix/server `{"m.server": "matrix.${serverName}:443"}`
          reverse_proxy /_matrix/* ${config.homefree.network.lan-address}:${toString port}
          reverse_proxy /_synapse/client/* ${config.homefree.network.lan-address}:${toString port}
          reverse_proxy /_synapse/admin/* ${config.homefree.network.lan-address}:${toString port}
        '';
      };
      backup = {
        paths = [ containerDataPath ];
        postgres-databases = [ database-name ];
      };
      options-metadata = [
        { path = "enable"; type = "bool"; default = false; description = "Enable Matrix homeserver"; }
        { path = "public"; type = "bool"; default = false; description = "Make service accessible from WAN"; }
        { path = "enable-federation"; type = "bool"; default = false; description = "Enable federation"; }
        { path = "admin-account"; type = "str"; nullable = true; default = null; description = "Admin account username (localpart)"; }
      ];
    }];
  };
}
