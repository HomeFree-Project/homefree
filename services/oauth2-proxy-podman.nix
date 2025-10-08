{ config, ... }:
let
  version = "v7.12.0";
  port = 4180;
in
{
  virtualisation.oci-containers.containers = if config.homefree.services.zitadel.enable == true then {
    oauth2-proxy = {
      image = "oauth2-proxy/oauth2-proxy:${version}";

      autoStart = true;

      extraOptions = [
        # @TODO: Is this necessary?
        "--network=host"
      ];

      ports = [
        "0.0.0.0:${toString port}:${toString port}"
      ];

      volumes = [
        "/etc/localtime:/etc/localtime:ro"
      ];

      environment = {
        TZ = config.homefree.system.timeZone;
        OAUTH2_PROXY_PROVIDER = "oidc";
        OAUTH2_PROXY_OIDC_ISSUER_URL = "https://sso.${config.homefree.system.domain}";
        OAUTH2_PROXY_REDIRECT_URL = "https://auth.${config.homefree.system.domain}/oauth2/callback";
        OAUTH2_PROXY_EMAIL_DOMAINS = "*";
        OAUTH2_PROXY_COOKIE_DOMAINS = ".${config.homefree.system.domain}";
        OAUTH2_PROXY_WHITELIST_DOMAINS = ".${config.homefree.system.domain}";
        OAUTH2_PROXY_HTTP_ADDRESS = "0.0.0.0:${toString port}";
        OAUTH2_PROXY_REVERSE_PROXY = "true";
        # OAUTH2_PROXY_UPSTREAMS = "static://202";
        OAUTH2_PROXY_COOKIE_SECURE = "true";
        OAUTH2_PROXY_COOKIE_HTTPONLY = "true";
        OAUTH2_PROXY_SCOPE = "openid email profile";
        ## Examples of exclusions
        # OAUTH2_PROXY_SKIP_AUTH_REGEX = "^/health$|^/metrics$";

        ## Needed to prevent Zitadel from blocking due to user agent headers being different
        OAUTH2_PROXY_PASS_USER_HEADERS = "true";
        OAUTH2_PROXY_SET_AUTHORIZATION_HEADER = "true";
      };

      ## @TODO: this shouldn't need to be exposed to user config
      environmentFiles = [
        config.homefree.services.oauth2-proxy.secrets.env
      ];
    };
  } else {};

  systemd.services.podman-oauth2-proxy = {
    after = [ "dns-ready.service" ];
    requires = [ "dns-ready.service" ];
    partOf =  [ "nftables.service" ];
  };

  homefree.service-config = if config.homefree.services.zitadel.enable == true then [
    {
      label = "oauth2proxy";
      name = "Oauth2 Proxy";
      project-name = "Oauth2 Proxy";
      systemd-service-names = [
        "podman-oauth2-proxy"
      ];
      reverse-proxy = {
        enable = true;
        subdomains = [ "auth" ];
        http-domains = [ "homefree.lan" config.homefree.system.localDomain ];
        https-domains = [ config.homefree.system.domain ];
        host = "10.0.0.1";
        port = port;
        # public = config.homefree.services.zitadel.public;
        public = false;
      };
    }
  ] else [];
}

