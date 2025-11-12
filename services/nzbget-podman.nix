{ config, lib, pkgs, ... }:
let
  version = "version-v24.8";
  port = 6799;
  containerDataPath = "/var/lib/nzbget";
  configPath = "${containerDataPath}/config";
  downloadsPath = if config.homefree.service-options.nzbget.downloads-path != null
    then config.homefree.service-options.nzbget.downloads-path
    else "${containerDataPath}/downloads";
  preStart = ''
    mkdir -p ${configPath}
    mkdir -p ${downloadsPath}
  '';
in
{
  options.homefree.service-options.nzbget = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "enable NZBGet service";
    };

    public = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Open to public on WAN port";
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
      default = "nzbget";
      internal = true;
      description = "Service label";
    };

    name = lib.mkOption {
      type = lib.types.str;
      default = "NZB Downloader";
      internal = true;
      description = "Service display name";
    };

    project-name = lib.mkOption {
      type = lib.types.str;
      default = "NZBGet";
      internal = true;
      description = "Project name";
    };
  };

  config = {
  virtualisation.oci-containers.containers = lib.optionalAttrs config.homefree.service-options.nzbget.enable {
    nzbget = {
      image = "lscr.io/linuxserver/nzbget:${version}";

      autoStart = true;

      extraOptions = [
        # "--pull=always"
      ];

      ports = [
        "0.0.0.0:${toString port}:6789"
      ];

      volumes = [
        "/etc/localtime:/etc/localtime:ro"
        "${configPath}:/config"
        "${downloadsPath}:/downloads"
      ];

      environment = {
        TZ = config.homefree.system.timeZone;
        PUID = "1000";
        PGID = "100";
        # NZBGET_USER = "nzbget"; #optional
        # NZBGET_PASS = "tegbzn6789"; #optional
      };
    };
  };

  systemd.services.podman-nzbget = lib.optionalAttrs config.homefree.service-options.nzbget.enable {
    after = [ "dns-ready.service" ];
    requires = [ "dns-ready.service" ];
    partOf =  [ "nftables.service" ];
    serviceConfig = {
      ExecStartPre = [ "!${pkgs.writeShellScript "nzbget-prestart" preStart}" ];
    };
  };

    homefree.service-config = [{
      inherit (config.homefree.service-options.nzbget) label name project-name;
      systemd-service-names = [
        "podman-nzbget"
      ];
      reverse-proxy = {
        enable = config.homefree.service-options.nzbget.enable;
        subdomains = [ "nzbget" ];
        http-domains = [ "homefree.lan" config.homefree.system.localDomain ];
        https-domains = [ config.homefree.system.domain ];
        host = config.homefree.network.lan-address;
        port = port;
        public = config.homefree.service-options.nzbget.public;
      };
      backup = lib.optionalAttrs config.homefree.service-options.nzbget.enable-backup-media {
        paths = [
          downloadsPath
        ];
      };
      options-metadata = [
        {
          path = "enable";
          type = "bool";
          default = false;
          description = "Enable NZBGet usenet downloader";
        }
        {
          path = "public";
          type = "bool";
          default = false;
          description = "Make service accessible from WAN";
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
          description = "Whether to backup downloads";
        }
      ];
    }];
  };
}
