{ config, lib, pkgs, ... }:
let
  userOptions = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "enable Trilium Notes service";
    };

    public = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Open to public on WAN port";
    };
  };

  version = "0.95.0";
  containerDataPath = "/var/lib/trilium-podman";
  port = config.homefree.allocPort "trilium";
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
  ## Admin-UI metadata namespace. The user-facing schema is declared
  ## in module.nix as `homefree.services.trilium`; module.nix's
  ## generic `intersectAttrs` mirror projects each user-facing service
  ## into `homefree.service-options.<name>` so admin-web can build its
  ## UI. That projection only includes services that have a matching
  ## `service-options.<name>` declaration here.
  options.homefree.services.trilium = userOptions;
  options.homefree.service-options.trilium = userOptions // {
    label = lib.mkOption {
      type = lib.types.str;
      default = "trilium";
      internal = true;
      description = "Service label";
    };

    name = lib.mkOption {
      type = lib.types.str;
      default = "Trilium Notes";
      internal = true;
      description = "Service display name";
    };

    project-name = lib.mkOption {
      type = lib.types.str;
      default = "TriliumNext Notes";
      internal = true;
      description = "Project name";
    };
  };

  config = {

  ## Container via the app-platform primitive (modules/app-platform.nix): the
  ## dns-ready podman unit and the data-dir mkdir (the entire preStart) are
  ## generated from this descriptor.
  homefree.containers.trilium = lib.mkIf config.homefree.services.trilium.enable {
    ## SKIPPED Phase 3 UID-pin: the triliumnext/notes image's entrypoint
    ## ALWAYS starts as root, runs `chown -R` over /home/node, then drops to
    ## the internal `node` user (uid 1000) via `su`. Setting user= forces a
    ## non-root start, the chown fails "Operation not permitted" on every
    ## file, and `su` bombs "must be suid to work properly".
    runAs = { mode = "root"; reason = "image entrypoint chowns /home/node as root then su-drops to node uid 1000; user= breaks it"; };
    image = "triliumnext/notes:v${version}";
    dataDir = containerDataPath;

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
      ## Disable Trilium's inner login screen — Caddy's SSO gate is the only
      ## auth layer; Trilium opens directly to the notes view.
      TRILIUM_GENERAL_NOAUTHENTICATION = "true";
      ## Trust Caddy's X-Forwarded-* so Trilium builds absolute URLs against
      ## the public hostname. Express rejects "true" via env, hence integer 1.
      TRILIUM_NETWORK_TRUSTEDREVERSEPROXY = "1";
    };
  };

  homefree.service-config = if config.homefree.services.trilium.enable == true then [
    {
      label = "trilium";
      port-request = null;
      name = "Trilium Notes";
      project-name = "TriliumNext Notes";
      systemd-service-names = [
        "podman-trilium"
      ];
      sso = {
        kind = "caddy_gated";
        ## Dev context (intentionally not surfaced in the admin UI):
        ## Trilium's inner auth is disabled
        ## (TRILIUM_GENERAL_NOAUTHENTICATION=true). Caddy's SSO gate
        ## (oauth2-proxy + Zitadel) is the only auth layer. Single-user
        ## only — anyone past the gate has owner access.
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
  };
}
