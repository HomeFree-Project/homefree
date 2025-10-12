
{ config, ... }:
let
  backup-path = "/var/backup/vaultwarden";
in
{
  services.vaultwarden = {
    enable =  config.homefree.services.vaultwarden.enable;
    dbBackend = "sqlite";   # "sqlite", "mysql", "postgresql"
    backupDir = backup-path;
    config = {
      ROCKET_ADDRESS = "${config.homefree.network.lan-address}";
      ROCKET_PORT = 8222;
    };
  };

  homefree.service-config = if config.homefree.services.vaultwarden.enable == true then [
    {
      label = "vaultwarden";
      name = "Password Manager";
      project-name = "Vaultwarden";
      systemd-service-names = [
        "vaultwarden"
      ];
      reverse-proxy = {
        enable = true;
        subdomains = [ "vaultwarden" ];
        http-domains = [ "homefree.lan" config.homefree.system.localDomain ];
        https-domains = [ config.homefree.system.domain ];
        host = config.homefree.network.lan-address;
        port = 8222;
        public = config.homefree.services.vaultwarden.public;
      };
      backup = {
        paths = [
          backup-path
        ];
      };
    }
  ] else [];
}
