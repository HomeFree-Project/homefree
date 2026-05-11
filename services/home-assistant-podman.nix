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

  ## Home Assistant SSO is currently unwired. Previous iterations
  ## installed the `auth_header` custom component to trust an
  ## upstream proxy's X-Remote-User header — but (a) the auth-header
  ## attribute disappeared from this nixpkgs revision, and (b)
  ## oauth2-proxy emits X-Forwarded-User not X-Remote-User, so the
  ## flow never worked end-to-end anyway.
  ##
  ## Follow-up work to wire HA SSO properly:
  ##  1. Add a service entry to services/zitadel-provision.nix's
  ##     SERVICES table for "home-assistant" with a redirect URI
  ##     of https://ha.<domain>/auth/external/callback.
  ##  2. Switch to the auth_oidc custom component
  ##     (pkgs.home-assistant-custom-components.auth_oidc), which
  ##     does a full OIDC dance from inside HA — no upstream-proxy
  ##     header trust needed. Render its client_id + client_secret
  ##     into configuration.yaml at preStart from the on-disk
  ##     /var/lib/homefree-secrets/home-assistant/oidc-client-*
  ##     files (same pattern as netbird's management.json synth).
  ##  3. Mount Caddy's local CA into the container so HA can
  ##     reach https://sso.<domain>/.well-known/openid-configuration.
  ##  4. Drop the Caddy oauth2 gate for the HA reverse-proxy entry
  ##     (or keep it for the LAN-direct path only) — auth_oidc
  ##     handles auth itself.
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
      ## HA expects trusted_proxies to be a YAML list, not a scalar.
      ## Caddy hits this container from the host's LAN IP, so adding
      ## that one entry is enough to satisfy the trust check.
      trusted_proxies = [ config.homefree.network.lan-address ];
    };
  };

  config-yaml = renderYAMLFile "configuration.yaml" ha-config;

  preStart = ''
    mkdir -p ${containerDataPath}/config
    cp ${config-yaml} ${containerDataPath}/config/configuration.yaml

    ## configuration.yaml uses `!include` for the four files below.
    ## If any are missing, HA fails YAML parsing and falls back to
    ## "recovery mode" — which serves a stripped-down config with
    ## NO trusted_proxies, breaking every reverse-proxied request
    ## with HTTP 400. Touch them so they exist as empty files; HA
    ## treats empty includes as "no entries", which is what a fresh
    ## install wants anyway.
    for f in automations.yaml scripts.yaml scenes.yaml groups.yaml; do
      [ -f "${containerDataPath}/config/$f" ] || \
        touch "${containerDataPath}/config/$f"
    done
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
        ## SSO is unwired for HA — see the long comment above the
        ## ha-config let-binding for the follow-up plan to wire it
        ## via auth_oidc. For now HA uses its own local login.
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
          description = "Enable Home Assistant Home Automation";
        }
        {
          path = "public";
          type = "bool";
          default = false;
          description = "Make service accessible from WAN";
        }
      ];
    }
  ];
  };
}
