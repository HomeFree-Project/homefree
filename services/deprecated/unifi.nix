{ config, lib, pkgs, ... }:
{
  nixpkgs.config.allowUnfree = true;

  services.unifi = lib.optionalAttrs config.homefree.services.unifi.enable {
    enable = true;
    openFirewall = true;
    unifiPackage = pkgs.unifi8;
    mongodbPackage = pkgs.mongodb-7_0;
  };

  homefree.service-config = lib.optionals config.homefree.services.unifi.enable [
    {
      label = "unifi";
      name = "Unifi Controller";
      project-name = "Unifi Controller";
      systemd-service-names = [
        "unifi"
      ];
      reverse-proxy = {
        enable = true;
        subdomains = [ "unifi" ];
        http-domains = [ "homefree.lan" config.homefree.system.localDomain ];
        https-domains = [ config.homefree.system.domain ];
        host = config.homefree.network.lan-address;
        port = 8443;
        ssl = true;
        ssl-no-verify = true;
        public = config.homefree.services.unifi.public;
      };
      backup = {
        paths = [
          ## @TODO: how to programmatically set backup frequency? Unifi UI defaults to monthly.
          "/var/lib/unifi/data/backup"
        ];
      };
    }
  ];
}

