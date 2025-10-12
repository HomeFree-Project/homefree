{ config, lib, ... }:
let
  version = "3.3.13";
  port = 8975;
  database-name = "joplin";
  database-user = "joplin";
in
{
  services.postgresql = lib.optionalAttrs config.homefree.services.joplin.enable {
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

  virtualisation.oci-containers.containers = lib.optionalAttrs config.homefree.services.joplin.enable {
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

  systemd.services.podman-joplin = lib.optionalAttrs config.homefree.services.joplin.enable {
    after = [ "dns-ready.service" ];
    requires = [ "dns-ready.service" ];
    partOf =  [ "nftables.service" ];
  };

  homefree.service-config = lib.optionals config.homefree.services.joplin.enable [
    {
      label = "joplin";
      name = "Joplin Notes";
      project-name = "Joplin";
      systemd-service-names = [
        "podman-joplin"
      ];
      reverse-proxy = {
        enable = true;
        subdomains = [ "joplin" ];
        http-domains = [ "homefree.lan" config.homefree.system.localDomain ];
        https-domains = [ config.homefree.system.domain ];
        host = "10.0.0.1";
        port = port;
        public = config.homefree.services.joplin.public;
      };
      backup = {
        postgres-databases = [
          database-name
        ];
      };
    }
  ];
}

