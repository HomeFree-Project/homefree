## HomeFree alerts engine wiring.
##
## What this module is responsible for:
##
##   1. Render the deployed `homefree.alerts` config to
##      /etc/homefree/alerts-config.json so the engine reads the
##      SETTLED view (not the disk JSON that may have un-applied
##      admin-UI edits) — same approach service-config.json uses.
##
##   2. Define the homefree-alerts.service oneshot + homefree-
##      alerts.timer that re-fires it every `interval`. State is on
##      disk (services.alerts_state_store), so each tick is
##      independent — a restart, reboot, or schedule change does
##      not lose in-flight alert state.
##
##   3. Auto-enable ntfy when alerts.channels.ntfy.enable is true.
##      A user who sets up alerts shouldn't also have to remember to
##      enable the underlying push server. Done with `lib.mkDefault`
##      so an explicit JSON assignment still wins (someone running
##      ntfy standalone is fine; flipping alerts off doesn't tear
##      down their ntfy).
##
## NOT here: the source / channel implementations. Those live in
## web-platform/backend/services/alerts_*.py so the same Python
## environment used by the admin-api can also read live state for
## the Alerts page (rather than spawning a separate process per
## query).

{ config, lib, pkgs, homefree-inputs, ... }:
let
  cfg = config.homefree.alerts;

  ## Resolved config snapshot, written into /etc/homefree on every
  ## activation. The engine reads this; admin-api also reads it for
  ## the GET /api/alerts/sources endpoint so both see the same
  ## generation-pinned view.
  alertsConfigJson = builtins.toJSON {
    enable = cfg.enable;
    interval = cfg.interval;
    channels = {
      ntfy = { enable = cfg.channels.ntfy.enable; };
    };
    sources = {
      disk-temperature = {
        enable       = cfg.sources.disk-temperature.enable;
        hysteresis-c = cfg.sources.disk-temperature.hysteresis-c;
        channels     = cfg.sources.disk-temperature.channels;
        thresholds = {
          hdd-warn-c  = cfg.sources.disk-temperature.thresholds.hdd-warn-c;
          hdd-err-c   = cfg.sources.disk-temperature.thresholds.hdd-err-c;
          ssd-warn-c  = cfg.sources.disk-temperature.thresholds.ssd-warn-c;
          ssd-err-c   = cfg.sources.disk-temperature.thresholds.ssd-err-c;
          nvme-warn-c = cfg.sources.disk-temperature.thresholds.nvme-warn-c;
          nvme-err-c  = cfg.sources.disk-temperature.thresholds.nvme-err-c;
        };
      };
      disk-space = {
        enable                 = cfg.sources.disk-space.enable;
        threshold-warn-percent = cfg.sources.disk-space.threshold-warn-percent;
        threshold-err-percent  = cfg.sources.disk-space.threshold-err-percent;
        hysteresis-percent     = cfg.sources.disk-space.hysteresis-percent;
        fs-types               = cfg.sources.disk-space.fs-types;
        skip-mount-prefixes    = cfg.sources.disk-space.skip-mount-prefixes;
        channels               = cfg.sources.disk-space.channels;
      };
      smart = {
        enable   = cfg.sources.smart.enable;
        channels = cfg.sources.smart.channels;
      };
      sensor-temperature = {
        enable       = cfg.sources.sensor-temperature.enable;
        hysteresis-c = cfg.sources.sensor-temperature.hysteresis-c;
        channels     = cfg.sources.sensor-temperature.channels;
        thresholds = {
          cpu-warn-c  = cfg.sources.sensor-temperature.thresholds.cpu-warn-c;
          cpu-err-c   = cfg.sources.sensor-temperature.thresholds.cpu-err-c;
          nvme-warn-c = cfg.sources.sensor-temperature.thresholds.nvme-warn-c;
          nvme-err-c  = cfg.sources.sensor-temperature.thresholds.nvme-err-c;
          gpu-warn-c  = cfg.sources.sensor-temperature.thresholds.gpu-warn-c;
          gpu-err-c   = cfg.sources.sensor-temperature.thresholds.gpu-err-c;
        };
      };
      services-down = {
        enable   = cfg.sources.services-down.enable;
        channels = cfg.sources.services-down.channels;
      };
      backup-failures = {
        enable   = cfg.sources.backup-failures.enable;
        channels = cfg.sources.backup-failures.channels;
      };
      attacks = {
        enable          = cfg.sources.attacks.enable;
        threshold-bans  = cfg.sources.attacks.threshold-bans;
        hysteresis-bans = cfg.sources.attacks.hysteresis-bans;
        channels        = cfg.sources.attacks.channels;
      };
      tls-cert = {
        enable    = cfg.sources.tls-cert.enable;
        warn-days = cfg.sources.tls-cert.warn-days;
        channels  = cfg.sources.tls-cert.channels;
      };
      wan-accessibility = {
        enable        = cfg.sources.wan-accessibility.enable;
        public-ip-url = cfg.sources.wan-accessibility.public-ip-url;
        doh-url       = cfg.sources.wan-accessibility.doh-url;
        channels      = cfg.sources.wan-accessibility.channels;
      };
      headscale-accessibility = {
        enable         = cfg.sources.headscale-accessibility.enable;
        journal-window = cfg.sources.headscale-accessibility.journal-window;
        channels       = cfg.sources.headscale-accessibility.channels;
      };
      config-divergence = {
        enable   = cfg.sources.config-divergence.enable;
        channels = cfg.sources.config-divergence.channels;
      };
    };

    ## System-level facts the engine needs but can't derive from sysfs
    ## or /etc/homefree alone. Currently just `domain` — the
    ## wan-accessibility and headscale-accessibility sources build
    ## the external-probe URL from it. Reading from this rendered
    ## blob keeps the engine from having to parse the per-instance
    ## homefree-config.json a second time.
    system = {
      domain = config.homefree.system.domain;
    };
  };

  ## Engine Python env. Deliberately MINIMAL — the engine itself
  ## needs only stdlib + httpx for the ntfy POST. Keeping this
  ## tight (rather than reusing the admin-web/dashboard pythonEnv)
  ## means the timer unit pulls in a small closure: faster cold
  ## starts, smaller systemd memory footprint, no surprise
  ## dependency drift between admin-api and the engine.
  pythonEnv = pkgs.python3.withPackages (ps: with ps; [
    httpx
  ]);

  webBackend = homefree-inputs.web-platform.legacyPackages.${pkgs.system}.source + "/backend";

  ## Shell wrapper. Mirrors the dashboard-sampler / drive-temp-
  ## sampler pattern in services/admin-web/default.nix. The PATH
  ## prepend is required for the `services-down` source which shells
  ## out to `systemctl is-active` — the default unit PATH is too
  ## restricted to find systemctl. Same approach drive-temp-sampler
  ## uses for smartctl.
  alerts-engine = pkgs.writeShellScriptBin "homefree-alerts-engine" ''
    #!/usr/bin/env bash
    export PATH="/run/current-system/sw/bin:$PATH"
    cd ${webBackend}
    exec ${pythonEnv}/bin/python homefree_alerts_engine.py
  '';
in
{
  config = lib.mkMerge [
    ## ── Always-on: render the config snapshot ────────────────────
    ## environment.etc lives outside the `mkIf cfg.enable` gate so
    ## the file disappears when alerts is turned off (avoids a stale
    ## config sitting in /etc), but otherwise is unconditional —
    ## services/admin-web reads it even when alerts is disabled to
    ## show "feature off" in the UI.
    (lib.mkIf cfg.enable {
      environment.etc."homefree/alerts-config.json" = {
        text = alertsConfigJson;
        mode = "0644";
      };

      ## ── Auto-enable ntfy when alerts uses it as a channel ──────
      ## We MUST override an explicit `services.ntfy.enable = false`
      ## in homefree-config.json here, because the admin UI's first
      ## Save after the ntfy schema was added stamps the JSON with
      ## the schema defaults ({ enable = false; public = false; }),
      ## and a plain JSON assignment at normal priority beats our
      ## old `mkDefault`. The visible symptom: the user toggles the
      ## ntfy channel on, the engine config writes
      ## channels.ntfy.enable = true, but services.ntfy-sh never
      ## starts — POSTs to localhost:2586 get "Connection refused",
      ## which manifests as HTTP 502 from the test endpoint and a
      ## generic 405 in the UI.
      ##
      ## Scoped via `mkIf cfg.channels.ntfy.enable` so the override
      ## ONLY applies when the user actually wants ntfy as a channel
      ## — when the channel is off (or alerts itself is off), this
      ## branch contributes no definition and the user's JSON value
      ## for services.ntfy.enable takes effect as normal (useful if
      ## anyone ever wants to run ntfy standalone for non-alerts
      ## use). Conversely: turning the channel on means ntfy on,
      ## period — channel-on + ntfy-explicitly-off is incoherent.
      homefree.services.ntfy.enable =
        lib.mkIf cfg.channels.ntfy.enable (lib.mkForce true);

      ## ── Engine: one-shot service + timer ───────────────────────
      systemd.services.homefree-alerts = {
        description = "HomeFree alerts engine — single tick";
        ## We need DNS / network up so the ntfy POST can succeed,
        ## and the ntfy server itself ready to receive (when the
        ## channel is enabled). `wants` is soft so a misconfigured
        ## ntfy doesn't block alert evaluation entirely — the
        ## engine logs a publish failure and moves on.
        after = [ "network-online.target" "ntfy-sh.service" ];
        wants = [ "network-online.target" ];
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${alerts-engine}/bin/homefree-alerts-engine";

          ## Engine writes here, every tick. `StateDirectory` both
          ## creates the directory (owner root, mode 0755 by
          ## default) and adds it to the sandbox's writable paths
          ## — no manual ReadWritePaths needed.
          StateDirectory = "homefree-alerts";
          ## mode 0755 (default) so admin-api (which runs as a
          ## different user) can READ the events / state DB for
          ## the Alerts page. The DB rows are not secret.
          StateDirectoryMode = "0755";

          ## Runs as root so it can read the 640 ntfy topic file
          ## and the drive-temp sampler DB. Could be tightened to
          ## a SystemUser with SupplementaryGroups later, but the
          ## tick is short (seconds) and the surface is small
          ## (read homefree-* files, POST to localhost).

          ## Lockdown. Matches the drive-temp sampler unit's
          ## posture.
          NoNewPrivileges = true;
          ProtectSystem = "strict";
          ProtectHome = true;
          PrivateTmp = true;
          ProtectKernelTunables = true;
          ProtectKernelModules = true;
          ProtectControlGroups = true;
          ## Match drive-temp-sampler's posture (services/admin-web/
          ## default.nix): no MemoryDenyWriteExecute, since Python's
          ## interpreter has been observed to need mmap with both W+X
          ## in some import paths.
        };
      };

      systemd.timers.homefree-alerts = {
        description = "Periodic HomeFree alerts engine tick";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          ## Short post-boot delay so the disk-temp sampler has had
          ## a tick before we evaluate (its first sample is on
          ## startup but takes a second). Avoids a "no data yet"
          ## first run that fires no alert when one is warranted.
          OnBootSec = "2min";
          OnUnitInactiveSec = cfg.interval;
          Unit = "homefree-alerts.service";
          ## Catch up on missed runs if the box was asleep / off
          ## past a scheduled tick. Mirrors btrfs-scrub's posture.
          Persistent = true;
        };
      };
    })
  ];
}
