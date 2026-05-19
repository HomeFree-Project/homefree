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

  version = "v1.0.0";
  containerDataPath = "/var/lib/unifi-os-podman";
  port = 11443;

  preStart = ''
    mkdir -p ${containerDataPath}/data
    mkdir -p ${containerDataPath}/unifi
    mkdir -p ${containerDataPath}/mongodb
    mkdir -p ${containerDataPath}/logs
    mkdir -p ${containerDataPath}/persistent
    mkdir -p ${containerDataPath}/journal
    mkdir -p ${containerDataPath}/rabbitmq-ssl
    mkdir -p ${containerDataPath}/unifi-tmp
  '';
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

  virtualisation.oci-containers.containers = if config.homefree.services.unifi.enable == true then {
    unifi-os = {
      image = "ghcr.io/lemker/unifi-os-server:${version}";

      autoStart = true;

      extraOptions = [
        # "--pull=always"
        "--privileged"
        "--stop-signal=SIGRTMIN+3"
        "--mount=type=tmpfs,target=/run,tmpfs-size=104857600"
        "--mount=type=tmpfs,target=/run/lock,tmpfs-size=104857600"
        "--mount=type=tmpfs,target=/tmp,tmpfs-size=104857600"
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
    };
  } else {};

  systemd.services.podman-unifi-os = {
    after = [ "dns-ready.service" ];
    wants = [ "dns-ready.service" ];
    serviceConfig = {
      ExecStartPre = [ "!${pkgs.writeShellScript "unifi-os-prestart" preStart}" ];
      TimeoutStopSec = lib.mkForce 180;
    };
  };

  homefree.service-config = if config.homefree.services.unifi.enable == true then [
    {
      label = "unifi";
      name = "UniFi OS";
      project-name = "UniFi OS Server";
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
