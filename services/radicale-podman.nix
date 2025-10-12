{ config, lib, pkgs, ... }:
let
  version = "3.5.2.0";
  containerDataPath = "/var/lib/radicale-podman";
  port = 5232;

  preStart = ''
    mkdir -p ${containerDataPath}
  '';
in
{
  virtualisation.oci-containers.containers = lib.optionalAttrs config.homefree.services.radicale.enable {
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

  systemd.services.podman-radicale = lib.optionalAttrs config.homefree.services.radicale.enable  {
    after = [ "dns-ready.service" ];
    requires = [ "dns-ready.service" ];
    partOf =  [ "nftables.service" ];
    serviceConfig = {
      ExecStartPre = [ "!${pkgs.writeShellScript "radicale-prestart" preStart}" ];
    };
  };

  homefree.service-config = lib.optionals config.homefree.services.radicale.enable [
    {
      label = "radicale";
      name = "Contacts/Calendar (CalDAV/CardDAV)";
      project-name = "Radicale";
      systemd-service-names = [
        "podman-radicale"
      ];
      reverse-proxy = {
        enable = true;
        subdomains = [ "radicale" "dav" "caldav" "carddav" ];
        http-domains = [ "homefree.lan" config.homefree.system.localDomain ];
        https-domains = [ config.homefree.system.domain ];
        host = "10.0.0.1";
        port = port;
        public = config.homefree.services.radicale.public;
        # basic-auth = true;
      };
      backup = {
        paths = [
          containerDataPath
        ];
      };
    }
  ];
}

