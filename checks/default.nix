## HomeFree-side verification gates.
##
## The web-platform subsystem owns its OWN checks (frontend-syntax,
## frontend-imports, backend-imports, python-unit) in web-platform/flake.nix;
## flake-modules/checks.nix re-exports those alongside these homefree-only
## gates. Everything here is offline + sandbox-safe.
{ self, system, pkgs, lib }:

let
  # Homefree pure-logic tests cover scripts/ (upgrade-apps bump-safety, stdlib
  # only) and apps/ (merge-ha-yaml — needs pyyaml). The web-platform backend
  # tests (hw_buckets) live in the web-platform flake.
  homefreePyEnv = pkgs.python3.withPackages (ps: [ ps.pytest ps.pyyaml ]);

  ## App-platform behaviour-preservation snapshots (imported once so the
  ## all-apps-enabled config is evaluated a single time, shared by both checks).
  appSnapshot = import ./app-snapshot.nix { inherit self pkgs lib system; };
in
{
  ## Homefree pure-logic unit tests (pytest): the upgrade-apps bump-safety
  ## logic (scripts/) and the Home Assistant YAML overlay merge (apps/). The
  ## hardware threshold tests moved to the web-platform flake with the backend.
  homefree-python-unit = pkgs.runCommandLocal "hf-python-unit"
    { nativeBuildInputs = [ homefreePyEnv ]; } ''
    cd ${self}
    export HOME=$TMPDIR PYTHONDONTWRITEBYTECODE=1
    pytest -q --import-mode=importlib -p no:cacheprovider \
      scripts/tests apps/home-assistant/tests
    touch $out
  '';

  ## Nix eval gate — force full module-system evaluation of every
  ## nixosConfiguration's toplevel (without BUILDING it), so `nix flake check`
  ## fails on any eval error or untracked .nix that breaks the flake. This is
  ## the structure-agnostic regression oracle the decomposition refactor leans
  ## on.
  ##
  ## IMPORTANT: do NOT put the toplevel `.drvPath` strings into the derivation
  ## env — a `.drvPath` carries string context, so Nix adds the three systems
  ## to this check's input closure and `nix flake check` would REALISE all
  ## three full NixOS systems (slow; needs network/secrets; observed pulling
  ## in mercurial/crypton/... before this fix). Instead `deepSeq` the drvPaths
  ## to force their evaluation, then return a context-free string so the build
  ## stays a trivial `touch`.
  nix-eval =
    let
      cfgs = [
        "homefree"
        "lan-client"
        "homefree-installer"
        "homefree-loader-test"
        "homefree-loader-test-minimal"
      ];
      drvPaths = map
        (n: self.nixosConfigurations.${n}.config.system.build.toplevel.drvPath)
        cfgs;
      forced = builtins.deepSeq drvPaths
        "nix-eval: all ${toString (builtins.length cfgs)} nixosConfigurations evaluate";
    in
    pkgs.runCommandLocal "hf-nix-eval" { } ''
      echo "${forced}" >&2
      touch $out
    '';

  ## Loader mapping + rule-11 backwards-compat. Asserts the
  ## homefree-config.json -> homefree.* loader maps values correctly (the full
  ## fixture) AND that an OLDER JSON missing the optional system.* keys still
  ## evaluates and receives the documented `or`-defaults
  ## (homefree-loader-test-minimal). Reads homefree.* VALUES — lazy, does not
  ## realise the systems. The fixture lives at
  ## tests/fixtures/sample-homefree-config.json (see flake-modules/loader-test.nix).
  loader-mapping =
    let
      full = self.nixosConfigurations.homefree-loader-test.config.homefree;
      minimal = self.nixosConfigurations.homefree-loader-test-minimal.config.homefree;
      tests = {
        "full: system.domain mapped" = full.system.domain == "homefree.example";
        "full: system.localDomain mapped" = full.system.localDomain == "homefree.lan";
        "full: network.lan-address mapped" = full.network.lan-address == "10.0.0.1";
        "full: network.lan-subnet mapped" = full.network.lan-subnet == "10.0.0.0/24";
        # rule-11: minimal JSON omits these -> loader `or`-defaults them.
        "bc: unitSystem -> metric" = minimal.system.unitSystem == "metric";
        "bc: currency -> null" = minimal.system.currency == null;
        "bc: language -> null" = minimal.system.language == null;
        "bc: wheel-passwordless -> true" = minimal.system.wheel-passwordless == true;
        "bc: project-mode -> false" = minimal.system.project-mode == false;
        "bc: bootMirror -> false" = minimal.system.bootMirror == false;
        "bc: hashedPassword -> null" = minimal.system.hashedPassword == null;
        "bc: ssh-key-only -> false" = minimal.system.ssh-key-only == false;
      };
      failures = builtins.attrNames (lib.filterAttrs (_: v: !v) tests);
      total = builtins.length (builtins.attrNames tests);
    in
    pkgs.runCommandLocal "hf-loader-mapping" { } (
      if failures == [ ]
      then ''echo "loader-mapping: all ${toString total} assertions pass" >&2; touch $out''
      else ''echo "loader-mapping FAILURES: ${builtins.concatStringsSep ", " failures}" >&2; exit 1''
    );

  ## App-platform behaviour-preservation safety net (collapsing the ~33 app
  ## skeletons churns drvPath, so it can't be the oracle). Two snapshots:
  ##  - structured oci-container / user / service-config output
  ##    (golden tests/app-config-snapshot.json)
  ##  - normalised podman-* preStart script bodies — the chown-marker /
  ##    CA-bundle / OIDC-env logic the primitive rewrites
  ##    (golden tests/app-prestart-snapshot.txt)
  ## See checks/app-snapshot.nix.
  app-config-snapshot = appSnapshot.check;
  app-prestart-snapshot = appSnapshot.prestartCheck;
}
