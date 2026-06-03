{ config, lib, pkgs, ... }:
let
  userOptions = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "enable Snipe-IT inventory management service";
    };

    public = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Open to public on WAN port";
    };

    secrets = {
      mysql-password = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = "Location of Snipe-IT mysql password file. Should not be a file included in your source repo.";
      };
      env = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = "Location of Snipe-IT env file. Contains DB_PASSWORD, which is the same as mysql-password above, and APP_KEY. Should not be a file included in your source repo.";
      };
    };
  };

  containerDataPath = "/var/lib/snipeit";
  secretsDir = "/var/lib/homefree-secrets/snipe-it";

  ## Anchors auto-generated secrets into encrypted /etc/nixos/secrets
  ## so they survive a restore — see lib/secrets-anchor.nix.
  anchor = import ../../lib/secrets-anchor.nix { inherit lib pkgs; };

  ## Auto-generate the MySQL password on first boot when the user
  ## hasn't supplied one. Same pattern as nextcloud / mediawiki.
  ## When secrets.mysql-password IS set, prefer that file. Either
  ## way, preStart reads the resolved path at runtime (no Nix-level
  ## null interpolation).
  userSuppliedMysqlPassword = config.homefree.service-options.snipe-it.secrets.mysql-password or null;
  mysqlPasswordFile =
    if userSuppliedMysqlPassword != null
    then userSuppliedMysqlPassword
    else "${secretsDir}/mysql-password";

  preStart = ''
    mkdir -p ${containerDataPath}
    mkdir -p ${secretsDir}

    ${anchor.preamble}

    ${lib.optionalString (userSuppliedMysqlPassword == null) (anchor.anchorSecret {
      service = "snipe-it";
      key = "mysql-password";
      dir = secretsDir;
      generate = "${pkgs.openssl}/bin/openssl rand -base64 32 | tr -d '/+=' | head -c 32";
    })}

    ## Laravel APP_KEY — required by Snipe-IT's bootstrapping or the
    ## container exits with "Please re-run with $APP_KEY". Regenerating
    ## it invalidates every encrypted DB column and signed cookie, so
    ## it is anchored into encrypted /etc/nixos/secrets to survive a
    ## restore. Format: literal "base64:" prefix + 32 raw bytes of
    ## openssl-emitted base64, matching `php artisan key:generate`.
    ${anchor.anchorSecret {
      service = "snipe-it";
      key = "app-key";
      dir = secretsDir;
      generate = "sh -c 'printf \"base64:%s\" \"$(${pkgs.openssl}/bin/openssl rand -base64 32)\"'";
    }}

    ## Synthesize the env file the container reads. Carries the two
    ## secrets that the container's Laravel bootstrap requires every
    ## boot. The user-provided secrets.env is still mounted (below)
    ## and overrides on top — last one wins.
    install -m 600 /dev/null ${containerDataPath}/runtime.env
    {
      echo "APP_KEY=$(cat ${secretsDir}/app-key)"
      echo "DB_PASSWORD=$(cat ${mysqlPasswordFile})"
    } > ${containerDataPath}/runtime.env

    MYSQL_PASSWORD=$(cat ${mysqlPasswordFile})

    ## Snipe-IT only needs full access to its own database — never
    ## *.*. The unconditional REVOKE ON *.* below cleans up the
    ## historical over-grant on existing boxes (was Phase 4's
    ## documented @TODO); idempotent on already-converged boxes.
    ${pkgs.mariadb}/bin/mysql -e "CREATE USER IF NOT EXISTS 'snipeit'@'localhost'"
    ${pkgs.mariadb}/bin/mysql -e "ALTER USER 'snipeit'@'localhost' IDENTIFIED BY '$MYSQL_PASSWORD'";
    ${pkgs.mariadb}/bin/mysql -e "REVOKE ALL PRIVILEGES, GRANT OPTION FROM 'snipeit'@'localhost'"
    ${pkgs.mariadb}/bin/mysql -e "GRANT ALL PRIVILEGES ON snipeit.* TO 'snipeit'@'localhost'"
    ${pkgs.mariadb}/bin/mysql -e "CREATE USER IF NOT EXISTS 'snipeit'@'%'"
    ${pkgs.mariadb}/bin/mysql -e "ALTER USER 'snipeit'@'%' IDENTIFIED BY '$MYSQL_PASSWORD'"
    ${pkgs.mariadb}/bin/mysql -e "REVOKE ALL PRIVILEGES, GRANT OPTION FROM 'snipeit'@'%'"
    ${pkgs.mariadb}/bin/mysql -e "GRANT ALL PRIVILEGES ON snipeit.* TO 'snipeit'@'%'"
  '';

  version = "v8.4.1";

  port = config.homefree.allocPort "snipe-it";
in
{
  options.homefree.services.snipe-it = userOptions;
  options.homefree.service-options.snipe-it = userOptions // {
    label = lib.mkOption {
      type = lib.types.str;
      default = "snipe-it";
      internal = true;
      description = "Service label";
    };

    name = lib.mkOption {
      type = lib.types.str;
      default = "snipeit";
      internal = true;
      description = "Service display name";
    };

    project-name = lib.mkOption {
      type = lib.types.str;
      default = "Snipe-IT";
      internal = true;
      description = "Project name";
    };
  };

  config = {

  services.mysql = lib.optionalAttrs config.homefree.service-options.snipe-it.enable {
    ensureDatabases = [
      "snipeit"
    ];

    ensureUsers = [
      {
        name = "snipeit";
        ensurePermissions = {
          "snipeit.*" = "ALL PRIVILEGES";
        };
      }
    ];
  };

  virtualisation.oci-containers.containers = lib.optionalAttrs config.homefree.service-options.snipe-it.enable {
    snipe-it = {
      image = "snipe/snipe-it:${version}";

      autoStart = true;

      extraOptions = [
        # "--pull=always"
      ];

      ports = [
        "0.0.0.0:${toString port}:80"
      ];

      volumes = [
        "/etc/localtime:/etc/localtime:ro"
        "${containerDataPath}:/var/lib/snipeit"
      ];

      ## runtime.env carries auto-generated APP_KEY + DB_PASSWORD. The
      ## user-supplied secrets.env (if set) is loaded after and can
      ## override either value.
      environmentFiles = [ "${containerDataPath}/runtime.env" ]
        ++ lib.optional
          (config.homefree.service-options.snipe-it.secrets.env or null != null)
          config.homefree.service-options.snipe-it.secrets.env;

      environment = {
        TZ = config.homefree.system.timeZone;

        # --------------------------------------------
        # REQUIRED: DOCKER SPECIFIC SETTINGS
        # --------------------------------------------
        APP_VERSION = version;
        APP_PORT = toString port;

        # --------------------------------------------
        # REQUIRED: BASIC APP SETTINGS
        # --------------------------------------------
        APP_ENV = "production";
        APP_DEBUG = "false";
        ## Please regenerate the APP_KEY value by calling `docker compose run --rm snipeit php artisan key:generate --show`. Copy paste the value here
        # APP_KEY = "base64:lorempipsum";
        APP_URL = "https://snipeit.${config.homefree.system.domain}";
        # https://en.wikipedia.org/wiki/List_of_tz_database_time_zones - TZ identifier
        APP_TIMEZONE = config.homefree.system.timeZone;
        ## Doesn't handle the module.nix local, with has the ".UTF-8" extension
        ## split off the first part before the dot
        APP_LOCALE = builtins.head (builtins.split "." config.homefree.system.defaultLocale);
        MAX_RESULTS = "500";

        # --------------------------------------------
        # REQUIRED: UPLOADED FILE STORAGE SETTINGS
        # --------------------------------------------
        PRIVATE_FILESYSTEM_DISK = "local";
        PUBLIC_FILESYSTEM_DISK = "local_public";

        # --------------------------------------------
        # REQUIRED: DATABASE SETTINGS
        # --------------------------------------------
        DB_CONNECTION = "mysql";
        DB_HOST = config.homefree.network.lan-address;
        DB_DATABASE = "snipeit";
        DB_PORT = "3306";
        DB_USERNAME = "snipeit";
        DB_PREFIX = "null";
        DB_DUMP_PATH = "'/usr/bin'";
        DB_CHARSET = "utf8mb4";
        DB_COLLATION = "utf8mb4_unicode_ci";

        # --------------------------------------------
        # OPTIONAL: SSL DATABASE SETTINGS
        # --------------------------------------------
        DB_SSL = "false";
        DB_SSL_IS_PAAS = "false";
        DB_SSL_KEY_PATH = "null";
        DB_SSL_CERT_PATH = "null";
        DB_SSL_CA_PATH = "null";
        DB_SSL_CIPHER = "null";
        DB_SSL_VERIFY_SERVER = "null";

        # --------------------------------------------
        # REQUIRED: OUTGOING MAIL SERVER SETTINGS
        # --------------------------------------------
        MAIL_MAILER = "smtp";
        MAIL_HOST = "mailhog";
        MAIL_PORT = "1025";
        MAIL_USERNAME = "null";
        MAIL_PASSWORD = "null";
        MAIL_TLS_VERIFY_PEER = "true";
        MAIL_FROM_ADDR = "you@example.com";
        MAIL_FROM_NAME = "'Snipe-IT'";
        MAIL_REPLYTO_ADDR = "you@example.com";
        MAIL_REPLYTO_NAME = "'Snipe-IT'";
        MAIL_AUTO_EMBED_METHOD = "'attachment'";

        # --------------------------------------------
        # REQUIRED: DATA PROTECTION
        # --------------------------------------------
        ALLOW_BACKUP_DELETE = "false";
        ALLOW_DATA_PURGE = "false";

        # --------------------------------------------
        # REQUIRED: IMAGE LIBRARY
        # This should be gd or imagick
        # --------------------------------------------
        IMAGE_LIB = "gd";

        # --------------------------------------------
        # OPTIONAL: BACKUP SETTINGS
        # --------------------------------------------
        MAIL_BACKUP_NOTIFICATION_DRIVER = "null";
        MAIL_BACKUP_NOTIFICATION_ADDRESS = "null";
        BACKUP_ENV = "true";

        # --------------------------------------------
        # OPTIONAL: SESSION SETTINGS
        # --------------------------------------------
        SESSION_LIFETIME = "12000";
        EXPIRE_ON_CLOSE = "false";
        ENCRYPT = "false";
        COOKIE_NAME = "snipeit_session";
        COOKIE_DOMAIN = "null";
        SECURE_COOKIES = "false";
        API_TOKEN_EXPIRATION_YEARS = "40";

        # --------------------------------------------
        # OPTIONAL: SECURITY HEADER SETTINGS
        # --------------------------------------------
        APP_TRUSTED_PROXIES = "192.168.1.1,${config.homefree.network.lan-address},172.16.0.0/12";
        ALLOW_IFRAMING = "false";
        REFERRER_POLICY = "same-origin";
        ENABLE_CSP = "false";
        CORS_ALLOWED_ORIGINS = "null";
        ENABLE_HSTS = "false";

        # --------------------------------------------
        # OPTIONAL: CACHE SETTINGS
        # --------------------------------------------
        CACHE_DRIVER = "file";
        SESSION_DRIVER = "file";
        QUEUE_DRIVER = "sync";
        CACHE_PREFIX = "snipeit";

        # --------------------------------------------
        # OPTIONAL: REDIS SETTINGS
        # --------------------------------------------
        REDIS_HOST = "null";
        REDIS_PASSWORD = "null";
        REDIS_PORT = "6379";

        # --------------------------------------------
        # OPTIONAL: MEMCACHED SETTINGS
        # --------------------------------------------
        MEMCACHED_HOST = "null";
        MEMCACHED_PORT = "null";

        # --------------------------------------------
        # OPTIONAL: PUBLIC S3 Settings
        # --------------------------------------------
        PUBLIC_AWS_SECRET_ACCESS_KEY = "null";
        PUBLIC_AWS_ACCESS_KEY_ID = "null";
        PUBLIC_AWS_DEFAULT_REGION = "null";
        PUBLIC_AWS_BUCKET = "null";
        PUBLIC_AWS_URL = "null";
        PUBLIC_AWS_BUCKET_ROOT = "null";

        # --------------------------------------------
        # OPTIONAL: PRIVATE S3 Settings
        # --------------------------------------------
        PRIVATE_AWS_ACCESS_KEY_ID = "null";
        PRIVATE_AWS_SECRET_ACCESS_KEY = "null";
        PRIVATE_AWS_DEFAULT_REGION = "null";
        PRIVATE_AWS_BUCKET = "null";
        PRIVATE_AWS_URL = "null";
        PRIVATE_AWS_BUCKET_ROOT = "null";

        # --------------------------------------------
        # OPTIONAL: AWS Settings
        # --------------------------------------------
        AWS_ACCESS_KEY_ID = "null";
        AWS_SECRET_ACCESS_KEY = "null";
        AWS_DEFAULT_REGION = "null";

        # --------------------------------------------
        # OPTIONAL: LOGIN THROTTLING
        # --------------------------------------------
        LOGIN_MAX_ATTEMPTS = "5";
        LOGIN_LOCKOUT_DURATION = "60";
        RESET_PASSWORD_LINK_EXPIRES = "900";

        # --------------------------------------------
        # OPTIONAL: MISC
        # --------------------------------------------
        LOG_CHANNEL = "stderr";
        LOG_MAX_DAYS = "10";
        APP_LOCKED = "false";
        APP_CIPHER = "AES-256-CBC";
        APP_FORCE_TLS = "false";
        GOOGLE_MAPS_API = "";
        LDAP_MEM_LIM = "500M";
        LDAP_TIME_LIM = "600";
      };
    };
  };

  systemd.services.podman-snipe-it = lib.mkIf config.homefree.service-options.snipe-it.enable {
    after = [ "dns-ready.service" ];
    wants = [ "dns-ready.service" ];
    serviceConfig = {
      ExecStartPre = [ "!${pkgs.writeShellScript "snipe-it-prestart" preStart}" ];
    };
  };

    homefree.service-config = [{
      inherit (config.homefree.service-options.snipe-it) label name project-name;
      port-request = null;
      enable = config.homefree.service-options.snipe-it.enable;
      sso = {
        kind = "none";
        applicable = false;
        ## Dev context (intentionally not surfaced in the admin UI):
        ## Snipe-IT supports SAML only — OIDC requires a third-party
        ## Laravel package not in the official image. SAML integration
        ## is a separate multi-day effort. Use Snipe-IT's built-in user
        ## system for now.
      };
      systemd-service-names = [
        "podman-snipe-it"
        "mysql"
      ];
      reverse-proxy = {
        enable = config.homefree.service-options.snipe-it.enable;
        subdomains = [ "snipeit" ];
        http-domains = [ "homefree.lan" config.homefree.system.localDomain ];
        https-domains = [ config.homefree.system.domain ];
        host = config.homefree.network.lan-address;
        port = port;
        public = config.homefree.service-options.snipe-it.public;
      };
      backup = {
        paths = [
          containerDataPath
        ];
        mysql-databases = [
          "snipeit"
        ];
      };
      options-metadata = [
        {
          path = "enable";
          type = "bool";
          default = false;
          description = "Enable Snipe-IT inventory management service";
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
