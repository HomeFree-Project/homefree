## ─── Forgejo → Radicle mirror ──────────────────────────────────────
##
## Periodic one-way mirror of Forgejo's non-empty PUBLIC repos to the
## local Radicle node. Each Forgejo repo gets a sidecar clone under
## /var/lib/radicle/forgejo-mirror/<owner>--<repo>/, which is
## `rad init`-ed once (assigning a stable RID) and then refreshed
## with `git fetch origin && git push rad` on every timer tick.
##
## Architecture choice (vs Forgejo git hooks): Forgejo writes its
## hooks per-repo under `<bare>.git/hooks/post-receive.d/`, so a
## "central declarative hook" doesn't exist on this version. Making
## hooks declarative would require a systemd job that walks all
## repos and installs symlinks into each `.d/` dir — effectively a
## timer for symlink maintenance, with newly-created repos still
## missing the hook until the next install pass. The timer-only
## approach below has one moving part and is deterministic across
## new-repo creation.
##
## Source-of-truth for "which repos are public and non-empty":
## Forgejo's SQLite DB at /var/lib/forgejo/data/forgejo.db. We
## read it directly with a single sqlite3 query — no Forgejo API
## token, no auth surface.

{ config, lib, pkgs, ... }:
let
  cfg = config.homefree.service-options.radicle;

  forgejoRoot = "/var/lib/forgejo";
  forgejoReposDir = "${forgejoRoot}/git/repositories";
  ## Forgejo keeps backwards-compatible paths from its Gitea origin:
  ## the runtime data dir is `gitea/` (not `data/`) and the SQLite
  ## file is `gitea.db` (not `forgejo.db`). Verified on the live box.
  forgejoDb = "${forgejoRoot}/gitea/gitea.db";

  radicleHome = "/var/lib/radicle";
  mirrorRoot = "${radicleHome}/forgejo-mirror";
  passphraseFile = "/var/lib/homefree-secrets/radicle/passphrase";

  ## sqlite3 is provided by pkgs.sqlite; rad lives in radicle-node's
  ## bin/ as `rad` (the same wrapper the container uses, but here
  ## we invoke it natively on the host with RAD_HOME pointing at the
  ## node's storage tree).
  syncScript = pkgs.writeShellApplication {
    name = "radicle-forgejo-mirror-sync";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.gitMinimal
      pkgs.openssh
      pkgs.sqlite
      pkgs.radicle-node
    ];
    text = ''
      set -euo pipefail

      ## RAD_HOME is the same data dir the radicle-node container
      ## mounts as /root/.radicle. The host-side `rad` reads/writes
      ## the same storage tree, so refs we push here are visible
      ## to the node immediately (no IPC needed beyond shared FS).
      export RAD_HOME=${radicleHome}

      ## Unlock the node key. The radicle CLI expects RAD_PASSPHRASE
      ## as a literal env value (no _FILE variant). We read the
      ## anchored passphrase here and DO NOT log it.
      if [ ! -r ${passphraseFile} ]; then
        echo "radicle-forgejo-mirror: passphrase not readable at ${passphraseFile}" >&2
        exit 1
      fi
      RAD_PASSPHRASE=$(cat ${passphraseFile})
      export RAD_PASSPHRASE

      mkdir -p ${mirrorRoot}

      ## Query Forgejo's SQLite for non-private, non-empty repos.
      ## Schema (stable across Forgejo minor versions):
      ##   user.id, user.lower_name
      ##   repository.owner_id, repository.lower_name,
      ##                        repository.is_private, repository.is_empty
      ## lower_name is the on-disk dir name; Forgejo always lowercases
      ## both the owner and the repo when laying out the bare repos.
      if [ ! -r ${forgejoDb} ]; then
        echo "radicle-forgejo-mirror: forgejo DB not readable at ${forgejoDb}; nothing to mirror" >&2
        exit 0
      fi

      mapfile -t SLUGS < <(
        sqlite3 -readonly ${forgejoDb} \
          "SELECT u.lower_name || '/' || r.lower_name
           FROM repository r
           JOIN user u ON r.owner_id = u.id
           WHERE r.is_private = 0 AND r.is_empty = 0
           ORDER BY u.lower_name, r.lower_name;"
      )

      if [ ''${#SLUGS[@]} -eq 0 ]; then
        echo "radicle-forgejo-mirror: no public non-empty repos found"
        exit 0
      fi

      ## Track outcomes so the unit's final exit reflects the cycle.
      n_ok=0
      n_skip=0
      n_fail=0

      for slug in "''${SLUGS[@]}"; do
        owner="''${slug%/*}"
        name="''${slug#*/}"
        bare="${forgejoReposDir}/$owner/$name.git"
        ## `<owner>--<name>` flattens the slug; `/` would collide
        ## with directory hierarchy and `--` is illegal in Forgejo
        ## repo names so there's no slug collision risk.
        mirror="${mirrorRoot}/$owner--$name"

        if [ ! -d "$bare" ]; then
          echo "skip $slug: bare repo missing ($bare)"
          n_skip=$((n_skip + 1))
          continue
        fi

        ## First-run: clone the Forgejo bare repo as a NON-bare repo
        ## with --no-checkout (no working tree on disk — `rad init`
        ## only reads refs and HEAD, not the worktree). Then add an
        ## `origin` remote pointing back at the live bare so future
        ## ticks can `git fetch` for updates.
        if [ ! -d "$mirror/.git" ]; then
          echo "init $slug → $mirror"
          if ! git clone --no-checkout "$bare" "$mirror"; then
            echo "fail $slug: clone failed"
            n_fail=$((n_fail + 1))
            continue
          fi
        fi

        cd "$mirror"

        ## Always re-pin origin to the current bare path — handles
        ## the case where Forgejo's data dir moves or the bare
        ## repo gets recreated under a new path.
        git remote set-url origin "$bare" 2>/dev/null \
          || git remote add origin "$bare"

        ## Detect the default branch from the Forgejo bare repo.
        ## Forgejo writes `ref: refs/heads/<name>` to HEAD; we read
        ## that directly rather than guessing "main" vs "master".
        default_branch=$(git -C "$bare" symbolic-ref --short HEAD 2>/dev/null || echo main)

        ## Idempotent `rad init`. Detect prior init by the presence
        ## of a `rad` remote — `rad init` adds it on success. NB: we
        ## intentionally do NOT pass `--no-seed`; that flag tells the
        ## node not to seed the repo, which then makes radicle-httpd
        ## (and the explorer) report 0 repos — defeats the mirror.
        ## Default scope is "all" — every remote node that fetches
        ## from us gets followed for this repo (fine for a public
        ## mirror).
        if ! git remote | grep -qx rad; then
          echo "rad-init $slug (default-branch=$default_branch)"
          if ! rad init \
              --name "$name" \
              --description "Mirror of $slug from Forgejo" \
              --default-branch "$default_branch" \
              --public \
              --no-confirm \
              2>&1 | sed "s|^|  rad-init[$slug]: |"; then
            echo "fail $slug: rad init failed"
            n_fail=$((n_fail + 1))
            cd - >/dev/null
            continue
          fi
        fi

        ## Pull latest refs from Forgejo into the mirror.
        ##
        ## --update-head-ok: the clone has HEAD pointing at the
        ## default branch (refs/heads/<default-branch>), and git's
        ## default safety refuses to fetch into the checked-out
        ## branch. That check is for interactive workflows where
        ## the worktree could diverge from the index — irrelevant
        ## here: this clone has no working tree (cloned with
        ## --no-checkout) and no one runs `git` in it interactively.
        ## Without this flag the first cycle works (clone seeded
        ## the refs) but every subsequent cycle silently fails to
        ## pick up new Forgejo pushes.
        ##
        ## --prune: drop branches that Forgejo no longer has, so the
        ## radicle mirror eventually loses retired branches too.
        if ! git fetch origin \
            "+refs/heads/*:refs/heads/*" \
            "+refs/tags/*:refs/tags/*" \
            --prune --update-head-ok 2>&1 | sed "s|^|  fetch[$slug]: |"; then
          echo "fail $slug: fetch failed"
          n_fail=$((n_fail + 1))
          cd - >/dev/null
          continue
        fi

        ## Push to radicle. --force propagates Forgejo-side force
        ## pushes (this is a mirror, divergence is always one-way).
        if ! ( git push rad --force --all 2>&1 | sed "s|^|  push-heads[$slug]: |" \
            && git push rad --force --tags 2>&1 | sed "s|^|  push-tags[$slug]: |" ); then
          echo "warn $slug: rad push failed (will retry next tick)"
          n_fail=$((n_fail + 1))
          cd - >/dev/null
          continue
        fi

        ## Idempotently apply the seeding policy. EVERY tick — not
        ## just when we init — so the six repos already created
        ## with --no-seed (before this bug was fixed) get retroactively
        ## seeded too. Extract the RID from the `rad` remote URL
        ## (format: rad://<RID> for fetch, rad://<RID>/<NID> for push).
        rid=$(git remote get-url rad | sed 's|^rad://||' | cut -d/ -f1)
        if [ -n "$rid" ]; then
          if ! rad seed "$rid" --scope all 2>&1 | sed "s|^|  rad-seed[$slug]: |"; then
            echo "warn $slug: rad seed failed (push succeeded; will retry next tick)"
          fi
        fi

        n_ok=$((n_ok + 1))
        cd - >/dev/null
      done

      echo "radicle-forgejo-mirror: cycle complete (ok=$n_ok skip=$n_skip fail=$n_fail)"
    '';
  };

  enabled = cfg.enable && cfg.forgejo-mirror;
in
{
  config = lib.mkIf enabled {
    systemd.services.radicle-forgejo-mirror = {
      description = "One-way mirror of Forgejo public repos to Radicle";
      ## The local node must be up before rad init can announce a
      ## new RID. Requires= so the unit refuses to run during a
      ## node restart instead of timing out mid-cycle.
      after = [ "podman-radicle-node.service" ];
      requires = [ "podman-radicle-node.service" ];
      ## Don't run if Forgejo hasn't initialized its DB yet (fresh
      ## box, pre-bootstrap) — sync would have nothing to do and
      ## just spam logs.
      unitConfig.ConditionPathExists = [
        forgejoDb
        "${radicleHome}/keys/radicle"
        passphraseFile
      ];
      environment = {
        ## Disable /etc/gitconfig — boxes may carry personal git
        ## settings there (`[include] path = ~/.gitconfig.local`
        ## etc.) that don't resolve under a HOME-less systemd unit
        ## and would fatal every clone/fetch/push.
        GIT_CONFIG_NOSYSTEM = "1";

        ## Bypass git's "dubious ownership" check (CVE-2022-24765).
        ## Forgejo's bare repos are owned by uid 1000 (the container's
        ## forgejo user), but this unit runs as root; git refuses
        ## cross-uid operations by default. `safe.directory=*` is the
        ## documented wildcard for trust-all, appropriate here because
        ## this is a privileged batch service operating only on
        ## known-trusted local paths.
        ##
        ## GIT_CONFIG_COUNT/KEY_N/VALUE_N is git's env-var protocol
        ## for injecting config without needing a HOME or a config
        ## file — cleaner than GIT_CONFIG_PARAMETERS (which requires
        ## awkward quote escaping) for a single key.
        GIT_CONFIG_COUNT = "1";
        GIT_CONFIG_KEY_0 = "safe.directory";
        GIT_CONFIG_VALUE_0 = "*";
      };
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${syncScript}/bin/radicle-forgejo-mirror-sync";
        ## A cycle is bounded by Forgejo repo count × network
        ## latency to peers. Cap at 10 minutes — anything longer
        ## means a stuck push and we want the next timer tick to
        ## get a fresh start, not pile up.
        TimeoutStartSec = "10min";
        ## Keep failure noisy but not unit-failed: a single broken
        ## repo shouldn't stop the next tick from running.
        SuccessExitStatus = [ 0 ];
      };
    };

    systemd.timers.radicle-forgejo-mirror = {
      description = "Run Forgejo→Radicle mirror every 5 minutes";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        ## OnBootSec gives the box a minute to settle (DNS, podman,
        ## Forgejo's own bootstrap) before the first tick.
        OnBootSec = "1min";
        OnUnitActiveSec = "5min";
        ## If the box is asleep / off, run as soon as it wakes —
        ## a missed tick is not worth backfilling cumulatively.
        Persistent = true;
      };
    };
  };
}
