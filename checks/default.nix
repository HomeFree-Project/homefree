## HomeFree verification gates (Wave 0a of the test-net + decomposition plan).
##
## Imported by flake.nix as `checks.x86_64-linux`. Each gate is a derivation
## that exits 0 on success; `nix flake check` runs them all. Run one with
## `nix build .#checks.x86_64-linux.<name>`.
##
## Every gate here is OFFLINE and sandbox-safe — no network, no KVM. The
## browser-based component tests and the full-box VM smoke (Wave 0b) live
## outside this set (see scripts/test.sh and the plan).
{ self, system, pkgs, lib }:

let
  frontendSrc = self + "/web-platform/frontend";
  backendSrc = self + "/web-platform/backend";

  # SAME dependency closure the admin/installer backend runs under.
  pythonEnv = pkgs.python3.withPackages (import (backendSrc + "/python-env.nix"));
in
{
  ## Frontend syntax gate — `node --check` over every source module (excl. the
  ## vendored Lit tree). Catches the repeat-offender Lit tagged-template
  ## backtick footgun (a stray backtick inside a css`/html` block closes the
  ## template; the rest parses as JS → SyntaxError → white-screened SPA). Does
  ## NOT catch the runtime TypeError variant (needs module evaluation in a
  ## browser — a later smoke test).
  frontend-syntax = pkgs.runCommandLocal "hf-frontend-syntax"
    { nativeBuildInputs = [ pkgs.nodejs ]; } ''
    fail=0
    while IFS= read -r f; do
      if ! node --check "$f"; then
        echo "SYNTAX FAIL: $f" >&2
        fail=1
      fi
    done < <(find ${frontendSrc}/src -name '*.js' -not -path '*/vendor/*' | sort)
    if [ "$fail" -ne 0 ]; then
      echo "frontend-syntax: one or more modules failed node --check" >&2
      exit 1
    fi
    echo "frontend-syntax: all modules parsed OK"
    touch $out
  '';

  ## Frontend import-graph gate — every RELATIVE import in our source resolves
  ## to a real file. Catches the most common white-screen: a component whose
  ## `./foo.js` import points at a missing module (or one present on disk but
  ## untracked, hence absent from the flake source — the rule-2 trap), which
  ## blocks the whole ES module graph. Bare/importmap specifiers are a
  ## documented v2 follow-up. scripts/test.sh additionally flags untracked
  ## files via git (the Nix sandbox can't see them).
  frontend-imports = pkgs.runCommandLocal "hf-frontend-imports"
    { nativeBuildInputs = [ pkgs.nodejs ]; } ''
    node ${self + "/scripts/check-frontend-imports.mjs"} ${frontendSrc}
    touch $out
  '';

  ## Backend import-all gate — import every backend library module under the
  ## packaged pythonEnv. Catches ModuleNotFoundError from a missing
  ## resolver/service import (a documented runtime-only failure). Excludes
  ## main.py/schema.py (dead strawberry path) and the sampler entrypoints —
  ## see web-platform/backend/tests/import_all.py.
  backend-imports = pkgs.runCommandLocal "hf-backend-imports"
    { nativeBuildInputs = [ pythonEnv ]; } ''
    cd ${backendSrc}
    PYTHONPATH=${backendSrc} python ${backendSrc}/tests/import_all.py
    touch $out
  '';

  ## Nix eval gate — force full module-system evaluation of every
  ## nixosConfiguration's toplevel (without BUILDING it), so `nix flake check`
  ## fails on any eval error or untracked .nix that breaks the flake. This is
  ## the structure-agnostic regression oracle the decomposition refactor leans
  ## on. Referencing each `.drvPath` instantiates (evaluates) the derivation
  ## but does not realise the system.
  nix-eval =
    let
      cfgs = [ "homefree" "lan-client" "homefree-installer" ];
      drvPaths = map
        (n: self.nixosConfigurations.${n}.config.system.build.toplevel.drvPath)
        cfgs;
    in
    pkgs.runCommandLocal "hf-nix-eval" { inherit drvPaths; } ''
      echo "nix-eval: all nixosConfigurations instantiated:" >&2
      for d in $drvPaths; do echo "  $d" >&2; done
      touch $out
    '';
}
