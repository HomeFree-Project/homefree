#!/usr/bin/env bash
# HomeFree local test runner (Wave 0a). Fast, offline verification for quick
# local feedback. `nix flake check` runs the same gates as Nix derivations
# (see checks/default.nix); this script additionally performs the
# untracked-file sweep the Nix sandbox CANNOT do — flakes only materialise
# git-TRACKED files, so a new-but-unstaged module is invisible to a build and
# silently white-screens the SPA / raises ModuleNotFoundError (rule 2).
#
# Usage: scripts/test.sh [syntax|imports|untracked|nix-eval|backend|all]
set -uo pipefail
cd "$(dirname "$0")/.."
target="${1:-all}"
rc=0

frontend_syntax() {
  local fail=0
  while IFS= read -r f; do
    node --check "$f" || { echo "SYNTAX FAIL: $f"; fail=1; }
  done < <(find web-platform/frontend/src -name '*.js' -not -path '*/vendor/*')
  return $fail
}

frontend_imports() { node web-platform/check-frontend-imports.mjs web-platform/frontend; }

# New source files present on disk but not git-tracked are excluded from the
# flake source and silently break builds. Flag them before they ever reach a
# rebuild.
untracked_sweep() {
  local found=0 f
  while IFS= read -r f; do
    echo "UNTRACKED (stage it — rule 2): $f"; found=1
  done < <(git ls-files --others --exclude-standard -- \
             'web-platform/*' 'services/*' 'apps/*' 'modules/*' \
             'profiles/*' 'checks/*' 'lib/*' '*.nix' \
           | grep -E '\.(js|mjs|nix|py)$' || true)
  return $found
}

nix_eval() {
  local c
  for c in homefree lan-client homefree-installer; do
    echo "eval $c ..."
    nix eval --raw ".#nixosConfigurations.$c.config.system.build.toplevel.drvPath" \
      >/dev/null || return 1
  done
}

run() { echo "── $1 ──"; "$2" || { echo "FAIL: $1"; rc=1; }; echo; }

case "$target" in
  syntax)    run frontend-syntax frontend_syntax ;;
  imports)   run frontend-imports frontend_imports ;;
  untracked) run untracked-sweep untracked_sweep ;;
  nix-eval)  run nix-eval nix_eval ;;
  backend)
    echo "backend import-all runs under the Nix pythonEnv:"
    echo "  nix build .#checks.x86_64-linux.backend-imports" ;;
  all)
    run frontend-syntax frontend_syntax
    run frontend-imports frontend_imports
    run untracked-sweep untracked_sweep
    run nix-eval nix_eval
    echo "Note: backend-imports needs the Nix pythonEnv — run via:"
    echo "  nix build .#checks.x86_64-linux.backend-imports" ;;
  *) echo "usage: scripts/test.sh [syntax|imports|untracked|nix-eval|backend|all]"; exit 2 ;;
esac

exit $rc
