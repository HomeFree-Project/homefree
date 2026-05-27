## 3-2-1 Backup strategy
## 3 copies of data - original plus 2 copies
## 2 different devices or media types
## 1 offsite backup
{ config, lib, pkgs, ... }:
let
  trimTrailingSlash = s: lib.head (lib.match "(.*[^/])[/]*" s);
  backup-to-path = if config.homefree.backups.to-path != null
    then trimTrailingSlash config.homefree.backups.to-path
    else "/var/lib/backups";
  ## Mount point that must be live before any LOCAL backup writes to
  ## `backup-to-path`. If the backup target lives on a NAS/backup volume that
  ## is currently unmounted, writing would land on a stub directory on the
  ## root filesystem and restic (initialize = true) would create a brand-new
  ## empty repo there, shadowing the real one. The local pre-start guard
  ## refuses to run when this mount is not mounted. Explicit override wins;
  ## otherwise auto-derive the longest mount-point that `backup-to-path` sits
  ## under, considering BOTH network mounts (homefree.mounts) and local btrfs
  ## volumes (homefree.storage.pools) — volumes mount nofail, so a backup
  ## target sitting on one must be guarded too, or an unmounted volume sends
  ## restic to a stub on root (null => local-disk target, no gating).
  required-mount =
    if config.homefree.backups.require-mountpoint != null
    then config.homefree.backups.require-mountpoint
    else
      let
        mount-points =
          (lib.map (m: m.mount-point) config.homefree.mounts)
          ++ (lib.map (p: p.mountpoint)
                (lib.filter (p: p.enabled or true) config.homefree.storage.pools));
        cands = lib.filter
          (mp: lib.hasPrefix (mp + "/") (backup-to-path + "/"))
          mount-points;
        sorted = lib.sort (a: b: lib.stringLength a > lib.stringLength b) cands;
      in if sorted == [] then null else lib.head sorted;
  ## Combine service backup paths to extra custom paths into an array of { label = "label"; paths = []; }
  backup-from-paths-all =
    (lib.map (entry: {
      label = entry.label;
      paths = entry.backup.paths
        ## Add postgres database backup paths
        ++ (if (lib.length entry.backup.postgres-databases) > 0 then [ "/var/backup/postgresql-homefree/${entry.label}" ] else [])
        ## Add mysql database backup paths
        ++ (if (lib.length entry.backup.mysql-databases) > 0 then [ "/var/backup/mysql-homefree/${entry.label}" ] else []);
    }) config.homefree.service-config)
    ## Backup the system config
    ++ [{ label = "system-config"; paths = [ "/etc/nixos" ]; }]
    ## Backup each extra path individually. The label
    ## (extra-path-<id>) is owned by the entry's stable `id`, NOT by
    ## its position in the array — so disabling, deleting, or
    ## reordering rows can never rewire an existing restic repository
    ## to a different source path. `id` is filled in by the JSON→Nix
    ## loader (modules/homefree-config-loader.nix) and persisted into
    ## homefree-config.json by the on-activation migration below; the
    ## index-fallback there preserves existing extra-path-N labels
    ## bit-identically on the first rebuild after upgrade.
    ## A disabled entry yields an empty `paths` list, which the
    ## `filtered-backup-from-paths` filter below drops, so no backup
    ## unit is generated for it. Orphaned repos (id no longer in the
    ## config) are left in place — purge them via the admin UI.
    ++ (lib.imap0 (index: entry: {
      label = "extra-path-${if entry.id != "" then entry.id else toString index}";
      paths = if entry.enabled then [ entry.path ] else [];
    }) config.homefree.backups.extra-from-paths);
  ## filter out any entries without backup paths
  filtered-backup-from-paths = lib.filter (entry: (lib.length entry.paths) > 0) backup-from-paths-all;
  ## Only populate paths if backups enabled
  backup-from-paths = if config.homefree.backups.enable == true then filtered-backup-from-paths else [];
  postgres-databases = lib.flatten (lib.map (entry: entry.backup.postgres-databases) config.homefree.service-config);
  service-to-postgres-databases-map  = lib.listToAttrs (lib.map (entry: {
    name = entry.label;
    value = entry.backup.postgres-databases;
  }) config.homefree.service-config);
  mysql-databases = lib.flatten (lib.map (entry: entry.backup.mysql-databases) config.homefree.service-config);
  service-to-mysql-databases-map  = lib.listToAttrs (lib.map (entry: {
    name = entry.label;
    value = entry.backup.mysql-databases;
  }) config.homefree.service-config);
  ## Backblaze B2 is used as a NATIVE restic repository (b2:bucket:label),
  ## not a mounted filesystem. restic talks to B2 directly; offsite gets a
  ## real restic repo with its own snapshot history and retention - so a
  ## corrupt latest snapshot can be rolled back offsite too, and `prune`
  ## bounds the offsite size. The credentials live in an EnvironmentFile.
  backblaze-enabled = config.homefree.backups.enable
    && config.homefree.backups.backblaze.enable;
  backblaze-bucket = config.homefree.backups.backblaze.bucket;
  restic-env-file = "/var/lib/homefree-secrets/backup/restic-environment";
  restore-cli = pkgs.writeShellScriptBin "restore-cli" ''
    export PATH="${pkgs.coreutils}/bin:${pkgs.util-linux}/bin:${pkgs.restic}/bin:${pkgs.findutils}/bin:${pkgs.gnugrep}/bin:${pkgs.gawk}/bin:${pkgs.gnused}/bin:${pkgs.rsync}/bin:${pkgs.gzip}/bin:${pkgs.sudo}/bin:${pkgs.postgresql}/bin:${pkgs.mariadb}/bin:${pkgs.jq}/bin:${pkgs.rclone}/bin:$PATH"
    ## Point the script at the configured local backup directory. Without
    ## this it falls back to its built-in default (/var/lib/backups) and
    ## cannot find repositories under a custom backups.to-path.
    export BACKUP_LOCAL_PATH="${backup-to-path}"
    ## Backblaze B2 is a native restic repo - tell the script the bucket
    ## and where the B2 credentials live so `--source backblaze` works.
    export BACKBLAZE_BUCKET="${if backblaze-enabled then backblaze-bucket else ""}"
    export RESTIC_ENV_FILE="${restic-env-file}"
    exec ${pkgs.bash}/bin/bash ${../../scripts/restore.sh} "$@"
  '';
  backup-mysql-script =
  let
    cfg = config.services.mysqlBackup;
  in
    db: ''
      dest="${cfg.location}/${db}.gz"
      if ${pkgs.mariadb}/bin/mysqldump ${lib.optionalString cfg.singleTransaction "--single-transaction"} ${db} | ${pkgs.gzip}/bin/gzip -c ${cfg.gzipOptions} > $dest.tmp; then
        mv $dest.tmp $dest
        echo "Backed up to $dest"
      else
        echo "Failed to back up to $dest"
        rm -f $dest.tmp
        failed="$failed ${db}"
      fi
    '';
in
{
  ## Typical rsync command
  ## rsync -avzP --delete --no-links src dest

  ## To see files in backup
  ## sudo restic ls latest -r local:<backup path>

  environment.systemPackages = [
    pkgs.restic
    restore-cli
    pkgs.jq
  ];

  # --------------------------------------------------------------------------------------
  # Postgres Dumps
  # --------------------------------------------------------------------------------------

  services.postgresqlBackup = {
    enable = config.homefree.backups.enable;
    ## Default location. Just repeated here for reference and stability.
    location = "/var/backup/postgresql";
    databases = postgres-databases;
    ## This isn't really used, as backups are kicked off by restic below,
    ## so select the least frequent period.
    startAt = "yearly";
  };

  # --------------------------------------------------------------------------------------
  # Mysql Dumps
  # --------------------------------------------------------------------------------------

  ## This service is only used for its config, but not actually run backups
  ## @TODO: Discard this
  services.mysqlBackup = {
    enable = config.homefree.backups.enable;
    ## Default location. Just repeated here for reference and stability.
    location = "/var/backup/mysql";
    databases = mysql-databases;
    ## This isn't really used, as backups are kicked off by restic below,
    ## so select the least frequent period.
    calendar = "01-01-01";
  };

  # --------------------------------------------------------------------------------------
  # Raw Snapshots
  # --------------------------------------------------------------------------------------

  # systemd.services.backups-snapshot = {
  #   enable = true;
  #   description = "Sync backup snapshot to nas";
  #   serviceConfig = {
  #     Type = "oneshot";
  #   };
  #   script = ''
  #     ${pkgs.rsync}/bin/rsync -avzP --delete /home/homefree/DockerData /mnt/Backups/snapshots/homefree/
  #   '';
  # };
  #
  # systemd.timers.backups-snapshot = {
  #   wantedBy = [ "timers.target" ];
  #   partOf = [ "snapshot-to-nas.service" ];
  #   timerConfig = {
  #     OnCalendar = "daily";
  #     Unit = "snapshot-to-nas.service";
  #   };
  # };

  # --------------------------------------------------------------------------------------
  # Incremental Backups
  # --------------------------------------------------------------------------------------

  ## Shared retention: keep 7 daily, 5 weekly, 10 yearly snapshots.
  ## restic prune enforces this, which also bounds repository size.

  services.restic.backups = lib.mkMerge ([
    ## --- Local restic repositories (on-disk, primary copy) -------------
    (lib.listToAttrs (lib.map (entry:
    {
      name = "local-${entry.label}";
      value = {
        initialize = true;
        passwordFile = "/var/lib/homefree-secrets/backup/restic-password";
        paths = entry.paths;
        repository = backup-to-path + "/${entry.label}";
        # Run after 02:00, staggered across a 45-minute window so the ~40
        # restic jobs don't all contend for disk/CPU at once.
        # Persistent so a missed run (box off) catches up.
        timerConfig = {
          OnCalendar = "02:00";
          RandomizedDelaySec = "45m";
          Persistent = true;
        };
        pruneOpts = [
          "--keep-daily 7"
          "--keep-weekly 5"
          "--keep-yearly 10"
        ];
      };
    }
    ) backup-from-paths))
  ]
  ## --- Backblaze B2 restic repositories (offsite, native) ------------
  ## Each service gets its own native restic repo at b2:<bucket>:<label>.
  ## This is a real restic repository with independent snapshot history
  ## and retention - NOT an rsync mirror of the local copy. A corrupt
  ## local snapshot therefore cannot corrupt the offsite copy, and a
  ## corrupt latest snapshot can be rolled back to an earlier one offsite.
  ++ lib.optionals backblaze-enabled [
    (lib.listToAttrs (lib.map (entry:
    {
      name = "backblaze-${entry.label}";
      value = {
        initialize = true;
        passwordFile = "/var/lib/homefree-secrets/backup/restic-password";
        environmentFile = restic-env-file;  # B2_ACCOUNT_ID / B2_ACCOUNT_KEY
        paths = entry.paths;
        repository = "b2:${backblaze-bucket}:${entry.label}";
        # Run after 04:00 - well after the 02:00-02:45 local window, so the
        # offsite job picks up the freshly-written local DB dumps and does
        # not contend with local backups for disk.
        timerConfig = {
          OnCalendar = "04:00";
          RandomizedDelaySec = "45m";
          Persistent = true;
        };
        pruneOpts = [
          "--keep-daily 7"
          "--keep-weekly 5"
          "--keep-yearly 10"
        ];
      };
    }
    ) backup-from-paths))
  ]);

  ## A restic backup unit's ExecStartPre: refresh this service's database
  ## dumps so the snapshot captures an up-to-date dump. Used by BOTH the
  ## local and the Backblaze backup units for a given service, so each
  ## repository is internally consistent regardless of run order.
  ##
  ## The dump step FAILS LOUDLY if a dump did not succeed - a backup must
  ## never silently capture a stale database dump.
  systemd.services =
  let
    ## Source paths to guard: the entry's own paths MINUS the generated
    ## database-dump directories (those are produced by the DB-dump step
    ## further down in this same script, so they legitimately do not exist
    ## yet at guard time). Guard only the real, pre-existing sources.
    db-dump-roots = [ "/var/backup/postgresql-homefree" "/var/backup/mysql-homefree" ];
    isDbDumpPath = p: lib.any (root: lib.hasPrefix (root + "/") (p + "/")) db-dump-roots;
    sourcePathsToGuard = entry: lib.filter (p: ! isDbDumpPath p) entry.paths;

    mkPreStart = entry: prefix: pkgs.writeShellScript "restic-backup-prestart-${prefix}-${entry.label}" (''
      set -euo pipefail
      ## ----------------------------------------------------------------
      ## Source guard (both local and Backblaze): refuse to back up a
      ## source that is missing or empty. A missing source already makes
      ## restic fail safely, but an EMPTY-but-present source (e.g. a NAS
      ## remounted but not yet repopulated, or an empty mountpoint stub)
      ## would snapshot successfully and then `prune` away real history -
      ## the catastrophic case. Abort loudly before any snapshot.
      ## ----------------------------------------------------------------
    ''
    + (lib.concatMapStrings (p: ''
      if [ ! -e ${lib.escapeShellArg p} ]; then
        echo "ERROR: backup source ${p} is missing - refusing to snapshot a missing source. Aborting." >&2
        exit 1
      fi
      if [ -d ${lib.escapeShellArg p} ] && [ -z "$(${pkgs.coreutils}/bin/ls -A ${lib.escapeShellArg p} 2>/dev/null)" ]; then
        echo "ERROR: backup source ${p} is an empty directory (NAS not mounted/populated?) - refusing to snapshot an empty source and prune real history. Aborting." >&2
        exit 1
      fi
      if [ -f ${lib.escapeShellArg p} ] && [ ! -s ${lib.escapeShellArg p} ]; then
        echo "ERROR: backup source file ${p} is empty - aborting." >&2
        exit 1
      fi
    '') (sourcePathsToGuard entry))
    ## ----------------------------------------------------------------
    ## Target-mount guard + repo-dir creation: LOCAL units only. The
    ## Backblaze target is a `b2:` remote, not a filesystem, so neither
    ## the mount guard nor the local repo-dir mkdir applies there.
    ## ----------------------------------------------------------------
    + (lib.optionalString (prefix == "local") ''
      ${lib.optionalString (required-mount != null) ''
        ## The backup target lives under a mount that must be live. Nudge
        ## x-systemd.automount by touching the mount root, then verify. If
        ## the volume is genuinely gone the mount will not come up and we
        ## abort BEFORE any mkdir/init - so we never create an empty repo
        ## on a root-filesystem stub that would shadow the real one.
        ${pkgs.coreutils}/bin/ls ${lib.escapeShellArg required-mount} >/dev/null 2>&1 || true
        if ! ${pkgs.util-linux}/bin/mountpoint -q ${lib.escapeShellArg required-mount}; then
          echo "ERROR: backup target mount ${required-mount} is not mounted - refusing to write to a stub on the root filesystem (would create an empty restic repo and shadow the real one). Aborting." >&2
          exit 1
        fi
      ''}
      ## Make sure the local backup path exists (only AFTER the mount is
      ## verified - the previously-unconditional mkdir was the root cause
      ## of empty stub repos being created on an unmounted target).
      mkdir -p "${backup-to-path + "/${entry.label}"}"
    '')
    + (lib.optionalString (lib.hasAttr entry.label service-to-postgres-databases-map)
        (lib.concatMapStrings (database: ''
          ## Refresh the PostgreSQL dump for ${database}. `systemctl restart`
          ## of a Type=oneshot blocks until the dump finishes and returns
          ## non-zero if it failed - so a stale dump can never be captured.
          echo "Dumping PostgreSQL database ${database}..."
          if ! systemctl restart postgresqlBackup-${database}; then
            echo "ERROR: PostgreSQL dump for ${database} failed - aborting backup" >&2
            exit 1
          fi
          if [ ! -s "/var/backup/postgresql/${database}.sql.gz" ]; then
            echo "ERROR: PostgreSQL dump /var/backup/postgresql/${database}.sql.gz missing or empty" >&2
            exit 1
          fi
          mkdir -p "/var/backup/postgresql-homefree/${entry.label}"
          cp -f "/var/backup/postgresql/${database}.sql.gz" "/var/backup/postgresql-homefree/${entry.label}/"
        '') service-to-postgres-databases-map.${entry.label}))
    + (lib.optionalString (lib.hasAttr entry.label service-to-mysql-databases-map)
        (lib.concatMapStrings (database: ''
          echo "Dumping MySQL database ${database}..."
          ${backup-mysql-script database}
          if [ -n "''${failed:-}" ]; then
            echo "ERROR: MySQL dump for ${database} failed - aborting backup" >&2
            exit 1
          fi
          if [ ! -s "${config.services.mysqlBackup.location}/${database}.gz" ]; then
            echo "ERROR: MySQL dump for ${database} missing or empty" >&2
            exit 1
          fi
          mkdir -p "/var/backup/mysql-homefree/${entry.label}"
          cp -f "${config.services.mysqlBackup.location}/${database}.gz" "/var/backup/mysql-homefree/${entry.label}/"
        '') service-to-mysql-databases-map.${entry.label})));

    ## Override applied to each restic-backups-<prefix>-<label> unit:
    ## prepend the DB-dump preStart (mkBefore so it runs before the restic
    ## module's own ExecStartPre). Backblaze units additionally require the
    ## B2 credentials env file to have been generated.
    mkUnitOverride = entry: prefix: {
      name = "restic-backups-${prefix}-${entry.label}";
      value = {
        serviceConfig.ExecStartPre =
          lib.mkBefore [ "!${mkPreStart entry prefix}" ];
      } // (lib.optionalAttrs (prefix == "backblaze") {
        after = [ "backup-b2-env.service" ];
        requires = [ "backup-b2-env.service" ];
        ## Belt-and-suspenders: also assert the env file exists at start,
        ## in case backup-b2-env's RemainAfterExit-less state drifted.
        unitConfig.ConditionPathExists = restic-env-file;
      });
    };

    ## Generates the restic B2 credentials EnvironmentFile from the
    ## admin-managed backblaze-id / backblaze-key secrets. restic's B2
    ## backend reads B2_ACCOUNT_ID / B2_ACCOUNT_KEY from the environment.
    ##
    ## This is a oneshot WITHOUT RemainAfterExit so it re-runs every
    ## rebuild/boot and stays in sync if the credentials change.
    b2EnvUnit = lib.optionalAttrs backblaze-enabled {
      backup-b2-env = {
        description = "Generate restic Backblaze B2 credentials env file";
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          Type = "oneshot";
          User = "root";
          ExecStart = pkgs.writeShellScript "backup-b2-env" ''
            set -euo pipefail
            id_file=/var/lib/homefree-secrets/backup/backblaze-id
            key_file=/var/lib/homefree-secrets/backup/backblaze-key
            if [ ! -s "$id_file" ] || [ ! -s "$key_file" ]; then
              echo "Backblaze credentials not configured yet; skipping" >&2
              exit 0
            fi
            umask 077
            tmp=$(mktemp)
            {
              echo "B2_ACCOUNT_ID=$(cat "$id_file")"
              echo "B2_ACCOUNT_KEY=$(cat "$key_file")"
            } > "$tmp"
            mv "$tmp" "${restic-env-file}"
            chmod 0600 "${restic-env-file}"
          '';
        };
      };
    };
  in
    b2EnvUnit // lib.listToAttrs (
      (lib.map (entry: mkUnitOverride entry "local") backup-from-paths)
      ++ lib.optionals backblaze-enabled
        (lib.map (entry: mkUnitOverride entry "backblaze") backup-from-paths)
    );

  ## --------------------------------------------------------------------
  ## On-activation migration: persist stable `id`s into
  ## backups.extra-from-paths in /etc/nixos/homefree-config.json.
  ##
  ## Without an id, the restic repository label was derived from the
  ## entry's position in the array (extra-path-N via lib.imap0). That
  ## meant deleting a middle row shifted every later index down by one,
  ## rewiring existing restic repositories to back up DIFFERENT source
  ## paths — silently corrupting snapshot history. The fix is to bind
  ## the label to a stable per-entry id; this script runs once per
  ## rebuild and fills in `id = str(current_index)` for any legacy
  ## entry that lacks one, so existing extra-path-N labels (and their
  ## restic repos) are preserved bit-identically across the upgrade.
  ##
  ## Idempotent: a no-op when every entry already has a non-empty id.
  ## Tolerates malformed JSON / missing file (fresh installs run before
  ## the installer has written the config). Runs unconditionally —
  ## the migration matters even when backups are currently disabled.
  ## --------------------------------------------------------------------
  system.activationScripts.homefree-backup-extra-paths-id-migrate = {
    text = ''
      ${pkgs.python3}/bin/python3 ${pkgs.writeText "homefree-backup-extra-paths-id-migrate.py" ''
        """Persist stable ids into backups.extra-from-paths in
        homefree-config.json. See services/backup/default.nix for
        rationale.
        """
        import json
        import os
        import stat
        import sys
        import tempfile

        CONFIG = "/etc/nixos/homefree-config.json"

        def main() -> int:
            if not os.path.exists(CONFIG):
                return 0
            try:
                with open(CONFIG, "r", encoding="utf-8") as f:
                    data = json.load(f)
            except (OSError, json.JSONDecodeError) as e:
                print(
                    f"homefree-backup-id-migrate: cannot read "
                    f"{CONFIG}: {e}",
                    file=sys.stderr,
                )
                return 0

            backups = data.get("backups")
            if not isinstance(backups, dict):
                return 0
            entries = backups.get("extra-from-paths")
            if not isinstance(entries, list):
                return 0

            changed = False
            new_entries = []
            for index, entry in enumerate(entries):
                if isinstance(entry, str):
                    new_entries.append({
                        "id": str(index),
                        "path": entry,
                        "enabled": True,
                    })
                    changed = True
                elif isinstance(entry, dict):
                    has_id = (
                        isinstance(entry.get("id"), str)
                        and entry.get("id") != ""
                    )
                    if has_id:
                        new_entries.append(entry)
                    else:
                        merged = {"id": str(index)}
                        for k, v in entry.items():
                            if k == "id":
                                continue
                            merged[k] = v
                        new_entries.append(merged)
                        changed = True
                else:
                    new_entries.append(entry)

            if not changed:
                return 0

            backups["extra-from-paths"] = new_entries

            target_dir = os.path.dirname(CONFIG)
            current_mode = None
            try:
                current_mode = stat.S_IMODE(os.stat(CONFIG).st_mode)
            except OSError:
                pass

            fd, tmp = tempfile.mkstemp(
                dir=target_dir,
                prefix=".homefree-config.",
                suffix=".tmp",
            )
            try:
                with os.fdopen(fd, "w", encoding="utf-8") as f:
                    f.write(json.dumps(data, indent=2, sort_keys=False))
                    f.write("\n")
                    f.flush()
                    os.fsync(f.fileno())
                if current_mode is not None:
                    os.chmod(tmp, current_mode)
                os.replace(tmp, CONFIG)
            except Exception:
                try:
                    os.unlink(tmp)
                except OSError:
                    pass
                raise

            print(
                f"homefree-backup-id-migrate: assigned stable ids to "
                f"{len(new_entries)} extra-from-paths entries",
                file=sys.stderr,
            )
            return 0

        if __name__ == "__main__":
            sys.exit(main())
      ''}
    '';
    deps = [];
  };
}
