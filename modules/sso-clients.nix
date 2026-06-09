## SSO OIDC-client registry — the per-app SSO-adapter seam.
##
## Each SSO-gated app pushes ONE descriptor per Zitadel OIDC client into
## `homefree.sso.clients`; apps/zitadel/provision.nix consumes the resolved
## (deduped + sorted) list to register the clients in Zitadel, write
## client_id/client_secret to each service's secrets dir
## (/var/lib/homefree-secrets/<svc>), and try-restart its consumer units.
##
## This decomposes the old hardcoded ~14-entry `services` catalog that lived
## inside provision.nix, so an app's OIDC wiring lives WITH the app (and a
## plugin-flake app carries its descriptor in its OWN repo). See plan §4
## "Refined (2026-06-08)".
##
## The push is UNCONDITIONAL (not gated on the app's enable) — matching the
## old catalog, which always provisioned all clients regardless of which apps
## were enabled; the per-client try-restart at consume time is what no-ops for
## a stopped service.

{ config, lib, ... }:

let
  clientSubmodule = lib.types.submodule {
    options = {
      svc = lib.mkOption {
        type = lib.types.str;
        description = "homefree service key — names the secrets dir /var/lib/homefree-secrets/<svc> the client_id/secret are written to.";
      };
      internal_name = lib.mkOption {
        type = lib.types.str;
        description = "Zitadel OIDC application name (unique — this is the dedup key).";
      };
      app_type = lib.mkOption {
        type = lib.types.str;
        default = "OIDC_APP_TYPE_WEB";
      };
      auth_method = lib.mkOption {
        type = lib.types.str;
        default = "OIDC_AUTH_METHOD_TYPE_POST";
      };
      response_types = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ "OIDC_RESPONSE_TYPE_CODE" ];
      };
      grant_types = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ "OIDC_GRANT_TYPE_AUTHORIZATION_CODE" "OIDC_GRANT_TYPE_REFRESH_TOKEN" ];
      };
      redirect_uris = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
      };
      post_logout_uris = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
      };
      needs_pat = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Also create a machine user with an ORG_OWNER PAT (for services that read users/grants).";
      };
      post_restart_units = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Units try-restarted after the client secret is (re)written, so they pick up the new files.";
      };
    };
  };

  ## Dedup by internal_name (a later push overrides an earlier one — so an
  ## app's own descriptor and a still-present provision.nix base entry for the
  ## same client coexist cleanly during migration, both being identical), then
  ## sort by internal_name for deterministic, registration-order-independent
  ## output (the provisioning loop processes each client independently).
  byName = lib.foldl' (acc: c: acc // { ${c.internal_name} = c; })
    { } config.homefree.sso.clients;
  resolved = lib.sort (a: b: a.internal_name < b.internal_name)
    (lib.attrValues byName);
in
{
  options.homefree.sso.clients = lib.mkOption {
    type = lib.types.listOf clientSubmodule;
    default = [ ];
    description = "OIDC client descriptors pushed by each SSO-gated app; consumed by apps/zitadel/provision.nix via resolved-clients.";
  };

  options.homefree.sso.resolved-clients = lib.mkOption {
    type = lib.types.listOf lib.types.attrs;
    internal = true;
    default = [ ];
    description = "Deduped-by-internal_name + sorted client list that provision.nix actually provisions. Computed; do not set directly.";
  };

  config.homefree.sso.resolved-clients = resolved;
}
