# SSO OIDC-client registry — `homefree.sso.clients`

`modules/sso-clients.nix` declares `homefree.sso.clients`, a registry each
SSO-gated app pushes ONE OIDC-client descriptor into, plus a computed
`homefree.sso.resolved-clients` (deduped by `internal_name`, sorted).
`apps/zitadel/provision.nix` consumes `resolved-clients` to register each OIDC
application in Zitadel, write `client_id`/`client_secret` to the service's secrets
dir (`/var/lib/homefree-secrets/<svc>`), optionally create a machine-user PAT
(`needs_pat`), and try-restart the consumer units.

This replaced the old ~14-entry hardcoded `services` catalog inside
`provision.nix`, so an app's OIDC wiring lives WITH the app (and a plugin-flake
app carries its descriptor in its OWN repo). See plan §4.

## Declaring a client (in `apps/<name>/default.nix`)

```nix
config.homefree.sso.clients = [{
  svc = "<name>";                 # gates provisioning + names the secrets dir
  internal_name = "homefree-<name>";  # Zitadel app name (the dedup key, unique)
  # app_type/auth_method/response_types/grant_types have sane OIDC defaults
  redirect_uris   = [ "https://<sub>.${config.homefree.system.domain}/<callback>" ];
  post_logout_uris = [ "https://<sub>.${config.homefree.system.domain}/" ];
  needs_pat = false;              # also mint an ORG_OWNER PAT machine user
  post_restart_units = [ "podman-<name>.service" ];  # try-restarted on secret (re)write
}];
```

Push UNCONDITIONALLY (NOT inside `lib.mkIf enable`) — the old catalog always
provisioned every client regardless of which apps were enabled; the per-client
try-restart is what no-ops for a stopped service.

## What stays in `provision.nix`

`baseClients` keeps only the two it owns:
- `homefree-oauth2proxy` — the SSO bridge; its `post_logout_uris` is DERIVED from
  the gated-service set (`oauth2ProxyPostLogoutUris`), not static.
- `homefree-grampsweb` — a plugin app whose descriptor stays here until its plugin
  repo grows a per-service OIDC extension point (TODO in the file).

## How the migration was verified (no behavioural test for live Zitadel)

`resolved-clients` (the sorted, deduped client set) is captured by the
app-config-snapshot (`ssoClients` field) — see
[snapshot-test-net.md](snapshot-test-net.md). The dedup lets an app's push and a
still-present `baseClients` copy coexist as a no-op DURING migration; the
authoritative check is that after removing a descriptor from `baseClients`,
`resolved-clients` is STILL the identical set (so the moved descriptor is
byte-correct). When moving a descriptor, the evaluated values must match exactly —
`${domain}` in `provision.nix` is `config.homefree.system.domain`, so use the
app's own `domain` let-binding or `${config.homefree.system.domain}`.
