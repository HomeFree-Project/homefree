{ buildNpmPackage, runCommand, lib, ... }:

# Build the eleventy site. App manuals live at apps/<name>/manual.md
# (next to each app's default.nix + icon.svg, per the "one place per
# service" rule). They get staged into the eleventy src tree under
# src/manual/apps/<name>.md immediately before the npm build so
# eleventy picks them up as regular markdown content with the same
# permalink/layout treatment as anything else in src/manual/apps/.
#
# Why stage rather than read app manuals at runtime: eleventy is a
# static site generator — the output is a snapshot, not a server.
# Staging at build time keeps the runtime artifact pure HTML and
# preserves the existing Caddy + manual.<domain> serving pipeline.
let
  appsDir = ../../../apps;

  # Find each apps/<dir>/manual.md and emit one cp line. Done at
  # Nix-eval time so the output derivation is deterministic given
  # the apps tree. New manuals appear automatically on rebuild —
  # no edits to this file needed.
  appManuals =
    if builtins.pathExists appsDir
    then
      let
        entries = builtins.readDir appsDir;
        dirs = lib.filterAttrs (n: t: t == "directory") entries;
        withManual = lib.filterAttrs
          (dir: _: builtins.pathExists "${appsDir}/${dir}/manual.md")
          dirs;
      in
      lib.mapAttrsToList (dir: _: {
        name = dir;
        path = "${appsDir}/${dir}/manual.md";
        # Capture sub-pages too: apps/<dir>/manual-*.md → manual/apps/<dir>-*.md
        extras =
          let
            subEntries = builtins.readDir "${appsDir}/${dir}";
            subFiles = lib.filterAttrs
              (n: t: t == "regular"
                && lib.hasPrefix "manual-" n
                && lib.hasSuffix ".md" n)
              subEntries;
          in
          lib.mapAttrsToList (sub: _: {
            srcPath = "${appsDir}/${dir}/${sub}";
            # apps/freshrss/manual-capy.md → freshrss-capy.md
            destName =
              let
                base = lib.removeSuffix ".md" sub;       # "manual-capy"
                suffix = lib.removePrefix "manual-" base; # "capy"
              in "${dir}-${suffix}.md";
          }) subFiles;
      }) withManual
    else [];

  stagedSite = runCommand "homefree-site-staged" {} ''
    cp -r ${./.} $out
    chmod -R u+w $out
    mkdir -p $out/src/manual/apps
    ${lib.concatMapStringsSep "\n"
      (m: ''
        cp ${m.path} $out/src/manual/apps/${m.name}.md
        ${lib.concatMapStringsSep "\n"
          (e: "cp ${e.srcPath} $out/src/manual/apps/${e.destName}")
          m.extras}
      '')
      appManuals}
  '';
in
buildNpmPackage {
  name = "default-landing-page";
  src = stagedSite;
  # npmDepsHash = lib.fakeHash;
  npmDepsHash = "sha256-uOLu/MrHS+Et9yUyZO66ANRCzG15hki+7oSTqw4eyT0=";
}
