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
    ## Phase 2: TCP entries authenticate via scram-sha-256 (peer auth
    ## for the unix socket stays trust, see below). Every container
    ## reaching this cluster over TCP from the podman bridge or
    ## loopback now needs a valid SCRAM password — currently:
    ##   - zitadel  (env: ZITADEL_DATABASE_POSTGRES_USER_PASSWORD)
    ##   - linkwarden (DATABASE_URL embedded password)
    ## All other apps (matrix, joplin, odoo, freshrss, nextcloud,
    ## mediawiki, etc.) bind-mount /run/postgresql and connect via
    ## the socket, hitting the `local` rule below.
    ##
    ## The socket entry stays `trust` because:
    ##   1. App containers bind-mount /run/postgresql and connect as
    ##      arbitrary roles (matrix-synapse, nextcloud, etc.) — peer
    ##      auth would require a pg_ident map for each one (the
    ##      container's UID rarely matches the role name).
    ##   2. Host-side root processes (the nextcloud/linkwarden/
    ##      zitadel prestarts that run CREATE ROLE / ALTER ROLE as
    ##      `postgres`) need passwordless socket access to bootstrap.
    ##      Switching to peer here would require all of those to set
    ##      up `root → postgres` map entries.
    ##   3. The socket itself lives under /run/postgresql which is
    ##      root:postgres 0775; only host-side processes that root
    ##      explicitly bind-mounts into a container can reach it.
    authentication = pkgs.lib.mkOverride 10 ''
      #type database  DBuser  auth-method
      local all       all     trust

      #type database DBuser origin-address auth-method
      # ipv4
      host  all      all     127.0.0.1/32   scram-sha-256
      # podman
      host  all      all     10.88.0.0/16   scram-sha-256
      # ipv6
      host all       all     ::1/128        scram-sha-256
    '';
  };
}
