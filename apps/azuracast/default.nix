{ config, pkgs, lib, ... }:
let
  containerDataPath = "/var/lib/azuracast";

  version = "0.23.2";

  image = "ghcr.io/azuracast/azuracast:${version}";

  commonVolumes = [
    "/etc/localtime:/etc/localtime:ro"
    "${containerDataPath}/station_data:/var/azuracast/stations"
    "${containerDataPath}/backups:/var/azuracast/backups"
    "${containerDataPath}/db_data:/var/lib/mysql"
    "${containerDataPath}/www_uploads:/var/azuracast/storage/uploads"
    "${containerDataPath}/shoutcast2_install:/var/azuracast/storage/shoutcast2"
    "${containerDataPath}/stereo_tool_install:/var/azuracast/storage/stereo_tool"
    "${containerDataPath}/rsas_install:/var/azuracast/storage/rsas"
    "${containerDataPath}/geolite_install:/var/azuracast/storage/geoip"
    "${containerDataPath}/sftpgo_data:/var/azuracast/storage/sftpgo"
    "${containerDataPath}/acme:/var/azuracast/storage/acme"
  ];

  preStart = ''
    mkdir -p ${containerDataPath}/station_data
    mkdir -p ${containerDataPath}/backups
    mkdir -p ${containerDataPath}/db_data
    mkdir -p ${containerDataPath}/www_uploads
    mkdir -p ${containerDataPath}/shoutcast2_install
    mkdir -p ${containerDataPath}/stereo_tool_install
    mkdir -p ${containerDataPath}/rsas_install
    mkdir -p ${containerDataPath}/geolite_install
    mkdir -p ${containerDataPath}/sftpgo_data
    mkdir -p ${containerDataPath}/acme

    # Get the UID/GID of the azuracast user from the container image
    # Use --entrypoint to bypass the normal startup which tries to initialize the database
    AZURACAST_UID=$(${config.virtualisation.podman.package}/bin/podman run --rm --entrypoint id ${image} -u azuracast)
    AZURACAST_GID=$(${config.virtualisation.podman.package}/bin/podman run --rm --entrypoint id ${image} -g azuracast)

    # Set ownership on directories that need to be writable by the container
    chown -R "$AZURACAST_UID:$AZURACAST_GID" ${containerDataPath}/station_data
    chown -R "$AZURACAST_UID:$AZURACAST_GID" ${containerDataPath}/backups
    chown -R "$AZURACAST_UID:$AZURACAST_GID" ${containerDataPath}/db_data
    chown -R "$AZURACAST_UID:$AZURACAST_GID" ${containerDataPath}/www_uploads
    chown -R "$AZURACAST_UID:$AZURACAST_GID" ${containerDataPath}/shoutcast2_install
    chown -R "$AZURACAST_UID:$AZURACAST_GID" ${containerDataPath}/stereo_tool_install
    chown -R "$AZURACAST_UID:$AZURACAST_GID" ${containerDataPath}/rsas_install
    chown -R "$AZURACAST_UID:$AZURACAST_GID" ${containerDataPath}/geolite_install
    chown -R "$AZURACAST_UID:$AZURACAST_GID" ${containerDataPath}/sftpgo_data
    chown -R "$AZURACAST_UID:$AZURACAST_GID" ${containerDataPath}/acme
  '';

  port = 8654;
  port-ssh = 2033;
in
{
  ## Admin-UI metadata namespace. The user-facing schema is declared
  ## in module.nix as `homefree.services.azuracast`; module.nix's
  ## generic `intersectAttrs` mirror projects each user-facing service
  ## into `homefree.service-options.<name>` so admin-web can build its
  ## UI. That projection only includes services that have a matching
  ## `service-options.<name>` declaration here.
  options.homefree.service-options.azuracast = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "enable AzuraCast service";
    };

    public = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Open to public on WAN port";
    };

    label = lib.mkOption {
      type = lib.types.str;
      default = "azuracast";
      internal = true;
      description = "Service label";
    };

    name = lib.mkOption {
      type = lib.types.str;
      default = "AzuraCast";
      internal = true;
      description = "Service display name";
    };

    project-name = lib.mkOption {
      type = lib.types.str;
      default = "AzuraCast";
      internal = true;
      description = "Project name";
    };
  };

  config = {

  virtualisation.oci-containers.containers = if config.homefree.services.azuracast.enable == true then {
     azuracast = {
      inherit image;

      autoStart = true;

      extraOptions = [
        "--add-host=host.docker.internal:host-gateway"
      ];

      ports = [
        "0.0.0.0:${toString port}:80"
        "0.0.0.0:${toString port-ssh}:2022"
      ];

      volumes = commonVolumes;

      environment = {
        TZ = config.homefree.system.timeZone;
        # Database will auto-initialize with these settings on first run
        MYSQL_RANDOM_ROOT_PASSWORD = "yes";
      };
    };
  } else {};

  systemd.services.podman-azuracast = {
    after = [ "dns-ready.service" ];
    requires = [ "dns-ready.service" ];
    serviceConfig = {
      ExecStartPre = [
        "!${pkgs.writeShellScript "azuracast-prestart" preStart}"
      ];
    };
  };

  homefree.service-config = if config.homefree.services.azuracast.enable == true then [
    {
      label = "azuracast";
      name = "AzuraCast";
      project-name = "AzuraCast";
      ## @TODO: Why is this not a list?
      systemd-service-names = [
        "podman-azuracast"
      ];
      reverse-proxy = {
        enable = true;
        subdomains = [ "azuracast" ];
        http-domains = [ "homefree.lan" config.homefree.system.localDomain ];
        https-domains = [ config.homefree.system.domain ];
        host = config.homefree.network.lan-address;
        port = port;
        public = config.homefree.services.azuracast.public;
      };
      backup = {
        paths = [
          containerDataPath
        ];
      };
    }
  ] else [];
  };
}
