{ config, lib, pkgs, ... }:
let
  version = "version-v26.1";
  port = config.homefree.allocPort "nzbget";
  containerDataPath = "/var/lib/nzbget";
  configPath = "${containerDataPath}/config";
  downloadsPath = if config.homefree.service-options.nzbget.downloads-path != null
    then config.homefree.service-options.nzbget.downloads-path
    else "${containerDataPath}/downloads";
  preStart = ''
    mkdir -p ${configPath}
    mkdir -p ${downloadsPath}
  '';

  ## Custom updater for the admin page's Update button. The tracked
  ## "latest" is an upstream GitHub release tag (v26.1) while the pin is
  ## LinuxServer's repackaged tag scheme (version-v24.8) — and nzbget's
  ## yearly version jumps (24 -> 26) trip the generic cross-major guard.
  ## The app owns the translation: rewrite this file's `version` binding
  ## to LSIO's tag for the target release.
  ## Contract (see module.nix version-tracking.update-command):
  ##   $1 = writable checkout root, $2 = target version; last stdout
  ##   line is reported as the new value.
  nzbgetUpdater = pkgs.writeShellScript "nzbget-update" ''
    set -eu
    root="$1"
    target="$2"
    [ -n "$target" ] || { echo "no target version resolved" >&2; exit 1; }
    tag="version-v''${target#v}"
    file="$root/apps/nzbget/default.nix"
    ${pkgs.gnugrep}/bin/grep -q '^  version = "' "$file"
    ${pkgs.gnused}/bin/sed -i "0,/^  version = \"[^\"]*\";/s//  version = \"$tag\";/" "$file"
    echo "$tag"
  '';

  userOptions = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "enable NZBGet downloader";
    };

    public = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Open to public on WAN port";
    };

    downloads-path = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Location of downloads";
    };

    enable-backup-media = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether to backup media";
    };
  };
in
{
  options.homefree.services.nzbget = userOptions;
  options.homefree.service-options.nzbget = userOptions // {
    label = lib.mkOption {
      type = lib.types.str;
      default = "nzbget";
      internal = true;
      description = "Service label";
    };

    name = lib.mkOption {
      type = lib.types.str;
      default = "NZB Downloader";
      internal = true;
      description = "Service display name";
    };

    project-name = lib.mkOption {
      type = lib.types.str;
      default = "NZBGet";
      internal = true;
      description = "Project name";
    };
  };

  config = {
  ## Container via the app-platform primitive (modules/app-platform.nix).
  ## LinuxServer image with a GENERIC PUID (1000): createUser = false so the
  ## generator emits PUID/PGID but makes no dedicated system user (uid 1000 is
  ## the host admin).
  homefree.containers.nzbget = lib.mkIf config.homefree.service-options.nzbget.enable {
    image = "lscr.io/linuxserver/nzbget:${version}";
    runAs = { mode = "linuxserver"; uid = 1000; gid = 100; createUser = false; };

    ports = [
      "0.0.0.0:${toString port}:6789"
    ];

    volumes = [
      "/etc/localtime:/etc/localtime:ro"
      "${configPath}:/config"
      "${downloadsPath}:/downloads"
    ];

    environment = {
      TZ = config.homefree.system.timeZone;
    };

    preStartInit = ''
      mkdir -p ${configPath}
      mkdir -p ${downloadsPath}
    '';
  };

    homefree.service-config = [{
      inherit (config.homefree.service-options.nzbget) label name project-name;
      port-request = null;
      enable = config.homefree.service-options.nzbget.enable;
      ## LinuxServer's `version-vNN.N` tag shares no shape with the upstream
      ## GitHub releases (`vNN.N`), so track the source repo directly and
      ## anchor on the clean version derived from the pin (loose compare
      ## tolerates the v / version-v difference). The Update button runs
      ## the custom updater above, which writes the LSIO-translated tag.
      version-tracking = {
        strategy = "github-releases";
        repo = "nzbgetcom/nzbget";
        current-version = lib.removePrefix "version-v" version;
        update-command = nzbgetUpdater;
      };
      sso = {
        kind = "none";
        applicable = false;
        ## Dev context (intentionally not surfaced in the admin UI):
        ## NZBGet exposes its JSON-RPC API on the same host:port as the
        ## UI, authenticated with HTTP Basic only. *arr-stack services
        ## and external scripts talk to that API directly — a site-wide
        ## SSO gate would break every integration. Use NZBGet's
        ## built-in auth.
      };
      systemd-service-names = [
        "podman-nzbget"
      ];
      reverse-proxy = {
        enable = config.homefree.service-options.nzbget.enable;
        subdomains = [ "nzbget" ];
        http-domains = [ "homefree.lan" config.homefree.system.localDomain ];
        https-domains = [ config.homefree.system.domain ];
        host = config.homefree.network.lan-address;
        port = port;
        public = config.homefree.service-options.nzbget.public;
        ## NOTE: NZBGet is intentionally NOT SSO-gated yet. UI and
        ## API share a host; gating would 302 API calls (used by
        ## Sonarr/Radarr) into the SSO flow. Same Phase-A treatment
        ## needed as Lidarr: split API onto its own subdomain.
      };
      backup = lib.optionalAttrs config.homefree.service-options.nzbget.enable-backup-media {
        paths = [
          downloadsPath
        ];
      };
      options-metadata = [
        {
          path = "enable";
          type = "bool";
          default = false;
          description = "Enable NZBGet usenet downloader";
        }
        {
          path = "public";
          type = "bool";
          default = false;
          description = "Make service accessible from WAN";
        }
        {
          path = "downloads-path";
          type = "path";
          nullable = true;
          default = null;
          description = "Location of downloads";
          ui-hint = "directory-picker";
        }
        {
          path = "enable-backup-media";
          type = "bool";
          default = true;
          description = "Whether to backup downloads";
        }
      ];
    }];
  };
}
