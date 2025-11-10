{ config, lib, ... }:
let
  version = "3.3.13";
  port = 8938;
in
{
  options.homefree.service-options.logseq = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "enable Logseq service";
    };

    public = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Open to public on WAN port";
    };

    label = lib.mkOption {
      type = lib.types.str;
      default = "logseq";
      internal = true;
      description = "Service label";
    };

    name = lib.mkOption {
      type = lib.types.str;
      default = "Logseq Knowledge Management";
      internal = true;
      description = "Service display name";
    };

    project-name = lib.mkOption {
      type = lib.types.str;
      default = "Logseq";
      internal = true;
      description = "Project name";
    };
  };

  config = {
  virtualisation.oci-containers.containers = lib.optionalAttrs config.homefree.service-options.logseq.enable {
    logseq = {
      image = "ghcr.io/logseq/logseq-webapp:${version}";

      autoStart = true;

      extraOptions = [
        # "--pull=always"
      ];

      ports = [
        "0.0.0.0:${toString port}:80"
      ];

      volumes = [
        "/etc/localtime:/etc/localtime:ro"
      ];

      environment = {
        TZ = config.homefree.system.timeZone;
      };
    };
  };

  systemd.services.podman-logseq = lib.optionalAttrs config.homefree.service-options.logseq.enable {
    after = [ "dns-ready.service" ];
    requires = [ "dns-ready.service" ];
    partOf =  [ "nftables.service" ];
  };

    homefree.service-config = [{
      inherit (config.homefree.service-options.logseq) label name project-name;
      systemd-service-names = [
        "podman-logseq"
      ];
      reverse-proxy = {
        enable = config.homefree.service-options.logseq.enable;
        subdomains = [ "logseq" ];
        http-domains = [ "homefree.lan" config.homefree.system.localDomain ];
        https-domains = [ config.homefree.system.domain ];
        host = config.homefree.network.lan-address;
        port = port;
        public = config.homefree.service-options.logseq.public;
      };
      backup = {
      };
    }];
  };
}

