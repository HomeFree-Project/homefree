## @TODOs
## - Look into HACS integration:
##   - https://community.home-assistant.io/t/installing-hacs-is-tricky-in-docker-but-the-documentation-is-very-straightforward-when-you-know-how-to-read/450283
## - Look into using packaged custom components:
##   - https://github.com/NixOS/nixpkgs/tree/nixos-24.11/pkgs/servers/home-assistant/custom-components
{ config, lib, pkgs, ... }:
let
  version = "2026.4";

  containerDataPath = "/var/lib/homeassistant";

  port = 8123;

  format = pkgs.formats.yaml {};

  # Post-process YAML output to add support for YAML functions, like
  # secrets or includes, by naively unquoting strings with leading bangs
  # and at least one space-separated parameter.
  # https://www.home-assistant.io/docs/configuration/secrets/
  renderYAMLFile = fn: yaml: pkgs.runCommandLocal fn { } ''
    cp ${format.generate fn yaml} $out
    sed -i -e "s/'\!\([a-z_]\+\) \(.*\)'/\!\1 \2/;s/^\!\!/\!/;" $out
  '';

  ha-config = {
    default_config = {};

    fontend = {
      themes = "!include_dir_merge_named themes";
    };

    automation = "!include automations.yaml";
    script = "!include scripts.yaml";
    scene = "!include scenes.yaml";
    group = "!include groups.yaml";

    http = {
      use_x_forwarded_for = true;
      trusted_proxies = "${config.homefree.network.lan-address}";
    };

    auth_header = {
      debug = true;
    };

    logger = {
      default = "info";
      logs = {
        custom_components.auth_header = "debug";
      };
    };
  };

  config-yaml = renderYAMLFile "configuration.yaml" ha-config;

  preStart = ''
    mkdir -p ${containerDataPath}/config
    mkdir -p ${containerDataPath}/config/custom_components
    ln -sfn ${pkgs.home-assistant-custom-components.auth-header}/custom_components/auth_header ${containerDataPath}/config/custom_components/

    cp ${config-yaml} ${containerDataPath}/config/configuration.yaml
  '';
in
{
  options.homefree.service-options.home-assistant = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "enable Home Assistant service";
    };

    public = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Open to public on WAN port";
    };

    label = lib.mkOption {
      type = lib.types.str;
      default = "homeassistant";
      internal = true;
      description = "Service label";
    };

    name = lib.mkOption {
      type = lib.types.str;
      default = "Home Assistant";
      internal = true;
      description = "Service display name";
    };

    project-name = lib.mkOption {
      type = lib.types.str;
      default = "Home Assistant";
      internal = true;
      description = "Project name";
    };
  };

  config = {
  virtualisation.oci-containers.containers = lib.optionalAttrs config.homefree.services.homeassistant.enable {
    homeassistant = {
      image = "ghcr.io/home-assistant/home-assistant:${version}";

      autoStart = true;

      extraOptions = [
        # "--pull=always"
        "--network=host"
        "--privileged"
      ];

      volumes = [
        "/etc/localtime:/etc/localtime:ro"
        "${containerDataPath}/config:/config"
        "/run/dbus:/run/dbus:ro"
      ];

      environment = {
        TZ = config.homefree.system.timeZone;
      };
    };
  };

  systemd.services.podman-homeassistant = lib.optionalAttrs config.homefree.services.homeassistant.enable {
    after = [ "dns-ready.service" ];
    requires = [ "dns-ready.service" ];
    partOf =  [ "nftables.service" ];
    serviceConfig = {
      ExecStartPre = [ "!${pkgs.writeShellScript "homeassistant-prestart" preStart}" ];
    };
  };

  homefree.service-config = lib.optionals config.homefree.services.homeassistant.enable [
    {
      inherit (config.homefree.service-options.home-assistant) label name project-name;
      systemd-service-names = [
        "podman-homeassistant"
      ];
      reverse-proxy = {
        enable = config.homefree.service-options.home-assistant.enable;
        subdomains = [ "homeassistant" "ha" ];
        http-domains = [ "homefree.lan" config.homefree.system.localDomain ];
        https-domains = [ config.homefree.system.domain ];
        host = config.homefree.network.lan-address;
        port = port;
        public = config.homefree.services.homeassistant.public;
      };
      backup = {
        paths = [
          containerDataPath
        ];
      };
    }
  ];
  };
}
