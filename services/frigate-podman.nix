{ config, lib, pkgs, ... }:
let
  version = "0.17.0-rc2";
  configVersion = "0.17-1";
  containerDataPath = "/var/lib/frigate";
  mediaPath = config.homefree.services.frigate.media-path or "${containerDataPath}/media";
  cameras-filtered = lib.filter (camera: camera.enable == true) config.homefree.services.frigate.cameras;
  cameras-go2rtc = lib.filter (camera: camera.direct-stream == false) cameras-filtered;
  retain = config.homefree.services.frigate.retain;

  frigate-config = {
    version = configVersion;

    detectors = {
      coral = {
        type = "edgetpu";
        device = "usb";
        # num_threads = 3;
      };
    };

    detect = {
      enabled = true;
    };

    ffmpeg = {
      ## Intel
      hwaccel_args = "preset-intel-qsv-h264";

      ## Raspberry Pi
      # hwaccel_args = "-c:v h264_v4l2m2m";
    };

    mqtt = {
      host = "10.0.0.1";
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
in
  {
    environment.systemPackages= [
    ## Google Coral (Edge TPU) USB Support
    pkgs.libedgetpu
  ];

  virtualisation.oci-containers.containers = if config.homefree.services.frigate.enable == true then {
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
        "--device=/dev/dri/card1:/dev/dri/card1" # For intel hwaccel, needs to be updated for your hardware
        "--device=/dev/dri/renderD128:/dev/dri/renderD128" # For intel hwaccel, needs to be updated for your hardware
        "--cap-add=CAP_PERFMON" # For GPU statistics
        "--privileged"
      ];

      ports = [
        "0.0.0.0:8971:8971"
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
  } else {};

  systemd.services.podman-frigate = {
    after = [ "dns-ready.service" ];
    requires = [ "dns-ready.service" ];
    partOf =  [ "nftables.service" ];
    serviceConfig = {
      ExecStartPre = [ "!${pkgs.writeShellScript "frigate-prestart" preStart}" ];
    };
  };

  systemd.services.frigate-cleanup-old-data = if retain != null && retain > 0 then {
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
  } else {};

  systemd.timers.frigate-cleanup-old-data = if retain != null && retain > 0 then {
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
  } else {};

  # systemd.services.podman-create-frigate-network = {
  #   serviceConfig.Type = "oneshot";
  #   wantedBy = [ "podman-frigate.service" ];
  #   script = ''
  #     podman network create -d ipvlan --subnet 10.0.0.0/24 --ip-range 10.0.99.0/24 --ipam-driver host-local podnet
  #   '';
  # };

  homefree.service-config = if config.homefree.services.frigate.enable == true then [
    {
      label = "frigate";
      name = "NVR (Network Video Recorer)";
      project-name = "Frigate";
      systemd-service-names = [
        "podman-frigate"
      ];
      reverse-proxy = {
        enable = true;
        subdomains = [ "nvr" "frigate" ];
        http-domains = [ "homefree.lan" config.homefree.system.localDomain ];
        https-domains = [ config.homefree.system.domain ];
        host = "10.0.0.1";
        port = 8971;
        ssl = true;
        ssl-no-verify = true;
        public = config.homefree.services.frigate.public;
      };
      backup = if config.homefree.services.frigate.enable-backup-media then {
        paths = [
          mediaPath
        ];
      } else {};
    }
  ] else [];
}

