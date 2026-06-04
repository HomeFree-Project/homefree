{ lib, pkgs, ... }:
let
  ## Anchors auto-generated secrets into encrypted /etc/nixos/secrets
  ## so they survive a restore — see lib/secrets-anchor.nix.
  anchor = import ../../lib/secrets-anchor.nix { inherit lib pkgs; };

  superuserPasswordDir = "/var/lib/homefree-secrets/postgres";
  superuserPasswordFile = "${superuserPasswordDir}/superuser-password";
in
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

  ## Anchor + rotate the `postgres` superuser password. Closes the
  ## Phase 2 TODO at apps/zitadel/default.nix where the literal
  ## "postgres" was sent over TCP as the ADMIN password — fine while
  ## pg_hba was `trust` (Phase 2 wave (a)), broken the moment Phase 2
  ## wave (b) flipped TCP to `scram-sha-256` on any box whose
  ## `postgres` role didn't happen to have a matching password.
  ##
  ## Design notes:
  ##  - Type=oneshot WITHOUT RemainAfterExit. The
  ##    oneshot+RemainAfterExit combo doesn't reliably re-run on
  ##    `nixos-rebuild switch` (bit us twice: Phase 1.5
  ##    zitadel-prepare-secrets, Phase 5 M9 setup-state). Plain
  ##    oneshot re-runs every switch, which is what we want — the
  ##    body is idempotent.
  ##  - `wantedBy + after = [ "postgresql.service" ]` so it fires
  ##    once postgres is up. ALTER USER via local socket (still
  ##    trust auth per pg_hba above) so no chicken-and-egg.
  ##  - The anchored value goes into encrypted
  ##    /etc/nixos/secrets/secrets.yaml via lib/secrets-anchor.nix,
  ##    so it survives a backup→restore.
  systemd.services.postgres-anchor-superuser-password = {
    description = "Anchor + rotate the postgres superuser password";
    wantedBy = [ "postgresql.service" ];
    after = [ "postgresql.service" ];
    requires = [ "postgresql.service" ];
    path = with pkgs; [ coreutils postgresql ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = false;
    };
    script = ''
      set -eu

      ${anchor.preamble}
      ${anchor.anchorSecret {
        service = "postgres";
        key = "superuser-password";
        dir = superuserPasswordDir;
        generate = "${pkgs.openssl}/bin/openssl rand -base64 32 | tr -d '/+=' | head -c 32";
      }}

      ## Wait for postgres to accept local socket connections —
      ## postgresql.service "active" doesn't necessarily mean the
      ## listener is up (initdb / recovery delay on first boot).
      for i in $(seq 1 60); do
        if ${pkgs.postgresql}/bin/pg_isready -h /run/postgresql -U postgres -q; then
          break
        fi
        sleep 1
      done

      ## Idempotent rotation: sets the role's password to the
      ## anchored value. No-op when they already match. Connects via
      ## the local socket under trust auth — does not need any
      ## existing password.
      PWD=$(cat ${superuserPasswordFile})
      ${pkgs.postgresql}/bin/psql -h /run/postgresql -U postgres \
        -c "ALTER USER postgres WITH PASSWORD '$PWD'" >/dev/null
    '';
  };
}
