{ lib, pkgs, ... }:
{
  services.postgresql = {
    enable = true;
    ## When bumping postgres major versions, existing data needs
    ## `pg_upgrade`. NixOS doesn't run this automatically — for an
    ## in-place upgrade you'd need to manually pg_dumpall on the old
    ## version, drop the data dir, switch the package, restart, and
    ## restore. Pinned to 18 (latest stable in this nixpkgs as of
    ## the rebuild).
    package = lib.mkForce pkgs.postgresql_18;
    enableTCPIP = true;
    authentication = pkgs.lib.mkOverride 10 ''
      #type database  DBuser  auth-method
      local all       all     trust

      #type database DBuser origin-address auth-method
      # ipv4
      host  all      all     127.0.0.1/32   trust
      # podman
      host  all      all     10.88.0.0/16   trust
      # ipv6
      host all       all     ::1/128        trust
    '';
  };
}
