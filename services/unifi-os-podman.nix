{ config, lib, pkgs, ... }:
let
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
  virtualisation.oci-containers.containers = if config.homefree.services.unifi-os.enable == true then {
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
        UOS_SYSTEM_IP = "10.0.0.1";
      };
    };
  } else {};

  systemd.services.podman-unifi-os = {
    after = [ "dns-ready.service" ];
    requires = [ "dns-ready.service" ];
    partOf =  [ "nftables.service" ];
    serviceConfig = {
      ExecStartPre = [ "!${pkgs.writeShellScript "unifi-os-prestart" preStart}" ];
      TimeoutStopSec = lib.mkForce 180;
    };
  };

  homefree.service-config = if config.homefree.services.unifi-os.enable == true then [
    {
      label = "unifi-os";
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
        host = "10.0.0.1";
        port = port;
        ssl = true;
        ssl-no-verify = true;
        public = config.homefree.services.unifi-os.public;
      };
      backup = {
        paths = [
          containerDataPath
        ];
      };
    }
  ] else [];
}
