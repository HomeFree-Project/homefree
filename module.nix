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

      enable-adblock = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "enable ad blocking";
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

      authentik = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "enable Authentik";
        };

        public = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Open to public on WAN port";
        };

        secrets = {
          environment = lib.mkOption {
            type = lib.types.path;
            description = "Location of Authentik environment variables file. Should not be a file included in your source repo.";
          };

          ldap-environment = lib.mkOption {
            type = lib.types.path;
            description = "Location of Authentik LDAP environment variables file. Should not be a file included in your source repo.";
          };
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

        secrets = {
          tailscale-key = lib.mkOption {
            type = lib.types.nullOr lib.types.path;
            default = null;
            description = "Location of Tailscale client key for server. Should not be a file included in your source repo.";
          };
          headplane-env = lib.mkOption {
            type = lib.types.path;
            description = "Location of Headplane environment var file. Contains COOKIE_SECRET, ROOT_API_KEY, OIDC_CLIENT_SECRET. Should not be a file included in your source repo.";
          };
        };
      };

      homeassistant = {
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

      kanidm = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "enable Kanidm";
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

      logseq = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "enable Logseq knowledge management service";
        };

        public = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Open to public on WAN port";
        };
      };

      # matrix = {
      #   enable = lib.mkOption {
      #     type = lib.types.bool;
      #     default = false;
      #     description = "enable Matrix chat service";
      #   };
      #
      #   enable-federation = lib.mkOption {
      #     type = lib.types.bool;
      #     default = false;
      #     description = "enable Matrix federation";
      #   };
      #
      #   federation-domain-whitelist = lib.mkOption {
      #     type = lib.types.listOf lib.types.str;
      #     default = [
      #       "matrix.org"
      #       "nixos.org"
      #       "homefree.host"
      #       "rycee.net" # home-manager room
      #       "gnome.org"
      #     ];
      #   };
      #
      #   public = lib.mkOption {
      #     type = lib.types.bool;
      #     default = false;
      #     description = "Open to public on WAN port";
      #   };
      #
      #   admin-account = lib.mkOption {
      #     type = lib.types.nullOr lib.types.str;
      #     default = null;
      #     description = "Admin user for matrix synapse server";
      #   };
      #
      #   secrets = {
      #     registration-shared-secret = lib.mkOption {
      #       type = lib.types.nullOr lib.types.path;
      #       default = null;
      #       description = "Location of Matrix Synapse shared secret file. Should not be a file included in your source repo.";
      #     };
      #     admin-account-password = lib.mkOption {
      #       type = lib.types.nullOr lib.types.path;
      #       default = null;
      #       description = "Location of admin account password. Should not be a file included in your source repo.";
      #     };
      #   };
      # };

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

      unifi-os = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "enable UniFi OS Server (replaces legacy UniFi Controller)";
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
          default = false;
          description = "enable Zitadel auth service";
        };

        public = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Open to public on WAN port";
        };

        secrets = {
          env = lib.mkOption {
            type = lib.types.nullOr lib.types.path;
            default = null;
            description = "Location of Zitadel environment var file. Contains ZITADEL_MASTERKEY. Should not be a file included in your source repo.";
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

    # Map user-facing service options to internal service-options
    homefree.service-options.adguard.enable = config.homefree.services.adguard.enable;
    homefree.service-options.adguard.public = config.homefree.services.adguard.public;

    homefree.service-options.baikal.enable = config.homefree.services.baikal.enable;
    homefree.service-options.baikal.public = config.homefree.services.baikal.public;

    homefree.service-options.cryptpad.enable = config.homefree.services.cryptpad.enable;
    homefree.service-options.cryptpad.public = config.homefree.services.cryptpad.public;
    homefree.service-options.cryptpad.adminKeys = config.homefree.services.cryptpad.adminKeys;

    homefree.service-options.forgejo.enable = config.homefree.services.forgejo.enable;
    homefree.service-options.forgejo.public = config.homefree.services.forgejo.public;
    homefree.service-options.forgejo.disable-registration = config.homefree.services.forgejo.disable-registration;

    homefree.service-options.freshrss.enable = config.homefree.services.freshrss.enable;
    homefree.service-options.freshrss.public = config.homefree.services.freshrss.public;

    homefree.service-options.frigate.enable = config.homefree.services.frigate.enable;
    homefree.service-options.frigate.enable-coral = config.homefree.services.frigate.enable-coral;
    homefree.service-options.frigate.public = config.homefree.services.frigate.public;
    homefree.service-options.frigate.media-path = config.homefree.services.frigate.media-path;
    homefree.service-options.frigate.enable-backup-media = config.homefree.services.frigate.enable-backup-media;
    homefree.service-options.frigate.retain = config.homefree.services.frigate.retain;
    homefree.service-options.frigate.cameras = config.homefree.services.frigate.cameras;

    homefree.service-options.grocy.enable = config.homefree.services.grocy.enable;
    homefree.service-options.grocy.public = config.homefree.services.grocy.public;

    homefree.service-options.home-assistant.enable = config.homefree.services.homeassistant.enable;
    homefree.service-options.home-assistant.public = config.homefree.services.homeassistant.public;

    homefree.service-options.homebox.enable = config.homefree.services.homebox.enable;
    homefree.service-options.homebox.public = config.homefree.services.homebox.public;

    homefree.service-options.immich.enable = config.homefree.services.immich.enable;
    homefree.service-options.immich.public = config.homefree.services.immich.public;

    homefree.service-options.jellyfin.enable = config.homefree.services.jellyfin.enable;
    homefree.service-options.jellyfin.public = config.homefree.services.jellyfin.public;
    homefree.service-options.jellyfin.media-path = config.homefree.services.jellyfin.media-path;

    homefree.service-options.joplin.enable = config.homefree.services.joplin.enable;
    homefree.service-options.joplin.public = config.homefree.services.joplin.public;

    homefree.service-options.kanidm.enable = config.homefree.services.kanidm.enable;
    homefree.service-options.kanidm.public = config.homefree.services.kanidm.public;

    homefree.service-options.lidarr.enable = config.homefree.services.lidarr.enable;
    homefree.service-options.lidarr.public = config.homefree.services.lidarr.public;
    homefree.service-options.lidarr.media-path = config.homefree.services.lidarr.media-path;
    homefree.service-options.lidarr.downloads-path = config.homefree.services.lidarr.downloads-path;
    homefree.service-options.lidarr.enable-backup-media = config.homefree.services.lidarr.enable-backup-media;

    homefree.service-options.linkwarden.enable = config.homefree.services.linkwarden.enable;
    homefree.service-options.linkwarden.public = config.homefree.services.linkwarden.public;
    homefree.service-options.linkwarden.secrets = config.homefree.services.linkwarden.secrets;

    homefree.service-options.logseq.enable = config.homefree.services.logseq.enable;
    homefree.service-options.logseq.public = config.homefree.services.logseq.public;

    # homefree.service-options.matrix.enable = config.homefree.services.matrix.enable;
    # homefree.service-options.matrix.public = config.homefree.services.matrix.public;
    # homefree.service-options.matrix.enable-federation = config.homefree.services.matrix.enable-federation;
    # homefree.service-options.matrix.federation-domain-whitelist = config.homefree.services.matrix.federation-domain-whitelist;
    # homefree.service-options.matrix.admin-account = config.homefree.services.matrix.admin-account;
    # homefree.service-options.matrix.secrets = config.homefree.services.matrix.secrets;

    homefree.service-options.mediawiki.enable = config.homefree.services.mediawiki.enable;
    homefree.service-options.mediawiki.public = config.homefree.services.mediawiki.public;
    homefree.service-options.mediawiki.instances = config.homefree.services.mediawiki.instances;

    homefree.service-options.minecraft.enable = config.homefree.services.minecraft.enable;
    homefree.service-options.minecraft.public = config.homefree.services.minecraft.public;
    homefree.service-options.minecraft.secrets = config.homefree.services.minecraft.secrets;
    homefree.service-options.minecraft.instances = config.homefree.services.minecraft.instances;

    homefree.service-options.nextcloud.enable = config.homefree.services.nextcloud.enable;
    homefree.service-options.nextcloud.public = config.homefree.services.nextcloud.public;
    homefree.service-options.nextcloud.secrets = config.homefree.services.nextcloud.secrets;

    homefree.service-options.nzbget.enable = config.homefree.services.nzbget.enable;
    homefree.service-options.nzbget.public = config.homefree.services.nzbget.public;

    homefree.service-options.ollama.enable = config.homefree.services.ollama.enable;
    homefree.service-options.ollama.public = config.homefree.services.ollama.public;

    homefree.service-options.postgres-vectorchord.enable = config.homefree.services.postgres-vectorchord.enable;
    homefree.service-options.postgres-vectorchord.public = config.homefree.services.postgres-vectorchord.public;

    homefree.service-options.radicale.enable = config.homefree.services.radicale.enable;
    homefree.service-options.radicale.public = config.homefree.services.radicale.public;

    homefree.service-options.screeenly.enable = config.homefree.services.screeenly.enable;
    homefree.service-options.screeenly.public = config.homefree.services.screeenly.public;

    homefree.service-options.snipe-it.enable = config.homefree.services.snipe-it.enable;
    homefree.service-options.snipe-it.public = config.homefree.services.snipe-it.public;
    homefree.service-options.snipe-it.secrets = config.homefree.services.snipe-it.secrets;

    homefree.service-options.unifi.enable = config.homefree.services.unifi.enable;
    homefree.service-options.unifi.public = config.homefree.services.unifi.public;

    homefree.service-options.vaultwarden.enable = config.homefree.services.vaultwarden.enable;
    homefree.service-options.vaultwarden.public = config.homefree.services.vaultwarden.public;

    homefree.service-options.webdav.enable = config.homefree.services.webdav.enable;
    homefree.service-options.webdav.public = config.homefree.services.webdav.public;

    homefree.service-options.zitadel.enable = config.homefree.services.zitadel.enable;
    homefree.service-options.zitadel.public = config.homefree.services.zitadel.public;
    homefree.service-options.zitadel.secrets = config.homefree.services.zitadel.secrets;

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
