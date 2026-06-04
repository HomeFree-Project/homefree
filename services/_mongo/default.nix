{ config, pkgs, ... }:
let
  ## tag 8.0 changes
  ## Use patch version for stability, e.g. "8.0.9"
  version = "8.2";
  containerDataPath = "/var/lib/mongo-podman";

  preStart = ''
    mkdir -p ${containerDataPath}
  '';
in
{
  virtualisation.oci-containers.containers.mongo = {
    image = "mongo:${version}";
    # image = "mongodb/mongodb-community-server:${version}";

    autoStart = true;

    extraOptions = [
      # "--pull=always"
    ];

    ports = [
      "0.0.0.0:27017:27017"
    ];

    volumes = [
      "/etc/localtime:/etc/localtime:ro"
      "${containerDataPath}:/data/db"
    ];

    environment = {
      TZ = config.homefree.system.timeZone;
      MONGO_INITDB_ROOT_USERNAME = "root";
      ## @TODO before re-enabling this module (rename `_mongo` → `mongo`):
      ## anchor the root password via lib/secrets-anchor.nix and feed it
      ## through environmentFiles, the same way snipe-it/nextcloud/
      ## zitadel do (see docs/agent-notes/security-audit-phase-5.md M8).
      ## Do NOT restore the literal `MONGO_INITDB_ROOT_PASSWORD =
      ## "password"` — that's the bug this empty-string default is
      ## documenting away. Mongo's image initialises with no
      ## authentication when PASSWORD is empty, which is fine for the
      ## inert state (the `_` prefix on the dirname blocks
      ## auto-discovery so the container never starts).
      MONGO_INITDB_ROOT_PASSWORD = "";
    };
  };

  systemd.services.podman-mongo = {
    after = [ "dns-ready.service" ];
    requires = [ "dns-ready.service" ];
    serviceConfig = {
      ExecStartPre = [ "!${pkgs.writeShellScript "mongo-prestart" preStart}" ];
    };
  };
}

