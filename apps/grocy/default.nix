{ config, lib, pkgs, ... }:
let
  containerDataPath = "/var/lib/grocy";

  preStart = ''
    mkdir -p ${containerDataPath}
  '';

  version = "4.6.0";

  port = 3018;

  userOptions = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "enable Grocy groceries & household management service";
    };

    public = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Open to public on WAN port";
    };
  };
in
{
  options.homefree.services.grocy = userOptions;

  options.homefree.service-options.grocy = userOptions // {
    # Metadata - always available, not user-configurable
    label = lib.mkOption {
      type = lib.types.str;
      default = "grocy";
      internal = true;
      description = "Service label";
    };

    name = lib.mkOption {
      type = lib.types.str;
      default = "Grocy";
      internal = true;
      description = "Service display name";
    };

    project-name = lib.mkOption {
      type = lib.types.str;
      default = "Grocy";
      internal = true;
      description = "Project name";
    };
  };

  config = {
    ## @NOTE: Default username and password: admin, admin
    ## @TODO: Setup LDAP login (see /var/lib/grocy/data/config.php)
    ##        Can this be set up with env vars?
    virtualisation.oci-containers.containers = lib.optionalAttrs config.homefree.service-options.grocy.enable {
    grocy = {
      image = "lscr.io/linuxserver/grocy:${version}";

      autoStart = true;

      extraOptions = [
        # "--pull=always"
      ];

      ports = [
        "0.0.0.0:${toString port}:80"
      ];

      volumes = [
        "/etc/localtime:/etc/localtime:ro"
        "${containerDataPath}:/config"
      ];

      environment = {
        TZ = config.homefree.system.timeZone;
      };
    };
  };

  systemd.services.podman-grocy = lib.optionalAttrs config.homefree.service-options.grocy.enable {
    after = [ "dns-ready.service" ];
    wants = [ "dns-ready.service" ];
    serviceConfig = {
      ExecStartPre = [ "!${pkgs.writeShellScript "grocy-prestart" preStart}" ];
    };
  };

    homefree.service-config = [{
      inherit (config.homefree.service-options.grocy) label name project-name;
      sso = {
        kind = "none";
        applicable = false;
        ## Dev context (intentionally not surfaced in the admin UI):
        ## Grocy serves its REST API on the same host as the web UI
        ## (no API/UI split). Adding an outer SSO gate would break
        ## mobile and barcode-scanner clients that authenticate with
        ## Grocy's native API keys. Use Grocy's built-in user system.
      };
      systemd-service-names = [
        "podman-grocy"
      ];
      reverse-proxy = {
        enable = config.homefree.service-options.grocy.enable;
        subdomains = [ "grocy" ];
        http-domains = [ "homefree.lan" config.homefree.system.localDomain ];
        https-domains = [ config.homefree.system.domain ];
        host = config.homefree.network.lan-address;
        port = port;
        public = config.homefree.service-options.grocy.public;
        ## NOTE: Grocy is intentionally NOT SSO-gated yet. Its
        ## official mobile app talks to Grocy's REST API on the
        ## same host as the web UI, using a server-issued API key
        ## (no browser cookies, no SSO traversal). Gating would
        ## break the app. Same Phase-A treatment as Lidarr: split
        ## API onto its own subdomain or use a path-scoped gate.
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
          description = "Enable Homebox inventory management service";
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

