## Apply a uniform Restart=always + rate-limit policy to every
## systemd unit that backs a HomeFree-managed service.
##
## Why: NixOS's default for podman-* container units is
## Restart=on-failure, which only fires when the unit exits non-zero.
## Some failure modes — notably Go runtime fatal errors like
## "concurrent map writes" — exit with status 0 because the runtime
## handles the abort itself. systemd treats those as a clean exit and
## leaves the service dead. We hit this with Forgejo on 2026-05-15
## and the service stayed down silently for 10+ hours.
##
## Restart=always fires regardless of exit code. The rate-limit
## (StartLimitBurst=5 within StartLimitIntervalSec=60) means a true
## config bug — where the unit will *never* start successfully — still
## flips the service to `failed` after 5 fast crash-loops, so it
## surfaces in the admin UI rather than burning CPU forever.
##
## Coverage: this module reads config.homefree.service-config (the
## same source the admin-api uses) so any new app/service that
## declares itself via the standard `systemd-service-names = [...]`
## block is picked up automatically. Apps that need different
## behavior (oneshot provisioners, backup runs) can override per-unit
## using mkForce; we use mkDefault here so explicit overrides win.
##
## Only ENABLED entries are considered. Apps emit their
## `service-config` block unconditionally (so the admin UI can list a
## disabled service), but when a service is disabled its backing unit
## is not generated at all. Declaring `systemd.services.<name>` here
## for a missing unit would materialize a stub unit with restart attrs
## but no ExecStart, which systemd rejects ("Service has no
## ExecStart=...") and which breaks `nixos-rebuild switch`. Filtering
## on `enable` is what keeps a disabled service from leaving that stub.
{ config, lib, ... }:

let
  ## Flatten every `systemd-service-names` entry across all
  ## *enabled* registered services into a unique unit-name list.
  allUnitNames = lib.unique (lib.concatMap
    (sc: sc.systemd-service-names or [])
    (lib.filter (sc: sc.enable or true)
      (config.homefree.service-config or []))
  );

  ## Per-unit overrides. mkDefault so an app's own
  ## `systemd.services.<name>.serviceConfig.Restart = lib.mkForce
  ## "no"` (or anything else) wins. Lifting this to a single attrset
  ## keeps the policy in one place.
  unitOverrides = lib.genAttrs allUnitNames (_: {
    serviceConfig = {
      Restart = lib.mkDefault "always";
      RestartSec = lib.mkDefault 10;
    };
    unitConfig = {
      StartLimitBurst = lib.mkDefault 5;
      StartLimitIntervalSec = lib.mkDefault 60;
    };
  });
in
{
  systemd.services = unitOverrides;
}
