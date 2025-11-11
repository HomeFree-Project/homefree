# Installer stub module
#
# This module provides a semantic import point for the HomeFree installer.
# It imports the unified web-platform which serves both installer and admin modes.
#
# The web-platform automatically detects mode based on whether
# /etc/nixos/homefree-configuration.nix exists:
# - If absent (fresh install) → Installer mode
# - If present (installed system) → Admin mode

{ ... }:

{
  imports = [
    ../web-platform
  ];
}
