{
  description = "HomeFree web-platform — admin/installer FastAPI backend + Lit frontend";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};

      # The backend's runtime closure (single source of truth in
      # backend/python-env.nix), and the same closure plus pytest for the
      # unit tests.
      pythonEnv = pkgs.python3.withPackages (import ./backend/python-env.nix);
      pythonUnitEnv = pkgs.python3.withPackages (ps:
        (import ./backend/python-env.nix ps) ++ [ ps.pytest ]);
    in
    {
      ## Dev shell for the Python + JS subsystem, independent of the NixOS
      ## flake: `cd web-platform && nix develop`.
      devShells.${system}.default = pkgs.mkShell {
        packages = [ pythonUnitEnv pkgs.nodejs ];
        shellHook = ''
          echo "HomeFree web-platform dev shell — python3 (+pytest), node $(node --version)."
        '';
      };

      ## Offline checks for the web-platform subsystem. These used to live in
      ## the homefree flake's checks/; they are owned here now and homefree
      ## re-exports them into its own `nix flake check`.
      checks.${system} = {
        ## `node --check` over every source module (excl. the vendored Lit
        ## tree) — the Lit tagged-template backtick catcher.
        frontend-syntax = pkgs.runCommandLocal "wp-frontend-syntax"
          { nativeBuildInputs = [ pkgs.nodejs ]; } ''
          fail=0
          while IFS= read -r f; do
            node --check "$f" || { echo "SYNTAX FAIL: $f" >&2; fail=1; }
          done < <(find ${self}/frontend/src -name '*.js' -not -path '*/vendor/*' | sort)
          [ "$fail" -eq 0 ] || { echo "frontend-syntax: a module failed node --check" >&2; exit 1; }
          echo "frontend-syntax: all modules parsed OK"
          touch $out
        '';

        ## Every RELATIVE import in src resolves to a real file — the
        ## missing-module white-screen catcher.
        frontend-imports = pkgs.runCommandLocal "wp-frontend-imports"
          { nativeBuildInputs = [ pkgs.nodejs ]; } ''
          node ${self}/check-frontend-imports.mjs ${self}/frontend
          touch $out
        '';

        ## Import every backend library module under the packaged pythonEnv —
        ## the ModuleNotFoundError catcher (excludes the dead strawberry path;
        ## see backend/tests/import_all.py).
        backend-imports = pkgs.runCommandLocal "wp-backend-imports"
          { nativeBuildInputs = [ pythonEnv ]; } ''
          cd ${self}/backend
          PYTHONPATH=${self}/backend python ${self}/backend/tests/import_all.py
          touch $out
        '';

        ## Pure-logic unit tests for the backend (hw_buckets threshold cascade,
        ## incl. the NVMe both-limits regression). homefree keeps the pytest
        ## that covers its own scripts/ + apps/ logic.
        python-unit = pkgs.runCommandLocal "wp-python-unit"
          { nativeBuildInputs = [ pythonUnitEnv ]; } ''
          cd ${self}/backend
          export HOME=$TMPDIR PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=${self}/backend
          pytest -q --import-mode=importlib -p no:cacheprovider tests
          touch $out
        '';
      };
    };
}
