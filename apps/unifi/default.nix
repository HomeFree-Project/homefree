{ config, lib, pkgs, ... }:
let
  userOptions = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "enable Unifi controller";
    };

    public = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Open to public on WAN port";
    };
  };

  version = "v1.3.0";
  containerDataPath = "/var/lib/unifi-os-podman";
  port = config.homefree.allocPort "unifi";

  enable = config.homefree.services.unifi.enable;
in
{
  ## Admin-UI metadata namespace. The user-facing schema is declared
  ## in module.nix as `homefree.services.unifi`; module.nix's generic
  ## `intersectAttrs` mirror projects each user-facing service into
  ## `homefree.service-options.<name>` so admin-web can build its UI.
  ## That projection only includes services that have a matching
  ## `service-options.<name>` declaration here.
  options.homefree.services.unifi = userOptions;
  options.homefree.service-options.unifi = userOptions // {
    label = lib.mkOption {
      type = lib.types.str;
      default = "unifi";
      internal = true;
      description = "Service label";
    };

    name = lib.mkOption {
      type = lib.types.str;
      default = "UniFi OS";
      internal = true;
      description = "Service display name";
    };

    project-name = lib.mkOption {
      type = lib.types.str;
      default = "UniFi OS Server";
      internal = true;
      description = "Project name";
    };
  };

  config = {

  ## Container via the app-platform primitive (modules/app-platform.nix).
  ## SKIPPED non-root: the unifi-os-server image runs systemd as PID 1 inside
  ## the container and requires --cgroupns=host + /sys/fs/cgroup bind mount +
  ## NET_RAW/NET_ADMIN caps. Setting user= would break in-container systemd.
  ## TimeoutStopSec=180 escape-hatch below (merged onto the generated unit).
  homefree.containers.unifi-os = lib.mkIf enable {
    image = "ghcr.io/lemker/unifi-os-server:${version}";
    runAs = {
      mode = "root";
      reason = "image runs systemd as PID 1 with --cgroupns=host + cgroup bind mount; user= breaks in-container systemd";
    };

    extraOptions = [
      # "--pull=always"
      # UniFi OS Server runs systemd as PID 1 inside the container. The
      # canonical recipe (upstream docker-compose.yaml at
      # https://github.com/lemker/unifi-os-server/blob/main/docker-compose.yaml)
      # is two caps + host cgroup namespace + a cgroup bind mount — NOT
      # --privileged. We deliberately do not use --privileged: with it,
      # podman bind-mounts host /dev into the container, the image's
      # in-container systemd starts agetty@ttyN against /dev/tty1..6,
      # races the host getty, and the physical console flips to
      # `uos login:`. That's a recovery-surface failure (AGENTS.md
      # rule 10) — the maintainer had to reboot to an older generation
      # to reclaim tty1. The cgroupns=host + /sys/fs/cgroup bind below
      # is the documented modern (cgroup v2) way to give an in-container
      # systemd the cgroup access it needs without granting it the host
      # device tree.
      "--cap-add=NET_RAW"
      "--cap-add=NET_ADMIN"
      "--cgroupns=host"
      "--add-host=host.docker.internal:host-gateway"
      "--stop-signal=SIGRTMIN+3"
      # `exec` on /run and /tmp: systemd drops helper binaries into
      # these and execs them; default tmpfs is `noexec` under podman.
      "--mount=type=tmpfs,target=/run,tmpfs-size=104857600,exec"
      "--mount=type=tmpfs,target=/run/lock,tmpfs-size=104857600"
      "--mount=type=tmpfs,target=/tmp,tmpfs-size=104857600,exec"
    ];

    ports = [
      ## Web interface / GUI / API (HTTPS)
      "0.0.0.0:${toString port}:443"

      ## Device and application communication
      "0.0.0.0:8080:8080"

      ## STUN port - disabled to not conflict with Headscale DERP
      # "0.0.0.0:3478:3478/udp"

      ## Device discovery during adoption
      "0.0.0.0:10001:10001/udp"

      ## Device discovery (UOS additional port)
      "0.0.0.0:10003:10003/udp"

      ## Used with "Make application discoverable on L2 network" in the UniFi Network settings.
      ## Conflicts with Jellyfin DLNA discovery
      # "0.0.0.0:1900:1900/udp"

      ## HTTPS portal redirection (only needed if using Guest hotspot)
      "0.0.0.0:8843:8843"

      ## HTTP hotspot redirection
      "0.0.0.0:8880:8880"

      ## UniFi mobile speed test
      "0.0.0.0:6789:6789"

      ## Remote syslog capture
      "0.0.0.0:5514:5514/udp"
    ];

    volumes = [
      "/etc/localtime:/etc/localtime:ro"
      # Required pair with --cgroupns=host above: in-container systemd
      # writes to the cgroup tree it sees here. Without this bind mount
      # (or with --privileged, which implicitly provides it), starting
      # systemd-managed services inside the container fails with
      # cgroup-mount errors.
      "/sys/fs/cgroup:/sys/fs/cgroup:rw"
      "${containerDataPath}/data:/data"
      "${containerDataPath}/unifi:/var/lib/unifi"
      "${containerDataPath}/mongodb:/var/lib/mongodb"
      "${containerDataPath}/logs:/var/log"
      "${containerDataPath}/persistent:/persistent"
      "${containerDataPath}/journal:/var/lib/journal"
      "${containerDataPath}/rabbitmq-ssl:/etc/rabbitmq/ssl"
      "${containerDataPath}/unifi-tmp:/var/opt/unifi/tmp"
    ];

    environment = {
      TZ = config.homefree.system.timeZone;
      UOS_SYSTEM_IP = config.homefree.network.lan-address;
    };

    ## Multiple independent subdirs — emit them verbatim (no single dataDir).
    preStartInit = ''
      mkdir -p ${containerDataPath}/data
      mkdir -p ${containerDataPath}/unifi
      mkdir -p ${containerDataPath}/mongodb
      mkdir -p ${containerDataPath}/logs
      mkdir -p ${containerDataPath}/persistent
      mkdir -p ${containerDataPath}/journal
      mkdir -p ${containerDataPath}/rabbitmq-ssl
      mkdir -p ${containerDataPath}/unifi-tmp
    '';
  };

  ## Escape hatch: TimeoutStopSec not covered by the app-platform descriptor.
  ## Merged onto the generated podman-unifi-os unit.
  systemd.services.podman-unifi-os = lib.mkIf enable {
    serviceConfig = {
      TimeoutStopSec = lib.mkForce 180;
    };
  };

  homefree.service-config = if config.homefree.services.unifi.enable == true then [
    {
      label = "unifi";
      port-request = 11443;
      name = "UniFi OS";
      project-name = "UniFi OS Server";
      ## ghcr.io/lemker/unifi-os-server is a community repackaging; its
      ## releases live on the source GitHub repo, so track that directly.
      version-tracking = {
        strategy = "github-releases";
        repo = "lemker/unifi-os-server";
      };
      systemd-service-names = [
        "podman-unifi-os"
      ];
      reverse-proxy = {
        enable = true;
        subdomains = [ "unifi" ];
        http-domains = [ "homefree.lan" config.homefree.system.localDomain ];
        https-domains = [ config.homefree.system.domain ];
        host = config.homefree.network.lan-address;
        port = port;
        ssl = true;
        ssl-no-verify = true;
        public = config.homefree.services.unifi.public;
      };
      backup = {
        paths = [
          containerDataPath
        ];
      };
    }
  ] else [];
  };
}
