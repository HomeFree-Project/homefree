{ config, lib, pkgs, ... }:
let
  containerDataPath = "/var/lib/homebox-podman";

  preStart = ''
    mkdir -p ${containerDataPath}
  '';

  port = 7745;
  version = "0.25.0";
in
{
  options.homefree.service-options.homebox = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "enable Homebox service";
    };

    public = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Open to public on WAN port";
    };

    label = lib.mkOption {
      type = lib.types.str;
      default = "homebox";
      internal = true;
      description = "Service label";
    };

    name = lib.mkOption {
      type = lib.types.str;
      default = "Homebox";
      internal = true;
      description = "Service display name";
    };

    project-name = lib.mkOption {
      type = lib.types.str;
      default = "Homebox";
      internal = true;
      description = "Project name";
    };
  };

  config = {
    virtualisation.oci-containers.containers = lib.optionalAttrs config.homefree.service-options.homebox.enable {
    homebox = {
      image = "ghcr.io/sysadminsmedia/homebox:${version}";

      autoStart = true;

      extraOptions = [
        # "--pull=always"
      ];

      ports = [
        "0.0.0.0:${toString port}:7745"
      ];

      volumes = [
        "/etc/localtime:/etc/localtime:ro"
        "${containerDataPath}:/data"
      ];

      environment = {
        TZ = config.homefree.system.timeZone;
        HBOX_WEB_MAX_FILE_UPLOAD = "50";
        HBOX_OPTIONS_ALLOW_ANALYTICS = "false";
      };
    };
  };

  systemd.services.podman-homebox = lib.optionalAttrs config.homefree.service-options.homebox.enable {
    after = [ "dns-ready.service" ];
    requires = [ "dns-ready.service" ];
    partOf =  [ "nftables.service" ];
    serviceConfig = {
      ExecStartPre = [ "!${pkgs.writeShellScript "homebox-prestart" preStart}" ];
    };
  };

    homefree.service-config = [{
      inherit (config.homefree.service-options.homebox) label name project-name;
      systemd-service-names = [
        "podman-homebox"
      ];
      reverse-proxy = {
        enable = config.homefree.service-options.homebox.enable;
        subdomains = [ "homebox" ];
        http-domains = [ "homefree.lan" config.homefree.system.localDomain ];
        https-domains = [ config.homefree.system.domain ];
        host = config.homefree.network.lan-address;
        port = port;
        public = config.homefree.service-options.homebox.public;
      };
      backup = {
        paths = [
          containerDataPath
        ];
      };
    }];
  };
}
