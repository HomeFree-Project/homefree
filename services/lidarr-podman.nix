{ config, lib, pkgs, ... }:
let
  version = "8.1.2135";
  port = 8976;
  containerDataPath = "/var/lib/lidarr";
  configPath = "${containerDataPath}/config";
  mediaPath = if config.homefree.service-options.lidarr.media-path != null
    then config.homefree.service-options.lidarr.media-path
    else "${containerDataPath}/media";
  downloadsPath = if config.homefree.service-options.lidarr.downloads-path != null
    then config.homefree.service-options.lidarr.downloads-path
    else "${containerDataPath}/downloads";
  preStart = ''
    mkdir -p ${configPath}
    mkdir -p ${mediaPath}
    mkdir -p ${downloadsPath}
  '';
in
{
  options.homefree.service-options.lidarr = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "enable Lidarr service";
    };

    public = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Open to public on WAN port";
    };

    media-path = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Location of music media";
    };

    downloads-path = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Location of downloads";
    };

    enable-backup-media = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether to backup media";
    };

    label = lib.mkOption {
      type = lib.types.str;
      default = "lidarr";
      internal = true;
      description = "Service label";
    };

    name = lib.mkOption {
      type = lib.types.str;
      default = "Lidarr Music Collection Manager";
      internal = true;
      description = "Service display name";
    };

    project-name = lib.mkOption {
      type = lib.types.str;
      default = "Lidarr";
      internal = true;
      description = "Project name";
    };
  };

  config = {
  virtualisation.oci-containers.containers = lib.optionalAttrs config.homefree.service-options.lidarr.enable {
    lidarr = {
      image = "lscr.io/linuxserver/lidarr:${version}";

      autoStart = true;

      extraOptions = [
        # "--pull=always"
      ];

      ports = [
        "0.0.0.0:${toString port}:8686"
      ];

      volumes = [
        "/etc/localtime:/etc/localtime:ro"
        "${configPath}:/config"
        "${mediaPath}:/music"
        "${downloadsPath}:/downloads"
      ];

      environment = {
        TZ = config.homefree.system.timeZone;
        PUID = "1000";
        PGID = "100";
      };
    };
  };

  systemd.services.podman-lidarr = lib.optionalAttrs config.homefree.service-options.lidarr.enable {
    after = [ "dns-ready.service" ];
    requires = [ "dns-ready.service" ];
    partOf =  [ "nftables.service" ];
    serviceConfig = {
      ExecStartPre = [ "!${pkgs.writeShellScript "lidarr-prestart" preStart}" ];
    };
  };

    homefree.service-config = [{
      inherit (config.homefree.service-options.lidarr) label name project-name;
      systemd-service-names = [
        "podman-lidarr"
      ];
      reverse-proxy = {
        enable = config.homefree.service-options.lidarr.enable;
        subdomains = [ "lidarr" ];
        http-domains = [ "homefree.lan" config.homefree.system.localDomain ];
        https-domains = [ config.homefree.system.domain ];
        host = config.homefree.network.lan-address;
        port = port;
        public = config.homefree.service-options.lidarr.public;
        ## NOTE: Lidarr is intentionally NOT SSO-gated yet. Its
        ## browser UI and its REST API live on the same hostname,
        ## and API consumers (Sonarr/Readarr/custom scripts) pass
        ## an API key — not browser cookies. Gating with oauth2-
        ## proxy would 302 every API call into the SSO flow and
        ## break ingest pipelines. Pre-condition for SSO-gating:
        ## split API path off into a separate subdomain (e.g.
        ## lidarr-api.<domain>) that stays open behind the API
        ## key, then gate the UI.
      };
      backup = lib.optionalAttrs config.homefree.service-options.lidarr.enable-backup-media {
        paths = [
          mediaPath
          downloadsPath
        ];
      };
      options-metadata = [
        {
          path = "enable";
          type = "bool";
          default = false;
          description = "Enable Lidarr music collection manager";
        }
        {
          path = "public";
          type = "bool";
          default = false;
          description = "Make service accessible from WAN";
        }
        {
          path = "media-path";
          type = "path";
          nullable = true;
          default = null;
          description = "Location of music media";
          ui-hint = "directory-picker";
        }
        {
          path = "downloads-path";
          type = "path";
          nullable = true;
          default = null;
          description = "Location of downloads";
          ui-hint = "directory-picker";
        }
        {
          path = "enable-backup-media";
          type = "bool";
          default = true;
          description = "Whether to backup media files";
        }
      ];
    }];
  };
}
