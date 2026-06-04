## Finish-setup state sentinel.
##
## The ISO installer cannot collect secret-bearing config, so a freshly-
## installed box reaches the admin UI with post-install setup still pending
## (no SSH authorized key, no DNS-01 provider — see the finish-setup wizard).
##
## Several subsystems need to know "is setup finished?" at RUNTIME, without a
## rebuild to flip them:
##   - the captive-portal Caddy module (services/finish-setup-portal) — must
##     stop redirecting LAN traffic the instant setup completes;
##   - the console TUI / MOTD (modules/finish-setup-console);
##   - the admin-api auth middleware (the finish-setup endpoint bypass).
##
## This module maintains a single on-disk fact they all read:
##
##   /var/lib/homefree-secrets/.setup-complete
##       present  => post-install setup is finished
##       absent   => still pending
##
## It mirrors the `.sso-provisioned` sentinel pattern (services/sso) — a plain
## marker file that Caddy checks with a request-time `file` matcher.
##
## IMPORTANT — why this is NOT inferred from config:
## An earlier version flipped the sentinel as soon as `authorizedKeys` and the
## DNS-01 provider were both present in homefree-config.json. That is wrong:
## the wizard writes those on its EARLY steps, so the sentinel flipped while
## the user was still mid-wizard (e.g. on the ddclient page) — which slammed
## the auth bypass shut and 401'd the rest of the flow.
##
## The sentinel is therefore set ONLY by an explicit "the wizard finished"
## action: the admin-api writes it when the wizard calls
## POST /api/finish-setup/complete on its final step. This module just
## guarantees the secrets dir exists and tidies the override sentinel; it
## never creates `.setup-complete` itself.
{ config, lib, pkgs, ... }:

let
  secretsDir = "/var/lib/homefree-secrets";
  completeSentinel = "${secretsDir}/.setup-complete";
  ## Manual override written by the console TUI's "disable redirect"
  ## keybind. Cleared once setup is genuinely complete so it never lingers.
  portalDisabledSentinel = "${secretsDir}/.setup-portal-disabled";
in
{
  systemd.services.homefree-setup-state = {
    description = "HomeFree finish-setup state — ensure secrets dir, tidy override";
    ## Order before caddy so the portal sees a stable secrets dir on boot.
    wantedBy = [ "multi-user.target" ];
    before = [ "caddy.service" ];
    path = with pkgs; [ coreutils ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };

    script = ''
      set -u
      mkdir -p ${secretsDir}
      ## Phase 5 M9 — tighten the secrets-dir mode. Individual secret
      ## files inside are already 600 (per lib/secrets-anchor.nix), so
      ## the secrets themselves are safe to begin with. The directory
      ## defaulted to umask (0755) which let any local user enumerate
      ## the set of services that have secrets (the file *names* under
      ## here leak the catalog).
      ##
      ## Mode 0711 (drwx--x--x), NOT 0700. The dir contains two
      ## sentinel files (`.setup-complete`, `.sso-provisioned`) that
      ## NON-root code paths must be able to stat-by-name:
      ##   - Caddy (running as the `caddy` user) needs to evaluate
      ##     CEL `file({"try_files": [...]})` matchers against these
      ##     sentinels — that's what gates the @sso_gate matcher and
      ##     keeps the admin UI's forward_auth chain functional.
      ##   - SSH login shells run `[ -e .setup-complete ]` from
      ##     /etc/profile to decide whether to show the "setup not
      ##     finished" banner.
      ## Mode 0700 made the dir untraversable by non-root, so Caddy's
      ## file() matcher silently evaluated false → @sso_gate failed →
      ## no X-Auth-Request-User reached admin-api → admin UI broke
      ## with "missing X-Auth-Request-User". 0711 lets any user
      ## stat-by-name (the sentinels work) but still blocks `ls`
      ## enumeration of the secrets catalog — which is the actual
      ## attack we cared about. Per-secret files inside stay 0600
      ## root:root, so this is a no-op on confidentiality.
      ##
      ## The chmod is unconditional so existing boxes get tightened
      ## on the next rebuild — idempotent on already-converged boxes.
      ## See docs/agent-notes/security-audit-phase-5.md M9. Per-
      ## service subdirectories under here are intentionally NOT
      ## touched — they have their own mode/owner requirements
      ## (headscale's needs to be 0750 root:headscale, etc., per
      ## feedback_no_dir_perm_clobber.md).
      chmod 711 ${secretsDir}

      ## The override sentinel is only meaningful WHILE setup is pending.
      ## If setup is already complete, drop a stale override marker.
      if [ -f ${completeSentinel} ]; then
        rm -f ${portalDisabledSentinel}
        echo "finish-setup: complete"
      else
        echo "finish-setup: pending"
      fi
    '';
  };

  ## Belt-and-suspenders for the M9 chmod above. The homefree-setup-
  ## state oneshot has `RemainAfterExit = true`, and NixOS's switch
  ## script does NOT reliably re-run such units when their content
  ## changes (observed empirically with zitadel-prepare-secrets in
  ## earlier audit work). An activation script ALWAYS runs on every
  ## `nixos-rebuild switch`, so this guarantees the mode flip lands
  ## on the very next rebuild — important here because the wrong mode
  ## (0700) breaks Caddy's @sso_gate file() matcher and takes the
  ## admin UI offline. Activation scripts run as root, so the chmod
  ## always succeeds; idempotent.
  system.activationScripts.homefree-secrets-dir-mode = ''
    if [ -d ${secretsDir} ]; then
      chmod 711 ${secretsDir}
    fi
  '';
}
