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
# byte-identical and behaviour is proven preserved. The preStart script BODIES
# — the part that does churn — are guarded by a SECOND snapshot in this same
# file (prestartCheck / tests/app-prestart-snapshot.txt): every podman-*
# ExecStartPre script, normalised (de-indented, hash-stripped) so re-indent
# churn is tolerated but a real logic change still shows.
#
# Regenerate the goldens after an INTENDED change (reviewing the diff first) —
# the normalisation must match each check's:
#   # structured snapshot:
#   nix eval --impure --raw --expr 'let f = builtins.getFlake (toString ./.); \
#     in (import ./checks/app-snapshot.nix { self = f; \
#         pkgs = f.inputs.nixpkgs.legacyPackages.x86_64-linux; \
#         lib = f.inputs.nixpkgs.legacyPackages.x86_64-linux.lib; \
#         system = "x86_64-linux"; }).snapshotJson' \
#     | jq -S . | sed -E 's#/nix/store/[a-z0-9]{32}-#/nix/store/#g' \
#     > tests/app-config-snapshot.json
#   # preStart snapshot (build the prestartText drv, copy its output):
#   cp "$(nix build --impure --no-link --print-out-paths --expr \
#       'let f = builtins.getFlake (toString ./.); \
#        in (import ./checks/app-snapshot.nix { self = f; \
#            pkgs = f.inputs.nixpkgs.legacyPackages.x86_64-linux; \
#            lib = f.inputs.nixpkgs.legacyPackages.x86_64-linux.lib; \
#            system = "x86_64-linux"; }).prestartText')" \
#     tests/app-prestart-snapshot.txt
#   # Caddy-config snapshot (same drv-build-and-copy as prestart, .caddyText):
#   cp "$(nix build --impure --no-link --print-out-paths --expr \
#       'let f = builtins.getFlake (toString ./.); \
#        in (import ./checks/app-snapshot.nix { self = f; \
#            pkgs = f.inputs.nixpkgs.legacyPackages.x86_64-linux; \
#            lib = f.inputs.nixpkgs.legacyPackages.x86_64-linux.lib; \
#            system = "x86_64-linux"; }).caddyText')" \
#     tests/caddy-config-snapshot.txt

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
      inherit (c) image imageFile cmd entrypoint environment environmentFiles
        ports volumes workdir dependsOn extraOptions autoStart user;
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

    ## The OIDC client set the zitadel-provision script registers (deduped by
    ## internal_name + sorted). Guards the provision.nix -> per-app SSO
    ## descriptor decomposition: moving a descriptor from provision.nix into
    ## its app must leave this set byte-identical.
    ssoClients = cfg.homefree.sso.resolved-clients;
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

  ## ── preStart-script snapshot ──────────────────────────────────────
  ## The structured snapshot above excludes script BODIES (they churn on
  ## extraction). This pins the chown-marker / CA-bundle / OIDC-env preStart
  ## logic that the app-platform primitive actually rewrites. We cat every
  ## podman-* ExecStartPre that is a single script FILE (the
  ## `!${writeShellScript …}` entries — NOT the inline `podman rm` commands
  ## oci-containers adds), normalised: strip leading indentation + blank lines
  ## (so re-indentation churn is tolerated) and strip store hashes. A real
  ## logic change still shows as a diff.
  prestartEntries =
    let
      units = lib.filterAttrs (n: _: lib.hasPrefix "podman-" n) cfg.systemd.services;
      entriesOf = unit: svc:
        lib.imap0 (idx: e: { inherit unit idx; path = lib.removePrefix "!" e; })
          (lib.filter
            (e: builtins.isString e && builtins.match "!?/nix/store/[^ ]+" e != null)
            (lib.toList (svc.serviceConfig.ExecStartPre or [ ])));
    in
    lib.sort (a: b: if a.unit != b.unit then a.unit < b.unit else a.idx < b.idx)
      (lib.flatten (lib.mapAttrsToList entriesOf units));

  ## Normalisation, per line: de-indent; drop comment lines (## / # — but keep
  ## the #! shebang) since comments never affect behaviour and would otherwise
  ## make every reworded comment look like drift during the migration; drop
  ## blank lines; strip store hashes. What remains is the actual COMMAND
  ## sequence — a real logic change still diffs, comment churn does not.
  prestartBody = lib.concatMapStrings (e: ''
    echo "### ${e.unit} [${toString e.idx}]"
    sed -E -e 's/^[[:space:]]+//' -e '/^#!/!{/^#/d}' -e '/^[[:space:]]*$/d' \
      -e 's#/nix/store/[a-z0-9]{32}-#/nix/store/#g' ${e.path}
    echo ""
  '') prestartEntries;

  ## Single source of the normalised concatenation: the check diffs the golden
  ## against this, and the golden is generated by building this same drv.
  prestartText = pkgs.runCommandLocal "app-prestart-text"
    { nativeBuildInputs = [ pkgs.gnused ]; } ''
    { ${prestartBody} } > $out
  '';
  prestartGolden = ../tests/app-prestart-snapshot.txt;

  ## ── Caddy-config snapshot ─────────────────────────────────────────
  ## The generated, `caddy fmt`-canonicalised Caddyfile for the all-apps
  ## config — the faithful oracle for any change to services/caddy (the
  ## directive-ordering footgun file): a refactor that rewrites the gate /
  ## vhost generation must keep this byte-identical. readFile forces the
  ## Caddyfile to render; store hashes are stripped (logDir / package paths).
  caddyRawFile = builtins.toFile "caddy-config-raw"
    (builtins.readFile cfg.services.caddy.configFile);
  caddyText = pkgs.runCommandLocal "caddy-config-text"
    { nativeBuildInputs = [ pkgs.gnused ]; } ''
    sed -E 's#/nix/store/[a-z0-9]{32}-#/nix/store/#g' ${caddyRawFile} > $out
  '';
  caddyGolden = ../tests/caddy-config-snapshot.txt;
in
{
  inherit snapshot snapshotJson prestartText caddyText;

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

  prestartCheck = pkgs.runCommandLocal "app-prestart-snapshot"
    { nativeBuildInputs = [ pkgs.diffutils ]; } ''
    if diff -u ${prestartGolden} ${prestartText}; then
      echo "app-prestart-snapshot: app preStart scripts match the golden."
      touch $out
    else
      {
        echo ""
        echo "app-prestart-snapshot DRIFT: an app's normalised preStart script"
        echo "differs from tests/app-prestart-snapshot.txt. If INTENDED (an"
        echo "app-platform extraction or a deliberate preStart edit), review the"
        echo "diff above, then regenerate the golden per the header and re-run."
      } >&2
      exit 1
    fi
  '';

  caddyCheck = pkgs.runCommandLocal "caddy-config-snapshot"
    { nativeBuildInputs = [ pkgs.diffutils ]; } ''
    if diff -u ${caddyGolden} ${caddyText}; then
      echo "caddy-config-snapshot: generated Caddyfile matches the golden."
      touch $out
    else
      {
        echo ""
        echo "caddy-config-snapshot DRIFT: the generated Caddyfile differs from"
        echo "tests/caddy-config-snapshot.txt. If INTENDED (a deliberate Caddy/"
        echo "ingress change), review the diff above, then regenerate the golden"
        echo "per the header in checks/app-snapshot.nix and re-run."
      } >&2
      exit 1
    fi
  '';
}
