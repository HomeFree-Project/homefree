{ config, lib, ... }:
let
  version = "???";
  port = 4185;
in
{
  virtualisation.oci-containers.containers = lib.optionalAttrs config.homefree.services.zitadel.enable {
    goidc-proxy = {
      image = "???/goidc-proxy:${version}";

      autoStart = true;

      extraOptions = [
        # "--network=host"
      ];

      ports = [
        "0.0.0.0:${toString port}:${toString port}"
      ];

      volumes = [
        "/etc/localtime:/etc/localtime:ro"
      ];

      environment = {
        TZ = config.homefree.system.timeZone;
      };
    };
  };

  systemd.services.podman-goidc-proxy = lib.optionalAttrs config.homefree.services.zitadel.enable {
    after = [ "dns-ready.service" ];
    requires = [ "dns-ready.service" ];
    partOf =  [ "nftables.service" ];
  };

  homefree.service-config = lib.optionals config.homefree.services.zitadel.enable [
    {
      label = "goidc-proxy";
      name = "goidc proxy (for Basic Auth)";
      project-name = "goidc-proxy";
      systemd-service-names = [
        "podman-goidc-proxy"
      ];
      reverse-proxy = {
        enable = true;
        subdomains = [ "auth" ];
        http-domains = [ "homefree.lan" config.homefree.system.localDomain ];
        https-domains = [ config.homefree.system.domain ];
        host = config.homefree.network.lan-address;
        port = port;
        # public = config.homefree.services.zitadel.public;
        public = false;
      };
    }
  ];
}

