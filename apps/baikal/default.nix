{ config, lib, pkgs, ... }:
let
  containerDataPath = "/var/lib/baikal";

  port = 3007;

  version = "0.10.1";

  preStart = ''
    mkdir -p ${containerDataPath}/config
    mkdir -p ${containerDataPath}/Specific
  '';

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
    virtualisation.oci-containers.containers = lib.optionalAttrs config.homefree.service-options.baikal.enable {
    baikal = {
      image = "ckulka/baikal:${version}-nginx";

      autoStart = true;

      extraOptions = [
        # "--pull=always"
      ];

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
  };

  systemd.services.podman-baikal = lib.optionalAttrs config.homefree.service-options.baikal.enable {
    after = [ "dns-ready.service" ];
    wants = [ "dns-ready.service" ];
    serviceConfig = {
      ExecStartPre = [ "!${pkgs.writeShellScript "baikal-prestart" preStart}" ];
    };
  };

    homefree.service-config = [{
      inherit (config.homefree.service-options.baikal) label name project-name;
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

