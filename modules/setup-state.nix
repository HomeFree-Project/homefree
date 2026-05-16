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
##   - the console TUI / MOTD (modules/finish-setup-console).
##
## This module maintains a single on-disk fact they all read:
##
##   /var/lib/homefree-secrets/.setup-complete
##       present  => post-install setup is finished
##       absent   => still pending
##
## It mirrors the `.sso-provisioned` sentinel pattern (services/sso) — a plain
## marker file that Caddy checks with a request-time `file` matcher, so no
## config regeneration is needed when the state changes.
##
## The predicate is the same one ModeService.get_pending_setup_items() uses in
## the backend: setup is complete when system.authorizedKeys is non-empty AND
## dns.cert-management.provider is set.
##
## The unit is a oneshot WITHOUT RemainAfterExit: it asserts live filesystem
## state, so it must re-run on every boot (per the oneshot-bootstrap pattern).
## The admin-api also `systemctl start`s it after the finish-setup wizard
## applies a rebuild, so the sentinel updates promptly.
{ config, lib, pkgs, ... }:

let
  homefreeConfigPath = "/etc/nixos/homefree-config.json";
  secretsDir = "/var/lib/homefree-secrets";
  completeSentinel = "${secretsDir}/.setup-complete";
  ## Manual override written by the console TUI's "disable redirect"
  ## keybind. Cleared here once setup is genuinely complete so it never
  ## lingers past its purpose.
  portalDisabledSentinel = "${secretsDir}/.setup-portal-disabled";
in
{
  ## A path unit re-runs the sentinel evaluation whenever
  ## homefree-config.json changes — so the finish-setup wizard's "Apply",
  ## the finish-setup.sh fix-up script, or a manual edit all refresh the
  ## sentinel within seconds, with no dependency on a rebuild or reboot.
  systemd.paths.homefree-setup-state = {
    description = "Watch homefree-config.json for finish-setup state changes";
    wantedBy = [ "multi-user.target" ];
    pathConfig = {
      PathChanged = homefreeConfigPath;
      Unit = "homefree-setup-state.service";
    };
  };

  systemd.services.homefree-setup-state = {
    description = "Maintain the HomeFree finish-setup state sentinel";
    ## Order before caddy so the catch-all portal sees an accurate
    ## sentinel on boot. wantedBy multi-user.target so it always runs.
    wantedBy = [ "multi-user.target" ];
    before = [ "caddy.service" ];
    path = with pkgs; [ coreutils jq systemd ];

    serviceConfig = {
      Type = "oneshot";
      ## No RemainAfterExit — re-evaluate live state every boot and on
      ## every homefree-config.json change (via the path unit above).
    };

    script = ''
      set -u
      mkdir -p ${secretsDir}

      complete=0
      if [ -f ${homefreeConfigPath} ]; then
        ## authorizedKeys non-empty?
        keycount=$(jq -r '(.system.authorizedKeys // []) | length' \
          ${homefreeConfigPath} 2>/dev/null || echo 0)
        ## DNS-01 provider set? (.dns.cert-management is null on a fresh box)
        provider=$(jq -r '(.dns["cert-management"].provider) // ""' \
          ${homefreeConfigPath} 2>/dev/null || echo "")

        if [ "$keycount" -gt 0 ] && [ -n "$provider" ]; then
          complete=1
        fi
      fi

      if [ "$complete" -eq 1 ]; then
        touch ${completeSentinel}
        ## Setup is finished — the override has served its purpose.
        rm -f ${portalDisabledSentinel}
        echo "finish-setup: complete (authorizedKeys + DNS-01 provider present)"
      else
        rm -f ${completeSentinel}
        echo "finish-setup: still pending"
      fi
    '';
  };
}
