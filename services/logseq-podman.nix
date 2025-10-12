{ config, lib, ... }:
let
  version = "3.3.13";
  port = 8938;
in
{
  virtualisation.oci-containers.containers = lib.optionalAttrs config.homefree.services.logseq.enable {
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

  systemd.services.podman-logseq = lib.optionalAttrs config.homefree.services.logseq.enable {
    after = [ "dns-ready.service" ];
    requires = [ "dns-ready.service" ];
    partOf =  [ "nftables.service" ];
  };

  homefree.service-config = lib.optionals config.homefree.services.logseq.enable [
    {
      label = "logseq";
      name = "Logseq Knowledge Management";
      project-name = "Logseq";
      systemd-service-names = [
        "podman-logseq"
      ];
      reverse-proxy = {
        enable = true;
        subdomains = [ "logseq" ];
        http-domains = [ "homefree.lan" config.homefree.system.localDomain ];
        https-domains = [ config.homefree.system.domain ];
        host = config.homefree.network.lan-address;
        port = port;
        public = config.homefree.services.logseq.public;
      };
      backup = {
      };
    }
  ];
}

