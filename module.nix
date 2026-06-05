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

      ## Generic per-service backup-source registry. The backup primitive
      ## (services/backup) consumes THIS, not homefree.service-config, so it
      ## stays decoupled from the service-config schema. Populated by the
      ## composition layer (config section below) from each service-config
      ## entry's backup fields. Generic per-entry shape:
      ## { label, paths, postgres-databases, mysql-databases }.
      backup-sources = lib.mkOption {
        type = with lib.types; listOf (submodule {
          options = {
            label = lib.mkOption { type = str; };
            paths = lib.mkOption { type = listOf str; default = [ ]; };
            postgres-databases = lib.mkOption { type = listOf str; default = [ ]; };
            mysql-databases = lib.mkOption { type = listOf str; default = [ ]; };
          };
        });
        internal = true;
        default = [ ];
        description = "Generic backup-source registry consumed by services/backup, decoupled from service-config.";
      };

      ## Generic ingress registry consumed by the ingress-related primitives —
      ## services/caddy (vhosts), services/unbound (split-horizon DNS records),
      ## profiles/router (WAN firewall ports for public services). Decoupled
      ## from the service-config schema; each entry is
      ## { label, reverse-proxy, firewall }. Populated by the composition layer.
      ingress-vhosts = lib.mkOption {
        type = with lib.types; listOf attrs;
        internal = true;
        default = [ ];
        description = "Generic ingress registry (label + reverse-proxy + firewall) consumed by caddy, unbound, and the router.";
      };

      ## Generic port-request registry consumed by services/port-allocator
      ## (label + port-request), decoupled from service-config.
      port-requests = lib.mkOption {
        type = with lib.types; listOf attrs;
        internal = true;
        default = [ ];
        description = "Generic port-request registry (label + port-request) consumed by the port allocator.";
      };

      ## Generic managed-unit registry consumed by modules/service-restart-policy
      ## (enable + systemd-service-names), decoupled from service-config.
      managed-units = lib.mkOption {
        type = with lib.types; listOf attrs;
        internal = true;
        default = [ ];
        description = "Generic managed-unit registry (enable + systemd-service-names) consumed by the restart policy.";
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

      ssh-key-only = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Disable SSH password + keyboard-interactive authentication
          on the deployed system, requiring SSH public-key auth only.

          Default `false` because most deployments depend on password
          login for the admin user (the Phase 4 sshd fail2ban jail
          and the WAN-firewall mitigate brute-force). Flip to `true`
          ONLY after confirming you can already log in via SSH with
          your key — otherwise you lose remote SSH access.

          Set in homefree-config.json as `system.ssh-key-only: true`
          (or via the System tab in the admin UI).
        '';
      };

      wheel-passwordless = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Whether the `wheel` group gets `NOPASSWD: ALL` in sudoers.

          Default `true` (the historical HomeFree behavior — useful
          for debugging, dev shells, and unattended automation that
          calls `sudo` non-interactively). Flip to `false` to require
          the admin user to re-enter their password on every `sudo`,
          which restores password-as-second-factor for privilege
          escalation but breaks scripts relying on passwordless sudo.

          Set in homefree-config.json as
          `system.wheel-passwordless: false` (or via the System tab
          in the admin UI).
        '';
      };

      ## Pre-hashed password for the admin user. Set from
      ## homefree-config.json (`system.hashedPassword`) by
      ## modules/homefree-config-loader.nix. It is a crypt-style hash
      ## (mkpasswd output), never a plaintext password. When null the
      ## admin account keeps its empty initialHashedPassword and the
      ## password must be set out of band (SSH / passwd). This replaces
      ## the old install.py template's `users.users.<name>.hashedPassword`
      ## injection — see modules/homefree-config-loader.nix.
      hashedPassword = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Pre-hashed (crypt) password for the admin user, or null to leave unset.";
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

      ## Set true when the box has a RAID1 boot mirror — a second ESP
      ## on disk 2 mounted at /boot2 (disko provisions it). systemd-boot
      ## only installs into /boot, so without an extraInstallCommands
      ## rsync hook /boot2 stays empty and disk 2 cannot boot if disk 1
      ## dies. modules/boot-mirror.nix applies the hook when this is on.
      ## The installer flips this on when raid='raid1' is selected;
      ## single-disk installs leave it false.
      bootMirror = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Mirror /boot/ to /boot2/ after every systemd-boot install.
          Required for RAID1 setups where disk 2 has its own ESP at
          /boot2; a no-op on single-disk installs.
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

      lan-address-v6 = lib.mkOption {
        type = lib.types.str;
        default = "fd01::1";
        description = ''
          Inside (LAN) ULA IPv6 address of the router. Used for the IPv6
          half of split-horizon: LAN-only vhosts (reverse-proxy.public ==
          false) bind this address and unbound returns it as the AAAA for
          those non-public names, so IPv6-preferring clients on the box's
          resolver get a working LAN path instead of NODATA. Must match the
          ULA assigned to the LAN interface in profiles/router.nix.
        '';
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

            network = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = ''
                ID of the guest network (homefree.network.guest-networks[].id)
                this reservation belongs to. null = main LAN.
              '';
            };
          };
        });
      };

      ## Per-instance VLAN/guest networks (Guest, IoT, Blocked, etc.).
      ## Each entry creates an 802.1Q sub-interface on lan-interface, its
      ## own DHCP scope, and per-VLAN nftables forward rules. Reaching
      ## clients on a VLAN requires an 802.1Q-aware AP/switch downstream;
      ## HomeFree only handles the router side.
      guest-networks = lib.mkOption {
        default = [];
        description = "Isolated VLAN networks (guest, IoT, blocked, etc.)";
        type = with lib.types; listOf (submodule {
          options = {
            id = lib.mkOption {
              type = lib.types.str;
              description = ''
                Stable slug used as the VLAN sub-interface name and as
                the foreign key referenced by static-ips[].network.
                Letters, digits, hyphens; immutable once set.
              '';
            };
            name = lib.mkOption {
              type = lib.types.str;
              description = "Display name shown in the admin UI";
            };
            vlan-id = lib.mkOption {
              type = lib.types.int;
              description = "802.1Q VLAN tag (1-4094)";
            };
            subnet = lib.mkOption {
              type = lib.types.str;
              description = "Subnet in CIDR notation (e.g. 10.3.0.0/24)";
            };
            gateway = lib.mkOption {
              type = lib.types.str;
              description = "Router IP on this VLAN (must lie inside subnet)";
            };
            dhcp-range-start = lib.mkOption {
              type = lib.types.str;
              description = "First DHCP-allocated address on this VLAN";
            };
            dhcp-range-end = lib.mkOption {
              type = lib.types.str;
              description = "Last DHCP-allocated address on this VLAN";
            };
            internet-access = lib.mkOption {
              type = lib.types.bool;
              default = true;
              description = "Allow egress to the WAN interface";
            };
            lan-access = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = "Allow reaching the main LAN subnet";
            };
            inter-network-access = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = "Allow reaching other guest networks";
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

      perIpConnectionLimit = lib.mkOption {
        type = lib.types.ints.between 0 65535;
        default = 64;
        description = ''
          Maximum concurrent inbound TCP connections to ports 80/443
          allowed from a single WAN source — per /32 for IPv4, per /64
          for IPv6 (matches the typical residential ISP assignment
          granularity, so a household isn't capped by a single client
          using SLAAC privacy addresses across its /64).

          A bound at the firewall layer that limits the blast radius
          of any single misbehaving client: scrapers, broken bots,
          slowloris, opportunistic DoS. Caps damage at the
          connection layer, before fail2ban (which is reactive — it
          only acts after logs are scraped) and before Caddy's
          rate-limit plugin (which sees requests, not connections).

          A legitimate browser opens ~6 concurrent connections per
          origin (HTTP/2 multiplexes far fewer), so 64 leaves
          generous headroom for a real visitor — even a multi-tab
          power user — while catching anything pathological.
          Operators behind a large corporate NAT or cellular CGN
          (where many users share one egress IP) may want to raise
          this; setting `0` disables the cap entirely.

          Applies only to traffic ingressing on the WAN interface;
          LAN/VLAN/tailscale/podman traffic is unrestricted.
        '';
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

    ## ─── Privacy / external-services ────────────────────────────────
    ## Single source of truth for every third-party host the box
    ## may contact AS PART OF A FEATURE (geocoding, elevation
    ## lookup, public-IP probing for alerts, DoH for DNS-leak
    ## detection, etc.). Asset loads on web pages are governed
    ## separately by AGENTS.md rule 8 (vendoring), which is
    ## absolute — those have no opt-in.
    ##
    ## Defaults follow the operator's stated stance: features that
    ## are nice-to-have (elevation) are disabled by default;
    ## features that the operator explicitly relies on (alerts,
    ## DoH leak detection) keep their existing defaults but are
    ## now system-wide configurable so a future Privacy admin
    ## page can surface them all in one place.
    privacy = {
      externalServices = {
        elevation = {
          url = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            example = "https://api.open-meteo.com/v1/elevation?latitude={lat}&longitude={lon}";
            description = ''
              URL template for elevation lookups in the lat/lng
              picker (installer Location step, admin System page).
              `{lat}` and `{lon}` placeholders are substituted by
              the admin-api proxy.

              Default: `null` (disabled — the "Look up from coords"
              button returns "elevation lookup not configured").
              The previous behaviour was to call api.open-meteo.com
              (with api.open-elevation.com fallback) DIRECTLY from
              the user's browser — that leaked the visitor's IP to
              a third party on every click. The new path proxies
              through admin-api when configured, so only the box's
              egress IP touches the upstream.

              Operators who want the feature back: set this to the
              Open-Meteo URL in `example` above. The Open-Meteo
              response shape (`{"elevation": [<meters>]}`) is what
              the admin-api endpoint expects; alternative providers
              are not currently supported on the parsing side.
            '';
          };
        };

        publicIp = {
          url = lib.mkOption {
            type = lib.types.str;
            default = "https://ipinfo.io/ip";
            description = ''
              Default URL for "what's our public egress IP?" checks
              (used by the alerts module's WAN-reachability watcher
              and any other feature that needs to know the box's
              own egress address). Plain-text endpoint — caller
              expects the body to be just the IP string.

              An intentional third-party dependency: alerts must
              know the box's outside-view address, and a self-
              referential answer wouldn't catch the case where the
              box can't reach the outside at all (which is what the
              alert exists to detect). Keep the default unless the
              operator has a specific replacement in mind.

              Per-alert overrides remain available in the alerts
              UI; this option is the box-wide default that fresh
              alerts inherit. The intent is to give a future
              Privacy admin page one place to surface and change
              every third-party endpoint at once.
            '';
          };
        };

        doh = {
          url = lib.mkOption {
            type = lib.types.str;
            default = "https://cloudflare-dns.com/dns-query";
            description = ''
              Default DNS-over-HTTPS endpoint for DNS-leak detection
              in the alerts module (compares what the box resolves
              against what the DoH endpoint returns for the same
              query). Cloudflare is the default because it's the
              best-known DoH endpoint with a stable JSON API
              (`Accept: application/dns-json`).

              An intentional third-party dependency: the leak check
              needs an external authoritative answer to compare
              against. Other DoH endpoints (Quad9, NextDNS, the
              operator's own resolver if it speaks DoH) work too.

              Per-alert overrides remain available in the alerts
              UI; this option is the box-wide default that fresh
              alerts inherit.
            '';
          };
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

    storage = {
      pools = lib.mkOption {
        description = ''
          Local btrfs data pools created by the Storage admin module from
          unused drives. Each enabled entry produces a
          `fileSystems."<mountpoint>"` declaration (mounted by btrfs
          filesystem UUID, `nofail`). Pools are CREATED imperatively by the
          admin backend (`mkfs.btrfs` once); this list only records their
          identity so NixOS can mount them and, later, scrub/snapshot them.
          A missing or degraded pool must never block boot, so every entry
          mounts `nofail` with a bounded `x-systemd.device-timeout`.
        '';
        default = [];
        example = [
          {
            enabled = true;
            name = "tank";
            mountpoint = "/mnt/tank";
            profile = "raid1";
            members = [
              "ata-WDC_WD40EFRX-68N32N0_WD-WCC7K1234567"
              "ata-WDC_WD40EFRX-68N32N0_WD-WCC7K7654321"
            ];
            fs-uuid = "b7c5e2f0-0000-0000-0000-000000000000";
          }
        ];
        type = with lib.types; listOf (submodule {
          options = {
            enabled = lib.mkOption {
              type = bool;
              default = true;
              description = ''
                When false the pool is not mounted, but its row is kept in
                homefree-config.json so the admin UI can re-enable it.
              '';
            };

            name = lib.mkOption {
              type = str;
              description = "Pool identity and btrfs filesystem label (e.g. tank).";
            };

            mountpoint = lib.mkOption {
              type = str;
              description = "Absolute path where the pool is mounted (e.g. /mnt/tank).";
            };

            profile = lib.mkOption {
              type = enum [ "single" "raid0" "raid1" "raid10" "raid5" "raid6" ];
              description = ''
                Data layout chosen at creation. single/raid0/raid1/raid10 are
                btrfs-native. raid5/raid6 are space-efficient PARITY layouts
                built as btrfs-on-mdadm (the Synology approach): Linux md owns
                the parity and btrfs runs single-profile on the resulting
                /dev/md device, adding checksums + scrub + snapshots. Native
                btrfs raid5/6 is deliberately NOT used (unresolved write hole).
                md's own write hole is mitigated by an internal write-intent
                bitmap plus btrfs checksums, which turn any post-failure parity
                corruption into a DETECTED read error rather than silent data
                loss (recover from Backups).
              '';
            };

            members = lib.mkOption {
              type = listOf str;
              default = [];
              description = ''
                Member backing devices as bare /dev/disk/by-id names (no
                /dev/ prefix). Recorded for display, scrub, and pool
                removal; the mount itself keys on fs-uuid.
              '';
            };

            fs-uuid = lib.mkOption {
              type = str;
              description = ''
                btrfs filesystem UUID captured at mkfs time. The mount keys
                on this — a multi-device btrfs assembles from whichever
                member is present, so the UUID is stable across disk
                reorder/reseat.
              '';
            };

            md-uuid = lib.mkOption {
              type = str;
              default = "";
              description = ''
                Parity volumes only (raid5/raid6): the Linux md array UUID
                captured at create time. Empty for btrfs-native profiles.
                Recorded for display, health, and reclaim — assembly itself is
                automatic, by homehost, via the mdadm udev rules.
              '';
            };

            md-device = lib.mkOption {
              type = str;
              default = "";
              description = ''
                Parity volumes only: the md array name (e.g. "tank", assembled
                at /dev/md/tank). Empty for btrfs-native profiles.
              '';
            };

            encrypted = lib.mkOption {
              type = bool;
              default = false;
              description = ''
                Whether the volume's members are LUKS containers unlocked at boot.
                The unlock key is the LUKS recovery passphrase at
                `/etc/nixos/secrets/recovery-passphrase.txt` (the same value the
                user types to unlock the system disk). Unlock is LATE — driven by
                `/etc/crypttab` after root mount, with `nofail` so a missing /
                failed disk never blocks the admin UI (AGENTS.md rule 10).
              '';
            };

            luks-mappers = lib.mkOption {
              type = listOf (submodule {
                options = {
                  mapper = lib.mkOption {
                    type = str;
                    description = ''
                      Mapper name exposed at `/dev/mapper/<mapper>`. Convention:
                      `cryptd-<pool>-<i>` (1..N) for per-disk LUKS on btrfs-native
                      profiles; `cryptd-<pool>` (single) for LUKS-on-md on parity
                      profiles.
                    '';
                  };
                  by-id = lib.mkOption {
                    type = str;
                    description = ''
                      Stable identifier of the LUKS backing device — used to build
                      the `/dev/disk/by-id/<by-id>` path in `/etc/crypttab`. For
                      btrfs-native profiles this is a member disk's by-id (mirrors
                      a row in `members`). For parity profiles it is the md
                      array's `md-uuid-<X>` symlink (one entry per pool, the LUKS
                      sits on the assembled `/dev/md`).
                    '';
                  };
                  luks-uuid = lib.mkOption {
                    type = str;
                    description = ''
                      LUKS2 container UUID captured at format time (via
                      `cryptsetup luksUUID`). Invariant across cable/controller
                      reseats — recorded for display, future rotation, and a
                      defensive sanity-check before opening (catch a swapped disk
                      before unlocking the wrong device).
                    '';
                  };
                  keyfile = lib.mkOption {
                    type = str;
                    default = "";
                    description = ''
                      Absolute path to a keyfile that auto-unlocks this LUKS
                      container at boot. Empty (the default) means the volume
                      is master-keyed: /etc/crypttab uses `none` as the
                      keyfile field with `tpm2-device=auto,tpm2-pcrs=7` so
                      TPM2 auto-unlocks and the recovery passphrase prompts as
                      fallback. Non-empty (typically
                      `/etc/nixos/secrets/luks-keys/<luks-uuid>.key`) means
                      the volume was adopted with a foreign passphrase — the
                      crypttab entry references the keyfile directly; if the
                      master key was ALSO adopted as a slot (luksAddKey),
                      TPM2 is still tried first and the keyfile is the
                      backup. The /etc/nixos/secrets directory is backed up,
                      so the keyfile survives restore.
                    '';
                  };
                  tpm2-enrolled = lib.mkOption {
                    type = bool;
                    default = true;
                    description = ''
                      Whether this LUKS container has a TPM2-bound keyslot
                      (`systemd-cryptenroll --tpm2-device=auto`). When TRUE
                      the generated /etc/crypttab line includes
                      `tpm2-device=auto,tpm2-pcrs=7` so systemd-cryptsetup
                      tries TPM2 unseal first at boot. When FALSE those opts
                      are OMITTED — critical, because a `tpm2-device=auto`
                      opt against a LUKS with NO TPM2 slot causes
                      systemd-cryptsetup to SEGFAULT inside `tpm2_unseal`
                      instead of falling through to the keyfile / prompt
                      (observed on systemd 260 — boot fails with
                      `core-dump`). Default true preserves the original
                      master-keyed behavior for legacy pool records (which
                      don't carry this field); foreign-keyed pools adopted
                      via the unlock flow set it explicitly based on a
                      probe of the live LUKS slots.
                    '';
                  };
                };
              });
              default = [];
              description = ''
                Per-member LUKS containers, populated by the pool create job when
                `encrypted = true`. Empty otherwise. Length is one entry per disk
                for btrfs-native profiles, and a single entry (for the md device)
                for parity profiles (raid5/raid6).
              '';
            };

            mount-options = lib.mkOption {
              type = listOf str;
              default = [ "compress=zstd" "noatime" ];
              description = ''
                btrfs mount options appended after the safety defaults
                (nofail + x-systemd.device-timeout).
              '';
            };

            device-timeout = lib.mkOption {
              type = str;
              default = "15s";
              description = ''
                x-systemd.device-timeout for the mount — how long boot waits
                for the pool device before giving up. The mount is nofail, so
                boot proceeds regardless.
              '';
            };

            snapshots = lib.mkOption {
              type = bool;
              default = false;
              description = ''
                Enable scheduled btrfs timeline snapshots (snapper) for this
                volume — fast LOCAL file recovery, NOT a backup (if the drive
                fails the snapshots are lost too). Retention is shared via
                homefree.snapshots.retention. Off by default.
              '';
            };
          };
        });
      };

      shares = lib.mkOption {
        description = ''
          NFS network shares exported from this host (Phase 2a). Each enabled
          entry adds a line to `services.nfs.server.exports`. These are
          host/subnet-trust NFS exports (no per-user auth) reachable only from
          the LAN — SMB and per-user (Zitadel-aligned) auth are a later phase,
          since file protocols cannot use OIDC SSO.
        '';
        default = [];
        example = [
          {
            enabled = true;
            name = "media";
            path = "/mnt/tank/media";
            allowed = "10.0.0.0/24";
            read-only = false;
          }
        ];
        type = with lib.types; listOf (submodule {
          options = {
            enabled = lib.mkOption {
              type = bool;
              default = true;
              description = "When false the export is omitted (row kept so the UI can re-enable it).";
            };
            name = lib.mkOption {
              type = str;
              description = "Share name (identifier, shown in the admin UI).";
            };
            path = lib.mkOption {
              type = str;
              description = "Absolute path to export — typically a volume mountpoint or a subdirectory of one.";
            };
            allowed = lib.mkOption {
              type = str;
              default = "";
              description = ''
                Allowed NFS clients: a comma/space-separated list of CIDRs or
                IPs (e.g. "10.0.0.0/24"). Empty defaults to the host's LAN
                subnet. A share with no resolvable clients is NOT exported
                (never world-exported).
              '';
            };
            read-only = lib.mkOption {
              type = bool;
              default = false;
              description = "Export read-only (ro) instead of read-write (rw).";
            };
            squash = lib.mkOption {
              type = enum [ "root" "none" "all" ];
              default = "root";
              description = ''
                NFS UID/GID squashing mode:
                - "root" (default): map client root to the anonymous user (root_squash).
                - "none":  pass client root through unchanged (no_root_squash). Trusts
                          the client; use only on hosts you fully control.
                - "all":   map every client UID/GID to the anonymous user (all_squash).
                          Pair with anon-uid / anon-gid so squashed clients write as
                          a specific account instead of nfsnobody.
              '';
            };
            anon-uid = lib.mkOption {
              type = nullOr int;
              default = null;
              description = ''
                UID that squashed clients are mapped to (anonuid). null leaves the
                NFS server default (typically nfsnobody / 65534). Set when squash
                = "all" to direct all writes to a specific owner's UID.
              '';
            };
            anon-gid = lib.mkOption {
              type = nullOr int;
              default = null;
              description = ''
                GID that squashed clients are mapped to (anongid). null leaves the
                NFS server default. Pairs with anon-uid.
              '';
            };
            media = lib.mkOption {
              type = bool;
              default = false;
              description = ''
                Expose this folder through the DLNA/UPnP media server (minidlna)
                so smart TVs and AV receivers on the LAN can browse and play its
                contents — the same role Synology's "Media Server" played. This
                is independent of the NFS export (`enabled`): a folder can be
                media-only, NFS-only, or both.

                SECURITY: DLNA has NO authentication. Any device on the LAN can
                read an exposed folder's contents. It is LAN-only (the router
                firewall never exposes DLNA to the WAN). Off by default; tick
                only for media folders.
              '';
            };
            media-type = lib.mkOption {
              type = enum [ "all" "audio" "video" "pictures" ];
              default = "all";
              description = ''
                Which media kinds this folder contributes to the DLNA library
                (only used when `media` is true). Maps to minidlna's media_dir
                type prefixes:
                - "all" (default): audio + video + images (no prefix).
                - "audio":    A, prefix — keeps a music folder out of the TV's
                              video menu.
                - "video":    V, prefix.
                - "pictures": P, prefix.
              '';
            };
          };
        });
      };

      media-server = {
        friendly-name = lib.mkOption {
          type = with lib.types; nullOr str;
          default = null;
          description = ''
            Name the DLNA/UPnP media server advertises to TVs and receivers on
            the LAN. null falls back to the box hostname.
          '';
        };
      };
    };

    snapshots = {
      system = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = ''
            Scheduled btrfs timeline snapshots of the OS root (/ and /home)
            for fast LOCAL recovery of mutable files. This is NOT system
            rollback — NixOS generations already boot a previous config — and
            NOT a backup. /nix is excluded (separate subvolume). Off by default
            (the root holds service databases under /var/lib, where snapshots
            add some space/fragmentation cost).
          '';
        };
      };
      retention = {
        hourly = lib.mkOption {
          type = lib.types.int;
          default = 24;
          description = "Hourly timeline snapshots to keep (snapper TIMELINE_LIMIT_HOURLY).";
        };
        daily = lib.mkOption {
          type = lib.types.int;
          default = 7;
          description = "Daily timeline snapshots to keep.";
        };
        weekly = lib.mkOption {
          type = lib.types.int;
          default = 4;
          description = "Weekly timeline snapshots to keep.";
        };
        monthly = lib.mkOption {
          type = lib.types.int;
          default = 6;
          description = "Monthly timeline snapshots to keep.";
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

          frontend-tls = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = ''
              When true, Caddy terminates TLS at the frontend even when
              the target is HTTP-only. Lets you serve an HTTP-only
              backend (target.http set, target.https null) via HTTPS at
              the public hostname — the standard reverse-proxy pattern.
              Combined with a wildcard domain, Caddy auto-acquires the
              wildcard cert via DNS-01.

              Default is false to preserve historical behavior (an
              HTTP target produces an HTTP-only vhost).
            '';
          };
        };
      });
    };

    ## Alerts framework. A small in-process polling engine that runs on
    ## a systemd timer, evaluates a registry of named "sources" (disk
    ## temperature, backup health, service liveness, …) on each tick,
    ## persists per-source state with hysteresis so transient blips
    ## don't spam, and dispatches transition events (open / close) to a
    ## set of named "channels" (ntfy push, email, …). v1 ships only the
    ## `disk-temperature` source and the `ntfy` channel; the option
    ## tree is shaped so additional sources / channels can be added
    ## without further schema churn — each new source becomes a new
    ## entry under `sources`, each new channel a new entry under
    ## `channels`. Code lives in web-platform/backend/services/alerts_*
    ## (engine + sources + channels) and web-platform/backend/
    ## homefree_alerts_engine.py (timer entrypoint).
    alerts = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Master toggle for the alerts engine. Fresh installs seed
          `alerts.enable: true` (plus the ntfy push channel) in
          homefree-config.json (see install.py's HOMEFREE_JSON_TEMPLATE),
          so new boxes default ON. This option
          default (false) — and the loader's matching `or false` — applies
          only to older configs that predate the alerts block, so
          upgrading boxes are not silently flipped on. Toggle it from the
          admin UI Alerts page.
        '';
      };

      interval = lib.mkOption {
        type = lib.types.str;
        default = "1min";
        description = ''
          Poll interval in systemd OnUnitInactiveSec syntax. Sets how
          often each enabled source is re-evaluated. The window from
          first-cross-threshold to first-notification is bounded by
          this; a tighter interval shortens the lag but also re-walks
          smartctl / filesystem stats more often. 1 minute matches the
          drive-temp sampler's own cadence (admin-web/default.nix
          SAMPLE_INTERVAL) so a fresh temp reading triggers an alert
          within ~2 ticks instead of waiting a sampler tick + a 5-min
          alerts tick.
        '';
      };

      channels = {
        ntfy = {
          enable = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = ''
              Dispatch alert events to the self-hosted ntfy server
              (services/ntfy). When true the alerts engine POSTs to
              `http://127.0.0.1:2586/<topic>` for every open/close
              event; the paired phone subscribed to `<topic>` gets a
              push. Setting this also auto-enables
              `homefree.services.ntfy` (see services/alerts/default.nix).
            '';
          };
        };
      };

      sources = {
        disk-temperature = {
          enable = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = ''
              Monitor every disk's reported SMART temperature; fire
              when any disk reaches the threshold for its drive class
              (HDD / SSD / NVMe), clear when it drops back below
              `threshold - hysteresis-c`.

              Per-class thresholds are necessary because safe operating
              ranges differ a lot across classes: spinning platters
              start losing MTBF around 45-50°C, while modern NVMe
              controllers idle at 60°C and only throttle near 80°C. A
              single global value made one of them wrong — either
              alert spam from healthy NVMe drives, or HDDs cooking
              unnoticed. Defaults here match the per-class warn
              thresholds the Hardware page already uses.
            '';
          };

          thresholds = {
            ## Per-class warn / err pairs mirror the Hardware page's
            ## two-tier colour scheme (warn = yellow, err = red), so
            ## an Alerts page reader doesn't have to learn a new
            ## mental model. Warn fires "high" priority pushes;
            ## err fires "max" priority and escalates the open
            ## history row's severity.
            hdd-warn-c = lib.mkOption {
              type = lib.types.int;
              default = 45;
              description = ''
                Warn-level temperature (°C) for SPINNING (HDD)
                drives. 45°C is the consensus rule-of-thumb where
                MTBF starts climbing — early enough to notice, late
                enough to filter normal scrub-induced heat.
              '';
            };
            hdd-err-c = lib.mkOption {
              type = lib.types.int;
              default = 50;
              description = ''
                Err-level temperature (°C) for HDDs. 50°C is the
                Hardware page's red threshold and the upper edge
                of the "operationally safe" range for 7200-RPM
                NAS drives.
              '';
            };

            ssd-warn-c = lib.mkOption {
              type = lib.types.int;
              default = 60;
              description = "Warn-level temperature (°C) for SATA SSDs.";
            };
            ssd-err-c = lib.mkOption {
              type = lib.types.int;
              default = 70;
              description = ''
                Err-level temperature (°C) for SATA SSDs. Typical
                spec is 70°C; at this temperature the controller
                may start throttling.
              '';
            };

            nvme-warn-c = lib.mkOption {
              type = lib.types.int;
              default = 70;
              description = "Warn-level temperature (°C) for NVMe drives.";
            };
            nvme-err-c = lib.mkOption {
              type = lib.types.int;
              default = 80;
              description = ''
                Err-level temperature (°C) for NVMe drives. 80°C is
                where most consumer NVMe controllers begin thermal
                throttling.
              '';
            };
          };

          hysteresis-c = lib.mkOption {
            type = lib.types.int;
            default = 4;
            description = ''
              Degrees BELOW the per-class threshold the disk must drop
              to before the engine considers the alert resolved.
              Prevents flap when a disk hovers right at the threshold.
              Applies to every class uniformly.
            '';
          };

          channels = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ "ntfy" ];
            description = ''
              Channel names this source's events dispatch to. Each
              entry must match an enabled channel under
              `homefree.alerts.channels`. Entries pointing at a
              disabled channel are silently skipped — the alert still
              fires and is recorded in history, it just produces no
              outbound notification.
            '';
          };
        };

        disk-space = {
          enable = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = ''
              Watch every locally-mounted filesystem and fire when any
              one passes `threshold-percent` full. Reads /proc/mounts
              + statvfs(); no smartctl, no external daemons. Mount
              membership is recomputed every tick so a removable disk
              that disappears is silently dropped instead of producing
              "could not stat" noise.
            '';
          };

          threshold-warn-percent = lib.mkOption {
            type = lib.types.int;
            default = 90;
            description = ''
              Warn-level percent-full at which a filesystem alerts.
              90% is the consensus warn level for general-purpose
              filesystems — writes start slowing well before 100
              (extent / metadata allocators get fragmentation-bound)
              and 10% headroom is enough to fit a few hours of
              typical NAS ingest.
            '';
          };

          threshold-err-percent = lib.mkOption {
            type = lib.types.int;
            default = 95;
            description = ''
              Err-level percent-full. 95% is close enough to full
              that imminent failure of writes is a real risk — the
              source escalates the alarm and pushes at max priority.
            '';
          };

          hysteresis-percent = lib.mkOption {
            type = lib.types.int;
            default = 3;
            description = ''
              Once firing, a filesystem only clears by dropping to
              `threshold-percent - hysteresis-percent`. Prevents flap
              when a filesystem hovers right at the threshold and
              writes/deletes a few files per tick.
            '';
          };

          fs-types = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [
              ## Real local filesystems.
              "ext2" "ext3" "ext4" "xfs" "btrfs" "zfs" "f2fs" "jfs"
              "reiserfs"
              ## Real removable / interop filesystems.
              "ntfs" "ntfs3" "vfat" "exfat"
              ## Real network filesystems (worth watching even when
              ## remote — out-of-space on NFS will still break writes).
              "nfs" "nfs4" "cifs"
            ];
            description = ''
              Allowlist of filesystem types to monitor. Everything not
              in this list is silently skipped (the standard set of
              kernel virtual filesystems — tmpfs, sysfs, proc, cgroup,
              overlay, squashfs, etc. — would otherwise generate noise
              and would never fill up usefully). Customise to also
              watch e.g. fuse mounts.
            '';
          };

          skip-mount-prefixes = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [
              ## Kernel / runtime — never user data.
              "/proc" "/sys" "/dev" "/run"
              ## Container layer storage (the active layer is on /,
              ## which we DO monitor; the per-container overlays are
              ## ephemeral and shouldn't generate alerts).
              "/var/lib/docker" "/var/lib/containers"
              ## NixOS profile / boot dirs — small fixed-size, and the
              ## user can't usefully react if they fill up (it'd take
              ## a `nix-collect-garbage` from the OS side).
              "/boot"
            ];
            description = ''
              Mountpoints whose path equals one of these, or starts with
              one followed by '/', are skipped even if their fs-type is
              on the allowlist. Catches transient mounts (docker layers,
              snap loopbacks under /var/lib/snapd) that wouldn't be
              actionable from a user push.
            '';
          };

          channels = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ "ntfy" ];
            description = ''
              Channel names this source's events dispatch to. See
              disk-temperature.channels for semantics.
            '';
          };
        };

        smart = {
          enable = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = ''
              Fire when ANY drive reports a SMART overall-health FAIL
              (smartctl -H). Uses the existing PhysicalDrivesResolver
              data, so the same drive enumeration powers the Hardware
              page and this alert. Drives that don't expose SMART
              (USB enclosures, some NVMe controllers) are silently
              ignored — absence of SMART is not failure.
            '';
          };

          channels = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ "ntfy" ];
          };
        };

        sensor-temperature = {
          enable = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = ''
              CPU / NVMe controller / GPU temperatures from hwmon
              (the same sensors the Hardware page Sensors panel shows).
              Per-class thresholds — silicon classes have very different
              safe operating ranges, just like the disk-temperature
              source's HDD/SSD/NVMe split.
            '';
          };

          thresholds = {
            ## Two-tier per-class warn / err (matching disk-
            ## temperature's shape). CPU/NVMe-controller/GPU only —
            ## memory and "other" hwmon kinds stay unmonitored,
            ## same as the prior single-tier behaviour.
            ##
            ## All six are `nullOr int` defaulting to null so the
            ## backend can run its inference cascade per reading:
            ## prefer the driver-reported `_crit`/`_max` from sysfs
            ## (works for Intel coretemp, NVMe, discrete GPUs); fall
            ## back to a class bucket keyed off CPUID family / PCI
            ## vendor (covers AMD k10temp/zenpower and integrated
            ## GPUs that hide Tjmax). A non-null value here is a
            ## user override — the cascade respects it verbatim.
            cpu-warn-c = lib.mkOption {
              type = lib.types.nullOr lib.types.int;
              default = null;
              description = ''
                Warn-level CPU sensor temperature (°C). Leave null to
                let the backend infer from the chip — `coretemp _crit`
                on Intel; CPUID family bucket on AMD (k10temp doesn't
                expose Tjmax, so we bucket Zen 3+/Zen 1-2/older).
              '';
            };
            cpu-err-c = lib.mkOption {
              type = lib.types.nullOr lib.types.int;
              default = null;
              description = ''
                Err-level CPU sensor temperature. Leave null for
                inference (typically Tjmax - 5).
              '';
            };

            nvme-warn-c = lib.mkOption {
              type = lib.types.nullOr lib.types.int;
              default = null;
              description = ''
                Warn-level NVMe controller temperature. Leave null
                to derive from the controller's own `temp1_max`
                (operating max per identify) or `temp1_crit`. Mirrors
                disk-temperature.thresholds.nvme-warn-c — the
                controller sensor is distinct from the media
                temperature monitored by the disk-temperature source.
              '';
            };
            nvme-err-c = lib.mkOption {
              type = lib.types.nullOr lib.types.int;
              default = null;
              description = ''
                Err-level NVMe controller temperature. Leave null
                for inference.
              '';
            };

            gpu-warn-c = lib.mkOption {
              type = lib.types.nullOr lib.types.int;
              default = null;
              description = ''
                Warn-level GPU temperature. Leave null to derive
                from amdgpu/nouveau/i915 `temp1_crit` when the
                driver exposes one (discrete cards do; integrated
                GPUs typically don't and fall to a class default).
              '';
            };
            gpu-err-c = lib.mkOption {
              type = lib.types.nullOr lib.types.int;
              default = null;
              description = ''
                Err-level GPU temperature. Leave null for inference.
              '';
            };
          };

          hysteresis-c = lib.mkOption {
            type = lib.types.int;
            default = 4;
            description = ''
              Degrees BELOW the per-class threshold the sensor must
              drop to before clearing. Same shape and rationale as
              disk-temperature.hysteresis-c.
            '';
          };

          channels = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ "ntfy" ];
          };
        };

        services-down = {
          enable = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = ''
              Fire when any enabled service in `homefree.service-config`
              has a systemd unit in the `failed` state. Iterates
              service-config entries with `enable = true`, runs
              `systemctl is-active` for each unit in their
              `systemd-service-names`, and reports the failures.

              We deliberately only alert on `failed` — `inactive` is
              ambiguous (a successful Type=oneshot RemainAfterExit=
              false unit is `inactive` and that's fine), and
              `activating` / `deactivating` are transient. A unit that
              SHOULD be running but is stopped via `systemctl stop`
              will not alert; that's a deliberate admin action.
            '';
          };

          channels = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ "ntfy" ];
          };
        };

        backup-failures = {
          enable = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = ''
              Fire when any scheduled backup unit's last run failed,
              or when the backup canary's last self-test failed.

              Pulls from BackupOperations.get_backup_health()
              (local + Backblaze) and get_canary_status() — the same
              data the Backups page health card shows. No threshold
              tuning: backup outcomes are binary, and a single failure
              is worth a push. The canary catches the case where every
              backup *unit* exits 0 but the backup is unrestorable
              (silent corruption / wrong key / bad target).
            '';
          };

          channels = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ "ntfy" ];
          };
        };

        attacks = {
          enable = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = ''
              Fire when the total of currently-banned IPs across all
              fail2ban jails crosses `threshold-bans`. Same data
              source as the Abuse Blocking page (fail2ban-client
              status).

              "Currently banned" — not a delta from last tick — keeps
              the alert stateless across engine restarts. The
              hysteresis below converts a sustained ban list into a
              single open + close pair rather than re-firing every
              poll while the ban list slowly drains.
            '';
          };

          threshold-bans = lib.mkOption {
            type = lib.types.int;
            default = 5;
            description = ''
              Total currently-banned-IP count across all jails that
              constitutes an "attack" event worth pushing. 5 is enough
              to filter out the constant background of single-IP
              scanner blocks any internet-facing host sees, while
              still catching a real botnet sweep that adds dozens of
              IPs in minutes.
            '';
          };

          hysteresis-bans = lib.mkOption {
            type = lib.types.int;
            default = 2;
            description = ''
              The current-ban total must drop to
              (threshold-bans - hysteresis-bans) before the alert
              clears. Prevents a single unban/reban flipping the
              alert state every tick when the ban list sits right
              at the threshold.
            '';
          };

          channels = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ "ntfy" ];
          };
        };

        tls-cert = {
          enable = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = ''
              Fire when any cert under Caddy's storage is expiring
              within `warn-days`, or already expired. Walks
              /var/lib/caddy/.local/share/caddy/certificates/*/*/
              and parses NotAfter from each .crt via openssl.

              Catches the failure mode where ACME renewal silently
              stops working (DNS-01 token revoked, rate-limit hit,
              CA changed terms) — Caddy keeps trying in the
              background but doesn't otherwise tell anyone, and the
              first user-visible symptom is a browser cert error
              well into the renewal window.
            '';
          };

          warn-days = lib.mkOption {
            type = lib.types.int;
            default = 14;
            description = ''
              Days-before-NotAfter at which a cert starts alerting.
              Let's Encrypt issues 90-day certs and Caddy renews when
              30 days remain — a 14-day warning gives 16 days of
              renewal attempts to recover before the alert fires,
              which is comfortable headroom over Caddy's default
              retry cadence.
            '';
          };

          channels = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ "ntfy" ];
          };
        };

        wan-accessibility = {
          enable = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = ''
              Verify the box is reachable from the public internet by
              cross-checking its public IP against the public DNS
              answer for `homefree.system.domain`. Specifically:
                * Fetch the box's egress IP via ipinfo.io/ip.
                * Resolve the domain via Cloudflare DoH
                  (cloudflare-dns.com/dns-query) so the lookup
                  bypasses local unbound's overrides and reflects
                  what the world actually sees.
                * Fire when the box's IP is NOT among the A records.

              This is a DNS-consistency check, not a reverse-ping.
              It DETERMINISTICALLY catches the most common WAN-broken
              scenario — DDNS expired / mis-updated / pointing at a
              stale IP — using two endpoints whose answers are
              independently verifiable.

              It does NOT detect "ISP blocked inbound 443" or
              "DDNS is fine but Caddy isn't binding the WAN" — for
              those, the `services-down` source on caddy is the
              primary signal, and the `tls-cert` source catches
              externally-broken certs at the renewal-window edge.

              An earlier draft of this source used a third-party
              reverse-ping service (isitup.org, then allorigins.win)
              but both proved either dead or too flaky for an alert
              source (rate-limited / inconsistent error shapes).
              The DNS-consistency design pivots to two endpoints
              that aren't claiming to know whether the box is up —
              just facts we can correlate.

              Auto-skips when no service in `homefree.service-config`
              is WAN-public.
            '';
          };

          public-ip-url = lib.mkOption {
            type = lib.types.str;
            default = "https://ipinfo.io/ip";
            description = ''
              Endpoint to fetch the box's own public (egress) IP.
              Default is ipinfo.io — the same service ddclient uses
              for IPv4 detection, so any consistency issues already
              affect DDNS itself. Body MUST be a plain IP address.
            '';
          };

          doh-url = lib.mkOption {
            type = lib.types.str;
            default = "https://cloudflare-dns.com/dns-query";
            description = ''
              DNS-over-HTTPS endpoint for the external public-DNS
              lookup of the domain. Default is Cloudflare's. The
              request adds `?name=<domain>&type=A` and an
              `Accept: application/dns-json` header — any RFC-8484-ish
              DoH JSON endpoint should work.

              Using DoH (vs the system resolver) is deliberate: a
              HomeFree box typically runs unbound with local overrides
              that resolve the box's own domain to its LAN address.
              The system resolver would tell us "yes, your domain
              resolves" without ever leaving the LAN — useless for
              detecting a public-DNS regression.
            '';
          };

          channels = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ "ntfy" ];
          };
        };

        headscale-accessibility = {
          enable = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = ''
              End-to-end health check for the self-hosted Headscale
              VPN control plane. Auto-skips when Headscale is not
              enabled.

              Four checks per tick:
                - headscale and headplane systemd units are not in
                  the `failed` state (same convention as the
                  `services-down` source — we treat `inactive` as
                  ambiguous and don't alert on it).
                - `headscale users list -o json` exits 0 — the
                  established readiness pattern from apps/headscale;
                  catches the case where the unit is up but the API
                  socket isn't binding.
                - `journalctl -u headscale -p err --since <window>`
                  is empty — catches transient errors that don't
                  take the unit down.
                - When `homefree.services.headscale.public = true`,
                  external probe of `headscale.<system.domain>`
                  via the same probe service `wan-accessibility`
                  uses.

              Does NOT verify a real Tailscale client can connect —
              that requires a second host. This source's job is
              "everything Headscale exposes from this box looks
              healthy."
            '';
          };

          journal-window = lib.mkOption {
            type = lib.types.str;
            default = "5 min ago";
            description = ''
              How far back to scan the headscale journal for error-
              level entries. `journalctl --since` syntax. 5 minutes
              tracks the default 1-minute tick: an error that
              clears quickly still gets at most a couple of pushes
              before the window slides past it.
            '';
          };

          channels = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ "ntfy" ];
          };
        };
      };
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

        suppressDefaultWarning = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = ''
            Suppress the build warning emitted when the landing page is
            left at the default Homefree landing page.
          '';
        };

        rateLimit = {
          enable = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = ''
              Apply a proactive per-IP request-rate cap on the apex
              landing site's HTML routes. Uses the
              mholt/caddy-ratelimit plugin (built in via
              overlays/caddy-with-plugins.nix).

              Complements the per-IP nftables connection cap
              (`homefree.network.perIpConnectionLimit`): nftables
              sees sockets, this sees individual HTTP requests, so
              an HTTP/2 client multiplexing 50 requests on one
              socket is still rate-limited here. Fires immediately
              on the request (vs fail2ban, which is reactive). 429
              responses are excluded from the fail2ban 404-storm /
              error-flood jails so a legitimate HN/Reddit surge
              doesn't trigger bans.

              Scoped narrowly: applies only to HTML routes on the
              apex landing site (`?v=*` hashed assets, `/downloads/*`,
              `/.well-known/*`, and the `/manual` redirect are
              exempt — they have their own profiles or are cheap to
              serve).

              Disable on a box where the landing page sees enough
              legitimate burst traffic that 429s would harm UX, or
              where Layer 3 (nftables) is judged sufficient on its
              own.
            '';
          };

          events = lib.mkOption {
            type = lib.types.ints.positive;
            default = 30;
            description = ''
              Maximum events (requests) allowed per source IP per
              `window`. Defaults to 30 requests / 10s = a sustained
              3 req/s per visitor, plenty of headroom for legitimate
              navigation (a real user clicking links). Lower on
              under-resourced boxes; raise if the page has lots of
              cheap sub-requests.
            '';
          };

          window = lib.mkOption {
            type = lib.types.str;
            default = "10s";
            description = ''
              Sliding window over which `events` is counted. Caddy
              duration syntax (`10s`, `1m`, etc.).
            '';
          };
        };

        edge = {
          enable = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = ''
              Opt-in: place a third-party CDN / edge in front of the
              public landing page. Layer 7 of the surge-resilience
              stack — the only real defence on residential
              asymmetric uplinks (25-50 Mbps up cable / DSL),
              where no amount of origin tuning will keep a Hacker
              News front-page hit from saturating the pipe.

              Cost: an external dependency for the marketing
              surface. The HomeFree project view (taken with the
              maintainer) is that the marketing site for the
              project itself is a different concern from each
              operator's own personal HomeFree box, so a CDN here
              is an acceptable trade-off for operators who need
              it. Personal HomeFree boxes running in personal-
              mode have no marketing site to defend, so this
              option doesn't apply.

              When enabled this option does NOT itself contact the
              CDN — it just configures the apex Caddy site to:
                (a) trust the configured proxy IPs so logs and
                    fail2ban see real client IPs, not the CDN edge;
                (b) reject requests that didn't come through the
                    CDN (header-token check), so an attacker can't
                    bypass the edge by hitting the origin IP
                    directly;
                (c) emit `Vary: Cookie` so the edge doesn't
                    accidentally serve a logged-in user's cached
                    response to an anonymous visitor.

              Operator-side setup (DNS, origin-pull config, page
              rule that caches HTML for ~60s) is the operator's
              responsibility — see
              docs/agent-notes/landing-page-edge-fronting.md.
            '';
          };

          provider = lib.mkOption {
            type = lib.types.enum [ "cloudflare" "bunny" "custom" ];
            default = "cloudflare";
            description = ''
              Which CDN provider is fronting the site. Determines
              the default `trustedProxies` CIDRs (Cloudflare's and
              bunny.net's are pre-populated below). `custom` means
              the operator MUST supply `trustedProxies` explicitly.
            '';
          };

          trustedProxies = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [];
            description = ''
              Additional CIDRs to add to Caddy's `trusted_proxies`.
              Concatenated with the provider's built-in list when
              `provider` is `cloudflare` or `bunny`; required and
              the sole source of trusted proxies when `provider`
              is `custom`.

              Trusted proxies tell Caddy which front-end IPs are
              allowed to set `X-Forwarded-For` (and equivalents) —
              every other source is treated as the actual client
              and its raw remote IP is what `{remote_host}` resolves
              to. Misconfiguring this either ignores the real
              client IP (fail2ban then bans the CDN edge — useless)
              or trusts an attacker's IP-spoofing claim — get it
              right.

              CIDRs only. Keep this list in sync with the CDN's
              published edge ranges; Cloudflare and bunny.net both
              publish a canonical URL the operator should
              periodically diff.
            '';
          };

          originSharedSecretEnv = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            example = "EDGE_ORIGIN_SECRET";
            description = ''
              Name of an environment variable (loaded into Caddy
              via EnvironmentFile) that holds a shared secret the
              CDN must send on every origin-pull request — Caddy
              rejects requests that don't carry it. Closes the
              origin-bypass hole: without it, an attacker who knows
              the box's IP can simply skip the CDN and hammer the
              origin directly, defeating the whole point of edge
              fronting.

              Operator workflow:
                1. Generate a high-entropy secret
                   (`openssl rand -hex 32`).
                2. Write it into the env file Caddy already loads,
                   under whatever variable name this option is set
                   to.
                3. Configure the CDN to add it as a custom
                   request header on every origin pull — for
                   Cloudflare this is a Transform Rule or a Worker;
                   for bunny.net a custom origin header.
                4. The header name Caddy expects is fixed at
                   `X-Edge-Origin-Auth`.

              Leaving this `null` disables the origin-bypass check
              — strongly discouraged; without it the CDN gives no
              real protection.
            '';
          };
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

      caddy = {
        resources = {
          memoryHigh = lib.mkOption {
            type = lib.types.str;
            default = "512M";
            description = ''
              systemd `MemoryHigh=` for caddy.service — the soft
              throttling threshold. Above this the kernel reclaims
              caddy's memory aggressively while letting it keep
              running, slowing the runaway without OOM-killing.
              Combined with `memoryMax` (hard cap) this bounds
              caddy's memory blast radius during a traffic surge so
              the rest of the system (sshd, admin-api, monitoring)
              stays responsive even when caddy is overloaded.

              Default is conservative for a 4 GB / 4-core minimum
              target. Raise on larger boxes where you'd rather
              caddy use the headroom.
            '';
          };

          memoryMax = lib.mkOption {
            type = lib.types.str;
            default = "1G";
            description = ''
              systemd `MemoryMax=` for caddy.service — the hard
              memory cap. If exceeded the kernel OOM-kills caddy
              (it then auto-restarts via the catalog Restart=always
              policy in modules/service-restart-policy.nix). The
              floor below which caddy cannot grow further; tune up
              if you legitimately need more (huge proxied response
              bodies, lots of TLS sessions).
            '';
          };

          cpuWeight = lib.mkOption {
            type = lib.types.ints.between 1 10000;
            default = 200;
            description = ''
              systemd `CPUWeight=` for caddy.service. Default
              weight is 100; raising to 200 gives caddy a 2x share
              of CPU under contention vs an unweighted service.
              This is a *relative* share, not a cap — under no
              contention caddy uses whatever it needs. Under
              contention (a load spike), caddy gets priority over
              background batch jobs but yields to anything else
              weighted equally.
            '';
          };

          tasksMax = lib.mkOption {
            type = lib.types.ints.positive;
            default = 4096;
            description = ''
              systemd `TasksMax=` for caddy.service — the cap on
              the number of pids/tasks caddy's cgroup may spawn.
              Bounds runaway-goroutine / connection blowups. 4 096
              is far above caddy's steady-state needs (which sit in
              the hundreds even under load), but low enough that a
              pathological growth halts before the kernel-wide
              pids.max is exhausted.
            '';
          };
        };
      };
    };

    ## Resolved label → host-port mapping. Populated by
    ## services/port-allocator/default.nix from the union of all
    ## `service-config[].port-request` values. Apps read this via
    ## `config.homefree.ports.<label>` and `config.homefree.allocPort`.
    ports = lib.mkOption {
      type = with lib.types; attrsOf int;
      default = {};
      internal = true;
      description = ''
        Resolved app-label → host-port mapping produced by the port
        allocator. Read-only from outside the allocator module — set
        each service's port via `service-config[].port-request`.
      '';
    };

    ## Convenience accessor — `config.homefree.allocPort "ollama"`
    ## returns the resolved port and throws a clear error if no
    ## service with that label requested one. Just sugar over
    ## `config.homefree.ports.<label>` with a better failure mode.
    allocPort = lib.mkOption {
      type = lib.types.functionTo lib.types.int;
      internal = true;
      default = _label: throw
        "homefree.allocPort: port allocator not loaded; import services/port-allocator";
      description = ''
        Returns the host-port the allocator assigned to the named
        service. Use in app `default.nix` `let` blocks instead of
        hardcoding integers:

          let port = config.homefree.allocPort "ollama"; in ...
      '';
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

          ## Optional pin for the host-side TCP port the service binds.
          ## `null` (default) means "any port from the auto pool" — the
          ## port-allocator in services/port-allocator picks one
          ## deterministically. An integer means "I need this exact
          ## number, fail the build if it collides with anyone else"
          ## (Forgejo SSH 3022, Minecraft 25565, AdGuard DNS 53, etc.).
          ##
          ## Apps consume the resolved value via
          ## `config.homefree.ports.<label>` — NEVER by hardcoding the
          ## same integer in their own `default.nix`, which would
          ## defeat the deconfliction. See
          ## docs/agent-notes/port-allocator.md for the migration
          ## pattern from a `let port = NNNN;` block to the helper.
          port-request = lib.mkOption {
            type = lib.types.nullOr lib.types.int;
            default = null;
            description = ''
              Optional pin for this service's host-side port.

              `null` → the allocator picks one from its auto pool.
              `<int>` → this exact port is reserved; build fails if it
                collides with another pinned service.
            '';
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

            strip-cookies = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = ''
                When true, Caddy removes the inbound Cookie header
                (`header_up -Cookie`) before forwarding to this
                upstream. Default is off (cookies pass through).

                Set this for buffer-constrained embedded HTTP servers
                — the same class of appliance as `disable-keepalive`
                (OpenSprinkler, some smart-home gear, older NAS admin
                pages). HomeFree's SSO session cookie is scoped to the
                parent domain (oauth2-proxy's COOKIE_DOMAINS), so the
                browser attaches the large, chunked oauth2 cookie to
                every `<sub>.<domain>` request — including non-SSO
                external proxies. A tiny appliance with a ~2 KB request
                buffer overflows on it and returns "The request was too
                large". These appliances do not use cookies, so dropping
                the header is safe. Leave off for normal apps, which
                need their cookies.
              '';
            };

            extra-csp-sources = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [];
              example = [ "https://ui.opensprinkler.com" ];
              description = ''
                Extra origins appended to THIS vhost's Content-Security-
                Policy fetch directives (script-src, style-src, img-src,
                font-src, connect-src), on top of the same-origin +
                `*.<domain>` baseline.

                Almost always leave empty — HomeFree's own pages must
                never load third-party assets (see AGENTS.md rule 8).
                The escape hatch exists for proxied THIRD-PARTY
                appliances whose own UI bootstraps from a vendor CDN —
                e.g. OpenSprinkler firmware serves a tiny HTML shell that
                pulls its JavaScript from https://ui.opensprinkler.com.
                Listing that origin here lets the device's UI load.

                This necessarily loosens this one vhost's CSP and makes
                the page issue off-box requests, so prefer self-hosting
                the asset where the device supports repointing it. Only
                affects external-proxy / non-static vhosts.
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

            staticCachePolicy = lib.mkOption {
              type = lib.types.enum [ "no-store" "vendor-hashed" ];
              default = "no-store";
              description = ''
                Cache-Control policy for `static-path`-served sites
                (no effect on reverse-proxied upstreams).

                `"no-store"` (default): every response gets
                `Cache-Control: no-store`, ETag/Last-Modified
                stripped, and inbound If-Modified-Since/If-None-Match
                stripped. This is the correct policy for application
                surfaces (`web-platform/frontend`, homefree-cli's
                static dir, anything that's live JS/HTML code served
                out of /nix/store) — it prevents the
                epoch-mtime 304 trap that would otherwise serve stale
                JS after a rebuild.

                `"vendor-hashed"`: HTML and unhashed assets still get
                the no-store treatment above (so newly-deployed pages
                are always seen immediately and the epoch-mtime 304
                trap stays defused), but URLs carrying a `?v=<hash>`
                query string — the Eleventy `assetVersion` filter's
                output — additionally get
                `Cache-Control: public, max-age=31536000, immutable`.
                Because the URL itself changes whenever the file
                changes, a stale cached asset can never be served.
                Intended for the static marketing landing page +
                manual, where aggressive browser/edge caching of
                hashed assets is the key resilience lever under a
                traffic surge (Hacker News, Reddit) without risking
                content drift on a rebuild.
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

      require-mountpoint = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          Mount point that must be a live mountpoint before any LOCAL restic
          backup runs. Guards against writing to a stub directory on the root
          filesystem (and initializing an empty repo that shadows the real one)
          when a NAS/backup volume is unmounted.

          Leave null for backup targets that live on a normal local disk; when
          null the required mount is auto-derived as the longest
          `homefree.mounts` mount-point that `to-path` sits under (if any), so
          deployments whose backup target lives on a managed NAS mount are
          protected automatically. Set this explicitly when the backup target
          lives on a filesystem declared outside `homefree.mounts` (e.g. a raw
          `fileSystems` entry).
        '';
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
              id = lib.mkOption {
                type = lib.types.str;
                default = "";
                description = ''
                  Stable identifier for this entry. Owns the restic
                  repository label (extra-path-<id>) so the repo
                  identity is independent of array position — deleting
                  or reordering rows never reassigns an existing
                  repository to a different source path. Existing
                  deployments are migrated to id = the original array
                  index by an on-activation step; new entries allocate
                  the next unused integer. When empty (legacy entries
                  that have not yet hit the migration), the backup
                  module falls back to the current array index to
                  preserve existing labels.
                '';
              };
              path = lib.mkOption {
                type = lib.types.str;
                description = "Source directory to back up";
              };
              enabled = lib.mkOption {
                type = lib.types.bool;
                default = true;
                description = ''
                  Whether this path is currently included in scheduled
                  backups. Disabling preserves the entry's restic
                  repository so re-enabling later resumes against the
                  same snapshot history. Deletion is also safe — the
                  repo is orphaned in place, not reassigned.
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
            path = "require-mountpoint";
            type = "str";
            nullable = true;
            default = null;
            description = "Mount point that must be mounted before local backups run (guards against writing to a stub on the root filesystem when a NAS/backup volume is unmounted). Leave empty for local-disk targets; auto-derived from homefree.mounts when empty.";
          }
          {
            path = "extra-from-paths";
            type = "listOf submodule";
            default = [];
            description = "Additional custom paths to include in backups";
            submodule-fields = [
              {
                path = "id";
                type = "str";
                default = "";
                description = "Stable identifier owning the restic repo label (extra-path-<id>). Allocated automatically; not user-edited.";
                hidden = true;
              }
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
    ## Composition glue: project each service-config entry's backup fields into
    ## the generic homefree.internal.backup-sources registry that the backup
    ## primitive consumes. This homefree-specific mapping keeps the backup
    ## module itself free of the service-config schema (registry middle-path).
    homefree.internal.backup-sources = lib.map
      (entry: {
        inherit (entry) label;
        inherit (entry.backup) paths postgres-databases mysql-databases;
      })
      config.homefree.service-config;

    ## Composition glue: project the ingress-relevant fields of each
    ## service-config entry into the generic ingress-vhosts registry that the
    ## caddy generator consumes (it reads only label + reverse-proxy).
    homefree.internal.ingress-vhosts = lib.map
      (entry: { inherit (entry) label reverse-proxy firewall; })
      config.homefree.service-config;

    ## Composition glue for the remaining generic-primitive consumers (port
    ## allocator, restart policy) — same pattern, narrow projections.
    homefree.internal.port-requests = lib.map
      (entry: { inherit (entry) label port-request; })
      config.homefree.service-config;

    homefree.internal.managed-units = lib.map
      (entry: { inherit (entry) label enable systemd-service-names; })
      config.homefree.service-config;

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
      (if config.homefree.services.landing-page.path == options.homefree.services.landing-page.path.default
          && !config.homefree.services.landing-page.suppressDefaultWarning then [
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
