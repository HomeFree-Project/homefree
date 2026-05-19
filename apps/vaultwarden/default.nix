{ config, lib, pkgs, ... }:
let
  userOptions = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "enable Vaultwarden Bitwarden password manager backend";
    };

    public = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Open to public on WAN port";
    };
  };

  containerDataPath = "/var/lib/vaultwarden-podman";
  domain = config.homefree.system.domain;
  secretsDir = "/var/lib/homefree-secrets/vaultwarden";

  port = 8222;
  version = "1.36.0";

  ssoEnvFile = "${containerDataPath}/sso.env";

  ## preStart writes Vaultwarden's OIDC env file from Zitadel
  ## secrets, plus a combined CA bundle so Vaultwarden's Rust HTTP
  ## stack trusts sso.<domain>'s Caddy-issued cert.
  ##
  ## Vaultwarden 1.36+ has native OIDC. The auto-derived callback
  ## URI is <DOMAIN>/identity/connect/oidc-signin — that's what we
  ## register in services/zitadel-provision.nix.
  ##
  ## Admin role mapping: Vaultwarden has NO concept of OIDC->admin
  ## propagation. The admin panel is gated by a separate
  ## ADMIN_TOKEN (kept disabled for now). Master password is still
  ## required after SSO — SSO authenticates, master password
  ## derives the vault encryption key. Users set it on first login.
  preStart = ''
    mkdir -p ${containerDataPath}

    ## Combined CA bundle (system + Caddy local CA) for Rust
    ## native-tls. SSL_CERT_FILE env var below points the container
    ## at this file.
    {
      cat /etc/ssl/certs/ca-certificates.crt
      if [ -r /var/lib/caddy/.local/share/caddy/pki/authorities/local/root.crt ]; then
        echo
        cat /var/lib/caddy/.local/share/caddy/pki/authorities/local/root.crt
      fi
    } > ${containerDataPath}/ca-bundle.crt
    chmod 644 ${containerDataPath}/ca-bundle.crt

    install -m 600 /dev/null ${ssoEnvFile}
    if [ -s ${secretsDir}/oidc-client-id ] \
       && [ -s ${secretsDir}/oidc-client-secret ]; then
      CID=$(cat ${secretsDir}/oidc-client-id)
      CSEC=$(cat ${secretsDir}/oidc-client-secret)
      {
        echo "SSO_ENABLED=true"
        echo "SSO_AUTHORITY=https://sso.${domain}"
        echo "SSO_CLIENT_ID=$CID"
        echo "SSO_CLIENT_SECRET=$CSEC"
        ## Default scopes are "profile email"; add Zitadel's roles
        ## scope for future role propagation. Harmless until
        ## Vaultwarden grows admin-role support upstream.
        echo "SSO_SCOPES=email profile urn:zitadel:iam:org:project:roles"
        ## SSO_ONLY=true hides the email/master-password form on
        ## the login page so users only see the "Sign in with SSO"
        ## button. Like Homebox's ALLOW_LOCAL_LOGIN=false but
        ## controlled by a different name. Only set when SSO is
        ## actually configured.
        echo "SSO_ONLY=true"
        ## Match existing-email users on first SSO login so a fresh
        ## SSO sign-in claims any pre-existing local account with
        ## the same email instead of creating a duplicate.
        echo "SSO_SIGNUPS_MATCH_EMAIL=true"
        ## PKCE is on by default in 1.36+; spell it out for clarity.
        echo "SSO_PKCE=true"
        ## Zitadel puts BOTH the client_id AND the project_id in the
        ## id_token's `aud` array. Vaultwarden by default trusts only
        ## the client_id and rejects the rest with "Invalid audiences:
        ## <id> is not a trusted audience". Trust any 18-digit Zitadel
        ## snowflake ID — Zitadel's audiences are all numeric resource
        ## IDs of fixed width.
        echo "SSO_AUDIENCE_TRUSTED=^[0-9]{15,20}$"
        ## Decouple Vaultwarden's own session lifetime from Zitadel's
        ## SSO session. With this OFF (the default), Vaultwarden
        ## re-validates every refresh-token rotation against Zitadel,
        ## which forces a fresh SSO prompt as soon as Zitadel's
        ## per-app token expires — often a few hours. With it ON,
        ## SSO authenticates the user once; thereafter Vaultwarden's
        ## own access/refresh tokens own the session, so the
        ## Bitwarden mobile app rotates silently in the background.
        echo "SSO_AUTH_ONLY_NOT_SESSION=true"
        ## Refresh token lifetime: default is 30 days. Extend to 1
        ## year so users away from a network where sso.<domain> is
        ## reachable don't get locked into a "sign back in" loop
        ## on the road. Trade-off: a stolen refresh token is valid
        ## for the full year; acceptable for a personal vault.
        echo "REFRESH_VALIDITY_SECS=31536000"
      } > ${ssoEnvFile}
    else
      ## Pre-provisioning (fresh install): empty env file. SSO is
      ## off, local signup-disabled flow is what Vaultwarden serves.
      : > ${ssoEnvFile}
    fi
    chmod 600 ${ssoEnvFile}
  '';
in
{
  options.homefree.services.vaultwarden = userOptions;
  options.homefree.service-options.vaultwarden = userOptions // {
    label = lib.mkOption {
      type = lib.types.str;
      default = "vaultwarden";
      internal = true;
      description = "Service label";
    };

    name = lib.mkOption {
      type = lib.types.str;
      default = "Password Manager";
      internal = true;
      description = "Service display name";
    };

    project-name = lib.mkOption {
      type = lib.types.str;
      default = "Vaultwarden";
      internal = true;
      description = "Project name";
    };
  };

  config = {
    virtualisation.oci-containers.containers = lib.optionalAttrs config.homefree.service-options.vaultwarden.enable {
      vaultwarden = {
        image = "vaultwarden/server:${version}";

        autoStart = true;

        extraOptions = [
          # "--pull=always"
        ];

        ports = [
          "0.0.0.0:${toString port}:80"
        ];

        volumes = [
          "/etc/localtime:/etc/localtime:ro"
          "${containerDataPath}:/data"
          ## Mount the synthesized CA bundle (Caddy local CA + system
          ## roots) so Vaultwarden's Rust HTTP client trusts
          ## sso.<domain> when fetching OIDC discovery.
          "${containerDataPath}/ca-bundle.crt:/etc/ssl/homefree-ca-bundle.crt:ro"
        ];

        environment = {
          TZ = config.homefree.system.timeZone;
          ## DOMAIN drives the redirect_uri Vaultwarden registers
          ## with Zitadel. Must be the public HTTPS URL — Caddy
          ## fronts the container at this URL.
          DOMAIN = "https://vaultwarden.${config.homefree.system.domain}";
          ## Disable open registration — SSO becomes the only path
          ## in. Existing local users created BEFORE SSO was wired
          ## up still log in via SSO_SIGNUPS_MATCH_EMAIL once they
          ## attempt SSO sign-in.
          SIGNUPS_ALLOWED = "false";
          ## Rust native-tls honors SSL_CERT_FILE.
          SSL_CERT_FILE = "/etc/ssl/homefree-ca-bundle.crt";
        };

        ## OIDC env synthesized by preStart from Zitadel secrets.
        environmentFiles = [ ssoEnvFile ];
      };
    };

    systemd.services.podman-vaultwarden =lib.optionalAttrs config.homefree.service-options.vaultwarden.enable {
      after = [ "dns-ready.service" ];
      wants = [ "dns-ready.service" ];
      serviceConfig = {
        ExecStartPre = [ "!${pkgs.writeShellScript "vaultwarden-prestart" preStart}" ];
      };
    };

    homefree.service-config = [{
      inherit (config.homefree.service-options.vaultwarden) label name project-name;
      systemd-service-names = [
        "podman-vaultwarden"
      ];
      sso = {
        kind = "native_oidc";
        notes = "Vaultwarden 1.36+ native OIDC. Master password still required after SSO for vault decryption (E2E encryption — can't be bypassed).";
      };
      reverse-proxy = {
        enable = config.homefree.service-options.vaultwarden.enable;
        subdomains = [ "vaultwarden" ];
        http-domains = [ "homefree.lan" config.homefree.system.localDomain ];
        https-domains = [ config.homefree.system.domain ];
        host = config.homefree.network.lan-address;
        port = port;
        public = config.homefree.service-options.vaultwarden.public;
      };
      backup = {
        paths = [
          containerDataPath
        ];
      };
      options-metadata = [
        {
          path = "enable";
          type = "bool";
          default = false;
          description = "Enable Vaultwarden Bitwarden password manager backend";
        }
        {
          path = "public";
          type = "bool";
          default = false;
          description = "Make service accessible from WAN";
        }
      ];
    }];
  };
}
