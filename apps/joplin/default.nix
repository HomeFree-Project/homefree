{ config, lib, ... }:
let
  version = "3.6.1";
  port = 8975;
  database-name = "joplin";
  database-user = "joplin";

  userOptions = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "enable Joplin notes service";
    };

    public = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Open to public on WAN port";
    };
  };
in
{
  options.homefree.services.joplin = userOptions;
  options.homefree.service-options.joplin = userOptions // {
    label = lib.mkOption {
      type = lib.types.str;
      default = "joplin";
      internal = true;
      description = "Service label";
    };

    name = lib.mkOption {
      type = lib.types.str;
      default = "joplin";
      internal = true;
      description = "Service display name";
    };

    project-name = lib.mkOption {
      type = lib.types.str;
      default = "Joplin";
      internal = true;
      description = "Project name";
    };
  };

  config = {
  services.postgresql = lib.optionalAttrs config.homefree.service-options.joplin.enable {
    enable = true;
    ensureDatabases = [ database-name ];
    ensureUsers = [
      {
        name = database-user;
        ensureDBOwnership = true;
        ensureClauses.login = true;
      }
    ];
  };

  virtualisation.oci-containers.containers = lib.optionalAttrs config.homefree.service-options.joplin.enable {
    joplin = {
      image = "joplin/server:${version}";

      autoStart = true;

      extraOptions = [
        # "--pull=always"
      ];

      ports = [
        "0.0.0.0:${toString port}:22300"
      ];

      volumes = [
        "/etc/localtime:/etc/localtime:ro"
        "/run/postgresql:/run/postgresql"
      ];

      environment = {
        TZ = config.homefree.system.timeZone;
        DB_CLIENT = "pg";
        POSTGRES_DATABASE = database-name;
        POSTGRES_USER = database-user;
        POSTGRES_PORT = "5432";
        POSTGRES_HOST = "/run/postgresql";
        APP_BASE_URL = "https://joplin.${config.homefree.system.domain}";
      };
    };
  };

  systemd.services.podman-joplin = lib.optionalAttrs config.homefree.service-options.joplin.enable {
    after = [ "dns-ready.service" ];
    wants = [ "dns-ready.service" ];
  };

    homefree.service-config = [{
      inherit (config.homefree.service-options.joplin) label name project-name;
      sso = {
        kind = "none";
        applicable = false;
        ## Dev context (intentionally not surfaced in the admin UI):
        ## Joplin Server supports SAML only — no native OIDC. Joplin's
        ## desktop and mobile clients sync via the server's own
        ## credentials API, so a Caddy SSO gate would break sync. OIDC
        ## support is requested upstream (laurent22/joplin#14252);
        ## revisit when shipped.
      };
      systemd-service-names = [
        "podman-joplin"
      ];
      reverse-proxy = {
        enable = config.homefree.service-options.joplin.enable;
        subdomains = [ "joplin" ];
        http-domains = [ "homefree.lan" config.homefree.system.localDomain ];
        https-domains = [ config.homefree.system.domain ];
        host = config.homefree.network.lan-address;
        port = port;
        public = config.homefree.service-options.joplin.public;
      };
      backup = {
        postgres-databases = [
          database-name
        ];
      };
      options-metadata = [
        {
          path = "enable";
          type = "bool";
          default = false;
          description = "Enable Joplin notes service";
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

