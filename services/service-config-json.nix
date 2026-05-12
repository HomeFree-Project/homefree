{ config, lib, pkgs, ... }:
let
  ## Render every entry in homefree.service-config to a JSON file
  ## that the admin backend (and any other tool) can read as the
  ## single source of truth for what services exist, how they auth,
  ## what their reverse-proxy/backup config is, etc.
  ##
  ## Path: /etc/homefree/service-config.json (managed via
  ## environment.etc — replaced atomically on every nixos-rebuild
  ## switch, so the backend's runtime view is always in sync with
  ## the active generation).
  ##
  ## Shape: a JSON array of full service-config entries. The backend
  ## filters/projects from this; we don't pre-shape for any one
  ## consumer.
  ##
  ## We use builtins.toJSON directly on the catalog, but Nix's JSON
  ## encoder doesn't handle every type cleanly: store paths get their
  ## /nix/store/... string, but `nullOr path` defaults to null which
  ## the encoder happily emits. The only fields that need
  ## normalization are paths-that-might-be-strings and lists of paths.
  ##
  ## Rather than hand-write a serializer for every field, we round-
  ## trip through writeText so Nix coerces store-path values to
  ## strings as it interpolates them — but that loses structure.
  ## Instead: we explicitly project each entry to its JSON-friendly
  ## shape below. Anything we DON'T project doesn't appear in the
  ## output; bump this when you add new submodule fields you want
  ## the backend to see.

  ## Convert a path-or-null to a string-or-null.
  pathToString = p: if p == null then null else toString p;

  ## Project one reverse-proxy submodule to a JSON-friendly attrset.
  projectReverseProxy = rp: {
    enable = rp.enable;
    description = rp.description;
    rootDomain = rp.rootDomain;
    subdomains = rp.subdomains;
    http-domains = rp.http-domains;
    https-domains = rp.https-domains;
    host = rp.host;
    port = rp.port;
    static-path = pathToString rp.static-path;
    subdir = rp.subdir;
    public = rp.public;
    ssl = rp.ssl;
    ssl-no-verify = rp.ssl-no-verify;
    basic-auth = rp.basic-auth;
    oauth2 = rp.oauth2;
    require-admin-role = rp.require-admin-role;
    inject-basic-auth-env = rp.inject-basic-auth-env;
    upstream-logout-paths = rp.upstream-logout-paths;
    ## extraCaddyConfig can be very long; include it so debugging is
    ## possible but truncated previews are up to the consumer.
    extraCaddyConfig = rp.extraCaddyConfig;
  };

  projectBackup = b: {
    paths = map toString b.paths;
    mysql-databases = b.mysql-databases;
    postgres-databases = b.postgres-databases;
  };

  ## options-metadata is already plain data (strings/bools/null) per
  ## its submodule schema in module.nix — no projection needed beyond
  ## making sure `default` survives. Nix's toJSON handles anything.
  projectEntry = e: {
    label = e.label;
    name = e.name;
    project-name = e.project-name;
    parent = e.parent;
    icon = pathToString e.icon;
    release-tracking = e.release-tracking;
    systemd-service-names = e.systemd-service-names;
    admin = e.admin;
    firewall = e.firewall;
    sso = e.sso;
    reverse-proxy = projectReverseProxy e.reverse-proxy;
    backup = projectBackup e.backup;
    options-metadata = e.options-metadata;
  };

  catalogJSON =
    builtins.toJSON (map projectEntry config.homefree.service-config);
in
{
  ## Always present, regardless of which services are enabled. An
  ## empty `service-config` produces "[]" — still useful for the
  ## backend to detect "module is alive" vs "stale install".
  environment.etc."homefree/service-config.json" = {
    text = catalogJSON;
    mode = "0644";
  };
}
