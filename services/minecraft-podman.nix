{ config, lib, pkgs, ... }:
let
  version = "2025.10.5";

  ## @TODO: Need to manage these ports to avoid conflicts
  initialPort = 25565;
in
{
  virtualisation.oci-containers.containers = lib.optionalAttrs config.homefree.services.minecraft.enable (
    lib.listToAttrs (lib.imap0 (index: instance:
      let
        instance-id = "minecraft_${instance.subdomain}";
        containerDataPath = "/var/lib/${instance-id}";
      in
      {
        name = "minecraft_${instance.subdomain}";
        value = {
          image = "itzg/minecraft-server:${version}";

          autoStart = true;

          extraOptions = [
            # "--pull=always"
            "--add-host=host.docker.internal:host-gateway"
          ];

          ports = [
            "0.0.0.0:${toString (initialPort + index)}:25565"
          ];

          volumes = [
            "/etc/localtime:/etc/localtime:ro"
            "${containerDataPath}/data:/data"
            "${containerDataPath}/downloads:/downloads"
          ];

          environmentFiles = [
            "${containerDataPath}/env"
          ];

          environment = {
            TZ = config.homefree.system.timeZone;
            EULA = "TRUE";
            MOTD = instance.name;
            # VERSION = minecraft_version;
            # OPS = "jumpingnosepizza,theomobile";
            # OPS = "ektoklast";
            # TYPE = "SPIGOT";
            # SERVER_PORT = "25566";
            # MODE = "adventure";
            # ENABLE_RCON = "TRUE";
            # RCON_PASSWORD = "REPLACEME";
            # RCON_PORT = "28016";
            # ANNOUNCE_PLAYER_ACHIEVEMENTS = "TRUE";
            # SPAWN_PROTECTION = "0";
            # WORLD = "/worlds/Lobby";
            # CONSOLE = "FALSE";
            # GUI = "FALSE";
            # ## Not enabled - doesn't work well with bungee-cord multi-server, as it takes a couple minutes
            # ## For each server to start, and they don't start until a portal is entered
            # # ENABLE_AUTOPAUSE = "TRUE";
            # # Time to autopause after last player logs off
            # AUTOPAUSE_TIMEOUT_EST = "900";
            # # Time to autopause after server start
            # AUTOPAUSE_TIMEOUT_INIT = "60";
            # # Needed for autopause
            # MAX_TICK_TIME="-1";
            # WATCHDOG="-1";
            # # Needed for bungeecord
            # ONLINE_MODE = "FALSE";
            # RESOURCE_PACK = "https://github.com/FentisDev/PortalGun/raw/master/resourcepacks/PortalGun-By-Fentis-1.0.0.zip";
            # RESOURCE_PACK_SHA1 = "eed7b6a1513957143fbc8841bd497e9ee41fdf1a";
            # RESOURCE_PACK_ENFORCE = "TRUE";
          } // lib.optionalAttrs (instance.type == "AUTO_CURSEFORGE") {
            # TYPE = "MODRINTH";
            # MODRINTH_MODPACK = instance.mod-pack.project-slug;
            # MODRINTH_MODPACK = instance.mod-pack.download-url;
            # TYPE = "PAPER";
            # GENERIC_PACK = instance.mod-pack.download-url;
            TYPE = "AUTO_CURSEFORGE";
            CF_SLUG = instance.mod-pack.project-slug;
          } // lib.optionalAttrs (instance.memory != null) {
            MEMORY = instance.memory;
          };
        };
      }
    ) config.homefree.services.minecraft.instances)
  );

  systemd.services = lib.optionalAttrs config.homefree.services.minecraft.enable
  (lib.listToAttrs (
    lib.map (instance:
    let
      instance-id = "minecraft_${instance.subdomain}";
      containerDataPath = "/var/lib/${instance-id}";

      preStart = ''
        mkdir -p ${containerDataPath}/data
        mkdir -p ${containerDataPath}/downloads
      '' + (lib.optionalString (config.homefree.services.minecraft.secrets.curseforge-api-key != null) ''
        echo "CF_API_KEY=$(cat ${config.homefree.services.minecraft.secrets.curseforge-api-key})" > ${containerDataPath}/env
      '');
    in
    {
      name = "podman-${instance-id}";
      value = {
        after = [ "dns-ready.service" ];
        requires = [ "dns-ready.service" ];
        partOf =  [ "nftables.service" ];
        serviceConfig = {
          ExecStartPre = [ "!${pkgs.writeShellScript "${instance-id}-prestart" preStart}" ];
        };
      };
    }) config.homefree.services.minecraft.instances)
  );

  homefree.service-config = lib.optionals config.homefree.services.minecraft.enable
  (lib.imap0 (index: instance:
  let
    instance-id = "minecraft_${instance.subdomain}";
    containerDataPath = "/var/lib/${instance-id}";
    port = initialPort + index;
  in
  {
    label = instance-id;
    name = "Minecraft - ${instance.name}";
    project-name = "Minecraft";
    systemd-service-names = [
      "podman-${instance-id}"
    ];
    # @TODO: Get rid of reverse-proxy
    reverse-proxy = {
      enable = true;
      subdomains = [ instance.subdomain ];
      http-domains = [ "homefree.lan" config.homefree.system.localDomain ];
      https-domains = [ config.homefree.system.domain ];
      host = config.homefree.network.lan-address;
      port = port;
      public = instance.public;
    };
    firewall = {
      open-ports = {
        tcp = [ port ];
      };
    };
    backup = {
      paths = [
        containerDataPath
      ];
    };
  }) config.homefree.services.minecraft.instances);
}

