# Dendritic shell (Wave 0c): the verification gates (Wave 0a) re-homed into a
# perSystem flake-module. `checks/default.nix` is unchanged — it already takes
# { self, system, pkgs, lib }. perSystem `pkgs` is the stable nixpkgs, matching
# the old `inputs.nixpkgs.legacyPackages` the checks used for deterministic
# tooling.
{ self, ... }:
{
  perSystem = { pkgs, system, ... }:
    {
      checks = import ../checks {
        inherit self system pkgs;
        lib = pkgs.lib;
      };
    };
}
