{ config, lib, pkgs, ... }:
let
  version = "0.17.1";
  configVersion = "0.17-1";
  containerDataPath = "/var/lib/frigate";
  mediaPath = if config.homefree.service-options.frigate.media-path == null
    then "${containerDataPath}/media"
    else config.homefree.service-options.frigate.media-path;
  cameras-filtered = if config.homefree.service-options.frigate.cameras != null
    then lib.filter (camera: camera.enable == true) config.homefree.service-options.frigate.cameras
    else [];
  cameras-go2rtc = lib.filter (camera: camera.direct-stream == false) cameras-filtered;
  retain = config.homefree.service-options.frigate.retain;
  container-external-port = 5000;
  authenticated-port = 8971;
  unauthenticated-port = 5000;

  frigate-config = {
    version = configVersion;

    detectors = {
      coral = lib.mkIf config.homefree.service-options.frigate.enable-coral {
        type = "edgetpu";
        device = "usb";
        # num_threads = 3;
      };
    };

    detect = {
      enabled = true;
    };

    ffmpeg = lib.optionalAttrs (config.homefree.service-options.frigate.hwaccel-args != "") {
      hwaccel_args = config.homefree.service-options.frigate.hwaccel-args;
    };

    mqtt = {
      host = config.homefree.network.lan-address;
      port = 1883;
      topic_prefix = "frigate";
      ## Must be unique if running multiple instances
      client_id = "frigate";
      stats_interval = 60;
    };

    objects = {
      track = [
        "person"
        "bicycle"
        "dog"
        "cat"
      ];
    };

    record = {
      enabled = true;
      # ## Minutes
      # expire_interval = 60;
      continuous = {
        days = 3;
      };
      motion = {
        days = 14;
      };
      alerts = {
        retain = {
          days = 30;
          mode = "motion";
        };
      };
      detections = {
        retain = {
          days = 30;
          mode = "motion";
        };
      };
    };

    snapshots = {
      # Optional: Enable writing jpg snapshot to /media/frigate/clips (default: shown below)
      # This value can be set via MQTT and will be updated in startup based on retained value
      enabled = true;
      # Optional: print a timestamp on the snapshots (default: shown below)
      timestamp = false;
      # Optional: draw bounding box on the snapshots (default: shown below)
      bounding_box = false;
      # Optional: crop the snapshot (default: shown below)
      crop = false;
      # # Optional: height to resize the snapshot to (default: original size)
      # height = 175;
      # Optional: Camera override for retention settings (default: global values)
      retain = {
        # Required: Default retention days (default: shown below)
        default = 10;
        # Optional: Per object retention days
        objects = {
          person = 15;
        };
      };
    };

    birdseye = {
      enabled = true;
      mode = "continuous";
    };

    ## Re-encode using go2rtc. Some cameras output to old formats that
    ## record empty video data.
    ## See: https://github.com/blakeblackshear/frigate/discussions/19513
    go2rtc.streams = lib.listToAttrs (lib.map (camera: {
      name = camera.name;
      value = [
        "ffmpeg:${camera.path}#video=h264#audio=copy#audio=aac#hardware"
      ];
    }) cameras-go2rtc);

    cameras = lib.listToAttrs (lib.map (camera: {
      name = camera.name;
      value = {
        enabled = camera.enable;
        ffmpeg = {
          output_args = {
            record = "preset-record-generic-audio-aac";
          };
          inputs = [
            {
              input_args = "preset-rtsp-restream";
              path = if camera.direct-stream == true then
                camera.path
              else
                "rtsp://127.0.0.1:8554/${camera.name}";
              roles = [
                "audio"
                "detect"
                "record"
              ];
            }
          ];
        };
        detect = {
          width = camera.width;
          height = camera.height;
          fps = 5;
        };
      };
    }) cameras-filtered);
  };

  config-yaml = (pkgs.formats.yaml {}).generate "frigate-config.yaml" frigate-config;

  preStart = ''
    mkdir -p ${containerDataPath}/config
    mkdir -p ${mediaPath}

    ## @TODO: just mount this directly as readonly, no need to copy
    cp ${config-yaml} ${containerDataPath}/config/config.yaml
  '';

  userOptions = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "enable Frigate video recording service";
    };

    enable-coral = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "enable Google Coral AI processor";
    };

    public = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Open to public on WAN port";
    };

    media-path = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Location to save recording";
    };

    enable-backup-media = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether to backup records";
    };

    retain = lib.mkOption {
      type = lib.types.nullOr lib.types.int;
      default = null;
      description = "If specified, how long in DAYS to keep files before deleting. This applies to ALL files: clips, recordings, exports, etc.";
    };

    hwaccel-args = lib.mkOption {
      type = lib.types.str;
      default = "preset-intel-qsv-h264";
      description = ''
        ffmpeg hwaccel preset. Intel iGPU: "preset-intel-qsv-h264".
        AMD GPU: "preset-vaapi". Raspberry Pi: "-c:v h264_v4l2m2m".
        Nvidia: "preset-nvidia-h264". Empty string disables hwaccel.
      '';
    };

    cameras = lib.mkOption {
      description = "list of cameras";
      default = null;
      type = with lib.types; nullOr (listOf (submodule {
        options = {
          enable = lib.mkOption { type = lib.types.bool; default = true; description = "Camera enabled"; };
          name = lib.mkOption { type = lib.types.str; description = "Camera name"; };
          path = lib.mkOption { type = lib.types.str; description = "URL / path to camera"; };
          width = lib.mkOption { type = lib.types.int; default = 1920; description = "Width in pixels"; };
          height = lib.mkOption { type = lib.types.int; default = 1080; description = "Height in pixels"; };
          direct-stream = lib.mkOption { type = lib.types.bool; default = false; description = "Don't use go2rtc by default. Addresses certain issues, such as audio delay in recordings"; };
        };
      }));
    };
  };
in
  {
  options.homefree.services.frigate = userOptions;
  options.homefree.service-options.frigate = userOptions // {
    label = lib.mkOption {
      type = lib.types.str;
      default = "frigate";
      internal = true;
      description = "Service label";
    };

    name = lib.mkOption {
      type = lib.types.str;
      default = "NVR (Network Video Recorer)";
      internal = true;
      description = "Service display name";
    };

    project-name = lib.mkOption {
      type = lib.types.str;
      default = "Frigate";
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
          description = "Enable Frigate video surveillance";
        }
        {
          path = "public";
          type = "bool";
          default = false;
          description = "Make service accessible from WAN";
        }
        {
          path = "enable-coral";
          type = "bool";
          default = false;
          description = "Enable Google Coral TPU support";
        }
        {
          path = "media-path";
          type = "path";
          nullable = true;
          default = null;
          description = "Location for storing video recordings";
          ui-hint = "directory-picker";
        }
        {
          path = "enable-backup-media";
          type = "bool";
          default = false;
          description = "Include media files in backups (can be large)";
        }
        {
          path = "retain";
          type = "int";
          nullable = true;
          default = null;
          description = "Days to retain recordings before deletion";
          ui-hint = {
            min = 1;
            max = 365;
            unit = "days";
          };
        }
        {
          path = "cameras";
          type = "listOf submodule";
          nullable = true;
          default = null;
          description = "Camera configurations";
          submodule-fields = [
            {
              path = "enable";
              type = "bool";
              default = true;
              description = "Enable this camera";
            }
            {
              path = "name";
              type = "str";
              required = true;
              description = "Camera name/identifier";
            }
            {
              path = "path";
              type = "str";
              required = true;
              description = "RTSP URL or path to camera stream";
              ui-hint = "url-input";
            }
            {
              path = "width";
              type = "int";
              default = 1920;
              description = "Video width in pixels";
            }
            {
              path = "height";
              type = "int";
              default = 1080;
              description = "Video height in pixels";
            }
            {
              path = "direct-stream";
              type = "bool";
              default = false;
              description = "Don't use go2rtc by default (addresses audio delay issues)";
            }
          ];
        }
      ];
    };
  };

  config = {
    environment.systemPackages= [
    ## Google Coral (Edge TPU) USB Support
    pkgs.libedgetpu
  ];

  virtualisation.oci-containers.containers = lib.optionalAttrs config.homefree.service-options.frigate.enable {
    frigate = {
      image = "ghcr.io/blakeblackshear/frigate:${version}";

      autoStart = true;

      extraOptions = [
        # "--pull=always"
        ## 1GB of memory, reduces SSD/SD Card wear
        "--mount=type=tmpfs,target=/tmp/cache,tmpfs-size=1000000000"
        "--shm-size=512M"
        # "--network=bridge"
        "--device=/dev/bus/usb:/dev/bus/usb"  # Passes the USB Coral, needs to be modified for other versions
        # "--device=/dev/dri/card1:/dev/dri/card1" # For intel hwaccel, needs to be updated for your hardware
        # "--device=/dev/dri/renderD128:/dev/dri/renderD128" # For intel hwaccel, needs to be updated for your hardware
        "--device=/dev/dri:/dev/dri"
        "--cap-add=CAP_PERFMON" # For GPU statistics
        "--privileged"
      ];

      ports = [
        "0.0.0.0:${toString container-external-port}:${toString unauthenticated-port}"
        "8554:8554" # RTSP feeds
        "8555:8555/tcp" # WebRTC over tcp
        "8555:8555/udp" # WebRTC over udp
      ];

      volumes = [
        "/etc/localtime:/etc/localtime:ro"
        "${containerDataPath}/config:/config"
        ## @TODO: make this configurable
        "${mediaPath}:/media/frigate"
      ];

      environment = {
        TZ = config.homefree.system.timeZone;
      };
    };
  };

  systemd.services.podman-frigate = lib.optionalAttrs config.homefree.service-options.frigate.enable {
    after = [ "dns-ready.service" ];
    wants = [ "dns-ready.service" ];
    serviceConfig = {
      ExecStartPre = [ "!${pkgs.writeShellScript "frigate-prestart" preStart}" ];
    };
  };

  systemd.services.frigate-cleanup-old-data = lib.optionalAttrs (retain != null && retain > 0) {
    wantedBy = [];  # Only ever start with timer
    description = "Clean up Frigate files older than ${toString retain} days";
    serviceConfig = {
      Type = "oneshot";
      User = "root";  # Change if you need different permissions
      # ExecStart = ''${pkgs.findutils}/bin/find "${mediaPath}" -type f -mtime +${toString retain} -delete'';
      ExecStart = ''${pkgs.bash}/bin/bash -c "${pkgs.findutils}/bin/find \"${mediaPath}\" -type f -mtime +30 -print -delete | ${pkgs.coreutils}/bin/wc -l | ${pkgs.findutils}/bin/xargs -I {} echo \"Deleted files: {}\""'';
    };
    # Optional: Add some safety and logging
    serviceConfig.StandardOutput = "journal";
    serviceConfig.StandardError = "journal";
  };

  systemd.timers.frigate-cleanup-old-data = lib.optionalAttrs (retain != null && retain > 0) {
    enable = true;
    description = "Timer for cleaning up old Frigate files";
    timerConfig = {
      OnCalendar = "daily";
      # Alternative specific time format:
      # OnCalendar = "*-*-* 03:00:00";
      Persistent = true;  # Run missed timers on boot
      RandomizedDelaySec = "30min";  # Optional: add some randomization
    };
    wantedBy = [ "timers.target" ];
  };

  # systemd.services.podman-create-frigate-network = {
  #   serviceConfig.Type = "oneshot";
  #   wantedBy = [ "podman-frigate.service" ];
  #   script = ''
  #     podman network create -d ipvlan --subnet 10.0.0.0/24 --ip-range 10.0.99.0/24 --ipam-driver host-local podnet
  #   '';
  # };

    homefree.service-config = [{
      inherit (config.homefree.service-options.frigate) label name project-name;
      enable = config.homefree.service-options.frigate.enable;
      systemd-service-names = [
        "podman-frigate"
      ];
      sso = {
        kind = "caddy_gated";
        ## Dev context (intentionally not surfaced in the admin UI):
        ## Outer gate admin-only. Frigate's own login still appears
        ## inside; native OIDC bridge pending.
      };
      reverse-proxy = {
        enable = config.homefree.service-options.frigate.enable;
        subdomains = [ "nvr" "frigate" ];
        http-domains = [ "homefree.lan" config.homefree.system.localDomain ];
        https-domains = [ config.homefree.system.domain ];
        host = config.homefree.network.lan-address;
        port = container-external-port;
        ## Frigate exposes two ports: 5000 (plain HTTP, unauth) and
        ## 8971 (TLS, Frigate's own auth). We forward only port 5000
        ## in the container spec above, and the Caddy SSO+admin-role
        ## gate is the only auth layer — so the upstream is plain
        ## HTTP. Setting ssl=true here caused Caddy to try a TLS
        ## handshake against an HTTP listener: 502 "tls: first
        ## record does not look like a TLS handshake".
        ssl = false;
        public = config.homefree.service-options.frigate.public;
        ## Intercept Frigate's own logout endpoint and bounce
        ## through the full SSO sign-out chain. Without this,
        ## clicking "Sign out" inside Frigate clears Frigate's
        ## session cookie but the user is still SSO-authenticated
        ## at the Caddy perimeter, so the next page load just
        ## drops them back at Frigate's local login form.
        ##
        ## Frigate exposes both /logout (GET, per upstream docs)
        ## and /api/logout (the configurable default). Cover both
        ## so it works regardless of which one the UI calls.
        upstream-logout-paths = [ "/logout" "/api/logout" ];
        ## Frigate has no native OIDC. SSO-gated at Caddy: any
        ## signed-in homefree user can view cameras. We do NOT
        ## require the homefree-admin role — household members
        ## should be able to use the NVR UI without admin privileges.
        ## Frigate's own per-user roles (viewer/admin) still apply
        ## once the user passes the SSO gate and lands at Frigate's
        ## local login.
        oauth2 = config.homefree.sso.per-service.frigate.enable or true;
        require-admin-role = false;
      };
      backup = if config.homefree.service-options.frigate.enable-backup-media then {
        paths = [
          mediaPath
        ];
      } else {};
    }];
  };
}

