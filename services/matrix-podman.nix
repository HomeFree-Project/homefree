{config, lib, pkgs, ...}:
let
  version = "v1.152.0";
  image = "matrixdotorg/synapse";
  containerDataPath = "/var/lib/matrix-synapse-podman";

  version-discord = "v0.7.3";
  image-discord = "dock.mau.dev/mautrix/discord";

  port = 8008;
  database-name = "matrix-synapse";
  database-user = "matrix-synapse";

  SYNAPSE_CONFIG_DIR = "/data";

  registration-shared-secret-path = config.homefree.service-options.matrix.secrets.registration-shared-secret;

  settings = {
    ## server_name is used for user logins, e.g. @user:homefree.host, rather than @user:matrix.homefree.host
    server_name = config.homefree.system.domain;
    public_baseurl = "https://matrix.${config.homefree.system.domain}";
    serve_server_wellknown = true;
    ## Set empty whitelist if federation is disabled
    federation_domain_whitelist = if config.homefree.service-options.matrix.enable-federation == false then [] else config.homefree.service-options.matrix.federation-domain-whitelist;
    extra_well_known_server_content = {
      m.homeserver = {
        base_url = "https://matrix.${config.homefree.system.domain}";
      };
    };
    extra_well_known_client_content = {
      m.homeserver = {
        base_url = "https://matrix.${config.homefree.system.domain}";
      };
      # m.identity_server = {
      #   base_url = "https://identity.${config.homefree.system.domain}";
      # };
    };
    listeners = [{
      port = 8008;
      bind_addresses = [ "0.0.0.0" ];
      type = "http";
      tls = false;
      x_forwarded = true;
      resources = [ {
        names = [ "client" "federation" ];
        compress = true;
      } ];
    }];
    report_stats = false;
    trusted_key_servers = [{
      server_name = "matrix.org";
    }];
    registration_shared_secret_path = "${SYNAPSE_CONFIG_DIR}/registration-shared-secret";

    rc_message = {
      per_second = 0.2;
      burst_count = 10.0;
    };
    rc_federation = {
      window_size = 1000;
      sleep_limit = 10;
      sleep_delay = 500;
      reject_limit = 50;
      concurrent = 3;
    };

    # Compress state automatically
    compress_state_on_startup = true;
    retention = {
      enabled = true;
      default_policy = {
        min_lifetime = "1d";
        max_lifetime = "365d";
      };
    };
  };

  config-yaml = (pkgs.formats.yaml {}).generate "homserver.yaml" settings;

  preStart = ''
    mkdir -p ${containerDataPath}

    mkdir -p "${builtins.dirOf config.homefree.service-options.matrix.secrets.admin-account-password}"
    mkdir -p "${builtins.dirOf config.homefree.service-options.matrix.secrets.registration-shared-secret}"

    ${pkgs.postgresql}/bin/psql -X -U postgres << EOF
      DO
      \$do\$
      BEGIN
         IF EXISTS (
            SELECT FROM pg_catalog.pg_roles
            WHERE  rolname = 'matrix-synapse') THEN

            RAISE NOTICE 'Role "matrix-synapse" already exists. Skipping.';
         ELSE
            BEGIN   -- nested block
               CREATE ROLE "matrix-synapse" WITH LOGIN PASSWORD 'changeme';
            EXCEPTION
               WHEN duplicate_object THEN
                  RAISE NOTICE 'Role "matrix-synapse" was just created by a concurrent transaction. Skipping.';
            END;
         END IF;
      END
      \$do\$;
    EOF

    ${pkgs.postgresql}/bin/psql -U postgres -tc "SELECT 1 FROM pg_database WHERE datname = 'matrix-synapse'" | ${pkgs.gnugrep}/bin/grep -q 1 || ${pkgs.postgresql}/bin/psql -U postgres -c "CREATE DATABASE \"matrix-synapse\" WITH OWNER \"matrix-synapse\" ENCODING 'UTF8' LOCALE 'C' TEMPLATE template0"

    ${pkgs.postgresql}/bin/psql -X -U postgres << EOF
      DO
      \$do\$
      BEGIN
        GRANT ALL PRIVILEGES ON DATABASE "matrix-synapse" to "matrix-synapse";
      END
      \$do\$;
    EOF
  '';

  postStart = (if config.homefree.service-options.matrix.admin-account != null then ''
    ${pkgs.podman}/bin/podman exec \
    -it ${image}:${version} \
    -v "${SYNAPSE_CONFIG_DIR}/data/admin-account-password-file:${config.homefree.service-options.matrix.secrets.admin-account-password}" \
    register_new_matrix_user http://localhost:${toString port} \
    -c /data/homeserver.yaml \
    --exists-ok \
    --admin \
    --user ${config.homefree.service-options.matrix.admin-account} \
    --password-file /data/admin-account-password-file
  '' else "");
in
{
  options.homefree.service-options.matrix = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "enable Matrix-Synapse service";
    };

    public = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Open to public on WAN port";
    };

    enable-federation = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "enable Matrix federation";
    };

    federation-domain-whitelist = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      description = "Federation domain whitelist";
    };

    admin-account = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Admin account username";
    };

    secrets = {
      registration-shared-secret = lib.mkOption {
        type = lib.types.path;
        description = "Path to registration shared secret file";
      };
      admin-account-password = lib.mkOption {
        type = lib.types.path;
        description = "Path to admin account password file";
      };
    };

    label = lib.mkOption {
      type = lib.types.str;
      default = "matrix";
      internal = true;
      description = "Service label";
    };

    name = lib.mkOption {
      type = lib.types.str;
      default = "matrix-synapse";
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

  virtualisation.oci-containers.containers = lib.optionalAttrs config.homefree.service-options.matrix.enable {
    matrix-synapse = {
      image = "${image}:${version}";

      autoStart = true;

      extraOptions = [
        # "--pull=always"
      ];

      ports = [
        "0.0.0.0:${toString port}:${toString port}"
      ];

      volumes = [
        "/etc/localtime:/etc/localtime:ro"
        "${containerDataPath}:${SYNAPSE_CONFIG_DIR}"
        "${registration-shared-secret-path}:${SYNAPSE_CONFIG_DIR}/registration-shared-secret"
        "${config-yaml}:${SYNAPSE_CONFIG_DIR}/homeserver.yaml:ro"
      ];

      environment = {
        TZ = config.homefree.system.timeZone;
        SYNAPSE_SERVER_NAME = "";
        SYNAPSE_REPORT_STATS = "no";
        SYNAPSE_HTTP_PORT = "${toString port}";
        SYNAPSE_CONFIG_DIR = SYNAPSE_CONFIG_DIR;
        SYNAPSE_CONFIG_PATH = "${SYNAPSE_CONFIG_DIR}/homeserver.yaml";
        SYNAPSE_DATA_DIR = SYNAPSE_CONFIG_DIR;
      };

      environmentFiles = [
        config.homefree.services.linkwarden.secrets.environment
      ];
    };

    # matrix-discord = {
    #   image = ":${}"
    # }
  };

  systemd.services.podman-matrix-synapse = lib.optionalAttrs config.homefree.service-options.matrix.enable {
    after = [ "dns-ready.service" ];
    requires = [ "dns-ready.service" ];
    partOf =  [ "nftables.service" ];
    serviceConfig = {
      ExecStartPre = [
        "!${pkgs.writeShellScript "matrix-synapse-prestart" preStart}"
      ];
      ExecStartPost = [ "!${pkgs.writeShellScript "matrix-synapse-poststart" postStart}" ];
    };
  };

  # services.coturn = rec {
  #   enable = config.homefree.service-options.matrix.enable;
  #   no-cli = true;
  #   no-tcp-relay = true;
  #   min-port = 49000;
  #   max-port = 50000;
  #   use-auth-secret = true;
  #   static-auth-secret = "will be world readable for local users :(";
  #   realm = "turn.${config.homefree.system.domain}";
  #   cert = "${config.security.acme.certs.${realm}.directory}/full.pem";
  #   pkey = "${config.security.acme.certs.${realm}.directory}/key.pem";
  #   extraConfig = ''
  #     # for debugging
  #     verbose
  #     # ban private IP ranges
  #     no-multicast-peers
  #     denied-peer-ip=0.0.0.0-0.255.255.255
  #     denied-peer-ip=10.0.0.0-10.255.255.255
  #     denied-peer-ip=100.64.0.0-100.127.255.255
  #     denied-peer-ip=127.0.0.0-127.255.255.255
  #     denied-peer-ip=169.254.0.0-169.254.255.255
  #     denied-peer-ip=172.16.0.0-172.31.255.255
  #     denied-peer-ip=192.0.0.0-192.0.0.255
  #     denied-peer-ip=192.0.2.0-192.0.2.255
  #     denied-peer-ip=192.88.99.0-192.88.99.255
  #     denied-peer-ip=192.168.0.0-192.168.255.255
  #     denied-peer-ip=198.18.0.0-198.19.255.255
  #     denied-peer-ip=198.51.100.0-198.51.100.255
  #     denied-peer-ip=203.0.113.0-203.0.113.255
  #     denied-peer-ip=240.0.0.0-255.255.255.255
  #     denied-peer-ip=::1
  #     denied-peer-ip=64:ff9b::-64:ff9b::ffff:ffff
  #     denied-peer-ip=::ffff:0.0.0.0-::ffff:255.255.255.255
  #     denied-peer-ip=100::-100::ffff:ffff:ffff:ffff
  #     denied-peer-ip=2001::-2001:1ff:ffff:ffff:ffff:ffff:ffff:ffff
  #     denied-peer-ip=2002::-2002:ffff:ffff:ffff:ffff:ffff:ffff:ffff
  #     denied-peer-ip=fc00::-fdff:ffff:ffff:ffff:ffff:ffff:ffff:ffff
  #     denied-peer-ip=fe80::-febf:ffff:ffff:ffff:ffff:ffff:ffff:ffff
  #   '';
  # };
  #
  # # get a certificate
  # security.acme.certs.${config.services.coturn.realm} = {
  #   /* insert here the right configuration to obtain a certificate */
  #   postRun = "systemctl restart coturn.service";
  #   group = "turnserver";
  # };

  ## These are blocked by adguardhome
  services.adguardhome.settings.user_rules = lib.optionals config.homefree.service-options.matrix.enable [
    # "@@||_matrix._tcp.bchn.foo^"
    # "@@||_matrix-fed._tcp.bchn.foo^"
    # "@@||_matrix._tcp.mastersh.pro^"
    # "@@||_matrix-fed._tcp.mastersh.pro^"
    # "@@||_matrix._tcp.dea.monster^"
    # "@@||_matrix-fed._tcp.dea.monster^"
    # "@@||dea.monster^"
  ];

  services.matrix-appservice-discord = lib.optionalAttrs config.homefree.service-options.matrix.enable {
    enable = config.homefree.service-options.matrix.enable;
    # environmentFile = /etc/keyring/matrix-appservice-discord/tokens.env;
    # The appservice is pre-configured to use SQLite by default.
    # It's also possible to use PostgreSQL.
    settings = {
      bridge = {
        domain = config.homefree.system.domain;
        homeserverUrl = "https://matrix.${config.homefree.system.domain}";
      };

      # The service uses SQLite by default, but it's also possible to use
      # PostgreSQL instead:
      #database = {
      #  filename = ""; # empty value to disable sqlite
      #  connString = "socket:/run/postgresql?db=matrix-appservice-discord";
      #};
    };
  };

  # ## @TODO: lock down user password
  # systemd.services.matrix-synapse =
  # let
  #   preStart = ''
  #     mkdir -p "${builtins.dirOf config.homefree.service-options.matrix.secrets.admin-account-password}"
  #     mkdir -p "${builtins.dirOf config.homefree.service-options.matrix.secrets.registration-shared-secret}"
  #
  #     ${pkgs.postgresql}/bin/psql -X -U postgres << EOF
  #       DO
  #       \$do\$
  #       BEGIN
  #          IF EXISTS (
  #             SELECT FROM pg_catalog.pg_roles
  #             WHERE  rolname = '${database-user}') THEN
  #
  #             RAISE NOTICE 'Role "${database-user}" already exists. Skipping.';
  #          ELSE
  #             BEGIN   -- nested block
  #                CREATE ROLE "${database-user}" WITH LOGIN PASSWORD 'changeme';
  #             EXCEPTION
  #                WHEN duplicate_object THEN
  #                   RAISE NOTICE 'Role "${database-user}" was just created by a concurrent transaction. Skipping.';
  #             END;
  #          END IF;
  #       END
  #       \$do\$;
  #     EOF
  #
  #     ${pkgs.postgresql}/bin/psql -U postgres -tc "SELECT 1 FROM pg_database WHERE datname = '${database-name}" | ${pkgs.gnugrep}/bin/grep -q 1 || ${pkgs.postgresql}/bin/psql -U postgres -c "CREATE DATABASE \"${database-name}\" WITH OWNER \"${database-user}\" ENCODING 'UTF8' LOCALE 'C' TEMPLATE template0"
  #
  #     ${pkgs.postgresql}/bin/psql -X -U postgres << EOF
  #       DO
  #       \$do\$
  #       BEGIN
  #         GRANT ALL PRIVILEGES ON DATABASE "${database-name}" to "${database-user}";
  #       END
  #       \$do\$;
  #     EOF
  #   '';
  #
  #   postStart = (if config.homefree.service-options.matrix.admin-account != null then ''
  #     /run/current-system/sw/bin/matrix-synapse-register_new_matrix_user --exists-ok --admin --user ${config.homefree.service-options.matrix.admin-account} --password-file ${config.homefree.service-options.matrix.secrets.admin-account-password}
  #   '' else "");
  # in
  # {
  #   serviceConfig = {
  #     ExecStartPre = [
  #       "${pkgs.writeShellScript "matrix-synapse-prestart-make-paths" preStart}"
  #     ];
  #     ExecStartPost = [
  #       "${pkgs.writeShellScript "matrix-synapse-poststart" postStart}"
  #     ];
  #     ## Make sure service can read the secrets, as it's heavily sandboxed.
  #     BindReadOnlyPaths = [
  #       config.homefree.service-options.matrix.secrets.admin-account-password
  #       config.homefree.service-options.matrix.secrets.registration-shared-secret
  #     ];
  #   };
  # };

    homefree.service-config = [{
      inherit (config.homefree.service-options.matrix) label name project-name;
      systemd-service-names = [
        "matrix-synapse"
        "matrix-synapse-discord"
      ];
      reverse-proxy = {
        enable = config.homefree.service-options.matrix.enable;
        subdomains = [ "matrix" ];
        http-domains = [ "homefree.lan" config.homefree.system.localDomain ];
        https-domains = [ config.homefree.system.domain ];
        host = config.homefree.network.lan-address;
        port = port;
        public = config.homefree.service-options.matrix.public;
        extraCaddyConfig = ''
          # Matrix Synapse settings
          respond /.well-known/matrix/server `{"m.server": "matrix.${config.homefree.system.domain}:443"}`
          reverse_proxy /_matrix/* ${config.homefree.network.lan-address}:8008
          reverse_proxy /_synapse/client/* ${config.homefree.network.lan-address}:8008
        '';
      };
      firewall = {
        open-ports = {
          tcp = [
            3478
            5349
          ];
          udp = [
            3478
            5349
          ]
          ++
          # Ports 49000-50000
          builtins.genList (x: x + 49000) 1001;
        };
      };
      backup = {
        paths = [
          containerDataPath
          "/var/lib/private/matrix-appservice-discord"
        ];
      };
    }];
  };
}
