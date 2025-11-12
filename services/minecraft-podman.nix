{ config, lib, pkgs, ... }:
let
  version = "2026.5.0";

  ## @TODO: Need to manage these ports to avoid conflicts
  initialPort = 25565;
in
{
  options.homefree.service-options.minecraft = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "enable Minecraft servers";
    };

    public = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Open to public on WAN port";
    };

    secrets = {
      curseforge-api-key = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = "Location of Curseforge API Key";
      };
      env = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = "Location of docker env file";
      };
      secret-file = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = "Location of Nextcloud secrets file";
      };
    };

    instances = lib.mkOption {
      description = "Minecraft instance config";
      default = [];
      type = with lib.types; listOf (submodule {
        options = {
          public = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Open to public on WAN port";
          };
          subdomain = lib.mkOption {
            type = lib.types.str;
            default = "minecraft";
            description = "Subdomain for Minecraft instance (must be unique)";
          };
          name = lib.mkOption {
            type = lib.types.str;
            default = "Minecraft";
            description = "Name for instance";
          };
        };
      });
    };

    options-metadata = [
      {
        path = "enable";
        type = "bool";
        default = false;
        description = "Enable Minecraft servers";
      }
      {
        path = "public";
        type = "bool";
        default = false;
        description = "Make service accessible from WAN";
      }
      {
        path = "instances";
        type = "listOf submodule";
        nullable = true;
        default = null;
        description = "Minecraft server instance configurations";
        submodule-fields = [
          {
            path = "public";
            type = "bool";
            default = false;
            description = "Make this instance accessible from WAN";
          }
          {
            path = "subdomain";
            type = "str";
            default = "minecraft";
            description = "Subdomain for Minecraft instance (must be unique)";
          }
          {
            path = "name";
            type = "str";
            default = "Minecraft";
            description = "Display name for instance";
          }
          {
            path = "memory";
            type = "str";
            nullable = true;
            default = null;
            description = "Memory for Java VM, e.g. 6G";
            ui-hint = "memory-size";
          }
          {
            path = "type";
            type = "enum";
            nullable = true;
            default = null;
            description = "Minecraft server type or mod platform";
            enum-values = [
              "AUTO_CURSEFORGE"
              "CURSEFORGE"
              "FTBA"
              "GTNH"
              "MODRINTH"
              "SPIGOT"
              "FABRIC"
              "MAGMA"
              "MAGMA_MAINTAINED"
              "KETTING"
              "MOHIST"
              "YOUER"
              "BANNER"
              "CATSERVER"
              "ARCLIGHT"
              "SPONGEVANILLA"
              "PAPER"
              "PURPUR"
              "LEAF"
              "FOLIA"
              "QUILT"
            ];
          }
          {
            path = "mod-pack";
            type = "submodule";
            description = "Mod pack configuration";
            submodule-fields = [
              {
                path = "download-url";
                type = "str";
                required = true;
                description = "Download URL for mod pack";
                ui-hint = "url-input";
              }
              {
                path = "project-slug";
                type = "str";
                required = true;
                description = "Project slug identifier";
              }
            ];
          }
          {
            path = "mods";
            type = "listOf submodule";
            default = [];
            description = "Individual mod configurations";
            submodule-fields = [
              {
                path = "download-url";
                type = "str";
                required = true;
                description = "Download URL for mod";
                ui-hint = "url-input";
              }
              {
                path = "project-slug";
                type = "str";
                required = true;
                description = "Project slug identifier";
              }
            ];
          }
        ];
      }
    ];
  };

  config = {
    virtualisation.oci-containers.containers = lib.optionalAttrs config.homefree.service-options.minecraft.enable (
    lib.listToAttrs (lib.imap0 (index: instance:
      let
        instance-id = "minecraft_${instance.subdomain}";
        containerDataPath = "/var/lib/${instance-id}";
      in
      {
        name = "minecraft_${instance.subdomain}";
        value = {
          image = "itzg/minecraft-server:${if instance.image-tag != null then instance.image-tag else version}";

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
            MODE = instance.mode;
            FORCE_GAMEMODE = "true";
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
    ) config.homefree.service-options.minecraft.instances)
  );

  systemd.services = lib.optionalAttrs config.homefree.service-options.minecraft.enable
  (lib.listToAttrs (
    lib.map (instance:
    let
      instance-id = "minecraft_${instance.subdomain}";
      containerDataPath = "/var/lib/${instance-id}";

      preStart = ''
        mkdir -p ${containerDataPath}/data
        mkdir -p ${containerDataPath}/downloads
      '' + (lib.optionalString (config.homefree.service-options.minecraft.secrets.curseforge-api-key != null) ''
        echo "CF_API_KEY=$(cat ${config.homefree.service-options.minecraft.secrets.curseforge-api-key})" > ${containerDataPath}/env
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
    }) config.homefree.service-options.minecraft.instances)
  );

  homefree.service-config = lib.optionals config.homefree.service-options.minecraft.enable
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
      enable = config.homefree.service-options.minecraft.enable;
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
  }) config.homefree.service-options.minecraft.instances);
  };
}

