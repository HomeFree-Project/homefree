{ config, lib, pkgs, ... }:
let
  version = "version-v26.2";
  port = config.homefree.allocPort "nzbget";
  containerDataPath = "/var/lib/nzbget";
  configPath = "${containerDataPath}/config";
  downloadsPath = if config.homefree.service-options.nzbget.downloads-path != null
    then config.homefree.service-options.nzbget.downloads-path
    else "${containerDataPath}/downloads";
  credentialsEnvFile = "${containerDataPath}/credentials.env";

  ## Anchors auto-generated secrets into encrypted /etc/nixos/secrets
  ## so they survive a restore — see lib/secrets-anchor.nix.
  anchor = import ../../lib/secrets-anchor.nix { inherit lib pkgs; };
  nzbgetSecretsDir = "/var/lib/homefree-secrets/nzbget";

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

    ## NZBGET_USER/NZBGET_PASS (-> ControlUsername/ControlPassword in the
    ## LinuxServer image's init) are carried in a runtime env-file that
    ## preStartInit generates from the anchored control-password — keeps
    ## the cleartext out of the world-readable Nix store. Mirrors the
    ## snipe-it runtime.env pattern.
    environmentFiles = [ credentialsEnvFile ];

    preStartInit = ''
      mkdir -p ${configPath}
      mkdir -p ${downloadsPath}
      mkdir -p ${nzbgetSecretsDir}
      chmod 700 ${nzbgetSecretsDir}

      ${anchor.preamble}

      ## Per-install NZBGet control password, anchored into encrypted
      ## /etc/nixos/secrets so it survives a restore (replaces the
      ## LinuxServer image's well-known default 'tegbzn6789'). Caddy
      ## injects this as HTTP Basic after the SSO gate so the user never
      ## sees NZBGet's own login (see services/caddy).
      ${anchor.anchorSecret {
        service = "nzbget";
        key = "control-password";
        dir = nzbgetSecretsDir;
        mkdirMode = null;
        mode = "400";
        generate = "${pkgs.openssl}/bin/openssl rand -base64 32 | tr -d '\\n'";
      }}

      ## Runtime env-file the container reads (NZBGET_USER/NZBGET_PASS).
      ## Username matches the operator's admin login for emergency
      ## direct-LAN access; falls back to 'nzbget' pre-provisioning.
      NZBGET_CTRL_USER=$(cat /var/lib/homefree-admin/admin-username 2>/dev/null || true)
      [ -n "$NZBGET_CTRL_USER" ] || NZBGET_CTRL_USER=nzbget
      install -m 600 /dev/null ${credentialsEnvFile}
      {
        printf 'NZBGET_USER=%s\n' "$NZBGET_CTRL_USER"
        printf 'NZBGET_PASS=%s\n' "$(cat ${nzbgetSecretsDir}/control-password)"
      } > ${credentialsEnvFile}

      ## Refresh Caddy's Basic-Auth bridge so the injected header tracks
      ## the current credential, then reload Caddy. --no-block + no-op
      ## guards keep this safe pre-boot / when Caddy isn't up yet.
      systemctl restart --no-block caddy-nzbget-basic-auth.service 2>/dev/null || true
      systemctl reload --no-block caddy.service 2>/dev/null || true
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
        kind = "basic_auth";
        ## NZBGet has no native OIDC. Caddy's SSO gate (admin-only)
        ## validates the user, then injects NZBGet's managed Basic
        ## credential so the user never sees NZBGet's own login — same
        ## model as AdGuard. The JSON-RPC API shares the UI's host:port,
        ## so the whole vhost is gated; non-browser API clients
        ## (Sonarr/Radarr/scripts) reach NZBGet via the direct LAN
        ## IP:port, which bypasses Caddy entirely.
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
        ## Gate the whole vhost at the Caddy layer via oauth2-proxy
        ## (NZBGet has no native OIDC). Per-service opt-out via
        ## homefree.sso.per-service.nzbget.enable=false.
        oauth2 = config.homefree.sso.per-service.nzbget.enable or true;
        ## NZBGet is an admin tool (downloader config, queue control).
        ## Restrict to users carrying the homefree-admin role; non-admin
        ## authenticated users hit a 403 at the Caddy gate.
        require-admin-role = true;
        ## After SSO succeeds, inject NZBGet's managed control credential
        ## as HTTP Basic so the user never sees NZBGet's local login. The
        ## env var is populated by caddy-nzbget-basic-auth.service
        ## (services/caddy) from
        ## /var/lib/homefree-secrets/nzbget/control-password.
        inject-basic-auth-env = "NZBGET_BASIC_AUTH";
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
