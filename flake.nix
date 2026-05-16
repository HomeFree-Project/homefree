{
  description = "HomeFree Self-Hosting Platform";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";

    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";

    nixos-hardware.url = "github:NixOS/nixos-hardware/master";

    disko.url = "github:nix-community/disko";
    disko.inputs.nixpkgs.follows = "nixpkgs";

    nixvim-config.url = "git+https://git.homefree.host/homefree/nixvim-config";

    nix-editor.url = "github:snowfallorg/nix-editor";

    sops-nix.url = "github:Mic92/sops-nix";

    headplane = {
      url = "github:tale/headplane";
      inputs.nixpkgs.follows = "nixpkgs-unstable";
    };

    adblock-unbound = {
      url = "github:MayNiklas/nixos-adblock-unbound";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # nixos-router = {
    #   url = "github:chayleaf/nixos-router";
    #   inputs.nixpkgs.follows = "nixpkgs";
    # };
  };

  outputs = { self, ... } @ inputs:
  let
    system = "x86_64-linux";
    # Can't use name "inputs" as it gets overridden by parent flakes that define inputs.nixpkgs.lib.nixosSystem
    homefree-inputs = inputs;
    # versionInfo = import ./version.nix;
    # version = versionInfo.version + (inputs.nixpkgs.lib.optionalString (!versionInfo.released) "-dirty");
    pkgs = import inputs.nixpkgs { inherit system; };
    update-versions = pkgs.writeShellApplication {
      name = "update-versions";
      runtimeInputs = with pkgs; [ python3 skopeo ];
      text = ''
        exec python3 ${./scripts/check-container-updates.py} "$@"
      '';
    };
  in
  {
    nixosModules = rec {
      homefree = import ./default.nix { inherit homefree-inputs; inherit system; };
      imports = [ ];
      default = homefree;
      lan-client = import ./lan-client.nix { inherit homefree-inputs; inherit system; };
    };
    nixosConfigurations = {
      homefree-test = inputs.nixpkgs.lib.nixosSystem {
        system = system;
        modules = [
          self.nixosModules.homefree
        ];
      };
      lan-client = inputs.nixpkgs.lib.nixosSystem {
        system = system;
        modules = [
          self.nixosModules.lan-client
        ];
      };
    };
    apps.${system} = {
      update-versions = {
        type = "app";
        program = "${update-versions}/bin/update-versions";
      };
    };
    packages.${system} = {
      inherit update-versions;
    };
  };
}
