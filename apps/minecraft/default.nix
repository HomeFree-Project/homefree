{ config, lib, pkgs, ... }:
let
  version = "2026.6.0";

  ## The DEFAULT image pin, on its own scanner-visible line: the version
  ## tracker / upgrade-apps.py parse literal `image = "...''${version}";`
  ## lines only — the previous inline `''${if instance.image-tag ...}`
  ## expression made minecraft invisible to both (never bumpable, and
  ## each instance container surfaced as its own row instead of
  ## collapsing onto this single source pin). Instance image-tag
  ## overrides are applied where the container is declared.
  image = "itzg/minecraft-server:${version}";

  ## @TODO: Need to manage these ports to avoid conflicts
  initialPort = 25565;

  ## itzg/minecraft-server reads UID / GID env vars (note: not
  ## PUID/PGID like LSIO) and chowns /data to that UID at entrypoint.
  ## All minecraft instances on the box share a single HomeFree-
  ## managed system user. Container PID 1 still runs as root briefly
  ## while the entrypoint does setup, then the Java process drops to
  ## this UID.
  minecraftUid = 812;
  minecraftGid = 812;

  userOptions = {
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
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "CurseForge API key for downloading modpacks (SOPS-managed)";
      };
    };

    instances = lib.mkOption {
      description = "Minecraft instance config";
      default = [];
      type = with lib.types; listOf (submodule {
        options = {
          enable = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = "Enable this Minecraft instance";
          };
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
          memory = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Memory for java vm, e.g. 6G";
          };
          image-tag = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Override itzg/minecraft-server image tag, e.g. \"2026.5.0-java17\". Falls back to the module-wide default when null.";
          };
          mode = lib.mkOption {
            type = lib.types.nullOr (lib.types.enum [ "adventure" "creative" "hardcore" "spectator" "survival" ]);
            default = "survival";
          };
          type = lib.mkOption {
            type = lib.types.nullOr (lib.types.enum [
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
            ]);
            default = null;
          };
          mod-pack = {
            download-url = lib.mkOption {
              type = lib.types.str;
              description = "Download URL";
            };
            project-slug = lib.mkOption {
              type = lib.types.str;
              description = "Project slug";
            };
          };
          mods = lib.mkOption {
            default = [];
            description = "Mod configs";
            type = with lib.types; listOf (submodule {
              options = {
                download-url = lib.mkOption {
                  type = lib.types.str;
                  description = "Download URL";
                };
                project-slug = lib.mkOption {
                  type = lib.types.str;
                  description = "Project slug";
                };
              };
            });
          };
        };
      });
    };
  };
in
{
  options.homefree.services.minecraft = userOptions;
  options.homefree.service-options.minecraft = userOptions // {
    # Internal option to hold metadata for admin UI schema generation
    options-metadata = lib.mkOption {
      type = lib.types.listOf lib.types.attrs;
      internal = true;
      default = [
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
          path = "secrets";
          type = "submodule";
          description = "Secret values for Minecraft service (managed via SOPS)";
          sops-managed = true;
          submodule-fields = [
            {
              path = "curseforge-api-key";
              type = "str";
              nullable = true;
              default = null;
              description = "CurseForge API key for downloading modpacks";
              sops-managed = true;
            }
          ];
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
              path = "image-tag";
              type = "str";
              nullable = true;
              default = null;
              description = "Pin a specific itzg/minecraft-server image tag (e.g. java21, 2025.7.0). Leave empty for the project default.";
            }
            {
              path = "mode";
              type = "enum";
              default = "survival";
              description = "Default game mode for the world";
              enum-values = [ "survival" "creative" "adventure" "spectator" ];
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
  };

  config = {
    users.users.minecraft = lib.mkIf config.homefree.service-options.minecraft.enable {
      isSystemUser = true;
      group = "minecraft";
      uid = minecraftUid;
      description = "Minecraft (itzg) container runtime user";
    };
    users.groups.minecraft = lib.mkIf config.homefree.service-options.minecraft.enable {
      gid = minecraftGid;
    };

    virtualisation.oci-containers.containers = lib.optionalAttrs config.homefree.service-options.minecraft.enable (
    lib.listToAttrs (lib.imap0 (index: instance:
      let
        instance-id = "minecraft_${instance.subdomain}";
        containerDataPath = "/var/lib/${instance-id}";
      in
      {
        name = "minecraft_${instance.subdomain}";
        value = {
          ## Per-instance image-tag override (App Configuration page);
          ## the default pin is the let-bound `image` above.
          image = if instance.image-tag != null
            then "itzg/minecraft-server:${instance.image-tag}"
            else image;

          autoStart = true;

          extraOptions = [
            # "--pull=always"
            "--add-host=host.docker.internal:host-gateway"
            # Disable the image's bundled healthcheck. The itzg/minecraft-server
            # image registers a HEALTHCHECK that podman runs as a transient
            # systemd unit. The check returns "starting" with exit 1 during
            # the 30-60s Java cold-start window. Each nixos-rebuild
            # immediately restarts the container (because its ExecStart path
            # transitively depends on glibc/coreutils/podman, all of which
            # rotate on rebuilds), so the healthcheck fires while still
            # "starting" and the rebuild logs report a failed unit and
            # nixos-rebuild exits with status 4. We don't act on the
            # healthcheck result anywhere, so suppressing it is harmless.
            "--no-healthcheck"
          ];

          ports = [
            "0.0.0.0:${toString (config.homefree.allocPort instance-id)}:25565"
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
            ## itzg/minecraft-server-specific UID/GID env (not PUID/
            ## PGID). Entrypoint chowns /data and runs Java as this UID.
            UID = toString minecraftUid;
            GID = toString minecraftGid;
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
    ) (lib.filter (instance: instance.enable) config.homefree.service-options.minecraft.instances))
  );

  systemd.services = lib.mkIf config.homefree.service-options.minecraft.enable
  (lib.listToAttrs (
    lib.map (instance:
    let
      instance-id = "minecraft_${instance.subdomain}";
      containerDataPath = "/var/lib/${instance-id}";

      preStart = ''
        mkdir -p ${containerDataPath}/data
        mkdir -p ${containerDataPath}/downloads
        # Create env file (empty or with secrets)
        if [ -f /var/lib/homefree-secrets/${instance-id}/curseforge-api-key ]; then
          echo "CF_API_KEY=$(cat /var/lib/homefree-secrets/${instance-id}/curseforge-api-key)" > ${containerDataPath}/env
        else
          # Create empty env file so podman doesn't fail
          touch ${containerDataPath}/env
        fi
      '';
    in
    {
      name = "podman-${instance-id}";
      value = {
        after = [ "dns-ready.service" ];
        wants = [ "dns-ready.service" ];
        # Don't kick the running game server on every nixos-rebuild just
        # because some transitive dependency (glibc, podman, coreutils)
        # rotated. The container itself doesn't change unless the image
        # tag, env, volumes, or our preStart script content changes —
        # those still go through the explicit reload path. Players don't
        # want their world dropped mid-match for a routine system update.
        restartIfChanged = false;
        serviceConfig = {
          ExecStartPre = [ "!${pkgs.writeShellScript "${instance-id}-prestart" preStart}" ];
        };
      };
    }) (lib.filter (instance: instance.enable) config.homefree.service-options.minecraft.instances))
  );

  homefree.service-config = lib.optionals config.homefree.service-options.minecraft.enable
  (
    # Parent service entry (no systemd services, aggregates status from children)
    [{
      label = "minecraft";
      name = "Minecraft";
      project-name = "Minecraft";
      sso = {
        kind = "none";
        applicable = false;
        ## Dev context (intentionally not surfaced in the admin UI):
        ## Minecraft uses the Minecraft protocol on raw TCP (default
        ## 25565), not HTTP. Player auth is handled by Mojang/Microsoft
        ## on the game client; the server has no web UI. SSO is not
        ## applicable.
      };
      systemd-service-names = [];
      reverse-proxy.enable = false;
    }]
    ++
    # Individual instance entries (only enabled instances)
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
      icon = ./icon.svg;
      port-request = initialPort + index;
      parent = "minecraft";  # Mark this as a child of the parent service
      sso = {
        kind = "none";
        applicable = false;
        ## Dev context (intentionally not surfaced in the admin UI):
        ## Minecraft protocol on raw TCP; no HTTP/OIDC surface. Player
        ## auth is Mojang/Microsoft-side.
      };
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
  }) config.homefree.service-options.minecraft.instances)
  );
  };
}

