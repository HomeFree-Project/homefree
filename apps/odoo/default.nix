# First run default username and password is admin/admin
{ config, lib, pkgs, ... }:
let
  version = "19.0";
  containerDataPath = "/var/lib/odoo-podman";
  port = 8069;
  database-name = "odoo";
  database-user = "odoo";

  # Odoo container runs as user 'odoo' with UID 100, GID 101
  odoo-uid = "100";
  odoo-gid = "101";

  preStart = ''
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

  services.postgresql = if config.homefree.services.odoo.enable then {
    enable = true;
    ensureDatabases = [ database-name ];
    ensureUsers = [{
      name = database-user;
      ensureDBOwnership = true;
      ensureClauses.login = true;
    }];
  } else {};

  virtualisation.oci-containers.containers = if config.homefree.services.odoo.enable then {
    odoo = {
      image = "odoo:${version}";
      autoStart = true;
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
        HOST = config.homefree.network.lan-address;
        PORT = "5432";
        USER = database-user;
      };

      # Initialize database with base module on startup
      # Odoo skips re-initialization if already done
      cmd = [ "--database" database-name "--init" "base" ];
    };
  } else {};

  systemd.services.podman-odoo = {
    after = [ "dns-ready.service" "postgresql.service" ];
    requires = [ "postgresql.service" ];
    wants = [ "dns-ready.service" ];
    serviceConfig = {
      ExecStartPre = [ "!${pkgs.writeShellScript "odoo-prestart" preStart}" ];
    };
  };

  homefree.service-config = if config.homefree.services.odoo.enable == true then [{
    label = "odoo";
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
