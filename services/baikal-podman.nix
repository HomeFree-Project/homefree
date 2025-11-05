{ config, lib, pkgs, ... }:
let
  containerDataPath = "/var/lib/baikal";

  port = 3007;

  preStart = ''
    mkdir -p ${containerDataPath}/config
    mkdir -p ${containerDataPath}/Specific
  '';
in
{
  virtualisation.oci-containers.containers = lib.optionalAttrs config.homefree.services.baikal.enable {
    baikal = {
      image = "ckulka/baikal:nginx";

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

  systemd.services.podman-baikal = lib.optionalAttrs config.homefree.services.baikal.enable {
    after = [ "dns-ready.service" ];
    requires = [ "dns-ready.service" ];
    partOf =  [ "nftables.service" ];
    serviceConfig = {
      ExecStartPre = [ "!${pkgs.writeShellScript "baikal-prestart" preStart}" ];
    };
  };

  homefree.service-config = lib.optionals config.homefree.services.baikal.enable [
    {
      label = "baikal";
      name = "Baikal CalDAV/CardDAV";
      project-name = "Baikal";
      systemd-service-names = [
        "podman-baikal"
      ];
      reverse-proxy = {
        enable = true;
        subdomains = [ "baikal" ];
        http-domains = [ "homefree.lan" config.homefree.system.localDomain ];
        https-domains = [ config.homefree.system.domain ];
        host = config.homefree.network.lan-address;
        port = port;
        public = config.homefree.services.baikal.public;
      };
      backup = {
        paths = [
          "${containerDataPath}/config"
          "${containerDataPath}/Specific"
        ];
      };
    }
  ];
}

