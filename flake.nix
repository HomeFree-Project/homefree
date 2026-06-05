{
  description = "HomeFree Self-Hosting Platform";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";

    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";

    nixos-hardware.url = "github:NixOS/nixos-hardware/master";

    disko.url = "github:nix-community/disko";
    disko.inputs.nixpkgs.follows = "nixpkgs";

    # Secure Boot support for the installer's optional lanzaboote path.
    # Pinned to a release tag; the generated installed-system flake
    # references this same revision when the user opts into Secure Boot.
    # v0.4.3 dropped the "fat stub" build (which on v0.4.2 broke under the
    # currently-locked nixpkgs because its rust-docs FOD fetched a file
    # with no extension that unpackPhase couldn't dispatch).
    lanzaboote.url = "github:nix-community/lanzaboote/v0.4.3";
    lanzaboote.inputs.nixpkgs.follows = "nixpkgs";

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

    ## Dendritic structure (Wave 0c): flake-parts is the module framework and
    ## import-tree auto-imports every .nix under ./flake-modules. The flake
    ## outputs (nixosModules, nixosConfigurations, apps, devShells, packages,
    ## checks) now live in flake-modules/*.nix — a pure structural move; the
    ## evaluated configs are unchanged (verified by drvPath equality).
    flake-parts.url = "github:hercules-ci/flake-parts";
    flake-parts.inputs.nixpkgs-lib.follows = "nixpkgs";

    import-tree.url = "github:vic/import-tree";
  };

  outputs = inputs:
    inputs.flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [ "x86_64-linux" ];
      imports = (inputs.import-tree ./flake-modules).imports;
    };
}
