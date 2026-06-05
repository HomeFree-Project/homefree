# Dendritic shell (Wave 0c): NixOS module + configuration outputs.
#
# This is a pure structural move out of the old monolithic flake.nix — the
# evaluated configs must be byte-for-byte identical (verified by drvPath
# equality). Feature-level decomposition into per-aspect flake-modules comes
# in later waves.
{ self, inputs, ... }:
let
  # Reconstruct the pre-flake-parts `homefree-inputs` EXACTLY as the old
  # `outputs = { self, ... } @ inputs` did: the original named inputs plus
  # `self`, and WITHOUT the flake-parts machinery. Keeping this set identical
  # is what makes the conversion drvPath-neutral for the homefree module.
  homefree-inputs =
    (builtins.removeAttrs inputs [ "flake-parts" "import-tree" ]) // { inherit self; };
  system = "x86_64-linux";
in
{
  flake.nixosModules = rec {
    homefree = import ../default.nix { inherit homefree-inputs system; };
    imports = [ ];
    default = homefree;
    lan-client = import ../lan-client.nix { inherit homefree-inputs system; };
    ## Per-instance config loader: maps a parsed homefree-config.json into
    ## homefree.*. The instance flake.nix adds this module and provides the
    ## parsed JSON + instance dir via specialArgs (homefreeConfigJson /
    ## homefreeInstanceDir). Kept OUT of the main `homefree` module's imports
    ## because the repo's own test nixosConfigurations don't supply those
    ## specialArgs. See modules/homefree-config-loader.nix and
    ## docs/agent-notes/homefree-configuration-nix-is-generated.md.
    homefree-config-loader = ../modules/homefree-config-loader.nix;
  };

  flake.nixosConfigurations = {
    # Note that this uses unstable
    homefree = inputs.nixpkgs-unstable.lib.nixosSystem {
      inherit system;
      modules = [
        self.nixosModules.homefree
        "${inputs.nixpkgs-unstable}/nixos/modules/virtualisation/qemu-vm.nix"
        ## Standalone eval/test config — NOT an instance (no homefree-config.json
        ## loader / specialArgs). modules/abuse-blocking.nix asserts
        ## networking.nftables.enable = true; a real box gets that from
        ## profiles/router.nix via instance config. Enable it here so this test
        ## config evaluates for the eval gate. Realistic router behaviour is
        ## covered by the Wave 2 VM test with a sample homefree-config.json.
        { networking.nftables.enable = true; }
      ];
      specialArgs = { inherit system homefree-inputs; };
    };

    # Note that this uses unstable
    lan-client = inputs.nixpkgs-unstable.lib.nixosSystem {
      inherit system;
      modules = [
        self.nixosModules.lan-client
        "${inputs.nixpkgs-unstable}/nixos/modules/virtualisation/qemu-vm.nix"
      ];
      specialArgs = { inherit system homefree-inputs; };
    };

    # Default installer - Web-based (replaces Calamares).
    # Uses STABLE, as the installation CD doesn't necessarily work on unstable.
    homefree-installer = inputs.nixpkgs.lib.nixosSystem {
      inherit system;
      modules = [
        ## HomeFree web-based installer
        ../installer
      ];
      specialArgs = { inherit system homefree-inputs; };
    };
  };
}
