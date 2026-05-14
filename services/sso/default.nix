{ config, lib, ... }:

## HomeFree SSO surface — the user-facing knobs that other modules
## consult to decide whether to wire themselves to Zitadel.
##
## The big idea: zitadel-provision.service touches
## /var/lib/homefree-secrets/.sso-provisioned once it has finished
## creating every OIDC application and writing every per-service
## secret to disk. Caddy's per-site oauth2 redirect block (in
## services/caddy.nix) consults that sentinel at REQUEST time via a
## `file` matcher, so the SSO gate flips on automatically as soon as
## the sentinel appears — no nixos-rebuild required after the
## initial one.
##
## The sentinel is created LAST in zitadel-provision so a partially-
## failed run doesn't enable SSO across services that don't yet have
## working OIDC apps.
##
## The `provisioned` option below is a build-time peek at that same
## sentinel. It's NOT used to gate Caddy auth (that's runtime in
## Caddy now), but it's exposed as a read-only signal that the admin
## UI / other modules can consume if they want to display status
## ("SSO is bootstrapped") in their own UIs.

let
  ## Per-service opt-out submodule — one entry per integrated service
  ## label. Keeps the surface uniform: a user can disable SSO for a
  ## single service by setting `homefree.sso.per-service.<label>.enable
  ## = false;` without touching internal provisioning state.
  perServiceSubmodule = lib.types.submodule {
    options.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Whether this service should require SSO via Zitadel.

        Default true means: once `homefree.sso.provisioned` flips on,
        Caddy redirects unauthenticated requests for this service to
        the OAuth2 Proxy at auth.<domain>. Set to false to keep the
        service accessible without SSO (relying on the service's own
        auth, if any).
      '';
    };
  };
in
{
  options.homefree.sso = {
    provisioned = lib.mkOption {
      type = lib.types.bool;
      default = builtins.pathExists "/var/lib/homefree-secrets/.sso-provisioned";
      readOnly = true;
      description = ''
        True iff zitadel-provision.service has completed at least once
        on this host (computed at nix-evaluation time from the on-disk
        sentinel).

        NOT used to gate Caddy auth — that gate runs at request time
        inside Caddy via a `file` matcher (services/caddy.nix), so a
        fresh install doesn't need a second rebuild to flip SSO on.
        This option is exposed as a read-only build-time signal for
        admin-UI status displays and similar consumers.

        Read-only — set by the provisioning oneshot, not the user.
      '';
    };

    ## enable-pam-sync is declared in services/zitadel-pam-bridge.nix
    ## (the module that consumes it). Listed here in the comments so
    ## anyone grepping for sso.* finds the cross-reference.

    allowUserRegistration = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether to expose the "Register new user" link on Zitadel's
        sign-in page.

        Default false because a default HomeFree deployment is a
        family / single-household server, not a public service —
        random visitors should not be able to self-create accounts
        (and even when they tried, registration failed in practice
        because the registration form had no path to grant the new
        user access to anything).

        Set true to allow self-service registration. Account creation
        will succeed but the new user will not have access to any
        HomeFree services until an admin grants them roles through
        the admin UI (or through Zitadel directly).
      '';
    };

    per-service = lib.mkOption {
      type = lib.types.attrsOf perServiceSubmodule;
      default = { };
      example = lib.literalExpression ''
        {
          adguard.enable = false;   # Keep AdGuard accessible without SSO
          immich.enable = true;
        }
      '';
      description = ''
        Per-service SSO opt-out. Defaults to enabled for every
        integrated service; flip individual entries off to skip the
        Caddy oauth2 gate for that service.

        Service labels match the labels declared in each service's
        homefree.service-config block (e.g. `admin`, `adguard`,
        `immich`, `nextcloud`, `forgejo`, `home-assistant`).
      '';
    };
  };
}
