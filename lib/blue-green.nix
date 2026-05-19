## ─── Generic zero-downtime blue/green deployment ────────────────────
##
## A `nixos-rebuild` that restarts a service in a live request path
## causes a visible outage for the duration of that restart. This
## module factors out a reusable "blue/green" (red-black) mechanism:
## a service runs as TWO permanent units on two ports; on a rebuild
## that changes the service, an activation script starts the standby
## colour, health-gates it, gracefully reloads Caddy onto it, then
## stops the old colour. The swap is invisible — zero downtime.
##
## It generalizes the original admin-api implementation so the same
## machinery covers admin-api (a plain systemd process) AND
## oauth2-proxy (a podman oci-container), and any future service.
##
## USAGE — from a service module that has `lib` and `pkgs` in scope:
##
##   bg = (import ../../lib/blue-green.nix { inherit lib pkgs; }) {
##     name = "admin-api";
##     stateDir = "/var/lib/homefree-admin";
##     colours = { blue = 8000; green = 8001; };
##     workload = { kind = "systemd"; mkUnit = colour: port: {...}; };
##     healthCheck = { kind = "http"; path = "/health"; };
##     closure = { kind = "store-path"; path = "${admin-backend}"; };
##     caddySnippets = [ { snippetName = "..."; body = "...__PORT__..."; } ];
##     migrateFrom = "admin-api.service";
##     migrateRollback = "restart-legacy";   # or "leave-down"
##     failureMarker = "admin-api-flip-failed.json";
##   };
##
## then merge `bg.config` into the module's `config`, and append
## `bg.caddyImportLine` to `homefree.internal.caddy-file-scope-imports`.
##
## INVARIANT (oci-container kind): the `mkContainer` factory MUST
## differ between colours ONLY by the port. The flip's change-detection
## uses the blue colour's generated unit-file hash as a canonical
## fingerprint of the container definition — if blue and green differed
## by anything other than the port, that fingerprint would be unstable.

{ lib, pkgs }:

descriptor:

let
  inherit (descriptor)
    name stateDir colours workload healthCheck closure caddySnippets
    migrateFrom migrateRollback failureMarker;

  bluePort  = colours.blue;
  greenPort = colours.green;

  ## Unit-name prefix. A `systemd` workload's unit is `<name>-<colour>`;
  ## an `oci-container` workload is expanded by NixOS into
  ## `podman-<name>-<colour>.service`. `unitPrefix` is Nix-static; the
  ## colour is appended either in Nix (`unitName`) or in shell
  ## (`${unitPrefix}$colour`) depending on the call site.
  unitPrefix =
    if workload.kind == "oci-container"
    then "podman-${name}-"
    else "${name}-";

  ## Real systemd unit name for a colour known at Nix-eval time.
  unitName = colour: "${unitPrefix}${colour}";

  ## Runtime snippet file — /run is tmpfs, so it is (re)created on every
  ## boot by <name>-snippet.service before caddy starts, and rewritten
  ## in place by the flip. `__PORT__` is the one token that changes.
  upstreamSnippetPath = "/run/homefree/${name}-upstream.caddy";

  ## The snippet-definition file imported at Caddy file scope. Each
  ## descriptor entry becomes a `(snippetName) { body }` block; call
  ## sites use `import <snippetName>`.
  snippetTemplate = pkgs.writeText "${name}-upstream.caddy.tmpl"
    (lib.concatMapStringsSep "\n" (s: ''
      (${s.snippetName}) {
      ${s.body}
      }
    '') caddySnippets);

  ## Shell fragment defining write_upstream_snippet <port>: substitutes
  ## __PORT__, validates non-empty (a missing/empty snippet would stop
  ## Caddy parsing its whole config), installs atomically via mv.
  writeUpstreamSnippet = ''
    write_upstream_snippet() {
      local port="$1"
      local tmp="${upstreamSnippetPath}.tmp"
      ${pkgs.coreutils}/bin/mkdir -p /run/homefree
      ${pkgs.gnused}/bin/sed "s/__PORT__/$port/g" ${snippetTemplate} > "$tmp"
      if [ ! -s "$tmp" ]; then
        echo "${name}: refusing to install empty upstream snippet" >&2
        ${pkgs.coreutils}/bin/rm -f "$tmp"
        return 1
      fi
      ${pkgs.coreutils}/bin/mv "$tmp" "${upstreamSnippetPath}"
    }
  '';

  marker = "${stateDir}/${failureMarker}";

  ## ── The active-colour anchor ──────────────────────────────────────
  ## `<name>-active.service` is a polling SUPERVISOR (defined below).
  ##
  ## A first design coupled it to the active colour with
  ## `Requires=`+`After=` and relied on `Restart=always` to resurrect
  ## a colour killed by `local-fs.target` cycling. That is WRONG and a
  ## live kill-test proved it: `Restart=` only restarts a service that
  ## exited on its OWN. When the colour stopped, `Requires=` stopped
  ## the anchor as a deliberate dependency cascade — a clean stop, for
  ## which `Restart=` is suppressed. The anchor went down and stayed
  ## down; the colour was never resurrected.
  ##
  ## The correct mechanism is an actual supervisor: NO dependency
  ## coupling to the colour at all (so the colour stopping never
  ## touches the anchor), and an `ExecStart` that polls — every couple
  ## of seconds it reads the `active-color` pointer and `systemctl
  ## start`s that colour if it is not running. The colour dying is
  ## then noticed and corrected within the poll interval; the flip
  ## only has to keep `active-color` current (which it does). No
  ## drop-in, no `daemon-reload`, no helper — one fewer moving part.

  ## Shell body of the supervisor loop. It is deliberately START-ONLY:
  ## every few seconds it reads the `active-color` pointer and
  ## `systemctl start`s that colour if it is not running. That is its
  ## ENTIRE job — keep the active colour alive (against a
  ## `local-fs.target` cycle, a crash, an OOM kill, anything).
  ##
  ## It must NOT stop the standby colour. An earlier version did, to
  ## "tidy up", and it caused a TOCTOU race against the flip: a flip
  ## intentionally runs BOTH colours during its handover (it starts the
  ## standby, health-gates it, only then retires the old colour). A
  ## flip-lock file was tried to make the supervisor stand down, but
  ## the supervisor's check-then-stop is not atomic — the flip could
  ## create the lock and start the standby in the gap between the
  ## supervisor's lock check and its `stop`, so the supervisor stopped
  ## the colour the flip had just started (observed live: a flip's
  ## health-gate timed out because the supervisor killed the standby
  ## under it). A start-only supervisor has no such conflict: it never
  ## touches the standby, so there is nothing to race. The flip itself
  ## stops the old colour at commit (step 7), and its failure paths
  ## stop the standby — stopping is wholly the flip's job. A standby
  ## left running by a crashed flip merely idles on its port (nothing
  ## routes to it) until the next flip; harmless.
  ##
  ## `active-color` is re-read every tick, so a committed flip is
  ## picked up with no supervisor restart. `systemctl start` on an
  ## already-running unit is a harmless no-op.
  activeSupervisorScript = ''
    sysctl=${pkgs.systemd}/bin/systemctl
    while :; do
      active_color="$(${pkgs.coreutils}/bin/cat ${stateDir}/active-color 2>/dev/null || echo blue)"
      case "$active_color" in
        green) want=${unitName "green"} ;;
        *)     want=${unitName "blue"}  ;;
      esac
      if [ "$($sysctl is-active "$want" 2>/dev/null)" != "active" ]; then
        echo "${name}-active: $want (active colour) not running — starting it"
        $sysctl start "$want" 2>/dev/null || true
      fi
      ${pkgs.coreutils}/bin/sleep 3
    done
  '';

  ## ── The two colour units ──────────────────────────────────────────
  ## For a `systemd` workload, mkUnit yields a full unit attrset.
  ## For an `oci-container` workload, mkContainer yields a container
  ## attrset (NixOS expands it into podman-<name>-<colour>.service),
  ## and extraUnitConfig is merged into that generated unit so we can
  ## set ExecStartPre, ordering, etc.
  ##
  ## CRITICAL: a colour unit must be invisible to `switch-to-
  ## configuration` — the flip owns 100% of its start/stop. Setting
  ## `restartIfChanged = false` alone is NOT enough: a changed unit
  ## that cannot reload (every podman container: `CanReload=no`) and
  ## still has the default `stopIfChanged = true` gets *stopped* by
  ## switch-to-configuration, and since a colour unit is `wantedBy`
  ## nothing, it never starts again. So BOTH flags are forced false
  ## here, for both workload kinds — the caller cannot opt out.
  lifecycleOwnedByFlip = {
    restartIfChanged = false;
    stopIfChanged = false;
  };

  colourUnits =
    if workload.kind == "systemd" then {
      systemd.services."${name}-blue"  =
        (workload.mkUnit "blue"  bluePort)  // lifecycleOwnedByFlip;
      systemd.services."${name}-green" =
        (workload.mkUnit "green" greenPort) // lifecycleOwnedByFlip;
    } else {
      virtualisation.oci-containers.containers."${name}-blue" =
        workload.mkContainer "blue" bluePort;
      virtualisation.oci-containers.containers."${name}-green" =
        workload.mkContainer "green" greenPort;
      systemd.services."podman-${name}-blue" =
        ((workload.extraUnitConfig or (_: {})) "blue")  // lifecycleOwnedByFlip;
      systemd.services."podman-${name}-green" =
        ((workload.extraUnitConfig or (_: {})) "green") // lifecycleOwnedByFlip;
    };

  ## ── Health-gate shell fragment ────────────────────────────────────
  ## health_gate <unit> <port>: poll until the service answers, ~30s,
  ## bailing the instant the unit dies (so a crash-loop doesn't burn
  ## the full timeout). http -> curl; tcp -> /dev/tcp connect probe.
  healthProbe =
    if healthCheck.kind == "tcp"
    then ''(exec 3<>"/dev/tcp/localhost/$port") 2>/dev/null''
    else ''${pkgs.curl}/bin/curl -fs -o /dev/null --max-time 2 "http://localhost:$port${healthCheck.path}"'';

  healthGateFn = ''
    health_gate() {
      local unit="$1" port="$2" i
      for i in $(${pkgs.coreutils}/bin/seq 1 60); do
        if ${healthProbe}; then
          return 0
        fi
        if [ "$($sysctl is-active "$unit" 2>/dev/null)" != "active" ]; then
          echo "${name}-flip: $unit is not active — aborting health gate" >&2
          return 1
        fi
        ${pkgs.coreutils}/bin/sleep 0.5
      done
      return 1
    }
  '';

  ## ── "definition changed?" detection ───────────────────────────────
  ## Shell that sets `desired_closure`. store-path: readlink the
  ## package. unit-file: readlink the canonical (blue) colour's
  ## generated unit file — its hash changes iff the container
  ## definition changes (see INVARIANT above).
  desiredClosureExpr =
    if closure.kind == "unit-file"
    then ''desired_closure="$(${pkgs.coreutils}/bin/readlink -f /etc/systemd/system/${unitName closure.colour}.service 2>/dev/null || echo unknown)"''
    else ''desired_closure="$(${pkgs.coreutils}/bin/readlink -f ${closure.path})"'';

  ## ── The flip activation script ────────────────────────────────────
  ## CRITICAL: NixOS concatenates every `system.activationScripts.*`
  ## fragment into ONE bash script. A bare `exit` therefore terminates
  ## the WHOLE activation — including every OTHER service's flip that is
  ## ordered after this one. So the entire flip body lives in a function
  ## and uses `return`, never `exit`; the fragment merely calls it.
  flipScript = ''
    ${writeUpstreamSnippet}
    ${healthGateFn}

    ${name}_flip() {
      local sysctl=${pkgs.systemd}/bin/systemctl
      local statedir=${stateDir}
      ${pkgs.coreutils}/bin/mkdir -p "$statedir"

      local blue_port=${toString bluePort}
      local green_port=${toString greenPort}
      local desired_closure
      ${desiredClosureExpr}

      # Remove a stale supervisor drop-in. An EARLIER (broken) version
      # of this module gave `${name}-active` a `Requires=<colour>`
      # drop-in under /run/systemd/system; the current supervisor uses
      # none. /run drop-ins are NOT cleaned by nixos-rebuild, and
      # survive until reboot — so a box upgrading from that version
      # keeps the poison: `Requires=<colour>` makes the supervisor stop
      # itself the moment it does its job of stopping the standby
      # colour. Delete it here, before the daemon-reload below picks up
      # its removal. Harmless when already absent.
      ${pkgs.coreutils}/bin/rm -rf /run/systemd/system/${name}-active.service.d

      # Activation scripts run BEFORE switch-to-configuration reloads the
      # systemd manager — the just-written colour units (and the removal
      # of the legacy unit) are not yet visible. Reload now so every
      # `systemctl` action below sees the new world.
      $sysctl daemon-reload

      # 1. No-op fast path — definition unchanged. Every rebuild that
      #    doesn't touch this service lands here. Clears any stale
      #    failure marker from a prior aborted rebuild — the active
      #    colour is, by definition, healthy here. The supervisor keeps
      #    the colour itself running; nothing else to do.
      if [ -f "$statedir/active-closure" ] && \
         [ "$(${pkgs.coreutils}/bin/cat "$statedir/active-closure")" = "$desired_closure" ]; then
        ${pkgs.coreutils}/bin/rm -f "${marker}"
        echo "${name}-flip: unchanged, no flip needed"
        return 0
      fi

      # mark_failed <colour> <reason>: write the marker and log. The box
      # keeps serving the previous known-good colour. The CALLER must
      # `return 0` immediately after — a failed flip must never fail the
      # rebuild, nor abort a sibling service's flip. printf (not
      # heredoc): activation text keeps its Nix indentation, which
      # breaks a heredoc terminator.
      mark_failed() {
        ${pkgs.coreutils}/bin/printf \
          '{"failed": true, "service": "%s", "attempted_color": "%s", "attempted_closure": "%s", "reason": "%s", "timestamp": "%s"}\n' \
          "${name}" "$1" "$desired_closure" "$2" "$(${pkgs.coreutils}/bin/date -Is)" \
          > "${marker}"
        echo "${name}-flip: FAILED ($2) — still serving previous version" >&2
      }

      # 2. Migration branch — first deploy of blue/green for this
      #    service. No pointer files yet; the legacy unit is retired.
      if [ ! -f "$statedir/active-color" ]; then
        echo "${name}-flip: first deploy — migrating to blue"
        write_upstream_snippet "$blue_port" || true
        $sysctl stop ${migrateFrom} 2>/dev/null || true
        if $sysctl start ${unitName "blue"} && health_gate ${unitName "blue"} "$blue_port"; then
          # active-color is the single source of truth — the supervisor
          # and the `${name}-snippet` oneshot both derive from it.
          echo blue > "$statedir/active-color"
          echo "$desired_closure" > "$statedir/active-closure"
          ${pkgs.coreutils}/bin/rm -f "${marker}"
          echo "${name}-flip: migrated — now serving blue"
        else
          echo "${name}-flip: blue failed on first deploy" >&2
          $sysctl stop ${unitName "blue"} 2>/dev/null || true
          ${lib.optionalString (migrateRollback == "restart-legacy") ''
            $sysctl start ${migrateFrom} 2>/dev/null || true
          ''}
          mark_failed blue "blue failed to come up on first deploy"
        fi
        return 0
      fi

      # 3. Normal flip. `${unitPrefix}` is the Nix-static unit-name
      #    prefix; the colour suffix is a shell variable.
      local current standby standby_port standby_unit current_unit
      current="$(${pkgs.coreutils}/bin/cat "$statedir/active-color")"
      if [ "$current" = "blue" ]; then
        standby=green; standby_port="$green_port"
      else
        standby=blue;  standby_port="$blue_port"
      fi
      standby_unit="${unitPrefix}$standby"
      current_unit="${unitPrefix}$current"
      echo "${name}-flip: $current -> $standby"

      # The supervisor is start-only and only ever (re)starts the
      # colour named by `active-color` (still `current` until step 7).
      # It never touches the standby — so the flip needs no lock to
      # run both colours during the handover below.

      # 4. Start the standby colour (its unit file already carries the
      #    new definition, written by activation above).
      if ! $sysctl start "$standby_unit"; then
        $sysctl stop "$standby_unit" 2>/dev/null || true
        mark_failed "$standby" "standby failed to start"
        return 0
      fi

      # 5. Health-gate the standby.
      if ! health_gate "$standby_unit" "$standby_port"; then
        $sysctl stop "$standby_unit" 2>/dev/null || true
        mark_failed "$standby" "health check timeout"
        return 0
      fi

      # 6. Point Caddy at the standby colour and reload gracefully.
      if ! write_upstream_snippet "$standby_port"; then
        $sysctl stop "$standby_unit" 2>/dev/null || true
        mark_failed "$standby" "could not write upstream snippet"
        return 0
      fi
      if ! $sysctl reload caddy; then
        # Roll the snippet back; keep the old colour serving.
        write_upstream_snippet "$( [ "$current" = blue ] && echo "$blue_port" || echo "$green_port" )" || true
        $sysctl stop "$standby_unit" 2>/dev/null || true
        mark_failed "$standby" "caddy reload failed"
        return 0
      fi

      # 7. Flip committed. ORDER MATTERS:
      #
      #  a. Write `active-color` FIRST. It is the single source of
      #     truth: the supervisor and the `${name}-snippet` oneshot
      #     both derive from it, and that oneshot re-runs later in this
      #     same rebuild during switch-to-configuration. If
      #     `active-color` were written last, that re-run would read
      #     the STALE colour and point the Caddy snippet at the
      #     now-dead old port (observed live: 502s `dial tcp
      #     :<oldport>: connection refused`). Writing it first makes
      #     the re-run re-derive the CORRECT port. It also immediately
      #     repoints the supervisor at the standby — correct, the
      #     standby is already running and healthy by now.
      #  b. Retire the old colour.
      echo "$standby" > "$statedir/active-color"
      echo "$desired_closure" > "$statedir/active-closure"
      $sysctl stop "$current_unit" 2>/dev/null || true
      ${pkgs.coreutils}/bin/rm -f "${marker}"
      echo "${name}-flip: now serving $standby"
      return 0
    }

    # Run the flip; never let its exit status abort the activation.
    ${name}_flip || true
  '';

  ## Activation-time snippet writer. Writes the upstream snippet for
  ## whichever colour the pointer names (default blue) — pure file I/O,
  ## no `systemctl`. Every blue/green service's flip depends on EVERY
  ## such script (via `snippetActivationDeps`), so that by the time any
  ## flip reaches `reload caddy`, every file-scope `import` target this
  ## repo emits already exists on disk. This closes the cross-service
  ## race: a `nixos-rebuild` runs all activation scripts, and a flip
  ## that reloads Caddy must not do so while a *sibling* service's
  ## import target is still missing.
  snippetActivationName = "${name}-bg-snippet";
  snippetActivationScript = ''
    ${writeUpstreamSnippet}
    active_color="$(${pkgs.coreutils}/bin/cat ${stateDir}/active-color 2>/dev/null || echo blue)"
    case "$active_color" in
      green) port=${toString greenPort} ;;
      *)     port=${toString bluePort} ;;
    esac
    write_upstream_snippet "$port" || true
  '';

in
{
  caddyImportLine = "import ${upstreamSnippetPath}";

  ## The name of this service's activation-time snippet writer. Every
  ## OTHER blue/green service must list this in its descriptor's
  ## `snippetActivationDeps` so all snippets are materialised before
  ## any flip reloads Caddy.
  inherit snippetActivationName;

  config = lib.mkMerge [
    colourUnits

    {
      ## Activation script: materialise this service's upstream snippet
      ## before any flip runs. `deps = ["etc"]` only — pure file I/O.
      system.activationScripts."${snippetActivationName}" = {
        deps = [ "etc" ];
        text = snippetActivationScript;
      };

      ## Boot oneshot: materialise the Caddy upstream snippet in /run
      ## BEFORE caddy starts. `/run` is tmpfs, lost on reboot, so this
      ## re-creates the snippet from the persisted `active-color`
      ## pointer. A missing import target stops caddy parsing its
      ## config — hence the hard `before = caddy.service`.
      systemd.services."${name}-snippet" = {
        description = "Write ${name} Caddy upstream snippet";
        wantedBy = [ "multi-user.target" ];
        before = [ "caddy.service" ];
        after = [ "local-fs.target" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          ${writeUpstreamSnippet}
          active_color="$(${pkgs.coreutils}/bin/cat ${stateDir}/active-color 2>/dev/null || echo blue)"
          case "$active_color" in
            green) port=${toString greenPort} ;;
            *)     port=${toString bluePort} ;;
          esac
          write_upstream_snippet "$port"
        '';
      };

      ## Active-colour supervisor.
      ##
      ## A colour unit is `autoStart = false` / `wantedBy` nothing, so
      ## systemd has no reason to keep it running. That is correct for
      ## the *standby* — but the *active* colour must be supervised, or
      ## it stays dead after any event that stops it: a `nixos-rebuild`
      ## cycles `local-fs.target`/`remote-fs.target`, which stops EVERY
      ## podman container; an ordinary `autoStart = true` container is
      ## then re-pulled by `multi-user.target`, but a colour unit would
      ## not be — and the service goes permanently dark.
      ##
      ## This unit is that supervisor. It has NO dependency coupling to
      ## the colour units at all — deliberately. Its `ExecStart` is a
      ## loop (`activeSupervisorScript`) that every few seconds reads
      ## the `active-color` pointer and `systemctl start`s that colour
      ## if it is not running. So:
      ##
      ##   • a colour killed by `local-fs.target` cycling — or by
      ##     anything else — is noticed within the poll interval and
      ##     restarted;
      ##   • the colour stopping does NOT touch this supervisor (no
      ##     `Requires`/`BindsTo`), so there is no dependency cascade
      ##     and `Restart=` is never relied on for colour resurrection
      ##     (`Restart=` does not fire for dependency-driven stops — an
      ##     earlier `Requires=`-based design failed a live kill-test
      ##     for exactly that reason);
      ##   • a flip just updates `active-color`; the very next poll
      ##     picks it up — no supervisor restart, no drop-in.
      ##
      ## `Restart=always` here is only for the supervisor's OWN process
      ## (e.g. if its shell is killed). `wantedBy multi-user.target`
      ## means a `local-fs` cycle that stops the supervisor too gets it
      ## (and hence the colour) back when the target is re-reached.
      ## The standby colour is named nowhere and stays dormant.
      systemd.services."${name}-active" = {
        description = "Active-colour supervisor for ${name}";
        wantedBy = [ "multi-user.target" ];
        after = [ "network.target" ];
        serviceConfig = {
          Type = "exec";
          Restart = "always";
          RestartSec = 2;
        };
        script = activeSupervisorScript;
      };

      ## The flip. Runs at the end of every `nixos-rebuild switch` (the
      ## one path common to UI-triggered and CLI rebuilds). `etc` must
      ## run first so the colour unit files exist before daemon-reload.
      ##
      ## It also depends on EVERY blue/green service's snippet-writer
      ## (`snippetActivationName` of this service plus every name passed
      ## in `snippetActivationDeps`) so that all file-scope Caddy
      ## `import` targets exist before this flip's `reload caddy`.
      system.activationScripts."${name}-flip" = {
        deps = [ "etc" snippetActivationName ]
          ++ (descriptor.snippetActivationDeps or [])
          ++ (descriptor.activationDeps or []);
        text = flipScript;
      };
    }
  ];
}
