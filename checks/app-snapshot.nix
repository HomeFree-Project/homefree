# App-config snapshot — the behaviour-preservation safety net for the
# app-platform refactor (collapsing the ~33 near-identical app skeletons
# into a shared primitive).
#
# The extraction will whitespace-churn drvPath (moving `''`-interpolated
# preStart scripts around re-indents them), so drvPath equality is NOT a
# usable oracle. This instead pins the STRUCTURED, behaviour-defining output
# of every app — the oci-container spec (image/user/ports/volumes/env/
# environmentFiles/extraOptions/...), the app system users+groups (UID/GID
# range 800–899), and the homefree.service-config registry entries
# (ingress/backup/sso/options-metadata). None of those are scripts, so they
# do NOT churn: if the primitive reproduces the same data, this snapshot is
# byte-identical and behaviour is proven preserved. (The preStart script
# bodies — the part that does churn — are guarded separately; see the
# normalized-prestart snapshot follow-up.)
#
# Regenerate the golden after an INTENDED change (reviewing the diff first) —
# the jq + hash-strip pipeline must match the check's normalisation:
#   nix eval --impure --raw --expr 'let f = builtins.getFlake (toString ./.); \
#     in (import ./checks/app-snapshot.nix { self = f; \
#         pkgs = f.inputs.nixpkgs.legacyPackages.x86_64-linux; \
#         lib = f.inputs.nixpkgs.legacyPackages.x86_64-linux.lib; \
#         system = "x86_64-linux"; }).snapshotJson' \
#     | jq -S . | sed -E 's#/nix/store/[a-z0-9]{32}-#/nix/store/#g' \
#     > tests/app-config-snapshot.json

{ self, pkgs, lib, system }:

let
  ## Every first-party app's enable knob. Mostly the directory name; the one
  ## exception is opensprinkler (option is `opensprinkler-ui`). Keep in sync
  ## with apps/ — a new app must be added here AND have the golden regenerated,
  ## or it sits outside the snapshot's protection.
  appNames = [
    "adguard" "azuracast" "backup-canary" "baikal" "cryptpad" "forgejo"
    "freshrss" "frigate" "grocy" "headscale" "home-assistant" "homebox"
    "immich" "jellyfin" "joplin" "lidarr" "linkwarden" "matrix" "mediawiki"
    "minecraft" "netbird" "nextcloud" "nzbget" "odoo" "ollama"
    "opensprinkler-ui" "radicale" "radicle" "screeenly" "snipe-it" "trilium"
    "unifi" "vaultwarden" "webdav" "zitadel" "zwave-js-ui"
  ];

  enableAllApps = { lib, ... }: {
    config.homefree.services = lib.genAttrs appNames (_: { enable = true; });
  };

  cfg = (self.nixosConfigurations.homefree.extendModules {
    modules = [ enableAllApps ];
  }).config;

  snapshot = {
    ## Curated container fields — data only, never script bodies.
    containers = lib.mapAttrs (_: c: {
      inherit (c) image cmd entrypoint environment environmentFiles ports
        volumes workdir dependsOn extraOptions autoStart user;
    }) cfg.virtualisation.oci-containers.containers;

    appUsers = lib.mapAttrs (_: u: { inherit (u) uid group isSystemUser; })
      (lib.filterAttrs (_: u: u.uid != null && u.uid >= 800 && u.uid < 900)
        cfg.users.users);

    appGroups = lib.mapAttrs (_: g: { inherit (g) gid; })
      (lib.filterAttrs (_: g: g.gid != null && g.gid >= 800 && g.gid < 900)
        cfg.users.groups);

    ## Sorted by label so the snapshot is robust to module list-merge order
    ## (which is behaviourally irrelevant — every consumer sorts/filters).
    serviceConfig = lib.sort (a: b: a.label < b.label) cfg.homefree.service-config;
  };

  snapshotJson = builtins.toJSON snapshot;
  ## Some container fields interpolate built packages (e.g. radicle's
  ## radicle-explorer), so the JSON carries string context (derivation
  ## refs). We want the PATH STRINGS captured as data, not to realise them —
  ## and `builtins.toFile` rejects context — so discard it. A dependency
  ## bump still shows as drift because the out-path string itself changes.
  generated = builtins.toFile "app-config-snapshot-generated.json"
    (builtins.unsafeDiscardStringContext snapshotJson);
  golden = ../tests/app-config-snapshot.json;

  ## Store-hash redaction: several fields hold store paths into packages
  ## built from the repo source (landing-page's static-path, radicle-
  ## explorer, ...). The 32-char hash churns on ANY repo change, so strip it
  ## — keeping `/nix/store/<name>-<version>/...` pins package identity (a real
  ## swap/version-bump still shows) while tolerating pure rebuild churn.
  stripHash = ''sed -E 's#/nix/store/[a-z0-9]{32}-#/nix/store/#g' '';
in
{
  inherit snapshot snapshotJson;

  check = pkgs.runCommandLocal "app-config-snapshot"
    { nativeBuildInputs = [ pkgs.diffutils pkgs.jq ]; } ''
    # Golden is stored jq-pretty + hash-redacted (reviewable, stable line
    # diffs); normalise the generated side identically before comparing.
    if diff -u ${golden} <(jq -S . ${generated} | ${stripHash}); then
      echo "app-config-snapshot: evaluated app config matches the golden."
      touch $out
    else
      {
        echo ""
        echo "app-config-snapshot DRIFT: the evaluated oci-container / user /"
        echo "service-config output differs from tests/app-config-snapshot.json."
        echo "If this change is INTENDED (an app-platform extraction or a"
        echo "deliberate app edit), review the diff above, then regenerate the"
        echo "golden per the header in checks/app-snapshot.nix and re-run."
      } >&2
      exit 1
    fi
  '';
}
