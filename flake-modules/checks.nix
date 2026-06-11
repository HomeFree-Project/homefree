# Dendritic shell (Wave 0c): the verification gates (Wave 0a) re-homed into a
# perSystem flake-module. `checks/default.nix` is unchanged — it already takes
# { self, system, pkgs, lib }. perSystem `pkgs` is the stable nixpkgs, matching
# the old `inputs.nixpkgs.legacyPackages` the checks used for deterministic
# tooling.
{ self, inputs, ... }:
{
  perSystem = { pkgs, system, ... }:
    {
      ## The web-platform subsystem owns its checks (frontend-syntax,
      ## frontend-imports, backend-imports, python-unit) in its own flake; we
      ## re-export them here so homefree's `nix flake check` runs everything.
      ## Homefree's own gates (nix-eval, loader-mapping, homefree-python-unit)
      ## are merged on top — no name collisions.
      checks =
        (inputs.web-platform.checks.${system} or { })
        // import ../checks {
          inherit self system pkgs;
          lib = pkgs.lib;
        };
    };
}
