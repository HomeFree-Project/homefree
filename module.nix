## @TODO: Look at the following for a VM test setup
## https://github.com/nix-community/disko/blob/master/module.nix

{ config, options, lib, pkgs, extendModules, ... }:

# let
#   vmVariantWithHomefree = extendModules {
#     modules = [
#       ./lib/interactive-vm.nix
#     ];
#   };
# in
{
  options.homefree = {
    development = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Indicates development mode is enabled.
        When true, services may bind to all interfaces for easier testing.
      '';
    };

    system = {
      hostName = lib.mkOption {
        type = lib.types.str;
        default = "homefree";
        description = "Hostname for the system";
      };

      ## @TODO: Detect or have user enter during setup
      timeZone = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = "Etc/UTC";
        description = ''
          Timezone for the system in tz database format.
          See: https://en.wikipedia.org/wiki/List_of_tz_database_time_zones

          example: America/Los_Angeles
        '';
      };

      countryCode = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          Country code in ISO-3166-1 two-letter code format.
          See: https://en.wikipedia.org/wiki/ISO_3166-1_alpha-2#Officially_assigned_code_elements

          example: US
        '';
      };

      elevation = lib.mkOption {
        type = lib.types.nullOr lib.types.int;
        default = null;
        description = ''
          Elevation above sea level in meters. Used by Home Assistant
          for sunrise/sunset and other location-aware integrations.
        '';
      };

      latitude = lib.mkOption {
        type = lib.types.nullOr (lib.types.either lib.types.float lib.types.int);
        default = null;
        description = ''
          Latitude in decimal degrees. Used by Home Assistant for
          location-based automations (sun, weather, etc.).
        '';
      };

      longitude = lib.mkOption {
        type = lib.types.nullOr (lib.types.either lib.types.float lib.types.int);
        default = null;
        description = "Longitude in decimal degrees.";
      };

      unitSystem = lib.mkOption {
        type = lib.types.enum [ "metric" "us_customary" ];
        default = "metric";
        description = ''
          Unit system. Values match Home Assistant's
          `homeassistant.unit_system` config key exactly.
        '';
      };

      currency = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          ISO 4217 three-letter currency code (e.g., USD, EUR, JPY).
          Used by Home Assistant and finance-related services.
        '';
      };

      language = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          BCP 47 user-facing language tag (e.g., en, en-GB, de).
          Distinct from `defaultLocale` (the POSIX system locale like
          en_US.UTF-8) — this is the preferred UI language passed to
          apps that have their own language setting (Home Assistant,
          Nextcloud, etc.).
        '';
      };

      ## @TODO: Detect during setup
      defaultLocale = lib.mkOption {
        type = lib.types.str;
        default = "en_US.UTF-8";
        description = "Default locale for the system";
      };

      keyMap = lib.mkOption {
        type = lib.types.str;
        default = "us";
        description = "Keymap for system";
      };

      localDomain = lib.mkOption {
        type = lib.types.str;
        ## @TODO: Should this be "local"?
        default = "lan";
        description = ''
          local lan domain for internal devices and services.

          Default is "lan". Don't choose "local", as this can conflict with Multicast DNS (mDNS) services,
          such as Apple's Bonjour/Zeroconf. "local" is also a reserved TLD and some tools and browsers
          might trigger cert warnings.

          Other common localdomains you can use:
          "localdomain"
          "home"
          "private"
          "internal"
        '';
      };

      domain = lib.mkOption {
        type = lib.types.str;
        default = "homefree.host";
        description = "Domain for the system";
      };

      additionalDomains = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        description = "Additional zones for the system";
      };

      project-mode = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          When true, the apex domain serves the public HomeFree project
          marketing site (hero, comparison, FAQ, install CTA). This is
          only appropriate for the upstream homefree.host instance.

          When false (the default for any real personal deployment), the
          apex domain redirects to home.<domain> — the per-user
          dashboard — so visitors flow into the SSO sign-in instead of
          being pitched the HomeFree project.

          The manual subdomain (manual.<domain>) is unaffected and stays
          available in both modes.
        '';
      };

      adminUsername = lib.mkOption {
        type = lib.types.str;
        default = "homefree";
        description = "Username for the system admin";
      };

      adminDescription = lib.mkOption {
        type = lib.types.str;
        default = "HomeFree Admin";
        description = "Username for the system admin";
      };

      adminEmail = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = "Email address for the system admin";
      };

      adminHashedPassword = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = ''
          Hashed password for the system admin
          Generate with:
          mkpasswd -m sha-512
        '';
      };

      authorizedKeys = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        description = ''
          SSH authorized keys for the system admin.

          Note: The first key will also be used for encrypting secrets with sops-nix.
          You'll need the corresponding private key to decrypt and manage secrets.
        '';
      };
    };

    ## @TODO: This section doesn't make sense. Some network config is in "system" above
    ##        and some is in separate services, e.g. unbound and ddns
    network = {
      ## @TODO: Detect during setup
      wan-interface = lib.mkOption {
        type = lib.types.str;
        default = "ens3";
        description = "External interface to the internet";
      };

      wan-bitrate-mbps-down = lib.mkOption {
        type = lib.types.nullOr lib.types.int;
        default = null;
        description = "WAN download bitrate in Mbit/s";
      };

      wan-bitrate-mbps-up = lib.mkOption {
        type = lib.types.nullOr lib.types.int;
        default = null;
        description = "WAN upload bitrate in Mbit/s";
      };

      ## @TODO: Detect during setup
      lan-interface = lib.mkOption {
        type = lib.types.str;
        default = "ens5";
        description = "Internal interface to the local network";
      };

      # QEMU User-Mode Network Details:
      # - Guest IP: Always 10.0.2.15
      # - Gateway/Host: Always 10.0.2.2
      # - DNS: Always 10.0.2.3
      # - Network: 10.0.2.0/24
      lan-address = lib.mkOption {
        type = lib.types.str;
        default = "10.0.0.1";
        description = "IP address of the LAN gateway (router address)";
      };

      lan-subnet = lib.mkOption {
        type = lib.types.str;
        default = "10.0.0.0/24";
        description = "LAN subnet in CIDR notation";
      };

      lan-netmask = lib.mkOption {
        type = lib.types.str;
        default = "255.255.255.0";
        description = "LAN subnet mask";
      };

      dhcp-range-start = lib.mkOption {
        type = lib.types.str;
        default = "10.0.0.100";
        description = "Start of DHCP IP address range";
      };

      dhcp-range-end = lib.mkOption {
        type = lib.types.str;
        default = "10.0.0.254";
        description = "End of DHCP IP address range";
      };

      dhcp-lease-time = lib.mkOption {
        type = lib.types.str;
        default = "8h";
        description = "DHCP lease time (e.g., '8h', '24h', '7d')";
      };

      static-ip-expiration = lib.mkOption {
        type = lib.types.str;
        default = "3d";
        description = "Expiration time of static IPs";
      };

      static-ips = lib.mkOption {
        default = [];
        description = "Static IP mappings";
        type = with lib.types; listOf (submodule {
          options = {
            mac-address = lib.mkOption {
              type = lib.types.str;
              description = "MAC address to assign IP to";
            };

            hostname = lib.mkOption {
              type = lib.types.str;
              description = "Hostname to assign to IP";
            };

            ip = lib.mkOption {
              type = lib.types.str;
              description = "IP Address";
            };

            wan-access = lib.mkOption {
              type = lib.types.bool;
              description = "Whether to allow IP access to WAN";
              default = true;
            };
          };
        });
      };

      enable-unbound-adblock = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Enable the Steven Black hosts list inside the Unbound resolver.
          This is a separate, lower-level ad-blocking layer than AdGuard
          Home and is typically left off when AdGuard is enabled.
        '';
      };

      blocked-domains = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        description = "list of domains to block";
      };

      router = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "enable router functionality";
        };
      };
    };

    dns = {
      local = {
        overrides = lib.mkOption {
          description = "dns hostname to IP overrides";
          default = [];
          type = with lib.types; listOf (submodule {
            options = {
              hostname = lib.mkOption {
                type = lib.types.str;
                description = "Hostname of override";
              };

              domain = lib.mkOption {
                type = lib.types.str;
                description = "Domain of override";
              };

              ip = lib.mkOption {
                type = lib.types.str;
                description = "IP Address";
              };
            };
          });
        };
      };

      remote = {
        cert-management = {
          dns-01 = {
            provider = lib.mkOption {
              type = lib.types.nullOr (lib.types.enum [
                "hetzner"
              ]);
              default = null;
              description = "Needed for wildcard certs. Usually requires an API Key";
            };

            resolvers = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ "1.1.1.1" ];
              description = "DNS resolvers for ACME zone detection. Required when local DNS has redirect zones that don't return SOA records.";
              example = [ "1.1.1.1" "8.8.8.8" ];
            };

            secrets = {
              api-token = lib.mkOption {
                type = lib.types.nullOr lib.types.path;
                default = null;
                description = "Location of API token. Should not be a file included in your source repo.";
              };
            };
          };
        };

        dynamic-dns = {
          interval = lib.mkOption {
            type = lib.types.str;
            default = "10m";
            description = "Interval for dynamic DNS client";
          };

          usev4 = lib.mkOption {
            type = lib.types.str;
            default = "webv4, webv4=ipinfo.io/ip";
            description = "Use format for obtaining ipv4 for dynamic DNS client";
          };

          usev6 = lib.mkOption {
            type = lib.types.str;
            default = "webv6, webv6=v6.ipinfo.io/ip";
            description = "Use format for obtaining ipv6 for dynamic DNS client";
          };

          zones = lib.mkOption {
            description = "Dynamic DNS Zone Config";
            default = [];
            type = with lib.types; listOf (submodule {
              options = {
                disable = lib.mkOption {
                  type = lib.types.bool;
                  default = false;
                  description = "disable dynamic dns for zone";
                };

                ## @TODO: validate against network.domain and network.additionalDomains?
                zone = lib.mkOption {
                  type = lib.types.str;
                  default = "homefree.host";
                  description = "Zone for dynamic DNS client";
                };

                protocol = lib.mkOption {
                  type = lib.types.str;
                  default = "hetzner";
                  description = "Protocol for dynamic DNS client";
                };

                username = lib.mkOption {
                  type = lib.types.str;
                  default = "erahhal";
                  description = "Username for dynamic DNS client";
                };

                domains = lib.mkOption {
                  type = lib.types.listOf lib.types.str;
                  default = [ "@" "*" "www" "dev" ];
                  description = "Domains for dynamic DNS client";
                };

                passwordFile = lib.mkOption {
                  type = lib.types.path;
                  description = "Path to password file";
                };
              };
            });
          };
        };
      };
    };

    mounts = lib.mkOption {
      description = ''
        Network filesystems to mount on the host. Each entry produces a
        `fileSystems."<mount-point>"` declaration. NFS entries also
        enable `services.rpcbind`. Used for backup destinations and
        media stores that live on a NAS.
      '';
      default = [];
      example = [
        {
          mount-point = "/mnt/ellis";
          device = "10.0.0.42:/volume1/ellis";
          fs-type = "nfs";
          nfs-version = "3";
          automount = true;
          idle-timeout = "600";
        }
      ];
      type = with lib.types; listOf (submodule {
        options = {
          mount-point = lib.mkOption {
            type = str;
            description = "Absolute path where the filesystem is mounted (e.g. /mnt/ellis).";
          };

          device = lib.mkOption {
            type = str;
            description = ''
              Source device. For NFS this is `<host>:<export>`
              (e.g. `10.0.0.42:/volume1/ellis`).
            '';
          };

          fs-type = lib.mkOption {
            type = str;
            default = "nfs";
            description = "Filesystem type passed to mount (e.g. nfs, cifs).";
          };

          nfs-version = lib.mkOption {
            type = enum [ "3" "4" "4.1" "4.2" ];
            default = "3";
            description = "NFS protocol version. Ignored for non-NFS filesystems.";
          };

          automount = lib.mkOption {
            type = bool;
            default = true;
            description = ''
              When true, the mount is realised on first access via
              x-systemd.automount + noauto, and unmounted after
              idle-timeout seconds of inactivity.
            '';
          };

          idle-timeout = lib.mkOption {
            type = str;
            default = "600";
            description = "Seconds of inactivity before an automount entry is unmounted.";
          };

          extra-options = lib.mkOption {
            type = listOf str;
            default = [];
            description = "Additional mount options appended after the computed defaults.";
          };
        };
      });
    };

    proxied-domains = lib.mkOption {
      description = "Domain proxy mappings for transparently forwarding entire domains to other servers";
      default = [];
      type = with lib.types; listOf (submodule {
        options = {
          domains = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            description = ''
              List of domains to proxy (supports wildcards like *.example.com).
              All requests matching these domains will be transparently forwarded to the target server.
            '';
            example = [ "example.com" "*.example.com" "another.org" ];
          };

          target = lib.mkOption {
            type = lib.types.submodule {
              options = {
                host = lib.mkOption {
                  type = lib.types.str;
                  description = "Target host IP address or hostname to proxy to";
                  example = "192.168.1.100";
                };

                http = lib.mkOption {
                  type = lib.types.nullOr (lib.types.submodule {
                    options = {
                      port = lib.mkOption {
                        type = lib.types.int;
                        default = 80;
                        description = "HTTP port number to proxy to";
                      };
                    };
                  });
                  default = null;
                  description = "HTTP configuration. If null, HTTP traffic will not be proxied.";
                  example = { port = 80; };
                };

                https = lib.mkOption {
                  type = lib.types.nullOr (lib.types.submodule {
                    options = {
                      port = lib.mkOption {
                        type = lib.types.int;
                        default = 443;
                        description = "HTTPS port number to proxy to on the backend server";
                      };

                      ignore-self-signed-cert = lib.mkOption {
                        type = lib.types.bool;
                        default = false;
                        description = ''
                          Whether to ignore self-signed or invalid certificates on the backend server.
                          This should only be enabled for development environments.
                          Setting this to true will disable certificate verification when connecting to the backend.
                        '';
                      };
                    };
                  });
                  default = null;
                  description = "HTTPS configuration. If null, HTTPS traffic will not be proxied.";
                  example = { port = 443; ignore-self-signed-cert = false; };
                };
              };
            };
            description = "Target server configuration for proxying";
          };

          public = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = ''
              Whether to make the proxied domains publicly accessible from WAN.
              If false, domains will only be accessible from LAN (bound to 10.0.0.1).
              If true, domains will be accessible from all interfaces.
            '';
          };
        };
      });
    };

    services = {
      adguard = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "enable AdGuard Home Ad Blocking";
        };

        public = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Open to public on WAN port";
        };
      };

      azuracast = {
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
      };

      baikal = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "enable Baikal CalDAV/CardDAV service";
        };

        public = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Open to public on WAN port";
        };
      };

      cryptpad = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "enable Cryptpad Document service";
        };

        public = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Open to public on WAN port";
        };

        adminKeys = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [];
          description = "Public keys that have access to admin panel";
        };
      };

      forgejo = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "enable Forgejo git service";
        };

        disable-registration = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Disable user registration";
        };

        public = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Open to public on WAN port";
        };
      };

      freshrss = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "enable FreshRSS news reader API";
        };

        public = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Open to public on WAN port";
        };
      };

      frigate = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "enable Frigate video recording service";
        };

        enable-coral = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "enable Google Coral AI processor";
        };

        public = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Open to public on WAN port";
        };

        media-path = lib.mkOption {
          type = lib.types.nullOr lib.types.path;
          default = null;
          description = "Location to save recording";
        };

        enable-backup-media = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Whether to backup records";
        };

        retain = lib.mkOption {
          type = lib.types.nullOr lib.types.int;
          default = null;
          description = "If specified, how long in DAYS to keep files before deleting. This applies to ALL files: clips, recordings, exports, etc.";
        };

        hwaccel-args = lib.mkOption {
          type = lib.types.str;
          default = "preset-intel-qsv-h264";
          description = ''
            ffmpeg hwaccel preset. Intel iGPU: "preset-intel-qsv-h264".
            AMD GPU: "preset-vaapi". Raspberry Pi: "-c:v h264_v4l2m2m".
            Nvidia: "preset-nvidia-h264". Empty string disables hwaccel.
          '';
        };

        cameras = lib.mkOption {
          description = "list of cameras";
          default = null;
          type = with lib.types; nullOr (listOf (submodule {
            options = {
              enable = lib.mkOption {
                type = lib.types.bool;
                default = true;
                description = "Camera enabled";
              };

              name = lib.mkOption {
                type = lib.types.str;
                description = "Camera name";
              };

              path = lib.mkOption {
                type = lib.types.str;
                description = "URL / path to camera";
              };

              width = lib.mkOption {
                type = lib.types.int;
                default = 1920;
                description = "Width in pixels";
              };

              height = lib.mkOption {
                type = lib.types.int;
                default = 1080;
                description = "Height in pixels";
              };

              direct-stream = lib.mkOption {
                type = lib.types.bool;
                default = false;
                description = "Don't use go2rtc by default. Addresses certain issues, such as audio delay in recordings";
              };
            };
          }));
        };
      };

      grocy = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "enable Homebox inventory management service";
        };

        public = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Open to public on WAN port";
        };
      };

      headscale = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "enable Headscale vpn service";
        };

        public = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "UI open to public on WAN port";
        };

        stun-port = lib.mkOption {
          type = lib.types.int;
          description = "DERP STUN relay port";
          ## Now using Unifi in a docker container to block STUN port conflict
          default = 3478;
          ## Non-standard port to avoid conflict with Unifi Controller STUN listener
          # default = 3578;
        };

        enable-public-derp-fallback = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = ''
            Include Tailscale's public DERP relay servers as fallback.

            When enabled, clients can relay traffic through Tailscale's
            infrastructure if the embedded DERP server on this machine is
            unreachable (e.g. after a network switch causes a DNS circular
            dependency where MagicDNS needs the tunnel to resolve the
            headscale server, but the tunnel needs DERP to recover).
            The embedded DERP is always preferred when reachable; public
            servers are only used as a last resort.

            NOTE: This creates a dependency on Tailscale's infrastructure
            (controlplane.tailscale.com). Disable this if you require
            complete independence from Tailscale's services.
          '';
        };

      };

      home-assistant = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "enable Home Assistant Home Automation";
        };

        public = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Open to public on WAN port";
        };
      };

      homebox = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "enable Homebox inventory management service";
        };

        disable-registration = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Disable user registration";
        };

        public = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Open to public on WAN port";
        };
      };

      immich = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "enable Immich photo management service";
        };

        public = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Open to public on WAN port";
        };
      };

      jellyfin = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "enable Jellyfin media server";
        };

        public = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Open to public on WAN port";
        };

        media-path = lib.mkOption {
          type = lib.types.nullOr lib.types.path;
          default = null;
          description = "Location of media files";
        };
      };

      joplin = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "enable Joplin notes service";
        };

        public = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Open to public on WAN port";
        };
      };

      lidarr = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "enable Lidarr music management service";
        };

        public = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Open to public on WAN port";
        };

        media-path = lib.mkOption {
          type = lib.types.nullOr lib.types.path;
          default = null;
          description = "Location of music media";
        };

        downloads-path = lib.mkOption {
          type = lib.types.nullOr lib.types.path;
          default = null;
          description = "Location of downloads";
        };

        enable-backup-media = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Whether to backup media";
        };
      };

      linkwarden = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "enable Linkwarden bookmarks service";
        };

        public = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Open to public on WAN port";
        };

        secrets = {
          environment = lib.mkOption {
            type = lib.types.nullOr lib.types.path;
            default = null;
            description = "Location of Linkwarden environment variables file. Should not be a file included in your source repo.";
          };
        };
      };

      matrix = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "enable Matrix chat service";
        };

        enable-federation = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "enable Matrix federation";
        };

        federation-domain-whitelist = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [
            "matrix.org"
            "nixos.org"
            "homefree.host"
            "rycee.net"
            "gnome.org"
          ];
        };

        public = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Open to public on WAN port";
        };

        admin-account = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "Admin user for matrix synapse server (localpart only)";
        };

        server-name = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "Override Matrix server_name. Defaults to homefree.system.domain.";
        };

        secrets = lib.mkOption {
          type = lib.types.attrsOf (lib.types.nullOr lib.types.path);
          default = {};
          description = "Secrets for Matrix service";
        };
      };

      mediawiki = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "enable MediaWiki";
        };

        public = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Open to public on WAN port";
        };

        instances = lib.mkOption {
          description = "Wiki site config";
          default = [];
          type = with lib.types; listOf (submodule {
            options = {
              enable = lib.mkOption {
                type = lib.types.bool;
                default = true;
                description = "Enable this MediaWiki site";
              };

              public = lib.mkOption {
                type = lib.types.bool;
                default = false;
                description = "Open to public on WAN port";
              };

              subdomain = lib.mkOption {
                type = lib.types.str;
                default = "wiki";
                description = "Subdomain for wiki (must be unique)";
              };

              name = lib.mkOption {
                type = lib.types.str;
                default = "Wiki";
                description = "Name for site";
              };

              logo-path = lib.mkOption {
                type = lib.types.nullOr lib.types.path;
                default = null;
                description = "Location of MediaWiki logo file. Optional — when null, MediaWiki's default placeholder logo is used.";
              };

              readonly = lib.mkOption {
                type = lib.types.bool;
                default = false;
                description = "No one can edit wiki";
              };

              disable-anonymous-editing = lib.mkOption {
                type = lib.types.bool;
                default = false;
                description = "Only users can edit wiki";
              };

              disable-anonymous-viewing = lib.mkOption {
                type = lib.types.bool;
                default = false;
                description = "Only users can view wiki";
              };

              disable-user-editing = lib.mkOption {
                type = lib.types.bool;
                default = false;
                description = "Only admins can edit wiki";
              };

              disable-user-registration = lib.mkOption {
                type = lib.types.bool;
                default = false;
                description = "Only admins can register users";
              };
            };
          });
        };

        # NB: MediaWiki has no user-facing secrets. Both the MySQL user
        # password and wgSecretKey are auto-generated on first start (see
        # mediawiki-podman.nix preStart). Everything is internal to this
        # host, so there's nothing for the user to provide.
      };

      minecraft = {
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
                default = "wiki";
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
                type = lib.types.nullOr (lib.types.enum [
                  ## Mod Platforms
                  "adventure"
                  "creative"
                  "hardcore"
                  "spectator"
                  "survival"
                ]);
                default = "survival";
              };

              type = lib.mkOption {
                type = lib.types.nullOr (lib.types.enum [
                  ## Mod Platforms
                  "AUTO_CURSEFORGE"
                  "CURSEFORGE"
                  "FTBA"
                  "GTNH"
                  "MODRINTH"

                  ## Server Types
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

              # MODS="<url-to-mod1.jar>,<url-to-mod2.jar>,<url-to-mod3.jar>"
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

      nextcloud = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "enable Nextcloud media server";
        };

        public = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Open to public on WAN port";
        };

        secrets = {
          admin-password = lib.mkOption {
            type = lib.types.nullOr lib.types.path;
            default = null;
            description = "Location of Nextcloud admin password file. Should not be a file included in your source repo.";
          };

          env = lib.mkOption {
            type = lib.types.nullOr lib.types.path;
            default = null;
            description = ''
              Location of docker env file. Contains:

              NEXTCLOUD_ADMIN_PASSWORD=<password>

              Should not be a file included in your source repo.
            '';
          };

          secret-file = lib.mkOption {
            type = lib.types.nullOr lib.types.path;
            default = null;
            description = "Location of Nextcloud secrets file. Should not be a file included in your source repo.";
          };
        };
      };

      nzbget = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "enable NZBGet downloader";
        };

        public = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Open to public on WAN port";
        };

        downloads-path = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "Location of downloads";
        };

        enable-backup-media = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Whether to backup media";
        };
      };

      odoo = {
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

      oauth2-proxy = {
        secrets = {
          env = lib.mkOption {
            type = lib.types.nullOr lib.types.path;
            default = null;
            description = ''
              Location of oauth2-proxy env file. Contains:

              OAUTH_PROXY_CLIENT_ID=<id>
              OAUTH_PROXY_CLIENT_SECRET=<client secret>
              OAUTH_PROXY_COOKIE_SECRET=<cookie secret>

              Should not be a file included in your source repo.
            '';
          };
        };
      };

      ollama = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "enable Ollama GenAI service";
        };

        public = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Open to public on WAN port";
        };
      };

      postgres-vectorchord = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "enable VectorChord PostgreSQL service";
        };

        public = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Open to public on WAN port";
        };
      };

      radicale = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "enable Radicale CalDAV/CardDAV service";
        };

        public = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Open to public on WAN port";
        };
      };

      screeenly = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "enable Screeenly preview generation service";
        };

        public = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Open to public on WAN port";
        };
      };

      snipe-it = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "enable Snipe-IT inventory management service";
        };

        public = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Open to public on WAN port";
        };

        secrets = {
          mysql-password = lib.mkOption {
            type = lib.types.nullOr lib.types.path;
            default = null;
            description = "Location of Snipe-IT mysql password file. Should not be a file included in your source repo.";
          };
          env = lib.mkOption {
            type = lib.types.nullOr lib.types.path;
            default = null;
            description = "Location of Snipe-IT env file. Contains DB_PASSWORD, which is the same as mysql-password above, and APP_KEY. Should not be a file included in your source repo.";
          };
        };
      };

      trilium = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "enable Trilium Notes service";
        };

        public = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Open to public on WAN port";
        };
      };

      unifi = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "enable Unifi controller";
        };

        public = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Open to public on WAN port";
        };
      };

      vaultwarden = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "enable Vaultwarden Bitwarden password manager backend";
        };

        public = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Open to public on WAN port";
        };
      };

      webdav = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "enable WebDAV service";
        };

        public = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Open to public on WAN port";
        };
      };

      zitadel = {
        enable = lib.mkOption {
          type = lib.types.bool;
          ## Zitadel is the SSO identity provider. Every other
          ## HomeFree app authenticates against it (oauth2-proxy
          ## for caddy-gated services, native OIDC for the rest),
          ## so disabling Zitadel breaks login for the box. Default
          ## on; fresh installs get a working SSO stack out of the
          ## box.
          default = true;
          description = "enable Zitadel auth service";
        };

        public = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Open to public on WAN port";
        };

      };

      ## NetBird is a second VPN service alongside Headscale. The full
      ## option schema lives in services/netbird.nix under
      ## homefree.service-options.netbird; the legacy declarations below
      ## are the path the admin UI's JSON config writes to. A compat shim
      ## further down mirrors them onto the new namespace.
      netbird = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "enable NetBird VPN server";
        };

        public = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Dashboard accessible from WAN";
        };

        client = {
          enable = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Run the NetBird client on this host (router as peer). Independent of server.";
          };
        };
      };

      admin = {
        # Note: admin service is always enabled - the enable option exists for config consistency
        # but the service will run regardless of this setting
        enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Enable admin interface (always enabled, this option exists for config consistency)";
        };

        public = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Open to public on WAN port (not recommended)";
        };
      };

      landing-page = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Enable landing page";
        };

        public = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Open to public on WAN port";
        };

        path = lib.mkOption {
          type = lib.types.path;
          default = "${pkgs.homefree-site}/lib/node_modules/homefree-site/public";
          description = "Path to landing page";
        };
      };
    };

    service-config = lib.mkOption {
      description = "Detailed config for services";
      type = with lib.types; listOf (submodule {
        options = {

          # @TODO: Add top-level enable

          label = lib.mkOption {
            type = lib.types.str;
            default = "";
            description = "Unique label for service";
          };

          name = lib.mkOption {
            type = lib.types.str;
            default = "";
            description = "Full name of service";
          };

          icon = lib.mkOption {
            type = lib.types.nullOr lib.types.path;
            default = null;
            description = "Path to service icon";
          };

          project-name = lib.mkOption {
            type = lib.types.str;
            default = "";
            description = "Official project name of application";
          };

          parent = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Label of parent service (for child instances)";
          };

          release-tracking = {
            type = lib.mkOption {
              type = lib.types.str;
              default = "github";
              description = "Project release service type";
            };

            project = lib.mkOption {
              type = lib.types.str;
              default = "";
              description = "Project path, e.g. <owner>/<repo> for github";
            };
          };

          systemd-service-names = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [];
            description = "Associated systemd services";
          };

          admin = {
            show = lib.mkOption {
              type = lib.types.bool;
              default = true;
              description = "Show in Admin UI";
            };

            urlPathOverride = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Override path of URL to service";
            };
          };

          firewall = {
            open-ports = {
              tcp = lib.mkOption {
                type = lib.types.listOf lib.types.int;
                default = [];
                description = "list of open tcp ports";
              };
              udp = lib.mkOption {
                type = lib.types.listOf lib.types.int;
                default = [];
                description = "list of open udp ports";
              };
            };
          };

          ## SSO catalog metadata. Drives the SSO admin page and any
          ## other tooling that needs to know how a service authenticates.
          ## Lives here (alongside reverse-proxy, backup, etc.) so each
          ## service declares its own SSO posture in its own .nix file
          ## — single source of truth. The activation-time renderer
          ## (services/service-config-json.nix) emits this whole tree
          ## to /etc/homefree/service-config.json for the admin
          ## backend to consume.
          sso = {
            kind = lib.mkOption {
              type = lib.types.enum [ "native_oidc" "caddy_gated" "basic_auth" "infra" "none" ];
              default = "none";
              description = ''
                How the service authenticates:
                  native_oidc  — service has its own OIDC client (Forgejo,
                                 Nextcloud, Vaultwarden, etc.)
                  caddy_gated  — outer SSO gate via oauth2-proxy in Caddy;
                                 user still sees the app's local login or
                                 lands directly on the app (no inner SSO)
                  basic_auth   — Caddy SSO gate + per-request HTTP Basic
                                 Auth injection (AdGuard, WebDAV)
                  infra        — this IS the SSO infrastructure (Zitadel
                                 itself, oauth2-proxy). Hidden from the
                                 SSO admin page since it's not a consumer.
                  none         — no SSO yet; local login only
              '';
            };

            notes = lib.mkOption {
              type = lib.types.str;
              default = "";
              description = ''
                Optional caveat / status note for the admin UI. Use this
                for things like "Master password still required after SSO"
                or "Outer gate admin-only; inner login still appears".
              '';
            };

            secrets-dir = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = ''
                Override the on-disk secrets dir name when it diverges
                from the service label. Defaults to the label
                (/var/lib/homefree-secrets/<label>/). Example: Home
                Assistant uses label `homeassistant` but its secrets
                live in `home-assistant/`.
              '';
            };
          };

          reverse-proxy = {
            enable = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = "Enable reverse proxy for service";
            };

            description = lib.mkOption {
              type = lib.types.str;
              default = "";
              description = "description of proxy config";
            };

            rootDomain = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = "Maps to root domain, i.e. no subdomain. Only one service can set this to true.";
            };

            subdomains = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [];
              description = "list of subdomains";
            };

            http-domains = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [];
              description = "list of http domains";
            };

            https-domains = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [];
              description = "list of https domains";
            };

            host = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "host name or address of service to proxy";
            };

            port = lib.mkOption {
              type = lib.types.nullOr lib.types.int;
              default = null;
              description = "port of service on lan network";
            };

            static-path = lib.mkOption {
              type = lib.types.nullOr lib.types.path;
              default = null;
              description = "path to static files to serve. Do not set host or port if using this.";
            };

            subdir = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              description = "subdir at which service is served";
              default = null;
            };

            # @TODO: This should be moved up one level, as it's not just for reverse proxy
            public = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = "Whether to expose on WAN interface";
            };

            ssl = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = "Whether upstream service is using TLS";
            };

            ssl-no-verify = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = "Whether to verify certificate of upstream service";
            };

            disable-keepalive = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = ''
                When true, Caddy will not reuse HTTP connections to
                this upstream — every request opens a fresh TCP
                connection. Default is off (Caddy's normal pooling).
                Set to true for upstream servers with broken or
                non-existent keep-alive handling (typical pattern:
                tiny embedded HTTP servers on appliances —
                OpenSprinkler, some smart-home gear, older NAS
                admin pages) where Caddy's pooled connection gets
                a TCP RST after the upstream's per-request close,
                producing intermittent 502s.
              '';
            };

            basic-auth = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = "Whether to enable basic auth headers";
            };

            oauth2 = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = "Whether to enable Oauth2";
            };

            extraCaddyConfig = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "custom caddy config";
            };

            dav-bypass = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = ''
                When set together with `oauth2 = true`, the SSO gate
                does NOT run for requests that look like CalDAV /
                CardDAV traffic:
                  - any request carrying `Authorization: Basic ...`
                    (every DAV client sends credentials on every
                    request, so this fingerprints them)
                  - any request using a DAV-only HTTP method
                    (PROPFIND, PROPPATCH, REPORT, MKCALENDAR, MKCOL,
                    COPY, MOVE, LOCK, UNLOCK)

                Browser traffic without Basic auth (the admin UI) is
                still gated by SSO; DAV clients reach the upstream
                directly and authenticate to it with their own
                per-user app password. Lets one host serve both an
                SSO-gated admin UI and a working DAV endpoint for
                Thunderbird / iOS Calendar / etc.

                Only meaningful for services that speak DAV: Baikal,
                Radicale, the Nextcloud /remote.php/dav split.
              '';
            };

            require-admin-role = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = ''
                Whether this service requires the homefree-admin
                project role on top of basic authentication. Only
                meaningful when `oauth2` is also true (admin-only
                services that gate via the Caddy oauth2-proxy
                forward_auth flow).

                When set, Caddy adds a second forward_auth call to
                the admin-api's /api/auth/admin-check endpoint after
                the oauth2-proxy session is validated. admin-api's
                middleware decides 200-vs-403 based on whether the
                user's Zitadel token carries homefree-admin in the
                project-roles claim. Non-admin authenticated users
                see a 403 from Caddy without ever reaching the
                upstream.

                We can't put this check on oauth2-proxy itself —
                Zitadel's namespaced role claim comes through as a
                JSON-object whose keys ARE the role names, and
                oauth2-proxy's group parser doesn't extract keys
                from that shape. admin-api's middleware does.
              '';
            };

            inject-basic-auth-env = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = ''
                Name of an environment variable (loaded into Caddy via
                EnvironmentFile) whose value is the base64-encoded
                `username:password` string. When set, Caddy injects an
                `Authorization: Basic {env.NAME}` header on every
                request it forwards to the upstream. Used to bridge
                services that have no OIDC support (e.g. AdGuard) but
                accept HTTP Basic Auth — the SSO gate authenticates the
                user, Caddy then logs them into the upstream with the
                service's own admin credentials, and the user never
                sees the second login form.
              '';
            };

            upstream-logout-paths = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [];
              example = [ "/control/logout" ];
              description = ''
                URL paths on the upstream that represent a sign-out
                action. When the user hits one of these, Caddy
                short-circuits the request and redirects to the full
                SSO sign-out chain instead of forwarding to the
                upstream.

                Only meaningful when `inject-basic-auth-env` is set:
                without the redirect, the upstream's own logout
                endpoint clears its session, but Caddy immediately
                re-authenticates the next request with the injected
                Basic Auth header — so the user can never actually
                sign out. Intercepting the path turns the upstream's
                "Sign out" button into a real sign-out.
              '';
            };
          };

          backup = {
            paths = lib.mkOption {
              type = lib.types.listOf lib.types.path;
              default = [];
              description = "list of paths to backup";
            };

            mysql-databases = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [];
              description = "list of mysql databases to backup";
            };

            postgres-databases = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [];
              description = "list of postgres databases to backup";
            };
          };

          options-metadata = lib.mkOption {
            type = with lib.types; listOf (submodule {
              options = {
                path = lib.mkOption {
                  type = lib.types.str;
                  description = "Option path/key";
                };

                type = lib.mkOption {
                  type = lib.types.str;
                  description = "Option type (bool, str, int, path, listOf str, listOf submodule, etc.)";
                };

                nullable = lib.mkOption {
                  type = lib.types.bool;
                  default = false;
                  description = "Whether option is nullable (nullOr type)";
                };

                default = lib.mkOption {
                  type = lib.types.anything;
                  default = null;
                  description = "Default value for option";
                };

                description = lib.mkOption {
                  type = lib.types.str;
                  default = "";
                  description = "Human-readable description";
                };

                required = lib.mkOption {
                  type = lib.types.bool;
                  default = false;
                  description = "Whether option is required";
                };

                category = lib.mkOption {
                  type = lib.types.str;
                  default = "basic";
                  description = "UI category (basic, advanced, secrets)";
                };

                ui-hint = lib.mkOption {
                  type = lib.types.nullOr lib.types.anything;
                  default = null;
                  description = "UI rendering hints (string or attrs)";
                };

                enum-values = lib.mkOption {
                  type = lib.types.nullOr (lib.types.listOf lib.types.str);
                  default = null;
                  description = "For enum types, the list of valid string values";
                };

                sops-managed = lib.mkOption {
                  type = lib.types.bool;
                  default = false;
                  description = "Whether this option (or its sub-fields) holds SOPS-encrypted secrets";
                };

                submodule-fields = lib.mkOption {
                  type = with lib.types; nullOr (listOf (submodule {
                    options = {
                      path = lib.mkOption {
                        type = lib.types.str;
                        description = "Field path/key within submodule";
                      };
                      type = lib.mkOption {
                        type = lib.types.str;
                        description = "Field type";
                      };
                      nullable = lib.mkOption {
                        type = lib.types.bool;
                        default = false;
                        description = "Whether field is nullable";
                      };
                      default = lib.mkOption {
                        type = lib.types.anything;
                        default = null;
                        description = "Default value";
                      };
                      description = lib.mkOption {
                        type = lib.types.str;
                        default = "";
                        description = "Field description";
                      };
                      required = lib.mkOption {
                        type = lib.types.bool;
                        default = false;
                        description = "Whether field is required";
                      };
                      ui-hint = lib.mkOption {
                        type = lib.types.nullOr lib.types.anything;
                        default = null;
                        description = "UI rendering hints";
                      };
                      enum-values = lib.mkOption {
                        type = lib.types.nullOr (lib.types.listOf lib.types.str);
                        default = null;
                        description = "For enum types, the list of valid string values";
                      };
                      sops-managed = lib.mkOption {
                        type = lib.types.bool;
                        default = false;
                        description = "Whether this field holds a SOPS-encrypted secret";
                      };
                    };
                  }));
                  default = null;
                  description = "For listOf submodule types, defines the submodule fields";
                };
              };
            });
            default = [];
            description = "Metadata for service options to enable admin UI configuration";
          };
        };
      });
    };

    docker-io-auth = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Enable docker.io auth";
      };

      username = lib.mkOption {
        type = lib.types.str;
        description = "docker.io username";
      };

      secrets = {
        password = lib.mkOption {
          type = lib.types.path;
          description = "Location of docker.io password file Should not be a file included in your source repo.";
        };
      };
    };

    backups = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Enable backups";
      };

      to-path = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = "/var/lib/backups";
        description = "Path to store backups";
      };

      extra-from-paths = lib.mkOption {
        type = lib.types.listOf lib.types.path;
        default = [];
        description = "Extra list of custom paths to backup";
      };

      backblaze = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Whether to enable Backblaze backups";
        };

        bucket = lib.mkOption {
          type = lib.types.str;
          description = "Bucket name";
        };
      };

      secrets = {
        restic-password = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "Restic repository password for encryption/decryption of backups (managed via SOPS)";
        };

        restic-environment = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = ''
            Restic environment variables (managed via SOPS).

            If using Backblaze, put in your ID and key in here, e.g.:

            B2_ACCOUNT_ID=<id>
            B2_ACCOUNT_KEY=<key>
          '';
        };

        backblaze-id = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "Backblaze account ID for B2 storage (managed via SOPS)";
        };

        backblaze-key = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "Backblaze account key for B2 storage (managed via SOPS)";
        };
      };

      # Internal option to hold metadata for admin UI schema generation
      options-metadata = lib.mkOption {
        type = lib.types.listOf lib.types.attrs;
        internal = true;
        default = [
          {
            path = "enable";
            type = "bool";
            default = false;
            description = "Enable automatic backups";
          }
          {
            path = "to-path";
            type = "str";
            default = "/var/lib/backups";
            description = "Local directory path where backups are stored";
          }
          {
            path = "extra-from-paths";
            type = "listOf str";
            default = [];
            description = "Additional custom paths to include in backups";
          }
          {
            path = "backblaze";
            type = "submodule";
            description = "Backblaze B2 cloud backup configuration";
            submodule-fields = [
              {
                path = "enable";
                type = "bool";
                default = false;
                description = "Enable Backblaze B2 cloud backups";
              }
              {
                path = "bucket";
                type = "str";
                default = "";
                description = "Backblaze B2 bucket name";
              }
            ];
          }
          {
            path = "secrets";
            type = "submodule";
            description = "Secret values for backup service (managed via SOPS)";
            sops-managed = true;
            submodule-fields = [
              {
                path = "restic-password";
                type = "str";
                nullable = true;
                default = null;
                description = "Restic repository password for encryption/decryption of backups";
                sops-managed = true;
              }
              {
                path = "restic-environment";
                type = "str";
                nullable = true;
                default = null;
                description = "Restic environment variables (B2_ACCOUNT_ID and B2_ACCOUNT_KEY for Backblaze)";
                sops-managed = true;
              }
              {
                path = "backblaze-id";
                type = "str";
                nullable = true;
                default = null;
                description = "Backblaze account ID for B2 storage";
                sops-managed = true;
              }
              {
                path = "backblaze-key";
                type = "str";
                nullable = true;
                default = null;
                description = "Backblaze account key for B2 storage";
                sops-managed = true;
              }
            ];
          }
        ];
      };
    };
  };

  config = {
    assertions =
      let
        elemInList = x: xs: lib.foldl' (acc: el: acc || el == x) false xs;
        unique = list:
          if list == [] then []
          else let
            x = builtins.head list;
            xs = builtins.tail list;
          in
            if elemInList x xs
            then unique xs
            else [x] ++ (unique xs);

        # Returns a list of labels that have duplicates (preserving original case)
        findDuplicateLabels = service-config:
          let
            # Create a list of label+lowercase pairs to preserve original case
            labelPairs = map (entry: {
              original = entry.label;
              lower = lib.toLower entry.label;
            }) service-config;

            # Helper to count occurrences of a label
            countOccurrences = label: builtins.foldl'
              (acc: pair: if pair.lower == label then acc + 1 else acc)
              0
              labelPairs;

            # Get unique lowercase labels
            lowerLabels = unique (map (pair: pair.lower) labelPairs);

            # Filter for labels that appear multiple times
            duplicateLowerLabels = builtins.filter
              (label: countOccurrences label > 1)
              lowerLabels;

            # Get first occurrence of original case for each duplicate
            getDuplicateOriginal = lowerLabel:
              (builtins.head (builtins.filter
                (pair: pair.lower == lowerLabel)
                labelPairs)).original;
          in
            map getDuplicateOriginal duplicateLowerLabels;

        duplicateLabels = findDuplicateLabels config.homefree.service-config;
        badServiceConfigs = builtins.filter (entry: (entry.reverse-proxy.host != null || entry.reverse-proxy.port != null) && entry.reverse-proxy.static-path != null) config.homefree.service-config;
        badServiceConfigLabels = builtins.map (entry: entry.label) badServiceConfigs;
        rootDomainConfigs = builtins.filter (entry: (entry.reverse-proxy.rootDomain == true)) config.homefree.service-config;
        rootDomainConfigLabels = builtins.map (entry: entry.label) rootDomainConfigs;
      in
    [
      {
        ## Make sure that two service configs don't use the same label
        assertion = lib.length duplicateLabels == 0;
        message = "Multiple homefree.service-config entries with the same label: ${lib.concatStringsSep ", " duplicateLabels}";
      }
      {
        assertion = lib.length badServiceConfigs == 0;
        message = "homefree.service-config contains entries with both a host/port and static-path config; can only specify one: ${lib.concatStringsSep ", " badServiceConfigLabels}";
      }
      {
        assertion = lib.length rootDomainConfigs <= 1;
        message = "homefree.service-config contains more than one service with rootDomain = true: ${lib.concatStringsSep ", " rootDomainConfigLabels}";
      }
    ];

    ## Mirror every user-facing `homefree.services.<name>` entry into
    ## the colocated `homefree.service-options.<name>` namespace that
    ## admin-web reads to build the admin UI's option schema. Replaces
    ## a 120-line block of per-service identity assignments.
    ##
    ## Filtering rule: only mirror services whose corresponding
    ## `options.homefree.service-options.<name>` block actually exists
    ## (declared in `apps/<name>/default.nix` for apps with admin-UI
    ## metadata). Services like `admin`, `landing-page`, `azuracast`,
    ## `odoo`, `trilium`, `unifi-os` deliberately have no service-options
    ## decl and would fail with "option does not exist" if mirrored.
    homefree.service-options =
      lib.intersectAttrs
        options.homefree.service-options
        config.homefree.services;

    warnings =
      (if config.homefree.backups.enable == false then [
        ''
          Backups not enabled. Set:module

            homefree.backups.enable = true;
        ''
      ] else [])
    ++
      (if config.homefree.backups.enable == true && config.homefree.backups.to-path == options.homefree.backups.to-path.default then [
        ''
          Backups being written locally to the default path of "${config.homefree.backups.to-path}".
          You should backup to an off-machine location, e.g. to an NFS mounted path. To change
          the backup path:

            homefree.backups.to-path = "<backup path>";
        ''
      ] else [])
    ++
      (if config.homefree.services.landing-page.path == options.homefree.services.landing-page.path.default then [
        ''
          Landing page is set to the default Homefree project landing page.

            homefree.services.landing-page.path = "<path to html root>";
        ''
      ] else [])
    ++
      (if config.homefree.services.headscale.enable
          && config.homefree.services.headscale.enable-public-derp-fallback then [
        ''
          Tailscale public DERP fallback is enabled (homefree.services.headscale.enable-public-derp-fallback).
          Clients may relay traffic through Tailscale's infrastructure when the embedded DERP is unreachable.
          Set to false for complete independence from Tailscale's services.
        ''
      ] else [])
    ;
  };

  # options.virtualisation.vmVariantWithHomefree = lib.mkOption {
  #   description = ''
  #     Machine configuration to be added for the vm script available at `.system.build.vmWithHomefree`.
  #   '';
  #   inherit (vmVariantWithHomefree) type;
  #   default = { };
  #   visible = "shallow";
  # };
  #
  # config = {
  #   system.build = {
  #     testVms = lib.mkDefault config.virtualisation.vmVariantWithHomefree.system.build.vmWithHomefree;
  #   };
  # };
}
