# Wave 2 fixture: a synthetic, fully-generic instance wired through the REAL
# homefree-config loader. Purpose:
#   (1) eval-test the homefree-config.json -> homefree.* mapping, including the
#       rule-11 backwards-compat tolerance (old/minimal JSON still evaluates);
#   (2) the foundation a later VM smoke test boots.
#
# The fixture (tests/fixtures/sample-homefree-config.json) is a sanitized,
# de-identified shape of a real instance config — no real domains, IPs, keys,
# or password hashes; disk pools / static leases / app set trimmed to a small
# evaluable core.
#
# NOTE: the main `homefree` test config deliberately does NOT include the
# loader (it has no specialArgs JSON); these two configs exercise it. Both are
# forced to fully evaluate by the nix-eval gate, and the loader-mapping check
# asserts the mapping + defaults.
{ self, inputs, ... }:
let
  homefree-inputs =
    (builtins.removeAttrs inputs [ "flake-parts" "import-tree" ]) // { inherit self; };
  system = "x86_64-linux";

  sampleJson = builtins.fromJSON
    (builtins.readFile ../tests/fixtures/sample-homefree-config.json);

  # rule-11 backwards-compat: an OLDER homefree-config.json that predates the
  # optional system.* keys (localization extras, security toggles, boot mirror)
  # must still evaluate through the loader, which `or`-defaults each one.
  minimalJson = sampleJson // {
    system = builtins.removeAttrs sampleJson.system [
      "elevation"
      "latitude"
      "longitude"
      "unitSystem"
      "currency"
      "language"
      "ssh-key-only"
      "wheel-passwordless"
      "project-mode"
      "hashedPassword"
      "bootMirror"
    ];
  };

  mkLoaderTest = json: inputs.nixpkgs-unstable.lib.nixosSystem {
    inherit system;
    modules = [
      self.nixosModules.homefree
      self.nixosModules.homefree-config-loader
      "${inputs.nixpkgs-unstable}/nixos/modules/virtualisation/qemu-vm.nix"
    ];
    specialArgs = {
      inherit system homefree-inputs;
      homefreeConfigJson = json;
      homefreeInstanceDir = ../tests/fixtures;
    };
  };
in
{
  flake.nixosConfigurations = {
    homefree-loader-test = mkLoaderTest sampleJson;
    homefree-loader-test-minimal = mkLoaderTest minimalJson;
  };
}
