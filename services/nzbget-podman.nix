{ config, lib, pkgs, ... }:
let
  version = "version-v24.8";
  port = 6799;
  containerDataPath = "/var/lib/nzbget";
  configPath = "${containerDataPath}/config";
  downloadsPath = config.homefree.services.nzbget.downloads-path or "${containerDataPath}/downloads";
  preStart = ''
    mkdir -p ${configPath}
    mkdir -p ${downloadsPath}
  '';
in
{
  virtualisation.oci-containers.containers = lib.optionalAttrs config.homefree.services.nzbget.enable {
    nzbget = {
      image = "lscr.io/linuxserver/nzbget:${version}";

      autoStart = true;

      extraOptions = [
        # "--pull=always"
      ];

      ports = [
        "0.0.0.0:${toString port}:6789"
      ];

      volumes = [
        "/etc/localtime:/etc/localtime:ro"
        "${configPath}:/config"
        "${downloadsPath}:/downloads"
      ];

      environment = {
        TZ = config.homefree.system.timeZone;
        PUID = "1000";
        PGID = "100";
        # NZBGET_USER = "nzbget"; #optional
        # NZBGET_PASS = "tegbzn6789"; #optional
      };
    };
  };

  systemd.services.podman-nzbget = lib.optionalAttrs config.homefree.services.nzbget.enable {
    after = [ "dns-ready.service" ];
    requires = [ "dns-ready.service" ];
    partOf =  [ "nftables.service" ];
    serviceConfig = {
      ExecStartPre = [ "!${pkgs.writeShellScript "nzbget-prestart" preStart}" ];
    };
  };

  homefree.service-config = lib.optionals config.homefree.services.nzbget.enable [
    {
      label = "nzbet";
      name = "NZB Downloader";
      project-name = "NZBGet";
      systemd-service-names = [
        "podman-nzbget"
      ];
      reverse-proxy = {
        enable = true;
        subdomains = [ "nzbget" ];
        http-domains = [ "homefree.lan" config.homefree.system.localDomain ];
        https-domains = [ config.homefree.system.domain ];
        host = config.homefree.network.lan-address;
        port = port;
        public = config.homefree.services.nzbget.public;
      };
      backup = lib.optionalAttrs {
        paths = [
          downloadsPath
        ];
      };
    }
  ];
}
