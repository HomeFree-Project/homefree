# First run default username and password is admin/admin
{ config, pkgs, ... }:
let
  version = "18.0";
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
in
{
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
        HOST = "10.0.0.1";
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
    requires = [ "dns-ready.service" "postgresql.service" ];
    partOf = [ "nftables.service" ];
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
    reverse-proxy = {
      enable = true;
      subdomains = [ "odoo" ];
      http-domains = [ "homefree.lan" config.homefree.system.localDomain ];
      https-domains = [ config.homefree.system.domain ];
      host = "10.0.0.1";
      port = port;
      public = config.homefree.services.odoo.public;
    };
    backup = {
      paths = [ containerDataPath ];
      postgres-databases = [ database-name ];
    };
  }] else [];
}
