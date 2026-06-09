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

  port = config.homefree.allocPort "vaultwarden";
  version = "1.36.0";

  ssoEnvFile = "${containerDataPath}/sso.env";

  ## Container runs under a dedicated unprivileged host UID instead
  ## of root. The vaultwarden upstream image's default USER is root
  ## but `/start.sh` does no chown-on-entry, so the data dir just has
  ## to be writable by the target UID. UIDs in the 800-899 range are
  ## reserved for HomeFree app-container runtimes.
  vaultwardenUid = 801;
  vaultwardenGid = 801;

  enable = config.homefree.service-options.vaultwarden.enable;
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
    ## Container workload via the app-platform primitive
    ## (modules/app-platform.nix). The chown-marker, CA-bundle synthesis,
    ## podman dns-ready unit, and the dedicated system user/group are all
    ## generated; this declares only the vaultwarden-specific data.
    homefree.containers.vaultwarden = lib.mkIf enable {
      image = "vaultwarden/server:${version}";

      ## Drop root inside the container. The vaultwarden image's
      ## /start.sh does no chown-on-entry - the bind-mounted /data
      ## just needs to be writable by this UID, which preStart ensures.
      runAs = { mode = "rootless"; uid = vaultwardenUid; gid = vaultwardenGid; };
      dataDir = containerDataPath;

      ## Vaultwarden (Rust) fetches Zitadel's OIDC discovery over Caddy's local CA.
      ## Rust native-tls honors SSL_CERT_FILE (default env var + container path).
      caBundle = true;

      ports = [
        ## Container-internal listen port is 8080, not the upstream
        ## image default of 80. Non-root processes cannot bind to
        ## privileged ports (<1024) and we now run vaultwarden as
        ## UID 801. ROCKET_PORT below tells the Rocket HTTP server
        ## to listen on 8080.
        "0.0.0.0:${toString port}:8080"
      ];

      volumes = [
        "/etc/localtime:/etc/localtime:ro"
        "${containerDataPath}:/data"
        ## (the synthesized CA bundle mount is appended by caBundle = true)
      ];

      environment = {
        TZ = config.homefree.system.timeZone;
        ## DOMAIN drives the redirect_uri Vaultwarden registers
        ## with Zitadel. Must be the public HTTPS URL - Caddy
        ## fronts the container at this URL.
        DOMAIN = "https://vaultwarden.${config.homefree.system.domain}";
        ## Disable open registration - SSO becomes the only path
        ## in. Existing local users created BEFORE SSO was wired
        ## up still log in via SSO_SIGNUPS_MATCH_EMAIL once they
        ## attempt SSO sign-in.
        SIGNUPS_ALLOWED = "false";
        ## Rocket's listen port. Must be >= 1024 because vaultwarden
        ## runs as a non-root UID inside the container.
        ROCKET_PORT = "8080";
        ## (SSL_CERT_FILE pointing at the CA bundle is added by caBundle = true)
      };

      ## OIDC env synthesized by preStartFinal from Zitadel secrets.
      environmentFiles = [ ssoEnvFile ];

      ## Synthesize Vaultwarden's OIDC env file from the secrets
      ## zitadel-provision writes. Runs after the CA-bundle synthesis.
      ##
      ## Vaultwarden 1.36+ has native OIDC. The auto-derived callback
      ## URI is <DOMAIN>/identity/connect/oidc-signin.
      ##
      ## Admin role mapping: Vaultwarden has NO concept of OIDC->admin
      ## propagation. The admin panel is gated by a separate
      ## ADMIN_TOKEN (kept disabled for now). Master password is still
      ## required after SSO - SSO authenticates, master password
      ## derives the vault encryption key. Users set it on first login.
      preStartFinal = ''
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
            echo "SSO_SCOPES=email profile urn:zitadel:iam:org:project:roles"
            echo "SSO_ONLY=true"
            echo "SSO_SIGNUPS_MATCH_EMAIL=true"
            echo "SSO_PKCE=true"
            echo "SSO_AUDIENCE_TRUSTED=^[0-9]{15,20}$"
            echo "SSO_AUTH_ONLY_NOT_SESSION=true"
            echo "REFRESH_VALIDITY_SECS=31536000"
          } > ${ssoEnvFile}
        else
          ## Pre-provisioning (fresh install): empty env file.
          : > ${ssoEnvFile}
        fi
        chmod 600 ${ssoEnvFile}
      '';
    };

    homefree.service-config = [{
      inherit (config.homefree.service-options.vaultwarden) label name project-name;
      port-request = null;
      enable = config.homefree.service-options.vaultwarden.enable;
      systemd-service-names = [
        "podman-vaultwarden"
      ];
      sso = {
        kind = "native_oidc";
        ## Dev context (intentionally not surfaced in the admin UI):
        ## Vaultwarden 1.36+ native OIDC. Master password still
        ## required after SSO for vault decryption (E2E encryption -
        ## cannot be bypassed).
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
