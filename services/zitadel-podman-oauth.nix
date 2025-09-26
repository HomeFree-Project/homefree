{ config, pkgs, ... }:

## Default username: zitadel-admin@zitadel.${config.homefree.system.domain}
## Default password: Password1!

let
  version = "v2.67.5";
  containerDataPath = "/var/lib/zitadel";
  port = 3241;

  preStart = ''
    mkdir -p ${containerDataPath}
  '';
in
{
  virtualisation.oci-containers.containers = if config.homefree.services.zitadel.enable == true then {
    zitadel = {
      image = "ghcr.io/zitadel/zitadel:${version}";

      autoStart = true;

      extraOptions = [
        # "--pull=always"
      ];

      ports = [
        "0.0.0.0:${toString port}:8080"
      ];

      volumes = [
        "/etc/localtime:/etc/localtime:ro"
        "${containerDataPath}:/data"
      ];

      cmd = [
        "start-from-init"
        "--masterkeyFromEnv"
      ];

      environment = {
        TZ = config.homefree.system.timeZone;

        ZITADEL_DATABASE_POSTGRES_HOST = "10.0.0.1";
        ZITADEL_DATABASE_POSTGRES_PORT = "5432";
        ZITADEL_DATABASE_POSTGRES_DATABASE = "zitadel";
        ZITADEL_DATABASE_POSTGRES_USER_USERNAME = "zitadel";
        ZITADEL_DATABASE_POSTGRES_USER_PASSWORD = "zitadel";
        ZITADEL_DATABASE_POSTGRES_USER_SSL_MODE = "disable";
        ZITADEL_DATABASE_POSTGRES_ADMIN_USERNAME = "postgres";
        ZITADEL_DATABASE_POSTGRES_ADMIN_PASSWORD = "postgres";
        ZITADEL_DATABASE_POSTGRES_ADMIN_SSL_MODE = "disable";
        ZITADEL_FIRSTINSTANCE_ORG_HUMAN_USERNAME = "zitadel-admin@zitadel.${config.homefree.system.domain}";
        ZITADEL_FIRSTINSTANCE_ORG_HUMAN_PASSWORD = "Password1!";

        ZITADEL_EXTERNALDOMAIN = "sso.${config.homefree.system.domain}";
        ZITADEL_EXTERNALPORT = "443";
        ZITADEL_EXTERNALSECURE = "true";
        ZITADEL_TLS_ENABLED = "false";
      };

      environmentFiles = [
        config.homefree.services.zitadel.secrets.env
      ];
    };
  } else {};

  systemd.services.podman-zitadel = {
    after = [ "dns-ready.service" ];
    requires = [ "dns-ready.service" ];
    partOf =  [ "nftables.service" ];
    serviceConfig = {
      ExecStartPre = [ "!${pkgs.writeShellScript "zitadel-prestart" preStart}" ];
    };
  };

  homefree.service-config = if config.homefree.services.zitadel.enable == true then [
    {
      label = "zitadel";
      name = "Auth/SSO";
      project-name = "Zitadel";
      systemd-service-names = [
        "podman-zitadel"
      ];
      reverse-proxy = {
        enable = true;
        subdomains = [ "sso" "zitadel" ];
        http-domains = [ "homefree.lan" config.homefree.system.localDomain ];
        https-domains = [ config.homefree.system.domain ];
        host = "10.0.0.1";
        port = port;
        public = config.homefree.services.zitadel.public;
        extraCaddyConfig = ''
          oauth2 {
            provider zitadel {
              client_id 332933984772227202
              scopes openid profile email
              authorization_url https://sso.${config.homefree.system.domain}/oauth/v2/authorize
              token_url https://sso.${config.homefree.system.domain}/oauth/v2/token
              userinfo_url https://sso.${config.homefree.system.domain}/oidc/v1/userinfo
            }
            redirect_uri https://auth.${config.homefree.system.domain}/oauth2/callback
          }
        '';
      };
      backup = {
        paths = [
          containerDataPath
        ];
        postgres-databases = [
          "zitadel"
        ];
      };
    }
    {
      label = "caddyauth";
      name = "Oauth2 proxy";
      project-name = "Caddy Security";
      systemd-service-names = [
        "podman-zitadel"
      ];
      reverse-proxy = {
        enable = true;
        subdomains = [ "auth" ];
        http-domains = [ "homefree.lan" config.homefree.system.localDomain ];
        https-domains = [ config.homefree.system.domain ];
        host = "10.0.0.1";
        port = port;
        public = config.homefree.services.zitadel.public;
        extraCaddyConfig = ''
          oauth2 {
            provider zitadel {
              client_id 332933984772227202
              scopes openid profile email
              authorization_url https://sso.${config.homefree.system.domain}/oauth/v2/authorize
              token_url https://sso.${config.homefree.system.domain}/oauth/v2/token
              userinfo_url https://sso.${config.homefree.system.domain}/oidc/v1/userinfo
            }
            redirect_uri https://auth.${config.homefree.system.domain}/oauth2/callback
          }
        '';
      };
      backup = {
        paths = [
          containerDataPath
        ];
        postgres-databases = [
          "zitadel"
        ];
      };
auth.yourdomain.com {
    oauth2 {
        provider zitadel {
            client_id YOUR_CLIENT_ID
            client_secret YOUR_CLIENT_SECRET
            scopes openid profile email
            authorization_url https://your-zitadel-instance.com/oauth/v2/authorize
            token_url https://your-zitadel-instance.com/oauth/v2/token
            userinfo_url https://your-zitadel-instance.com/oidc/v1/userinfo
        }
        redirect_uri https://auth.yourdomain.com/oauth2/callback
    }

    handle /auth {
        oauth2_auth
        respond "OK" 200
    }
}
    }
  ] else [];
}

