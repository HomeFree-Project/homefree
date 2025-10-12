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

    adblock-unbound = {
      url = "github:MayNiklas/nixos-adblock-unbound";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    authentik-nix = {
      # url = "github:nix-community/authentik-nix";
      # url = "github:nix-community/authentik-nix/version/2024.10.4";
      # url = "github:erahhal/authentik-nix/no-docs";
      url = "github:erahhal/authentik-nix/daba454bd25cea9796e525d225f06fb0782abba6";

      ## optional overrides. Note that using a different version of nixpkgs can cause issues, especially with python dependencies
      # inputs.flake-parts.follows = "flake-parts";
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
      build-qcow2-image = mkScriptApp system pkgs "build-qcow2-image" ./scripts/build-qcow2-installer.sh;
      flash = mkScriptApp system pkgs "flash" ./scripts/flash.sh;
      build = mkScriptApp system pkgs "build" ./scripts/build.sh;
      run-vm = mkScriptApp system pkgs "run" ./scripts/run-vm.sh;
    };
  in
  {
    apps = {
      x86_64-linux = mkSystemApps "x86_64-linux" inputs.nixpkgs.legacyPackages.x86_64-linux;
    };

    nixosModules = rec {
      homefree = import ./default.nix { inherit homefree-inputs; inherit system; };
      imports = [ ];
      default = homefree;
      lan-client = import ./lan-client.nix { inherit homefree-inputs; inherit system; };
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
          ./installer-web
        ];
        specialArgs = {
          system = system;
          inherit homefree-inputs;
        };
      };

      # Legacy Calamares installer (backup, use: nix build .#nixosConfigurations.homefree-installer-calamares.config.system.build.isoImage)
      homefree-installer-calamares = inputs.nixpkgs.lib.nixosSystem {
        system = system;
        modules = [
          ## Official NixOS GNOME installer with Calamares
          "${inputs.nixpkgs}/nixos/modules/installer/cd-dvd/installation-cd-graphical-calamares-gnome.nix"
          ## HomeFree installer customizations
          ./installer
        ];
        specialArgs = {
          system = system;
          inherit homefree-inputs;
        };
      };
    };
  };
}
