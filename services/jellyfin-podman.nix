{ config, lib, pkgs, ... }:
let
  containerDataPath = "/var/lib/jellyfin-podman";
  media-path = if config.homefree.services.jellyfin.media-path == null
    then "${containerDataPath}/media"
    else config.homefree.services.jellyfin.media-path;

  preStart = ''
    mkdir -p ${containerDataPath}
    mkdir -p ${containerDataPath}/media
  '';

  port = 8096;
  version = "10.10.7";
in
{
  ##--------------------------------------------------------------------------------
  ## Enable hardware transcoding
  ## Only works on Intel
  ## @TODO: Move to hardware config
  ## @TODO: Add flags for which capabilities are needed by each service
  ##--------------------------------------------------------------------------------

  ## enable vaapi on OS-level
  nixpkgs.config.packageOverrides = pkgs: (lib.optionalAttrs config.homefree.services.jellyfin.enable {
    vaapiIntel = pkgs.vaapiIntel.override { enableHybridCodec = true; };
  });

  hardware.graphics = lib.optionalAttrs config.homefree.services.jellyfin.enable {
    enable = true;
    extraPackages = with pkgs; [
      intel-media-driver
      intel-vaapi-driver # previously vaapiIntel
      libva-vdpau-driver
      intel-compute-runtime # OpenCL filter support (hardware tonemapping and subtitle burn-in)
      vpl-gpu-rt # QSV on 11th gen or newer
      ## Insecure
      ## @TODO: Re-enable!!!
      # intel-media-sdk # QSV up to 11th gen
    ];
  };

  virtualisation.oci-containers.containers = lib.optionalAttrs config.homefree.services.jellyfin.enable {
    jellyfin = {
      image = "linuxserver/jellyfin:${version}";

      autoStart = true;

      extraOptions = [
        # "--pull=always"
        ## 1GB of memory, reduces SSD/SD Card wear
        "--mount=type=tmpfs,target=/tmp/cache,tmpfs-size=1000000000"
        "--device=/dev/dri:/dev/dri"
        "--cap-add=CAP_PERFMON" # For GPU statistics
        # "--privileged"
      ];

      ports = [
        ## HTTP
        "0.0.0.0:${toString port}:8096"
        ## HTTPS
        # "0.0.0.0:8920:8920" #optional
        ## Local network discovery
        "0.0.0.0:7359:7359/udp" #optional
        ## DLNA service discovery
        "0.0.0.0:1900:1900/udp" #optional
      ];

      volumes = [
        "/etc/localtime:/etc/localtime:ro"
        "${containerDataPath}:/config"
        "${media-path}:/data"
      ];

      environment = {
        TZ = config.homefree.system.timeZone;
        JELLYFIN_PublishedServerUrl = "https://media.${config.homefree.system.domain}";
      };
    };
  };

  systemd.services.podman-jellyfin = lib.optionalAttrs config.homefree.services.jellyfin.enable {
    after = [ "dns-ready.service" ];
    requires = [ "dns-ready.service" ];
    partOf =  [ "nftables.service" ];
    serviceConfig = {
      ExecStartPre = [ "!${pkgs.writeShellScript "jellyfin-prestart" preStart}" ];
    };
  };

  homefree.service-config = lib.optionals config.homefree.services.jellyfin.enable [
    {
      label = "jellyfin";
      name = "Streaming Media";
      project-name = "Jellyfin";
      systemd-service-names = [
        "podman-jellyfin"
      ];
      reverse-proxy = {
        enable = true;
        subdomains = [ "media" "video" "jellyfin" ];
        http-domains = [ "homefree.lan" config.homefree.system.localDomain ];
        https-domains = [ config.homefree.system.domain ];
        host = config.homefree.network.lan-address;
        port = port;
        public = config.homefree.services.jellyfin.public;
      };
      backup = {
        paths = [
          containerDataPath
        ];
      };
    }
  ];
}
