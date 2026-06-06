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
      runtimeInputs = [ (pkgs.python3.withPackages (ps: [ ps.httpx ps.fastapi ])) ];
      text = ''
        exec python3 ${./scripts/upgrade-apps.py} "$@"
      '';
    };

    # Helper function to create script apps
    mkScriptApp = system: pkgs: scriptName: scriptPath: {
      type = "app";
      program = "${pkgs.writeShellScriptBin scriptName ''
        exec ${scriptPath} "$@"
      ''}/bin/${scriptName}";
    };

    # Create apps for a specific system
    mkSystemApps = system: pkgs: {
      deploy = mkScriptApp system pkgs "deploy" ./scripts/deploy.sh;
      build-iso-image = mkScriptApp system pkgs "build-image" ./scripts/build-image.sh;
      flash = mkScriptApp system pkgs "flash" ./scripts/flash.sh;
      build = mkScriptApp system pkgs "build" ./scripts/build.sh;
      run-vm = mkScriptApp system pkgs "run" ./scripts/run-vm.sh;
    };
  in
  {
    apps = {
      ${system} = (mkSystemApps system inputs.nixpkgs.legacyPackages.${system}) // {
        update-versions = {
          type = "app";
          program = "${update-versions}/bin/update-versions";
        };
      };
    };

    # Development shell with everything ./scripts/run-vm.sh needs to
    # build an installer image and boot it in QEMU - including swtpm
    # (emulated TPM2) and virtiofsd (source-tree share / dev mode).
    devShells.${system}.default = pkgs.mkShell {
      packages = with pkgs; [
        qemu            # qemu-system-x86_64 + qemu-img + qemu-bridge-helper
        swtpm           # emulated TPM2 for --tpm
        virtiofsd       # source-tree share for the wizard's dev mode
        OVMF            # UEFI firmware (run-vm.sh also resolves this itself)
        nix             # build-image / flake builds
        git
        jq
        virt-viewer     # remote-viewer for --virtviewer
      ];
      shellHook = ''
        echo "HomeFree dev shell - VM tooling ready."
        echo "  nix run .#build           # build the installer ISO"
        echo "  nix run .#run-vm -- --tpm # boot it with an emulated TPM2"
      '';
    };

    nixosModules = rec {
      homefree = import ./default.nix { inherit homefree-inputs; inherit system; };
      imports = [ ];
      default = homefree;
      lan-client = import ./lan-client.nix { inherit homefree-inputs; inherit system; };
      ## Per-instance config loader: maps a parsed homefree-config.json
      ## into homefree.*. The instance flake.nix adds this module and
      ## provides the parsed JSON + instance dir via specialArgs
      ## (homefreeConfigJson / homefreeInstanceDir). Kept OUT of the main
      ## `homefree` module's imports because the repo's own test
      ## nixosConfigurations don't supply those specialArgs. See
      ## modules/homefree-config-loader.nix and
      ## docs/agent-notes/homefree-configuration-nix-is-generated.md.
      homefree-config-loader = ./modules/homefree-config-loader.nix;
    };

    nixosConfigurations = {
      # Note that this uses unstable
      homefree = inputs.nixpkgs-unstable.lib.nixosSystem {
        system = system;
        modules = [
          self.nixosModules.homefree
          "${inputs.nixpkgs-unstable}/nixos/modules/virtualisation/qemu-vm.nix"
        ];
        specialArgs = {
          system = system;
          inherit homefree-inputs;
        };
      };

      # Note that this uses unstable
      lan-client = inputs.nixpkgs-unstable.lib.nixosSystem {
        system = system;
        modules = [
          self.nixosModules.lan-client
          "${inputs.nixpkgs-unstable}/nixos/modules/virtualisation/qemu-vm.nix"
        ];
        specialArgs = {
          system = system;
          inherit homefree-inputs;
        };
      };

      # Default installer - Web-based (replaces Calamares)
      # Note that this uses STABLE, as the installation CD doesn't necessarily work on unstable
      homefree-installer = inputs.nixpkgs.lib.nixosSystem {
        system = system;
        modules = [
          ## HomeFree web-based installer
          ./installer
        ];
        specialArgs = {
          system = system;
          inherit homefree-inputs;
        };
      };
    };
    packages.${system} = {
      inherit update-versions;
    };
  };
}
