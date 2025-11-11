{ config, lib, pkgs, ... }:
let
  version = "v2.14.1";
  version-meili = "v1.43.0";
  containerDataPath = "/var/lib/linkwarden-podman";

  port = 3005;
  database-name = "linkwarden";
  database-user = "linkwarden";

  preStart = ''
    mkdir -p ${containerDataPath}/linkwarden
    mkdir -p ${containerDataPath}/meili
  '';
in
{
  options.homefree.service-options.linkwarden = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "enable linkwarden service";
    };

    public = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Open to public on WAN port";
    };

    label = lib.mkOption {
      type = lib.types.str;
      default = "linkwarden";
      internal = true;
      description = "Service label";
    };

    name = lib.mkOption {
      type = lib.types.str;
      default = "linkwarden";
      internal = true;
      description = "Service display name";
    };

    project-name = lib.mkOption {
      type = lib.types.str;
      default = "linkwarden";
      internal = true;
      description = "Project name";
    };

    secrets = lib.mkOption {
      type = lib.types.attrsOf (lib.types.nullOr lib.types.path);
      default = {};
      description = "Secrets for linkwarden service";
    };
  };

  config = {
  ## Copied from nixpkgs
  services.postgresql = lib.optionalAttrs config.homefree.service-options.linkwarden.enable {
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


  virtualisation.oci-containers.containers = lib.optionalAttrs config.homefree.service-options.linkwarden.enable {
    linkwarden = {
      image = "ghcr.io/linkwarden/linkwarden:${version}";

      dependsOn = [
        "meilisearch"
      ];

      autoStart = true;

      extraOptions = [
        # "--pull=always"
      ];

      ports = [
        "0.0.0.0:${toString port}:3000"
      ];

      volumes = [
        "/etc/localtime:/etc/localtime:ro"
        "${containerDataPath}/linkwarden:/data/data"
        "/run/postgresql:/run/postgresql"
      ];

      environment = {
        TZ = config.homefree.system.timeZone;
        DATABASE_URL = "postgresql://${database-user}@${config.homefree.network.lan-address}:5432/${database-name}";
      };

      environmentFiles = lib.optional
        (config.homefree.service-options.linkwarden.secrets.environment != null)
        config.homefree.service-options.linkwarden.secrets.environment;
    };

    meilisearch = {
      image = "getmeili/meilisearch:${version-meili}";

      autoStart = true;

      extraOptions = [
        # "--pull=always"
      ];

      volumes = [
        "/etc/localtime:/etc/localtime:ro"
        "${containerDataPath}/meili:/meili_data"
      ];

      environment = {
        TZ = config.homefree.system.timeZone;
      };
    };

  };

  systemd.services.podman-linkwarden = lib.optionalAttrs config.homefree.service-options.linkwarden.enable {
    after = [ "dns-ready.service" ];
    requires = [ "dns-ready.service" ];
    partOf = [ "nftables.service" ];
    serviceConfig = {
      ExecStartPre = [ "!${pkgs.writeShellScript "linkwarden-prestart" preStart}" ];
    };
  };

  systemd.services.podman-meilisearch = lib.optionalAttrs config.homefree.service-options.linkwarden.enable {
    after = [ "dns-ready.service" ];
    requires = [ "dns-ready.service" ];
    partOf =  [ "nftables.service" ];
    serviceConfig = {
      ExecStartPre = [ "!${pkgs.writeShellScript "meili-prestart" preStart}" ];
    };
  };

    homefree.service-config = [{
      inherit (config.homefree.service-options.linkwarden) label name project-name;
      systemd-service-names = [
        "podman-linkwarden"
        "podman-meilisearch"
        "postgresql"
      ];
      reverse-proxy = {
        enable = config.homefree.service-options.linkwarden.enable;
        subdomains = [ "links" "linkwarden" ];
        http-domains = [ "homefree.lan" config.homefree.system.localDomain ];
        https-domains = [ config.homefree.system.domain ];
        host = config.homefree.network.lan-address;
        port = port;
        public = config.homefree.service-options.linkwarden.public;
      };
      backup = {
        paths = [
          "${containerDataPath}/linkwaren"
        ];
        postgres-databases = [
          database-name
        ];
      };
    }];
  };
}
