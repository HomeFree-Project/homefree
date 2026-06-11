{ config, lib, pkgs, ... }:
let
  containerDataPath = "/var/lib/jellyfin-podman";
  media-path = if config.homefree.service-options.jellyfin.media-path == null
    then "${containerDataPath}/media"
    else config.homefree.service-options.jellyfin.media-path;

  ## LinuxServer image, PUID/PGID pattern. s6-overlay stays as root
  ## inside the container but the actual Jellyfin process runs as
  ## this uid. Hardware transcoding needs /dev/dri access, which on
  ## NixOS is split between the `video` (card0) and `render`
  ## (renderD128) groups — we add both via --group-add below.
  jellyfinUid = 811;
  jellyfinGid = 811;

  port = config.homefree.allocPort "jellyfin";
  version = "10.11.11";

  enable = config.homefree.service-options.jellyfin.enable;

  userOptions = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "enable Jellyfin media server";
    };

    public = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Open to public on WAN port";
    };

    media-path = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Location of media files";
    };
  };
in
{
  options.homefree.services.jellyfin = userOptions;
  options.homefree.service-options.jellyfin = userOptions // {
    label = lib.mkOption {
      type = lib.types.str;
      default = "jellyfin";
      internal = true;
      description = "Service label";
    };

    name = lib.mkOption {
      type = lib.types.str;
      default = "Streaming Media";
      internal = true;
      description = "Service display name";
    };

    project-name = lib.mkOption {
      type = lib.types.str;
      default = "Jellyfin";
      internal = true;
      description = "Project name";
    };
  };

  config = {
  ##--------------------------------------------------------------------------------
  ## Enable hardware transcoding
  ## Only works on Intel
  ## @TODO: Move to hardware config
  ## @TODO: Add flags for which capabilities are needed by each service
  ##--------------------------------------------------------------------------------

  ## enable vaapi on OS-level
  nixpkgs.config.packageOverrides = pkgs: (lib.optionalAttrs enable {
    vaapiIntel = pkgs.vaapiIntel.override { enableHybridCodec = true; };
  });

  hardware.graphics = lib.optionalAttrs enable {
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

  ## Container via app-platform (modules/app-platform.nix). The dedicated
  ## system user/group (uid/gid 811), PUID/PGID env injection, dataDir mkdir,
  ## dns-ready ordering, and podman unit wiring are all generated from this
  ## descriptor.
  homefree.containers.jellyfin = lib.mkIf enable {
    image = "lscr.io/linuxserver/jellyfin:${version}";

    ## LinuxServer PUID/PGID: s6-overlay starts as root then drops to
    ## PUID:PGID. The platform creates the dedicated system user/group
    ## and injects PUID/PGID env automatically.
    runAs = { mode = "linuxserver"; uid = jellyfinUid; gid = jellyfinGid; };
    dataDir = containerDataPath;

    ## Marker-gated full-tree chown to the dedicated jellyfin UID.
    ## The LSIO entrypoint chowns /config on first start when PUID
    ## changes, but its chown has been observed to miss deep
    ## descendants (jellyfin.db left at uid 911 after switching
    ## PUID=811 in Phase 3, breaking the SQLite write path). A
    ## host-side chown -R once per UID change is the reliable fix.
    ## Marker file gates so subsequent boots are a no-op even on a
    ## multi-TB library; remove the marker to force re-chown.
    preStartInit = ''
      mkdir -p ${containerDataPath}/media
      if [ ! -f ${containerDataPath}/.chowned-${toString jellyfinUid} ]; then
        chown -R ${toString jellyfinUid}:${toString jellyfinGid} ${containerDataPath}
        touch ${containerDataPath}/.chowned-${toString jellyfinUid}
      fi
    '';

    extraOptions = [
      ## 1GB of memory, reduces SSD/SD Card wear
      "--mount=type=tmpfs,target=/tmp/cache,tmpfs-size=1000000000"
      "--device=/dev/dri:/dev/dri"
      "--cap-add=CAP_PERFMON" # For GPU statistics
      ## Supplementary groups so the Jellyfin process can access
      ## /dev/dri/card0 (video) and /dev/dri/renderD128 (render).
      ## Looked up from NixOS's config — falls back gracefully if a
      ## group isn't declared on this box.
      "--group-add=${toString config.users.groups.video.gid}"
      "--group-add=${toString (config.users.groups.render.gid or 303)}"
    ];

    ports = [
      ## HTTP
      "0.0.0.0:${toString port}:8096"
      ## HTTPS
      # "0.0.0.0:8920:8920" #optional
      ## Jellyfin client auto-discovery (7359/udp) and DLNA SSDP
      ## (1900/udp) are deliberately omitted. 1900/udp conflicts
      ## with Home Assistant's SSDP integration, which binds 1900
      ## by default for device discovery. Modern Jellyfin clients
      ## connect via HTTPS to the reverse-proxied subdomain rather
      ## than discovering over UDP, so these mappings are dead
      ## weight on a HomeFree box. Re-enable in a downstream
      ## override only if you explicitly need DLNA broadcasting
      ## to legacy smart-TV menus.
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

    homefree.service-config = [{
      inherit (config.homefree.service-options.jellyfin) label name project-name;
      port-request = 8096;
      enable = config.homefree.service-options.jellyfin.enable;
      sso = {
        kind = "none";
        applicable = false;
        ## Dev context (intentionally not surfaced in the admin UI):
        ## Jellyfin's mobile, TV, and desktop clients authenticate with
        ## Jellyfin's native username/password — they do not speak
        ## OIDC. A site-wide SSO gate would lock every client out.
        ## Native OIDC is plugin-based (Jellyfin.Plugin.SSO) and
        ## brittle to wire declaratively. Use Jellyfin's built-in
        ## users.
      };
      systemd-service-names = [
        "podman-jellyfin"
      ];
      reverse-proxy = {
        enable = config.homefree.service-options.jellyfin.enable;
        subdomains = [ "media" "video" "jellyfin" ];
        http-domains = [ "homefree.lan" config.homefree.system.localDomain ];
        https-domains = [ config.homefree.system.domain ];
        host = config.homefree.network.lan-address;
        port = port;
        public = config.homefree.service-options.jellyfin.public;
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
          description = "Enable Jellyfin media server";
        }
        {
          path = "public";
          type = "bool";
          default = false;
          description = "Make service accessible from WAN";
        }
        {
          path = "media-path";
          type = "path";
          nullable = true;
          default = null;
          description = "Location of media files";
          ui-hint = "directory-picker";
        }
      ];
    }];
  };
}
