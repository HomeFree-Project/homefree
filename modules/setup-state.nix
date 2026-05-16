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
}
