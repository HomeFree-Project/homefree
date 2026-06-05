# Dendritic shell (Wave 0c): runnable apps + the update-versions package.
# Moved verbatim from flake.nix; uses the perSystem `pkgs` (stable nixpkgs),
# matching the old `inputs.nixpkgs.legacyPackages` usage.
{ ... }:
{
  perSystem = { pkgs, ... }:
    let
      update-versions = pkgs.writeShellApplication {
        name = "update-versions";
        runtimeInputs = with pkgs; [ python3 skopeo ];
        text = ''
          exec python3 ${../scripts/check-container-updates.py} "$@"
        '';
      };

      # Wrap a repo script as a `nix run`-able app.
      mkScriptApp = scriptName: scriptPath: {
        type = "app";
        program = "${pkgs.writeShellScriptBin scriptName ''
          exec ${scriptPath} "$@"
        ''}/bin/${scriptName}";
      };
    in
    {
      packages.update-versions = update-versions;

      apps = {
        deploy = mkScriptApp "deploy" ../scripts/deploy.sh;
        build-iso-image = mkScriptApp "build-image" ../scripts/build-image.sh;
        flash = mkScriptApp "flash" ../scripts/flash.sh;
        build = mkScriptApp "build" ../scripts/build.sh;
        run-vm = mkScriptApp "run" ../scripts/run-vm.sh;
        update-versions = {
          type = "app";
          program = "${update-versions}/bin/update-versions";
        };
      };
    };
}
