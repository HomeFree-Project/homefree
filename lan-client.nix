{ homefree-inputs, ... }:
{
  _module.args.homefree-inputs = homefree-inputs;

  imports = [
    homefree-inputs.nixos-hardware.nixosModules.common-cpu-intel
    homefree-inputs.nixos-hardware.nixosModules.common-pc-laptop
    ./hosts/lan-client/configuration.nix
  ];
}
