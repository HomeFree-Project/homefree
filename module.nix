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

    internal = {
      caddy-file-scope-imports = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        internal = true;
        default = [];
        description = ''
          Caddy `import` directives to emit at FILE SCOPE (outside any
          site block, before the vhosts) in the generated Caddyfile.
          Blue/green services (lib/blue-green.nix) append their runtime
          snippet import here so caddy/default.nix need not know which
          services use the mechanism. Each entry is a full directive
          line, e.g. `import /run/homefree/admin-api-upstream.caddy`.
        '';
      };
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

      abuseBlockCidrs = lib.mkOption {
        default = [];
        description = ''
          IPv4 or IPv6 CIDR ranges to drop at the firewall. Entries
          are routed by address family to the abusive_nets4 /
          abusive_nets6 nftables sets. Each entry can be individually
          enabled or disabled and carries a free-text comment
          explaining why it is blocked.

          This list is fully user-owned. On a fresh install it is
          seeded once with known abusive scraper networks (Alibaba
          Cloud — see modules/abuse-blocking.nix), but after that the
          admin UI's Abuse Blocking page is authoritative: disable an
          entry to keep it for reference without enforcing it, or
          remove it entirely. Removed entries are not re-seeded.

          Hand-editing /etc/nixos/homefree-config.json works too.
        '';
        type = with lib.types; listOf (submodule {
          options = {
            cidr = lib.mkOption {
              type = lib.types.str;
              description = ''
                IPv4 or IPv6 CIDR range to block, e.g. 47.74.0.0/15
                or 2001:db8::/32. A single host is /32 (IPv4) or /128
                (IPv6).
              '';
            };
            enabled = lib.mkOption {
              type = lib.types.bool;
              default = true;
              description = ''
                Whether this range is actively enforced. A disabled
                entry stays in the list (and in the UI) but is not
                added to the nftables drop set.
              '';
            };
            comment = lib.mkOption {
              type = lib.types.str;
              default = "";
              description = "Free-text note on why this range is blocked.";
            };
          };
        });
      };

      geoip = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = ''
            Maintain a local GeoIP database (DB-IP "IP to City Lite",
            CC-BY-4.0) so the admin UI's Abuse Blocking page can show
            the country/city of traffic sources.

            Per-IP lookups are 100% local — no network requests. The
            ONLY network activity is a weekly download of the refreshed
            monthly database file from db-ip.com. Disable this if you
            don't want the server reaching out to db-ip.com at all
            (air-gapped installs, strict egress policy); the Abuse
            Blocking page then simply omits the Location column.
          '';
        };
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
          enabled = true;
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
          enabled = lib.mkOption {
            type = bool;
            default = true;
            description = ''
              When false, the mount is excluded from `fileSystems` entirely
              and is not surfaced to the kernel. Use to temporarily disable
              a mount whose backing host is offline (an unreachable NFS
              server hangs anything that touches the path) without losing
              the row's configuration.
            '';
          };

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

    ## Per-app `homefree.services.<name>` option declarations now live
    ## in each app's own `apps/<name>/default.nix` (alongside its
    ## `homefree.service-options.<name>` decl), so an app fully owns
    ## both halves of its option schema — the same shape a custom-flake
    ## app must use. Only the handful of entries with no app directory
    ## remain declared here.
    services = {
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
    };

    service-config = lib.mkOption {
      description = "Detailed config for services";
      type = with lib.types; listOf (submodule {
        options = {

          ## Whether the service this entry describes is actually
          ## enabled. Apps emit their `service-config` block
          ## unconditionally (so the admin UI can list a disabled
          ## service and offer to turn it on), so consumers that act
          ## on the *running* system — notably
          ## modules/service-restart-policy.nix — must filter on this
          ## flag. Each app should set it to its own enable flag,
          ## e.g. `enable = config.homefree.service-options.<n>.enable;`.
          ## Default true so a block that predates this field (or an
          ## app that is always-on) keeps working unchanged.
          enable = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = "Whether the described service is enabled";
          };

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

            applicable = lib.mkOption {
              type = lib.types.bool;
              default = true;
              description = ''
                Whether SSO is meaningfully applicable to this service.
                Only consulted when kind = "none". Set false when a
                service deliberately cannot/should not be SSO-gated
                (no HTTP surface, API-key clients that OIDC would
                break, etc.) — the admin UI then shows "not applicable"
                rather than "not yet implemented". Leave true (default)
                for integrations that are simply pending.
              '';
            };

            notes = lib.mkOption {
              type = lib.types.str;
              default = "";
              description = ''
                Developer-only caveat / status note. NOT surfaced in the
                admin UI — keep human-facing rationale in a code comment
                beside the sso block instead. Retained for any tooling
                that still reads it.
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

            extra-http-hosts = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [];
              description = ''
                Literal Caddy site addresses (e.g. "http://10.0.0.1")
                appended verbatim to this service's virtualHost. Unlike
                http-domains these are NOT crossed with `subdomains` — they
                are used as-is. Intended for serving a service on a bare IP
                or other fixed address with no subdomain prefix.
              '';
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

            upstream-snippet = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = ''
                Name of a Caddy snippet to `import` as this service's
                reverse_proxy target, instead of a literal host:port.
                Used by the blue/green mechanism (lib/blue-green.nix):
                the snippet points at whichever colour is currently
                active and is rewritten at flip time, so the upstream
                can change with no nixos-rebuild. When set, the generic
                reverse-proxy generator emits `import <snippet>` in
                place of `reverse_proxy host:port`.
              '';
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

            sso-bypass-paths = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [];
              example = [ "/api/*" ];
              description = ''
                Request path patterns that skip the SSO gate when
                `oauth2 = true`. Each entry is a Caddy path matcher
                token; a request whose path matches any entry bypasses
                the oauth2-proxy `forward_auth` and reaches the
                upstream directly.

                This is a generic primitive — the base distribution
                does not assume what any path means. A service (in
                this repo or in an external flake) declares the paths
                its non-browser API clients use, because those clients
                cannot complete an interactive OAuth login and would
                otherwise be locked out. Such clients authenticate to
                the upstream with its own native credentials, while
                browser traffic to the web UI stays gated.
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

      ## Normalize every entry before any consumer reads the option.
      ## Targets External Proxy rows added through the admin UI, whose
      ## editor collects neither a subdomain nor a domain reliably:
      ##
      ##   - Empty `subdomains` defaults to `[ label ]`. The editor's
      ##     help text promises this ("defaults to [label] if blank")
      ##     but never applied it, so entries saved with the field
      ##     blank had `subdomains = []` — URL generation
      ##     (services/admin-web) and Caddy vhost generation
      ##     (services/caddy) both key off `subdomains`, so the entry
      ##     got no URL and no route.
      ##   - Empty `https-domains`/`http-domains` defaults
      ##     `https-domains` to the deployment's own domains.
      ##
      ## With both filled, the entry gets a real URL — visible on the
      ## admin card and surfaced on the home.<domain> grid — and an
      ## actual Caddy route, with no instance-side glue.
      ##
      ## An entry that already specifies these is left untouched
      ## (HomeFree's own apps set them in their .nix files).
      apply = entries: map (entry:
        let
          rp = entry.reverse-proxy;
          ## Only normalize entries that actually serve over the reverse
          ## proxy — leave disabled entries and non-proxy entries alone.
          ## rootDomain entries deliberately have no subdomain.
          normalize = rp.enable && !rp.rootDomain;
          needsSubdomain = normalize && rp.subdomains == [] && entry.label != "";
          needsDomains =
            normalize
            && rp.https-domains == []
            && rp.http-domains == [];
          subdomains =
            if needsSubdomain then [ entry.label ] else rp.subdomains;
          https-domains =
            if needsDomains
            then [ config.homefree.system.domain ]
                 ++ config.homefree.system.additionalDomains
            else rp.https-domains;
        in
          entry // {
            reverse-proxy = rp // {
              inherit subdomains https-domains;
            };
          }
      ) entries;
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
        ## A bare string is coerced into { path = <str>; enabled = true; }
        ## so older homefree-configuration.nix files (which pass the raw
        ## JSON string array straight through) keep evaluating against
        ## the promoted schema until they get regenerated. Without this
        ## the submodule type rejects the string and the error path
        ## attempts to render the path literal under pure-eval, which
        ## blows up with `access to absolute path ... is forbidden`.
        ##
        ## `path` is `str`, not `lib.types.path`, for the same reason:
        ## restic only needs the text — the path is opened at runtime,
        ## not imported into the system closure.
        type = lib.types.listOf (lib.types.coercedTo
          lib.types.str
          (s: { path = s; enabled = true; })
          (lib.types.submodule {
            options = {
              path = lib.mkOption {
                type = lib.types.str;
                description = "Source directory to back up";
              };
              enabled = lib.mkOption {
                type = lib.types.bool;
                default = true;
                description = ''
                  Whether this path is currently included in scheduled
                  backups. A disabled entry keeps its slot in the list
                  so its restic repository label (extra-path-N) stays
                  stable when it is re-enabled.
                '';
              };
            };
          }));
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
            type = "listOf submodule";
            default = [];
            description = "Additional custom paths to include in backups";
            submodule-fields = [
              {
                path = "path";
                type = "str";
                description = "Source directory to back up";
              }
              {
                path = "enabled";
                type = "bool";
                default = true;
                description = "Whether this path is included in scheduled backups";
              }
            ];
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
    ##
    ## Mirrored values are wrapped in `lib.mkDefault` so the JSON-driven
    ## `homefree.services.<name>` value is only the *default* for
    ## `service-options.<name>`. An instance (or another module, e.g.
    ## home-assistant.nix setting zwave-js-ui.deviceId) may assign a
    ## `service-options.<name>.<opt>` directly at normal priority and
    ## win, instead of colliding with the mirrored default.
    homefree.service-options =
      lib.mapAttrs
        (_: lib.mkDefault)
        (lib.intersectAttrs
          options.homefree.service-options
          config.homefree.services);

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
