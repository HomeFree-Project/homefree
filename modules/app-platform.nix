## Container app-platform primitive.
##
## Collapses the per-CONTAINER skeleton that ~33 app modules each hand-rolled:
## a dedicated system user/group, the marker-gated recursive chown of the
## bind-mounted data dir, CA-bundle synthesis (system roots + Caddy's local CA)
## for in-container OIDC discovery, the oci-container declaration, and the
## `podman-<name>` unit ordered after `dns-ready`.
##
## The unit of duplication is the CONTAINER, not the app — so an app declares
## ONE entry per container under `homefree.containers.<name>`:
##   * single-container apps (homebox)        -> 1 entry
##   * multi-container apps (immich, nextcloud) -> several entries
##   * non-container apps (headscale)          -> 0 entries (host service instead)
##
## An app's INGRESS / backup / SSO / catalog presence is workload-agnostic and
## stays in its `homefree.service-config` entry — separate from this, because a
## 3-container app still has a single service-config entry and a host-service
## app has one with zero containers.
##
## Behaviour preservation across the migration of the hand-written apps onto
## this primitive is guarded by checks/app-snapshot.nix (structured container/
## user spec + normalized preStart bodies). Canonical consumer:
## apps/homebox/default.nix.

{ config, lib, pkgs, ... }:

let
  cfg = config.homefree.containers;
  enabled = lib.filterAttrs (_: c: c.enable) cfg;
  rootless = lib.filterAttrs (_: c: c.runAs.mode == "rootless") enabled;
  ## Both rootless and linuxserver run as a dedicated HomeFree-managed uid/gid
  ## (rootless via podman user=, linuxserver via PUID/PGID); only `root`
  ## documented-skips have no system user. The chown marker + user= field stay
  ## rootless-only (s6 chowns /config itself for linuxserver images).
  withUser = lib.filterAttrs
    (_: c: (c.runAs.mode == "rootless" || c.runAs.mode == "linuxserver")
           && c.runAs.createUser) enabled;

  ## Caddy's internal-CA root, concatenated into each app's bundle so the
  ## container trusts sso.<domain> when fetching OIDC discovery.
  caddyLocalRoot =
    "/var/lib/caddy/.local/share/caddy/pki/authorities/local/root.crt";

  ## The standard preStart, assembled in the order the hand-written apps use:
  ##   mkdir data dir -> app init hook -> marker-gated chown (rootless) ->
  ##   CA-bundle synthesis (if caBundle) -> app final hook.
  ## Empty fragments are dropped so the rendered script has no blank-line noise.
  mkPreStart = c:
    let
      isRootless = c.runAs.mode == "rootless";
      ## chown target defaults to dataDir, but an app whose data dir is a CHILD
      ## of the dir it actually owns (e.g. webdav mkdir's .../data but chowns
      ## the parent) sets chownDir explicitly.
      chownTarget = if c.chownDir != null then c.chownDir else c.dataDir;
      caBundleHost = "${c.dataDir}/ca-bundle.crt";
    in
    lib.concatStringsSep "\n" (lib.filter (s: s != "") [
      (lib.optionalString (c.dataDir != null) "mkdir -p ${c.dataDir}")
      c.preStartInit
      (lib.optionalString (isRootless && chownTarget != null) ''
        if [ ! -f ${chownTarget}/.chowned-${toString c.runAs.uid} ]; then
          chown -R ${toString c.runAs.uid}:${toString c.runAs.gid} ${chownTarget}
          touch ${chownTarget}/.chowned-${toString c.runAs.uid}
        fi'')
      (lib.optionalString c.caBundle ''
        {
          cat /etc/ssl/certs/ca-certificates.crt
          if [ -r ${caddyLocalRoot} ]; then
            echo
            cat ${caddyLocalRoot}
          fi
        } > ${caBundleHost}
        chmod 644 ${caBundleHost}'')
      c.preStartFinal
    ]);

  mkContainer = _name: c: {
    inherit (c) image autoStart ports environmentFiles cmd dependsOn;
    ## Only set imageFile when given (a locally-built tarball); otherwise
    ## leave it at the oci default so the image is pulled from the registry.
    imageFile = lib.mkIf (c.imageFile != null) c.imageFile;
    ## rootless -> drop privileges with user=; linuxserver/root leave it unset
    ## (the image's s6 init / entrypoint handles the drop via PUID/PGID).
    user = lib.mkIf (c.runAs.mode == "rootless")
      "${toString c.runAs.uid}:${toString c.runAs.gid}";
    environment = c.environment
      // lib.optionalAttrs (c.runAs.mode == "linuxserver") {
        PUID = toString c.runAs.uid;
        PGID = toString c.runAs.gid;
      }
      // lib.optionalAttrs (c.caBundle && c.caBundleEnvVar != null) {
        ${c.caBundleEnvVar} = c.caBundleContainerPath;
      };
    volumes = c.volumes
      ++ lib.optional c.caBundle
        "${c.dataDir}/ca-bundle.crt:${c.caBundleContainerPath}:ro";
    extraOptions = c.extraOptions
      ++ lib.optional c.capNetBind "--cap-add=CAP_NET_BIND_SERVICE";
  };

  containerOpts = { name, ... }: {
    options = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Whether to emit this container (apps gate via mkIf).";
      };
      image = lib.mkOption {
        type = lib.types.str;
        description = "Fully-qualified container image ref (registry/repo:tag).";
      };
      imageFile = lib.mkOption {
        type = lib.types.nullOr lib.types.package;
        default = null;
        description = "Optional locally-built image tarball (oci-containers imageFile) for images not pulled from a registry.";
      };
      runAs = lib.mkOption {
        description = ''
          The non-root strategy (rule 13). `rootless` drops to uid:gid via
          podman `user=` and chowns the data dir; `linuxserver` passes
          PUID/PGID env (the s6 image renames its internal user at runtime);
          `root` is a documented-skip — record why in `reason`.
        '';
        type = lib.types.submodule {
          options = {
            mode = lib.mkOption { type = lib.types.enum [ "rootless" "linuxserver" "root" ]; };
            uid = lib.mkOption { type = lib.types.nullOr lib.types.int; default = null; };
            gid = lib.mkOption { type = lib.types.nullOr lib.types.int; default = null; };
            reason = lib.mkOption { type = lib.types.nullOr lib.types.str; default = null; };
            createUser = lib.mkOption {
              type = lib.types.bool;
              default = true;
              description = ''
                Create a dedicated `users.users/groups.<name>` system user for
                this container. Set false for a `linuxserver` app whose
                PUID/PGID point at a GENERIC, pre-existing uid (e.g. 1000) that
                must NOT get a new system user (would collide with the host
                admin) — the PUID/PGID env is still emitted.
              '';
            };
          };
        };
      };
      dataDir = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Bind-mounted data dir to create (mkdir -p) + (rootless) chown once via a marker.";
      };
      chownDir = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Dir the rootless chown marker recurses over; defaults to dataDir. Set when the dir to own differs from the dir to create (e.g. dataDir is a child of it).";
      };
      caBundle = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Synthesize a CA bundle (system roots + Caddy local CA), mount it, point the app at it.";
      };
      caBundleEnvVar = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = "SSL_CERT_FILE";
        description = "Env var the app reads its CA bundle from (e.g. NODE_EXTRA_CA_CERTS); null = mount only, no env (the bundle overwrites the in-container caBundleContainerPath, e.g. /etc/ssl/certs/ca-certificates.crt).";
      };
      caBundleContainerPath = lib.mkOption {
        type = lib.types.str;
        default = "/etc/ssl/homefree-ca-bundle.crt";
        description = "In-container mount path of the synthesized CA bundle.";
      };
      ports = lib.mkOption { type = lib.types.listOf lib.types.str; default = [ ]; };
      volumes = lib.mkOption { type = lib.types.listOf lib.types.str; default = [ ]; };
      environment = lib.mkOption { type = lib.types.attrsOf lib.types.str; default = { }; };
      environmentFiles = lib.mkOption { type = lib.types.listOf lib.types.str; default = [ ]; };
      extraOptions = lib.mkOption { type = lib.types.listOf lib.types.str; default = [ ]; };
      capNetBind = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Add CAP_NET_BIND_SERVICE (privileged port inside the container) instead of --privileged.";
      };
      cmd = lib.mkOption { type = lib.types.listOf lib.types.str; default = [ ]; };
      dependsOn = lib.mkOption { type = lib.types.listOf lib.types.str; default = [ ]; };
      autoStart = lib.mkOption { type = lib.types.bool; default = true; };
      dnsReady = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Order the podman unit after dns-ready (image pull / startup DNS).";
      };
      preStartInit = lib.mkOption {
        type = lib.types.lines;
        default = "";
        description = "App preStart fragment run AFTER mkdir, BEFORE the chown marker.";
      };
      preStartFinal = lib.mkOption {
        type = lib.types.lines;
        default = "";
        description = "App preStart fragment run AFTER CA-bundle synthesis (e.g. OIDC env synthesis).";
      };
    };
  };
in
{
  options.homefree.containers = lib.mkOption {
    default = { };
    description = "App-platform container registry; see modules/app-platform.nix.";
    type = lib.types.attrsOf (lib.types.submodule containerOpts);
  };

  config = {
    users.users = lib.mapAttrs (name: c: {
      isSystemUser = true;
      group = name;
      uid = c.runAs.uid;
      description = "${name} container runtime user";
    }) withUser;

    users.groups = lib.mapAttrs (_: c: { gid = c.runAs.gid; }) withUser;

    virtualisation.oci-containers.containers = lib.mapAttrs mkContainer enabled;

    systemd.services = lib.mapAttrs'
      (name: c:
        let pre = mkPreStart c; in
        lib.nameValuePair "podman-${name}" (
          {
            after = lib.optional c.dnsReady "dns-ready.service";
            wants = lib.optional c.dnsReady "dns-ready.service";
          }
          ## Only wire an ExecStartPre when there is actually a preStart to run
          ## — a container with no dataDir/caBundle/hooks (e.g. radicle-httpd)
          ## must not gain an empty prestart script it never had.
          // lib.optionalAttrs (pre != "") {
            serviceConfig.ExecStartPre =
              [ "!${pkgs.writeShellScript "${name}-prestart" pre}" ];
          })
      )
      enabled;
  };
}
