{ config, lib, pkgs, ... }:
let
  containerDataPath = "/var/lib/baikal";

  port = config.homefree.allocPort "baikal";

  version = "0.10.1";

  userOptions = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "enable Baikal CalDAV/CardDAV service";
    };

    public = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Open to public on WAN port";
    };
  };
in
{
  options.homefree.services.baikal = userOptions;

  options.homefree.service-options.baikal = userOptions // {
    # Metadata - always available, not user-configurable
    label = lib.mkOption {
      type = lib.types.str;
      default = "baikal";
      internal = true;
      description = "Service label";
    };

    name = lib.mkOption {
      type = lib.types.str;
      default = "Baikal CalDAV/CardDAV";
      internal = true;
      description = "Service display name";
    };

    project-name = lib.mkOption {
      type = lib.types.str;
      default = "Baikal";
      internal = true;
      description = "Project name";
    };
  };

  config = {
    ## Container via the app-platform primitive (modules/app-platform.nix).
    ## The dns-ready podman unit ordering and ExecStartPre are generated;
    ## this declares only the baikal-specific data.
    homefree.containers.baikal = lib.mkIf config.homefree.service-options.baikal.enable {
      ## SKIPPED Phase 3 non-root pass: the ckulka/baikal-nginx
      ## image's entrypoint does `chown -R www-data /var/www/baikal`
      ## on every start — including the image's own vendor PHP files
      ## which are owned by root in the image layer. As a non-root
      ## UID the chown fails with "Operation not permitted" on every
      ## file and the container exits 1. Fix-options if hardening
      ## becomes a priority: (a) build a custom image with --chown=
      ## baked in and the entrypoint chown removed, (b) switch to a
      ## different Baikal image (sabre/baikal-podman variants exist).
      runAs = {
        mode = "root";
        reason = "image entrypoint chowns /var/www/baikal as root; non-root start fails with EPERM";
      };
      image = "ckulka/baikal:${version}-nginx";

      ## preStart creates two sub-directories (not just the top-level
      ## containerDataPath), so dataDir is null and the mkdirs are
      ## emitted verbatim via preStartInit.
      dataDir = null;
      preStartInit = ''
        mkdir -p ${containerDataPath}/config
        mkdir -p ${containerDataPath}/Specific
      '';

      ports = [
        "0.0.0.0:${toString port}:80"
      ];

      volumes = [
        "/etc/localtime:/etc/localtime:ro"
        "${containerDataPath}/config:/var/www/baikal/config"
        "${containerDataPath}/Specific:/var/www/baikal/Specific"
      ];

      environment = {
        TZ = config.homefree.system.timeZone;
      };
    };

    homefree.service-config = [{
      inherit (config.homefree.service-options.baikal) label name project-name;
      port-request = null;
      enable = config.homefree.service-options.baikal.enable;
      systemd-service-names = [
        "podman-baikal"
      ];
      sso = {
        kind = "caddy_gated";
        ## Dev context (intentionally not surfaced in the admin UI):
        ## SSO gates the admin UI only. DAV clients (Thunderbird, iOS
        ## Calendar, etc.) authenticate to Baikal directly via HTTP
        ## Basic Auth with their per-user app password.
      };
      reverse-proxy = {
        enable = config.homefree.service-options.baikal.enable;
        subdomains = [ "baikal" ];
        http-domains = [ "homefree.lan" config.homefree.system.localDomain ];
        https-domains = [ config.homefree.system.domain ];
        host = config.homefree.network.lan-address;
        port = port;
        public = config.homefree.service-options.baikal.public;
        ## SSO-gate the admin UI but leave DAV traffic alone. The
        ## dav-bypass flag tells Caddy to skip the @sso_gate matcher
        ## for any request that (a) carries `Authorization: Basic ...`
        ## or (b) uses a DAV-only HTTP method. Result:
        ##   - Browser to /admin/ without cookie  -> SSO challenge
        ##   - Thunderbird / iOS Calendar / KOrganizer on /dav.php
        ##     with their app password           -> straight through
        ##     to Baikal, which authenticates them with their own
        ##     credentials.
        oauth2 = true;
        dav-bypass = true;
      };
      backup = {
        paths = [
          "${containerDataPath}/config"
          "${containerDataPath}/Specific"
        ];
      };
      options-metadata = [
        {
          path = "enable";
          type = "bool";
          default = false;
          description = "Enable Baikal CalDAV/CardDAV service";
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
