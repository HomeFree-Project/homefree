{ config, pkgs, ... }:
let
  version = "7.11.0";
  port = 5232;
  oauth2-proxy-config = pkgs.writeText ''
    # OAuth Provider
    provider = "oidc"
    oidc_issuer_url = "https://sso.${config.homefree.system.domain}"

    # Client Configuration
    client_id = "your-client-id"
    client_secret = "your-client-secret"

    # URLs
    redirect_url = "https://your-app.example.com/oauth2/callback"

    # Upstream
    upstream = "http://localhost:8080/"  # Your actual application

    # Server Configuration
    http_address = "0.0.0.0:4180"

    # Cookie Configuration
    cookie_secret = "your-32-char-base64-encoded-secret"
    cookie_secure = true
    cookie_httponly = true

    # Additional OIDC settings
    scope = "openid email profile"

    # Skip auth for health checks, static assets, etc.
    skip_auth_regex = "^/health$|^/static/"
  '';

  ''
in
{
  virtualisation.oci-containers.containers = if config.homefree.services.radicale.enable == true then {
    radicale = {
      image = "bitnami/oauth2-proxy:${version}";

      autoStart = true;

      extraOptions = [
        # "--pull=always"
        "--network=host"
      ];

      ports = [
        "0.0.0.0:${toString port}:5232"
      ];

      volumes = [
        "/etc/localtime:/etc/localtime:ro"
      ];

      environment = {
        TZ = config.homefree.system.timeZone;
      };
    };
  } else {};

  systemd.services.podman-radicale = {
    after = [ "dns-ready.service" ];
    requires = [ "dns-ready.service" ];
    partOf =  [ "nftables.service" ];
  };

  homefree.service-config = if config.homefree.services.radicale.enable == true then [
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
  ] else [];
}

