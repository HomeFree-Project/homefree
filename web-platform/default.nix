# HomeFree Web Platform - Backward Compatibility Module
#
# This file maintains backward compatibility for any code that imports
# the web-platform directory directly. It simply re-exports the shared
# configuration.
#
# For the full installer configuration (shared + installer-specific),
# use ../installer/default.nix instead.

{ ... }:

{
  imports = [
    ./shared.nix
  ];
}
