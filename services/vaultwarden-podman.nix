{ config, lib, pkgs, ... }:
let
  containerDataPath = "/var/lib/vaultwarden-podman";

  preStart = ''
    mkdir -p ${containerDataPath}
  '';

  port = 8222;
  version = "1.36.0";
in
{
  options.homefree.service-options.vaultwarden = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "enable Vaultwarden service";
    };

    public = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Open to public on WAN port";
    };

    label = lib.mkOption {
      type = lib.types.str;
      default = "vaultwarden";
      internal = true;
      description = "Service label";
    };

    name = lib.mkOption {
      type = lib.types.str;
      default = "Password Manager";
      internal = true;
      description = "Service display name";
    };

    project-name = lib.mkOption {
      type = lib.types.str;
      default = "Vaultwarden";
      internal = true;
      description = "Project name";
    };
  };

  config = {
  virtualisation.oci-containers.containers = lib.optionalAttrs config.homefree.service-options.vaultwarden.enable {
    vaultwarden = {
      image = "vaultwarden/server:${version}";

      autoStart = true;

      extraOptions = [
        # "--pull=always"
      ];

      ports = [
        "0.0.0.0:${toString port}:80"
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

  systemd.services.podman-vaultwarden =lib.optionalAttrs config.homefree.service-options.vaultwarden.enable {
    after = [ "dns-ready.service" ];
    requires = [ "dns-ready.service" ];
    partOf =  [ "nftables.service" ];
    serviceConfig = {
      ExecStartPre = [ "!${pkgs.writeShellScript "vaultwarden-prestart" preStart}" ];
    };
  };

    homefree.service-config = [{
      inherit (config.homefree.service-options.vaultwarden) label name project-name;
      systemd-service-names = [
        "podman-vaultwarden"
      ];
      reverse-proxy = {
        enable = config.homefree.service-options.vaultwarden.enable;
        subdomains = [ "vaultwarden" ];
        http-domains = [ "homefree.lan" config.homefree.system.localDomain ];
        https-domains = [ config.homefree.system.domain ];
        host = config.homefree.network.lan-address;
        port = port;
        public = config.homefree.service-options.vaultwarden.public;
      };
      backup = {
        paths = [
          containerDataPath
        ];
      };
    }];
  };
}
