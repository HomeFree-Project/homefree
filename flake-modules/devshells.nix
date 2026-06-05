# Dendritic shell (Wave 0c): the dev shell. Everything ./scripts/run-vm.sh
# needs to build an installer image and boot it in QEMU — including swtpm
# (emulated TPM2) and virtiofsd (source-tree share / dev mode). Moved verbatim
# from flake.nix.
{ ... }:
{
  perSystem = { pkgs, ... }:
    {
      devShells.default = pkgs.mkShell {
        packages = with pkgs; [
          qemu # qemu-system-x86_64 + qemu-img + qemu-bridge-helper
          swtpm # emulated TPM2 for --tpm
          virtiofsd # source-tree share for the wizard's dev mode
          OVMF # UEFI firmware (run-vm.sh also resolves this itself)
          nix # build-image / flake builds
          git
          jq
          virt-viewer # remote-viewer for --virtviewer
        ];
        shellHook = ''
          echo "HomeFree dev shell - VM tooling ready."
          echo "  nix run .#build           # build the installer ISO"
          echo "  nix run .#run-vm -- --tpm # boot it with an emulated TPM2"
        '';
      };
    };
}
