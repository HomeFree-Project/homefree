# First run default username and password is admin/admin
{ config, lib, pkgs, ... }:
let
  version = "19.0";
  containerDataPath = "/var/lib/odoo-podman";
  port = config.homefree.allocPort "odoo";
  database-name = "odoo";
  database-user = "odoo";

  # Odoo container runs as user 'odoo' with UID 100, GID 101
  odoo-uid = "100";
  odoo-gid = "101";

  enable = config.homefree.services.odoo.enable;

  userOptions = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "enable Odoo ERP service";
    };

    public = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Open to public on WAN port";
    };
  };
in
{
  ## Admin-UI metadata namespace. The user-facing schema is declared
  ## in module.nix as `homefree.services.odoo`; module.nix's generic
  ## `intersectAttrs` mirror projects each user-facing service into
  ## `homefree.service-options.<name>` so admin-web can build its UI.
  ## That projection only includes services that have a matching
  ## `service-options.<name>` declaration here.
  options.homefree.services.odoo = userOptions;
  options.homefree.service-options.odoo = userOptions // {
    label = lib.mkOption {
      type = lib.types.str;
      default = "odoo";
      internal = true;
      description = "Service label";
    };

    name = lib.mkOption {
      type = lib.types.str;
      default = "Odoo ERP";
      internal = true;
      description = "Service display name";
    };

    project-name = lib.mkOption {
      type = lib.types.str;
      default = "odoo";
      internal = true;
      description = "Project name";
    };
  };

  config = {

  services.postgresql = if enable then {
    enable = true;
    ensureDatabases = [ database-name ];
    ensureUsers = [{
      name = database-user;
      ensureDBOwnership = true;
      ensureClauses.login = true;
    }];
  } else {};

  ## Container via the app-platform primitive (modules/app-platform.nix).
  ## SKIPPED non-root: Odoo 19's official image is built with uid 100 / gid 101
  ## baked in; the entrypoint chowns /var/lib/odoo and /etc/odoo at startup as
  ## root then drops to that uid. Passing user= prevents the chown, causing
  ## startup failures. The image predates HomeFree's 800-899 uid range and has
  ## no PUID/PGID mechanism. postgresql ordering + partOf are in the escape-hatch
  ## systemd.services.podman-odoo block below.
  homefree.containers.odoo = lib.mkIf enable {
    image = "odoo:${version}";
    runAs = {
      mode = "root";
      reason = "official image chowns /var/lib/odoo + /etc/odoo as root at startup then drops to uid 100; user= breaks the chown";
    };

    ports = [ "0.0.0.0:${toString port}:8069" ];

    volumes = [
      "/etc/localtime:/etc/localtime:ro"
      "${containerDataPath}/data:/var/lib/odoo"
      "${containerDataPath}/config:/etc/odoo"
      "${containerDataPath}/addons:/mnt/extra-addons"
      "/run/postgresql:/run/postgresql"
    ];

    environment = {
      TZ = config.homefree.system.timeZone;
      ## libpq treats a host beginning with `/` as a unix socket
      ## directory. /run/postgresql is bind-mounted into the
      ## container (volumes above), so odoo connects via the socket
      ## under local-trust auth — no password needed, and the
      ## connection bypasses the host pg_hba TCP rules entirely.
      ## Same pattern as freshrss / joplin / matrix / nextcloud.
      ## (Previously HOST was the lan-address with TCP+trust; Phase
      ## 2's hba swap to scram-sha-256 broke that path because
      ## odoo's role has no password.)
      HOST = "/run/postgresql";
      USER = database-user;
    };

    # Initialize database with base module on startup
    # Odoo skips re-initialization if already done
    cmd = [ "--database" database-name "--init" "base" ];

    ## Multiple independent subdirs + config file + unconditional chowns.
    ## Emit the full preStart verbatim (no generated mkdir/chown — root mode).
    preStartInit = ''
      mkdir -p ${containerDataPath}/data
      mkdir -p ${containerDataPath}/config
      mkdir -p ${containerDataPath}/addons

      # Create default odoo.conf if it doesn't exist
      if [ ! -f ${containerDataPath}/config/odoo.conf ]; then
        cat > ${containerDataPath}/config/odoo.conf << 'EOF'
[options]
addons_path = /mnt/extra-addons
data_dir = /var/lib/odoo
EOF
      fi

      # Ensure proper permissions for odoo user (uid 100, gid 101)
      chown -R ${odoo-uid}:${odoo-gid} ${containerDataPath}/data || true
      chown -R ${odoo-uid}:${odoo-gid} ${containerDataPath}/config || true
      chown -R ${odoo-uid}:${odoo-gid} ${containerDataPath}/addons || true
    '';
  };

  ## Escape hatch: postgresql ordering not covered by the app-platform descriptor.
  ## Merged onto the generated podman-odoo unit (dns-ready after/wants come from
  ## the generator; postgresql after/requires/partOf are added here).
  systemd.services.podman-odoo = lib.mkIf enable {
    after = [ "postgresql.service" ];
    requires = [ "postgresql.service" ];
    ## Re-bind /run/postgresql when postgres restarts — without
    ## partOf the container's existing mount is orphaned and DB
    ## queries fail with ENOENT. Same pattern as nextcloud/freshrss.
    partOf = [ "postgresql.service" ];
  };

  homefree.service-config = if enable then [{
    label = "odoo";
      port-request = null;
    name = "Odoo ERP";
    project-name = "odoo";
    systemd-service-names = [
      "podman-odoo"
      "postgresql"
    ];
    sso = {
      kind = "none";
      applicable = false;
      ## Dev context (intentionally not surfaced in the admin UI):
      ## Odoo 19 CE has no usable in-tree OIDC: `auth_oauth` is
      ## hardcoded to Google/Facebook/Odoo.com with implicit-flow only
      ## (no client_secret/token_endpoint/jwks_uri fields), and Odoo
      ## has no auth-disable or trusted-header mode, so caddy_gated is
      ## also out. A clean integration requires the third-party OCA
      ## `auth_oidc` module mounted into addons_path, a SQL provisioner
      ## inserting an auth_oauth_provider row with Zitadel's endpoints,
      ## and pre-creating every Odoo user with a matching email — even
      ## then the local /web/login form stays reachable. Deferred until
      ## Odoo usage justifies the moving parts. Use Odoo's built-in
      ## users for now.
    };
    reverse-proxy = {
      enable = true;
      subdomains = [ "odoo" "erp" ];
      http-domains = [ "homefree.lan" config.homefree.system.localDomain ];
      https-domains = [ config.homefree.system.domain ];
      host = config.homefree.network.lan-address;
      port = port;
      public = config.homefree.services.odoo.public;
    };
    backup = {
      paths = [ containerDataPath ];
      postgres-databases = [ database-name ];
    };
  }] else [];
  };
}
