{ config, lib, pkgs, ... }:
## Re-create netavark's nftables entries after nftables.service is
## reloaded or restarted.
##
## Background: NixOS configures nftables.service with
## X-ReloadIfChanged=true. On every `switch-to-configuration`, that
## causes systemd to call `ExecReload` which flushes and re-applies
## the entire ruleset. netavark's hostport DNAT chains
## (NETAVARK-HOSTPORT-DNAT, nv_*_dnat, etc.) live in the same nft
## namespace, so they get wiped along with everything else. Containers
## keep running with healthy listeners on conmon, but the host-side
## port forwards silently disappear — `curl host:port` hangs forever.
##
## Upstream tracking: containers/netavark#1258 ("Handle nftables
## reload/restart"). The canonical fix on non-firewalld systems is to
## run `podman network reload --all` after every nftables reload,
## which re-emits all of netavark's rules without bouncing the
## containers themselves.
##
## We wire this as a oneshot bound to nftables.service so that:
##   - on nftables `restart`: PartOf=nftables.service stops us, then
##     we re-run via WantedBy and re-add the rules.
##   - on nftables `reload`: ReloadPropagatedFrom triggers our reload,
##     which just re-runs the ExecStart to re-add the rules.
{
  systemd.services.netavark-nftables-reload = {
    description = "Re-emit netavark hostport rules after nftables reload";
    wantedBy = [ "multi-user.target" ];
    after = [ "nftables.service" "podman.service" ];
    requires = [ "nftables.service" ];
    ## When nftables stops, we stop too; when nftables reloads, we
    ## reload too. Both trigger a fresh `podman network reload --all`.
    reloadTriggers = [];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ## Re-emit netavark rules on start AND on reload. Reload uses
      ## the same command (idempotent — podman re-creates the rules
      ## from the live container state).
      ExecStart = "${config.virtualisation.podman.package}/bin/podman network reload --all";
      ExecReload = "${config.virtualisation.podman.package}/bin/podman network reload --all";
    };

    unitConfig = {
      ## Propagate `systemctl reload nftables` to us so ExecReload
      ## fires automatically. NixOS's switch-to-configuration uses
      ## reload (not restart) when nftables ruleset changes, so this
      ## is the path that matters most.
      ReloadPropagatedFrom = [ "nftables.service" ];
    };
  };
}
