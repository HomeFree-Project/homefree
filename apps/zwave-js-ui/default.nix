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
  version = "11.20.0";

  containerDataPath = "/var/lib/zwave-js-ui";
  seedDir = "/var/lib/homefree-secrets/zwave-js-ui/seed";

  port-ui = 8091;
  port-ws = 3001;  ## Note: 3000 conflicts with AdGuardHome on a stock HomeFree

  ## /dev/serial/by-id/* is stable across reboots; the device id varies
  ## per stick (e.g. usb-0658_0200-if00 for an Aeotec Z-Stick Gen5).
  ## Instance config sets this. It is OPTIONAL: a missing deviceId must
  ## not fail the build (Z-Wave is an optional peripheral, and the box may
  ## be built before the stick is attached) — the container then starts
  ## WITHOUT the USB bind and the UI loads with no controller, with a
  ## build warning (see `warnings` below) instead of an assertion.
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
    ## Optional-peripheral degradation: enabling the service without a
    ## deviceId WARNS (not fails). The container still builds and runs;
    ## the web UI is reachable but has no controller bound until the stick
    ## is attached and deviceId is set + rebuilt. See the conditional
    ## `--device` bind below.
    warnings = lib.optional
      (config.homefree.services.zwave-js-ui.enable && deviceId == "")
      ''
        homefree.service-options.zwave-js-ui is enabled but deviceId is
        unset — Z-Wave JS UI will start WITHOUT a controller. The UI is
        reachable but cannot manage a Z-Wave network until you attach the
        USB controller, set deviceId (find it with `ls /dev/serial/by-id/`),
        and rebuild.
      '';

    ## Container via the app-platform primitive (modules/app-platform.nix).
    ## The dns-ready podman unit ordering and ExecStartPre are generated;
    ## this declares only the zwave-js-ui-specific data.
    homefree.containers.zwave-js-ui = lib.mkIf config.homefree.services.zwave-js-ui.enable {
      ## zwavejs/zwave-js-ui runs as root internally and requires access
      ## to the USB Z-Wave stick via --device.
      runAs = {
        mode = "root";
        reason = "image runs as root; needs direct USB device access via --device";
      };
      image = "zwavejs/zwave-js-ui:${version}";

      ## preStart has set -eu + conditional seed logic; dataDir = null
      ## and the full preStart goes in preStartInit.
      dataDir = null;
      preStartInit = ''
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

      ## Only bind the USB controller when a deviceId is configured.
      ## Without it the container runs deviceless (UI up, no Z-Wave net) —
      ## podman would otherwise exit 125 trying to mount a nonexistent
      ## /dev/serial/by-id/ path.
      extraOptions = [
        "--network=host"
      ] ++ lib.optional (deviceId != "") "--device=${deviceArg}";

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
