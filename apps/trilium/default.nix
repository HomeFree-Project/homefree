{ config, lib, pkgs, ... }:
let
  version = "0.95.0";
  containerDataPath = "/var/lib/trilium-podman";
  port = 8081;
  domain = config.homefree.system.domain;

  ## Trilium's native OIDC (TRILIUM_OAUTH_*) only activates once the
  ## user opens Trilium's settings and switches MFA Method to
  ## "OAuth" — there's no env-var to flip that flag before first run.
  ## So instead of native OIDC, we use the Caddy SSO gate
  ## (caddy_gated): Caddy validates via oauth2-proxy + Zitadel; then
  ## Trilium runs with TRILIUM_GENERAL_NOAUTHENTICATION=true so the
  ## user never sees an inner login. Single-user instance only —
  ## anyone behind the SSO gate has full owner access.
  preStart = ''
    mkdir -p ${containerDataPath}
  '';
in
{
  virtualisation.oci-containers.containers = if config.homefree.services.trilium.enable == true then {
    trilium = {
      image = "triliumnext/notes:v${version}";

      autoStart = true;

      extraOptions = [
        # "--pull=always"
      ];

      ports = [
        "0.0.0.0:${toString port}:8080"
      ];

      volumes = [
        "/etc/localtime:/etc/localtime:ro"
        "${containerDataPath}:/home/node/trilium-data"
      ];

      environment = {
        TZ = config.homefree.system.timeZone;
        TRILIUM_DATA_DIR = "/home/node/trilium-data";
        ## Disable Trilium's inner login screen — Caddy's SSO gate
        ## is the only auth layer. Trilium opens directly to the
        ## notes view for anyone who got past the gate.
        TRILIUM_GENERAL_NOAUTHENTICATION = "true";
        ## Trust Caddy's X-Forwarded-* headers so Trilium builds
        ## absolute URLs against the public hostname. Hop count = 1
        ## (Caddy is the only proxy in front). Express's `trust
        ## proxy` rejects the literal string "true" via env vars,
        ## hence the integer.
        TRILIUM_NETWORK_TRUSTEDREVERSEPROXY = "1";
      };
    };
  } else {};

  systemd.services.podman-trilium = lib.optionalAttrs (config.homefree.services.trilium.enable == true) {
    after = [ "dns-ready.service" ];
    requires = [ "dns-ready.service" ];
    serviceConfig = {
      ExecStartPre = [ "!${pkgs.writeShellScript "trilium-prestart" preStart}" ];
    };
  };

  homefree.service-config = if config.homefree.services.trilium.enable == true then [
    {
      label = "trilium";
      name = "Trilium Notes";
      project-name = "TriliumNext Notes";
      systemd-service-names = [
        "podman-trilium"
      ];
      sso = {
        kind = "caddy_gated";
        notes = "Trilium's inner auth is disabled (TRILIUM_GENERAL_NOAUTHENTICATION=true). Caddy's SSO gate (oauth2-proxy + Zitadel) is the only auth layer. Single-user only — anyone past the gate has owner access.";
      };
      reverse-proxy = {
        enable = true;
        subdomains = [ "notes" "trilium" ];
        http-domains = [ "homefree.lan" config.homefree.system.localDomain ];
        https-domains = [ config.homefree.system.domain ];
        host = config.homefree.network.lan-address;
        port = port;
        public = config.homefree.services.trilium.public;
        oauth2 = config.homefree.sso.per-service.trilium.enable or true;
      };
      backup = {
        paths = [
          containerDataPath
        ];
      };
    }
  ] else [];
}
