## backup-canary
##
## A deliberately tiny "service" whose ONLY purpose is to verify the
## HomeFree backup/restore pipeline end to end. It looks and behaves like
## a real catalog service - native systemd unit, a Postgres database, a
## data directory, a web page - but holds nothing but throwaway data.
##
## A writer refreshes a "marker" (timestamp + random token) in both the
## data dir and the database on a timer. A nightly self-test then backs
## up the canary, mutates the marker, restores the snapshot, and asserts
## the marker reverted - proving backups actually work. The result is
## surfaced on the canary's web page and in the admin Backups module.
##
## Disabled by default; opt in with homefree.service-options.backup-canary.
{ config, lib, pkgs, ... }:
let
  cfg = config.homefree.service-options.backup-canary;

  data-dir = "/var/lib/backup-canary";
  db-name = "backup_canary";
  port = 8099;

  ## The canary's Postgres operations run as the system superuser role so
  ## the writer / self-test can psql without a password (peer auth).
  db-role = "postgres";

  ## A wrapper that always runs psql against the canary DB with a clean
  ## environment. The scripts below invoke `psql` directly via PATH.
  canary-env = {
    CANARY_DATA_DIR = data-dir;
    CANARY_DB = db-name;
    CANARY_PORT = toString port;
  };

  canary-server = pkgs.writeShellScriptBin "backup-canary-server" ''
    export PATH="${lib.makeBinPath [ pkgs.postgresql ]}:$PATH"
    exec ${pkgs.python3}/bin/python3 ${./canary-server.py}
  '';

  canary-writer = pkgs.writeShellScriptBin "canary-writer" ''
    export PATH="${lib.makeBinPath [
      pkgs.coreutils pkgs.postgresql pkgs.util-linux
    ]}:$PATH"
    exec ${pkgs.bash}/bin/bash ${./canary-writer.sh} "$@"
  '';

  canary-selftest = pkgs.writeShellScriptBin "canary-selftest" ''
    export PATH="${lib.makeBinPath [
      pkgs.coreutils pkgs.postgresql pkgs.systemd pkgs.util-linux
    ]}:$PATH"
    ## restore-cli is provided by services/backup via the system profile;
    ## use the stable profile path so it tracks the deployed generation.
    export RESTORE_CLI="/run/current-system/sw/bin/restore-cli"
    export CANARY_WRITER="${canary-writer}/bin/canary-writer"
    exec ${pkgs.bash}/bin/bash ${./canary-selftest.sh} "$@"
  '';
in
{
  options.homefree.service-options.backup-canary = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Enable the backup-canary service. It verifies that the backup
        and restore pipeline works, using only throwaway data.
      '';
    };

    public = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Open the canary web page to the public WAN.";
    };

    selftest-source = lib.mkOption {
      type = lib.types.enum [ "local" "backblaze" "both" ];
      default = "local";
      description = ''
        Which backup source the automated self-test exercises:
        'local' (on-disk repo), 'backblaze' (offsite B2 repo), or
        'both'. Backblaze must be configured for the latter two.
      '';
    };

    # Metadata - always available, not user-configurable.
    label = lib.mkOption {
      type = lib.types.str;
      default = "backup-canary";
      internal = true;
      description = "Service label";
    };

    name = lib.mkOption {
      type = lib.types.str;
      default = "Backup Self-Test";
      internal = true;
      description = "Service display name";
    };

    project-name = lib.mkOption {
      type = lib.types.str;
      default = "Backup Self-Test";
      internal = true;
      description = "Project name";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [
      canary-server
      canary-writer
      canary-selftest
    ];

    ## The canary's database. Owned by the postgres superuser role so the
    ## writer/self-test reach it over peer auth without a password.
    services.postgresql = {
      enable = true;
      ensureDatabases = [ db-name ];
    };

    ## --- The canary web service -------------------------------------
    systemd.services.backup-canary = {
      description = "HomeFree backup canary web service";
      after = [ "postgresql.service" "network.target" ];
      wants = [ "postgresql.service" ];
      wantedBy = [ "multi-user.target" ];
      environment = canary-env;
      serviceConfig = {
        Type = "simple";
        User = db-role;
        ExecStartPre = "!${pkgs.writeShellScript "backup-canary-prestart" ''
          mkdir -p ${data-dir}
          chown ${db-role} ${data-dir}
        ''}";
        ExecStart = "${canary-server}/bin/backup-canary-server";
        Restart = "on-failure";
        RestartSec = "5s";
      };
    };

    ## --- The marker writer ------------------------------------------
    ## Runs at activation/boot AND hourly. The activation run matters:
    ## it ensures the canary has data (a marker file + a DB row) the
    ## moment the service is enabled, so a self-test triggered straight
    ## after enabling does not fail on an uninitialised canary.
    systemd.services.backup-canary-writer = {
      description = "Refresh the backup-canary marker";
      after = [ "postgresql.service" ];
      requires = [ "postgresql.service" ];
      wantedBy = [ "multi-user.target" ];
      environment = canary-env;
      serviceConfig = {
        Type = "oneshot";
        User = db-role;
        ExecStart = "${canary-writer}/bin/canary-writer";
      };
    };

    systemd.timers.backup-canary-writer = {
      description = "Periodically refresh the backup-canary marker";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        ## Refresh hourly so each daily snapshot differs from the last.
        OnCalendar = "hourly";
        Persistent = true;
      };
    };

    ## --- The automated self-test (runs daily) -----------------------
    ## Runs as root: it drives systemctl (backup units) and restore-cli,
    ## which need root. The script is hardcoded to act only on the
    ## "backup-canary" service.
    systemd.services.backup-canary-selftest = {
      description = "Verify the backup/restore pipeline via the canary";
      after = [ "postgresql.service" ];
      wants = [ "postgresql.service" ];
      environment = canary-env // {
        CANARY_SELFTEST_SOURCE = cfg.selftest-source;
      };
      serviceConfig = {
        Type = "oneshot";
        User = "root";
        ExecStart = "${canary-selftest}/bin/canary-selftest";
      };
    };

    systemd.timers.backup-canary-selftest = {
      description = "Daily backup self-test via the canary";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        ## After the local (02:00) and Backblaze (04:00) backup windows.
        OnCalendar = "05:30";
        RandomizedDelaySec = "15m";
        Persistent = true;
      };
    };

    ## --- Catalog registration ---------------------------------------
    ## Registering the canary as a real catalog service is the point: it
    ## gets backed up, and stop/start-resolved, exactly like any service.
    homefree.service-config = [{
      inherit (cfg) label name project-name;

      sso = {
        kind = "none";
        notes = ''
          The backup canary holds only throwaway data and exposes no
          sensitive information; it is intentionally not SSO-gated.
        '';
      };

      ## The exact unit the restore path stops/starts for this service.
      systemd-service-names = [
        "backup-canary"
      ];

      reverse-proxy = {
        enable = cfg.enable;
        subdomains = [ "canary" ];
        http-domains = [ "homefree.lan" config.homefree.system.localDomain ];
        https-domains = [ config.homefree.system.domain ];
        host = config.homefree.network.lan-address;
        port = port;
        public = cfg.public;
      };

      backup = {
        paths = [ data-dir ];
        postgres-databases = [ db-name ];
      };

      options-metadata = [
        {
          path = "enable";
          type = "bool";
          default = false;
          description = "Enable the backup canary self-test service";
        }
        {
          path = "public";
          type = "bool";
          default = false;
          description = "Make the canary page accessible from WAN";
        }
        {
          path = "selftest-source";
          type = "str";
          default = "local";
          description = "Backup source the self-test verifies: local, backblaze, or both";
        }
      ];
    }];
  };
}
