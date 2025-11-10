{ config, lib, ... }:
let
  version = "???";
  port = 4185;
in
{
  options.homefree.service-options.goidc-proxy = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "enable goidc-proxy service";
    };

    public = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Open to public on WAN port";
    };

    label = lib.mkOption {
      type = lib.types.str;
      default = "goidc-proxy";
      internal = true;
      description = "Service label";
    };

    name = lib.mkOption {
      type = lib.types.str;
      default = "goidc proxy (for Basic Auth)";
      internal = true;
      description = "Service display name";
    };

    project-name = lib.mkOption {
      type = lib.types.str;
      default = "goidc-proxy";
      internal = true;
      description = "Project name";
    };
  };

  config = {
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
      inherit (config.homefree.service-options.goidc-proxy) label name project-name;
      systemd-service-names = [
        "podman-goidc-proxy"
      ];
      reverse-proxy = {
        enable = config.homefree.service-options.goidc-proxy.enable;
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

