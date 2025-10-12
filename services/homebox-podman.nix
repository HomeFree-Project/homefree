{ config, lib, pkgs, ... }:
let
  containerDataPath = "/var/lib/homebox-podman";

  preStart = ''
    mkdir -p ${containerDataPath}
  '';

  port = 7745;
  version = "0.20.2";
in
{
  virtualisation.oci-containers.containers = lib.optionalAttrs config.homefree.services.homebox.enable {
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

  systemd.services.podman-homebox = lib.optionalAttrs config.homefree.services.homebox.enable {
    after = [ "dns-ready.service" ];
    requires = [ "dns-ready.service" ];
    partOf =  [ "nftables.service" ];
    serviceConfig = {
      ExecStartPre = [ "!${pkgs.writeShellScript "homebox-prestart" preStart}" ];
    };
  };

  homefree.service-config = lib.optionals config.homefree.services.homebox.enable [
    {
      label = "homebox";
      name = "Homebox";
      project-name = "Homebox";
      systemd-service-names = [
        "podman-homebox"
      ];
      reverse-proxy = {
        enable = true;
        subdomains = [ "homebox" ];
        http-domains = [ "homefree.lan" config.homefree.system.localDomain ];
        https-domains = [ config.homefree.system.domain ];
        host = "10.0.0.1";
        port = port;
        public = config.homefree.services.homebox.public;
      };
      backup = {
        paths = [
          containerDataPath
        ];
      };
    }
  ];
}
