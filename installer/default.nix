# Installer Configuration
#
# This module provides the installer ISO configuration for HomeFree.
# It imports both the shared web platform components and installer-specific config.

{ ... }:

{
  imports = [
    ../web-platform/shared.nix      # Shared backend, frontend, and services
    ../web-platform/installer.nix   # Installer-specific: ISO config, GNOME autostart, etc.
  ];
}
