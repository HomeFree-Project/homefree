{ config, lib, pkgs, ... }:
## Wrap `reboot` / `poweroff` / `halt` to stop podman containers
## cleanly BEFORE invoking the systemd shutdown machinery.
##
## Why: netavark's per-container cleanup hook (`podman-<name>-pre-stop`)
## calls aardvark-dns to remove DNS entries. aardvark-dns is spawned
## by netavark as a TRANSIENT systemd scope (`systemd-run --scope ...`).
## Once `reboot.target` has a start job queued — which happens
## immediately on `systemctl reboot` — systemd refuses every new
## transient scope start with:
##
##   Transaction for run-pXXX.scope/start is destructive
##   (reboot.target has 'start' job queued, but 'stop' is included
##   in transaction).
##
## The cleanup fails, container stops time out and get SIGKILLed,
## `/home` unmount fails ('target is busy'), and the box sits in
## late-shutdown limbo until the hardware watchdog (or an impatient
## human) hard-resets it. We saw 15+ containers fail this way on a
## single reboot — every container with a podman pre-stop hook is
## a victim.
##
## By running `podman stop -a` BEFORE the binary that queues
## `reboot.target`, container cleanup runs in normal multi-user.target
## context where transient scope starts are still allowed. By the
## time the real reboot is invoked there are no containers left and
## netavark has no more cleanup to do, so the destructive-transaction
## error never triggers.
##
## Catches: shell-invoked `reboot` / `poweroff` / `halt`. These are
## the symlinks NixOS puts in the system PATH; we shadow them via
## `lib.hiPrio` so this package wins the filename collision in
## /run/current-system/sw/bin. `nixos-rebuild boot && reboot` and
## `sudo reboot` are the common paths and both go through here.
##
## Does NOT catch:
##   - `systemctl reboot|poweroff|halt` (deliberate escape hatch
##     for operations that explicitly want the raw behaviour).
##   - `shutdown` (intentionally NOT wrapped: it takes a delay arg
##     like `shutdown +1h`, and eagerly stopping containers on a
##     delayed shutdown is the wrong behaviour).
##   - power-button events (handled by systemd-logind → systemd-
##     reboot.service, not the symlinks).
##   - IPMI shutdown, kernel panic, BMC reset.
##
## For the unwrapped paths, the manual procedure is documented in
## docs/agent-notes/podman-shutdown-hang.md:
##   podman stop -a -t 10 && systemctl reboot
##
## Upstream tracking: there is no managed-aardvark mode in netavark —
## aardvark-dns is fully lifecycle-managed by netavark as a transient
## scope, so a real fix requires upstream cooperation. Revisit if
## netavark grows an external-aardvark mode or relaxes the
## transient-scope cleanup behaviour.
let
  podman = "${config.virtualisation.podman.package}/bin/podman";
  systemctl = "${config.systemd.package}/bin/systemctl";
  timeout = "${pkgs.coreutils}/bin/timeout";

  ## Best-effort: container cleanup must run while transient scopes
  ## can still start. The outer `timeout 30` caps total wall time so
  ## a stuck container can't block reboot indefinitely; the inner
  ## `-t 10` is podman's per-container SIGTERM-to-SIGKILL grace.
  ## `|| true` keeps the wrapper non-fatal — if podman is broken
  ## the reboot still proceeds (worst case: today's behaviour).
  preStop = ''
    ${timeout} 30 ${podman} stop -a -t 10 >/dev/null 2>&1 || true
  '';

  mkWrapper = name: target: lib.hiPrio (pkgs.writeShellScriptBin name ''
    ${preStop}
    exec ${target} "$@"
  '');
in {
  config = lib.mkIf config.virtualisation.podman.enable {
    environment.systemPackages = [
      (mkWrapper "reboot"   "${systemctl} reboot")
      (mkWrapper "poweroff" "${systemctl} poweroff")
      (mkWrapper "halt"     "${systemctl} halt")
    ];
  };
}
