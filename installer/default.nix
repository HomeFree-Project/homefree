# Installer Configuration
#
# This module provides the installer ISO configuration for HomeFree.
# It imports the shared web platform (served backend/frontend) from the
# web-platform flake input, plus the installer-specific boot/ISO config
# which lives here (it references repo-root themes/ + profiles/, so it is
# a homefree concern, not web-platform content).

{ homefree-inputs, system, ... }:

{
  imports = [
    # Shared backend + frontend + serving, consumed from the web-platform
    # flake input rather than a ../web-platform/ relative path. `system` is a
    # specialArg (safe to use in `imports`, unlike pkgs/config).
    "${homefree-inputs.web-platform.legacyPackages.${system}.source}/shared.nix"
    ./installer.nix   # Installer-specific: ISO config, GRUB branding, GNOME autostart
  ];
}
