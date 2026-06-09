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

      ## Filtered view of the web-platform tree. The raw flake source
      ## (self.outPath) is fetched verbatim by the `path:./web-platform`
      ## input, which — when homefree is built from a dirty working tree —
      ## drags in gitignored build junk (__pycache__/*.pyc, possibly with
      ## mismatched cpython tags, plus result symlinks / .pytest_cache).
      ## The old `../../web-platform` path import never saw those (it was
      ## filtered to homefree's git-tracked tree). `src` reproduces that
      ## clean view so BOTH these checks and homefree's consumers serve
      ## byte-identical, deterministic content regardless of how the parent
      ## flake is evaluated. Exposed below as `legacyPackages.<sys>.source`.
      src = pkgs.lib.cleanSourceWith {
        name = "web-platform-src";
        src = ./.;
        filter = path: _type:
          let base = baseNameOf (toString path); in
          ! ( base == "__pycache__"
              || base == ".pytest_cache"
              || base == "result"
              || pkgs.lib.hasPrefix "result-" base
              || pkgs.lib.hasSuffix ".pyc" base );
      };
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
          done < <(find ${src}/frontend/src -name '*.js' -not -path '*/vendor/*' | sort)
          [ "$fail" -eq 0 ] || { echo "frontend-syntax: a module failed node --check" >&2; exit 1; }
          echo "frontend-syntax: all modules parsed OK"
          touch $out
        '';

        ## Every RELATIVE import in src resolves to a real file — the
        ## missing-module white-screen catcher.
        frontend-imports = pkgs.runCommandLocal "wp-frontend-imports"
          { nativeBuildInputs = [ pkgs.nodejs ]; } ''
          node ${src}/check-frontend-imports.mjs ${src}/frontend
          touch $out
        '';

        ## Import every backend library module under the packaged pythonEnv —
        ## the ModuleNotFoundError catcher (excludes the dead strawberry path;
        ## see backend/tests/import_all.py).
        backend-imports = pkgs.runCommandLocal "wp-backend-imports"
          { nativeBuildInputs = [ pythonEnv ]; } ''
          cd ${src}/backend
          PYTHONPATH=${src}/backend python ${src}/backend/tests/import_all.py
          touch $out
        '';

        ## Pure-logic unit tests for the backend (hw_buckets threshold cascade,
        ## incl. the NVMe both-limits regression). homefree keeps the pytest
        ## that covers its own scripts/ + apps/ logic.
        python-unit = pkgs.runCommandLocal "wp-python-unit"
          { nativeBuildInputs = [ pythonUnitEnv ]; } ''
          cd ${src}/backend
          export HOME=$TMPDIR PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=${src}/backend
          pytest -q --import-mode=importlib -p no:cacheprovider tests
          touch $out
        '';
      };

      ## The filtered web-platform tree, consumed by homefree's admin-web /
      ## finish-setup / alerts modules in place of the old `../../web-platform`
      ## relative path import. legacyPackages (not packages) so `nix flake
      ## check` doesn't try to realise it as a derivation.
      legacyPackages.${system}.source = src;
    };
}
