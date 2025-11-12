{ config, lib, pkgs, ... }:
let
  containerDataPath = "/var/lib/baikal";

  port = 3007;

  version = "0.10.1";

  preStart = ''
    mkdir -p ${containerDataPath}/config
    mkdir -p ${containerDataPath}/Specific
  '';
in
{
  options.homefree.service-options.baikal = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "enable Baikal CalDAV/CardDAV service";
    };

    public = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Open to public on WAN port";
    };

    # Metadata - always available, not user-configurable
    label = lib.mkOption {
      type = lib.types.str;
      default = "baikal";
      internal = true;
      description = "Service label";
    };

    name = lib.mkOption {
      type = lib.types.str;
      default = "Baikal CalDAV/CardDAV";
      internal = true;
      description = "Service display name";
    };

    project-name = lib.mkOption {
      type = lib.types.str;
      default = "Baikal";
      internal = true;
      description = "Project name";
    };
  };

  config = {
    virtualisation.oci-containers.containers = lib.optionalAttrs config.homefree.service-options.baikal.enable {
    baikal = {
      image = "ckulka/baikal:${version}-nginx";

      autoStart = true;

      extraOptions = [
        # "--pull=always"
      ];

      ports = [
        "0.0.0.0:${toString port}:80"
      ];

      volumes = [
        "/etc/localtime:/etc/localtime:ro"
        "${containerDataPath}/config:/var/www/baikal/config"
        "${containerDataPath}/Specific:/var/www/baikal/Specific"
      ];

      environment = {
        TZ = config.homefree.system.timeZone;
      };
    };
  };

  systemd.services.podman-baikal = lib.optionalAttrs config.homefree.service-options.baikal.enable {
    after = [ "dns-ready.service" ];
    requires = [ "dns-ready.service" ];
    partOf =  [ "nftables.service" ];
    serviceConfig = {
      ExecStartPre = [ "!${pkgs.writeShellScript "baikal-prestart" preStart}" ];
    };
  };

    homefree.service-config = [{
      inherit (config.homefree.service-options.baikal) label name project-name;
      systemd-service-names = [
        "podman-baikal"
      ];
      reverse-proxy = {
        enable = config.homefree.service-options.baikal.enable;
        subdomains = [ "baikal" ];
        http-domains = [ "homefree.lan" config.homefree.system.localDomain ];
        https-domains = [ config.homefree.system.domain ];
        host = config.homefree.network.lan-address;
        port = port;
        public = config.homefree.service-options.baikal.public;
      };
      backup = {
        paths = [
          "${containerDataPath}/config"
          "${containerDataPath}/Specific"
        ];
      };
      options-metadata = [
        {
          path = "enable";
          type = "bool";
          default = false;
          description = "Enable Baikal CalDAV/CardDAV service";
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

