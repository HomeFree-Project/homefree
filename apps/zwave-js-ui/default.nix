{ config, lib, pkgs, ... }:
let
  userOptions = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "enable Z-Wave JS UI controller daemon";
    };

    public = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Open to public on WAN port";
    };

    deviceId = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = ''
        Stable serial-by-id of the Z-Wave USB controller (without the
        /dev/serial/by-id/ prefix). For example, an Aeotec Z-Stick
        Gen5 typically presents as "usb-0658_0200-if00".
        Find with: ls /dev/serial/by-id/
      '';
    };
  };

  ## Image pinned to a known-good tag. Update on review.
  version = "11.19.1";

  containerDataPath = "/var/lib/zwave-js-ui";
  seedDir = "/var/lib/homefree-secrets/zwave-js-ui/seed";

  port-ui = 8091;
  port-ws = 3001;  ## Note: 3000 conflicts with AdGuardHome on a stock HomeFree

  ## /dev/serial/by-id/* is stable across reboots; the device id varies
  ## per stick (e.g. usb-0658_0200-if00 for an Aeotec Z-Stick Gen5).
  ## Instance config sets this; with no default, enabling the service
  ## without a deviceId fails Nix evaluation — surfaces the missing
  ## config at build time instead of at container boot.
  rawDeviceId = config.homefree.service-options.zwave-js-ui.deviceId;
  ## Accept either the bare id ("usb-0658_0200-if00") or the full path
  ## ("/dev/serial/by-id/usb-0658_0200-if00"). The admin UI and the
  ## option description both say "bare id", but the field is a free
  ## text input and users routinely paste the result of `ls -l
  ## /dev/serial/by-id/*` (full path). Without this strip, the bind
  ## mount becomes `/dev/serial/by-id//dev/serial/by-id/...` and podman
  ## exits 125 on first start.
  deviceId = lib.removePrefix "/dev/serial/by-id/" rawDeviceId;
  deviceArg = "/dev/serial/by-id/${deviceId}:/dev/zwave";

  preStart = ''
    set -eu
    mkdir -p ${containerDataPath}
    ## First-run seed: if there's no settings.json yet and a seed
    ## file exists at the secrets path, copy it (and nodes.json) in.
    ## After seed, subsequent rebuilds do NOT overwrite — the UI
    ## owns its store from then on.
    if [ ! -s ${containerDataPath}/settings.json ] \
       && [ -d "${seedDir}" ]; then
      for f in settings.json nodes.json; do
        if [ -f "${seedDir}/$f" ]; then
          cp "${seedDir}/$f" "${containerDataPath}/$f"
          chmod 600 "${containerDataPath}/$f"
        fi
      done
    fi
  '';
in
{
  options.homefree.services.zwave-js-ui = userOptions;
  options.homefree.service-options.zwave-js-ui = userOptions // {
    label = lib.mkOption {
      type = lib.types.str;
      default = "zwave-js-ui";
      internal = true;
      description = "Service label";
    };

    name = lib.mkOption {
      type = lib.types.str;
      default = "Z-Wave JS UI";
      internal = true;
      description = "Service display name";
    };

    project-name = lib.mkOption {
      type = lib.types.str;
      default = "Z-Wave JS UI";
      internal = true;
      description = "Project name";
    };

    options-metadata = lib.mkOption {
      type = lib.types.listOf lib.types.attrs;
      internal = true;
      default = [
        {
          path = "enable";
          type = "bool";
          default = false;
          description = "Enable Z-Wave JS UI controller daemon";
        }
        {
          path = "public";
          type = "bool";
          default = false;
          description = "Make service accessible from WAN";
        }
        {
          path = "deviceId";
          type = "str";
          default = "";
          description = "USB serial-by-id of the Z-Wave controller (e.g. usb-0658_0200-if00)";
        }
      ];
    };
  };

  config = {
    assertions = lib.optional
      (config.homefree.services.zwave-js-ui.enable && deviceId == "")
      {
        assertion = false;
        message = ''
          homefree.service-options.zwave-js-ui.deviceId must be set when
          the service is enabled. Find it with:
            ls /dev/serial/by-id/
        '';
      };

    virtualisation.oci-containers.containers = lib.optionalAttrs config.homefree.services.zwave-js-ui.enable {
      zwave-js-ui = {
        image = "zwavejs/zwave-js-ui:${version}";
        autoStart = true;

        extraOptions = [
          "--network=host"
          "--device=${deviceArg}"
        ];

        volumes = [
          "/etc/localtime:/etc/localtime:ro"
          "${containerDataPath}:/usr/src/app/store"
        ];

        environment = {
          TZ = config.homefree.system.timeZone;
          ## Pin the ports inside the container (defaults match these
          ## but be explicit so a future image bump can't silently shift
          ## them and break the Caddy upstream / HA WS URL).
          PORT = toString port-ui;
          ZWAVEJS_EXTERNAL_CONFIG = "/usr/src/app/store/.config-db";
        };
      };
    };

    systemd.services.podman-zwave-js-ui = lib.mkIf config.homefree.services.zwave-js-ui.enable {
      after = [ "dns-ready.service" ];
      wants = [ "dns-ready.service" ];
      serviceConfig = {
        ExecStartPre = [ "!${pkgs.writeShellScript "zwave-js-ui-prestart" preStart}" ];
      };
    };

    homefree.service-config = lib.optionals config.homefree.services.zwave-js-ui.enable [
      {
        inherit (config.homefree.service-options.zwave-js-ui) label name project-name;
        systemd-service-names = [
          "podman-zwave-js-ui"
        ];
        sso = {
          kind = "caddy_gated";
          ## Dev context (intentionally not surfaced in the admin UI):
          ## Outer gate is admin-only. Z-Wave JS UI's own login still
          ## appears inside; no native OIDC.
        };
        reverse-proxy = {
          enable = config.homefree.services.zwave-js-ui.enable;
          subdomains = [ "zwave" "zwavejs" ];
          http-domains = [ "homefree.lan" config.homefree.system.localDomain ];
          https-domains = [ config.homefree.system.domain ];
          host = config.homefree.network.lan-address;
          port = port-ui;
          ssl = false;
          public = config.homefree.services.zwave-js-ui.public;
          ## Admin-only gate: Z-Wave JS UI exposes the S2 security keys
          ## and the ability to add/remove paired devices. Leaking
          ## these keys compromises the entire mesh. Restrict to
          ## homefree-admin role.
          oauth2 = config.homefree.sso.per-service.zwave-js-ui.enable or true;
          require-admin-role = true;
        };
        backup = {
          paths = [
            containerDataPath
          ];
        };
        options-metadata = config.homefree.service-options.zwave-js-ui.options-metadata;
      }
    ];
  };
}
