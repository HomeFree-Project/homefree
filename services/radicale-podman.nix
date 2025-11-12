{ config, lib, pkgs, ... }:
let
  version = "3.6.1.0";
  containerDataPath = "/var/lib/radicale-podman";
  port = 5232;

  preStart = ''
    mkdir -p ${containerDataPath}
  '';
in
{
  options.homefree.service-options.radicale = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "enable Radicale service";
    };

    public = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Open to public on WAN port";
    };

    label = lib.mkOption {
      type = lib.types.str;
      default = "radicale";
      internal = true;
      description = "Service label";
    };

    name = lib.mkOption {
      type = lib.types.str;
      default = "Contacts/Calendar (CalDAV/CardDAV)";
      internal = true;
      description = "Service display name";
    };

    project-name = lib.mkOption {
      type = lib.types.str;
      default = "Radicale";
      internal = true;
      description = "Project name";
    };
  };

  config = {
  virtualisation.oci-containers.containers = lib.optionalAttrs config.homefree.service-options.radicale.enable {
    radicale = {
      image = "tomsquest/docker-radicale:${version}";

      autoStart = true;

      extraOptions = [
        # "--pull=always"
      ];

      ports = [
        "0.0.0.0:${toString port}:5232"
      ];

      volumes = [
        "/etc/localtime:/etc/localtime:ro"
        "${containerDataPath}:/data"
      ];

      environment = {
        TZ = config.homefree.system.timeZone;
      };
    };
  };

  systemd.services.podman-radicale = lib.optionalAttrs config.homefree.service-options.radicale.enable  {
    after = [ "dns-ready.service" ];
    requires = [ "dns-ready.service" ];
    partOf =  [ "nftables.service" ];
    serviceConfig = {
      ExecStartPre = [ "!${pkgs.writeShellScript "radicale-prestart" preStart}" ];
    };
  };

    homefree.service-config = [{
      inherit (config.homefree.service-options.radicale) label name project-name;
      systemd-service-names = [
        "podman-radicale"
      ];
      reverse-proxy = {
        enable = config.homefree.service-options.radicale.enable;
        subdomains = [ "radicale" "dav" "caldav" "carddav" ];
        http-domains = [ "homefree.lan" config.homefree.system.localDomain ];
        https-domains = [ config.homefree.system.domain ];
        host = config.homefree.network.lan-address;
        port = port;
        public = config.homefree.service-options.radicale.public;
        # basic-auth = true;
      };
      backup = {
        paths = [
          containerDataPath
        ];
      };
      options-metadata = [
        {
          path = "enable";
          type = "bool";
          default = false;
          description = "Enable Radicale CalDAV/CardDAV service";
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
