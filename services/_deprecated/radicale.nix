{ config, ... }:
{
  services.radicale = {
    enable =  config.homefree.services.radicale.enable;
    settings = {
      server.hosts = [ "${config.homefree.network.lan-address}:5232" ];

      # auth = {
      #   type = "http_x_remote_user";
      # };

      # auth = {
      #   type = "htpasswd";
      #   htpasswd_filename = "/var/lib/radicale/htpasswd";
      #   # hash function used for passwords. May be `plain` if you don't want to hash the passwords
      #   htpasswd_encryption = "bcrypt";
      # };
    };
  };

  homefree.service-config = if config.homefree.services.radicale.enable == true then [
    {
      label = "radicale";
      name = "Contacts/Calendar (CalDAV/CardDAV)";
      project-name = "Radicale";
      systemd-service-names = [
        "radicale"
      ];
      reverse-proxy = {
        enable = true;
        subdomains = [ "radicale" "dav" "caldav" "carddav" ];
        http-domains = [ "homefree.lan" config.homefree.system.localDomain ];
        https-domains = [ config.homefree.system.domain ];
        host = config.homefree.network.lan-address;
        port = 5232;
        public = config.homefree.services.radicale.public;
        # basic-auth = true;
      };
      backup = {
        paths = [
          "/var/lib/radicale"
        ];
      };
    }
  ] else [];
}
