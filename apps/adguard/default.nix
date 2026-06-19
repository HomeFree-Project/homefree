{ config, lib, pkgs, ... }:
let
  version = "v0.108.0-b.88";
  image = "adguard/adguardhome:${version}";
  containerDataPath = "/var/lib/adguardhome-podman";
  port = config.homefree.allocPort "adguard";

  ## Does lan-address actually land on a NIC? Only router mode
  ## (profiles/router.nix) and the static-IP module (modules/lan-static-ip.nix)
  ## assign it. In plain non-router mode the box leases its address via DHCP and
  ## lan-address is on NO interface, so binding services to it fails. Mirrors the
  ## gate in services/caddy and services/unbound.
  lan-address-assigned = config.homefree.network.router.enable || config.homefree.network.static.enable;

  ## DNS listener (:53). We CANNOT fall back to 0.0.0.0 here: port 53 is already
  ## held by systemd-resolved (127.0.0.53/.54) and podman's aardvark-dns
  ## (10.88.0.1), so a 0.0.0.0:53 bind dies with "address already in use" and
  ## the container crash-loops — taking LAN DNS and the dns-ready gate (which
  ## fronts every app) down with it. Router/static mode dodges those by binding
  ## the known lan-address; in DHCP mode the box's LAN IP isn't known at eval
  ## time, so the YAML carries an @@ADGUARD_LAN_IP@@ placeholder that preStart
  ## resolves to the leased address (src of the default route) at runtime, bound
  ## alongside 127.0.0.1. unbound always binds loopback, so the AdGuard->unbound
  ## upstream link uses a concrete self address (lan-address or 127.0.0.1).
  dns-bind-hosts =
    if lan-address-assigned
    then [ "${config.homefree.network.lan-address}" "127.0.0.1" "${config.homefree.network.lan-address-v6}" ]
    else [ "127.0.0.1" "@@ADGUARD_LAN_IP@@" ];
  ## DNS port-publish list (cosmetic under --network=host, which discards -p, but
  ## kept in parallel with bind_hosts). 0.0.0.0 would be the same conflict, so
  ## in DHCP mode publish loopback only.
  dns-publish-ports =
    if lan-address-assigned
    then [
      "${config.homefree.network.lan-address}:53:53/tcp"
      "${config.homefree.network.lan-address}:53:53/udp"
      "127.0.0.1:53:53/tcp"
      "127.0.0.1:53:53/udp"
    ]
    else [
      "127.0.0.1:53:53/tcp"
      "127.0.0.1:53:53/udp"
    ];

  ## Web UI (the allocated port, NOT 53 — uncontended, so 0.0.0.0 is fine and
  ## keeps emergency LAN-direct access working). Caddy fronts it and must reach
  ## it over a live address: lan-address in router/static mode, loopback in DHCP
  ## mode (lan-address is dead there).
  listen-address = if lan-address-assigned then config.homefree.network.lan-address else "0.0.0.0";
  caddy-upstream-host = if lan-address-assigned then config.homefree.network.lan-address else "127.0.0.1";
  unbound-upstream-host = if lan-address-assigned then config.homefree.network.lan-address else "127.0.0.1";

  settings = {
    http = {
      address = "${listen-address}:${toString port}";
      session_ttl = "720h";
    };
    ## AdGuard requires a non-empty `users:` block — an empty list
    ## triggers its first-run setup wizard, which we don't want.
    ## But we don't want a hardcoded credential either: the SSO-only
    ## rule says no per-service local passwords. So we declare a
    ## sentinel hash here and rewrite it at preStart with a random
    ## per-install bcrypt hash. The plaintext is stashed in
    ## /var/lib/homefree-secrets/adguard/admin-password for emergency
    ## LAN-direct access (if SSO is broken and the Caddy gate has to
    ## be bypassed) — root-only, never shown in the UI.
    users = [
      {
        name = config.homefree.system.adminUsername;
        password = "@@ADGUARD_PASSWORD_HASH@@";
      }
    ];
    auth_attempts = 5;
    block_auth_min = 15;
    theme = "auto";
    dns = {
      ## Must specify interfaces, otherwise it conflicts with podman.
      ## Tailscale-interface DNS reachability is provided by a separate
      ## dnsmasq forwarder defined in apps/headscale/default.nix that
      ## listens on tailscale0 with --bind-dynamic and forwards here.
      ## See that file for rationale (Tailscale-IP isn't known at Nix
      ## eval time; --bind-dynamic + --interface=tailscale0 binds at
      ## runtime to whatever IP tailscaled assigns).
      bind_hosts = dns-bind-hosts;
      port = 53;
      anonymize_client_ip = false;
      ratelimit = 0;
      ratelimit_subnet_len_ipv4 = 24;
      ratelimit_subnet_len_ipv6 = 56;
      ratelimit_whitelist = [];
      refuse_any = true;
      upstream_dns = [
        # "127.0.0.1:53530"
        "${unbound-upstream-host}:53530"
        # "https://dns10.quad9.net/dns-query"
      ];
      bootstrap_dns = [
        "9.9.9.10"
        "149.112.112.10"
        "2620:fe::10"
        "2620:fe::fe:10"
      ];
      upstream_mode = "parallel";
      fastest_timeout = "1s";
      blocked_hosts = [
        "version.bind"
        "id.server"
        "hostname.bind"
      ];
      trusted_proxies = [
        "127.0.0.0/8"
        "::1/128"
      ];
      cache_size = 128000000;
      cache_ttl_min = 3600;
      cache_ttl_max = 86400;
      cache_optimistic = true;
      aaaa_disabled = false;
      enable_dnssec = false;
      edns_client_subnet = {
        custom_ip = "";
        enabled = false;
        use_custom = false;
      };
      max_goroutines = 2000;
      handle_ddr = true;
      ipset = [];
      ipset_file = "";
      bootstrap_prefer_ipv6 = false;
      upstream_timeout = "10s";
      private_networks = [];
      use_private_ptr_resolvers = true;
      local_ptr_upstreams = [];
      use_dns64 = false;
      dns64_prefixes = [];
      serve_http3 = false;
      use_http3_upstreams = false;
      serve_plain_dns = true;
      hostsfile_enabled = true;
    };
    filters = [
      {
        enabled = true;
        url = "https://adguardteam.github.io/HostlistsRegistry/assets/filter_1.txt";
        name = "AdGuard DNS filter";
        id = 1;
      }
      {
        enabled = false;
        url = "https://adguardteam.github.io/HostlistsRegistry/assets/filter_2.txt";
        name = "AdAway Default Blocklist";
        id = 2;
      }
      {
        enabled = true;
        url = "https://adguardteam.github.io/HostlistsRegistry/assets/filter_7.txt";
        name = "Perflyst and Dandelion Sprout's Smart-TV Blocklist";
        id = 7;
      }
      {
        enabled = true;
        url = "https://raw.githubusercontent.com/hagezi/dns-blocklists/main/adblock/pro.txt";
        name = "HaGeZi's Pro DNS Blocklist";
        id = 99;
      }
    ];
    whitelist_filters = [];
    user_rules = [
    ];
    dhcp = {
      enabled = false;
    };
    filtering = {
      blocking_ipv4 = "";
      blocking_ipv6 = "";
      blocked_services = {
        schedule = {
          time_zone = "Local";
        };
        ids = [];
      };
      protection_disabled_until = null;
      safe_search = {
        enabled = false;
        bing = true;
        duckduckgo = true;
        google = true;
        pixabay = true;
        yandex = true;
        youtube = true;
      };
      blocking_mode = "default";
      parental_block_host = "family-block.dns.adguard.com";
      safebrowsing_block_host = "standard-block.dns.adguard.com";
      rewrites = [];
      safebrowsing_cache_size = 1048576;
      safesearch_cache_size = 1048576;
      parental_cache_size = 1048576;
      cache_time = 30;
      filters_update_interval = 24;
      blocked_response_ttl = 10;
      filtering_enabled = true;
      parental_enabled = false;
      safebrowsing_enabled = false;
      protection_enabled = true;
    };
    clients = {
      runtime_sources = {
        whois = true;
        arp = true;
        rdns = true;
        dhcp = true;
        hosts = true;
      };
      persistent = [];
    };
    log = {
      file = "";
      max_backups = 0;
      max_size = 100;
      max_age = 3;
      compress = false;
      local_time = false;
      verbose = false;
    };
    schema_version = 28;
  };

  config-yaml = (pkgs.formats.yaml {}).generate "AdGuardHome.yaml" settings;

  adguardSecretsDir = "/var/lib/homefree-secrets/adguard";

  ## Anchors auto-generated secrets into encrypted /etc/nixos/secrets
  ## so they survive a restore — see lib/secrets-anchor.nix.
  anchor = import ../../lib/secrets-anchor.nix { inherit lib pkgs; };

  userOptions = {
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
in
{
  options.homefree.services.adguard = userOptions;

  options.homefree.service-options.adguard = userOptions // {
    # Metadata - always available, not user-configurable
    label = lib.mkOption {
      type = lib.types.str;
      default = "adguard";
      internal = true;
      description = "Service label";
    };

    name = lib.mkOption {
      type = lib.types.str;
      default = "Ad Blocker";
      internal = true;
      description = "Service display name";
    };

    project-name = lib.mkOption {
      type = lib.types.str;
      default = "AdGuard Home";
      internal = true;
      description = "Project name";
    };
  };

  config = {
    ## Container via the app-platform primitive (modules/app-platform.nix).
    ## The dns-ready podman unit ordering and ExecStartPre are generated.
    ## Extra unit properties (restartTriggers, unitConfig, ExecStopPost,
    ## LimitNOFILE, Restart override) are in the separate
    ## systemd.services.podman-adguardhome block below.
    homefree.containers.adguardhome = lib.mkIf config.homefree.service-options.adguard.enable {
      ## AdGuard Home requires root for DNS ports (<1024) and --network=host.
      runAs = {
        mode = "root";
        reason = "needs root for DNS port 53 binding and --network=host; CAP_NET_BIND_SERVICE alone is insufficient with --network=host";
      };
      image = image;

      ## AdGuard IS the box's LAN resolver, so it must NOT order itself
      ## after dns-ready — dns-ready is ordered after *it*
      ## (services/unbound/default.nix `dnsUnits`). Leaving the
      ## app-platform default (dnsReady = true) creates a systemd ordering
      ## cycle (podman-adguardhome -> dns-ready -> podman-adguardhome) that
      ## systemd breaks by deleting one job at random: on the boots where it
      ## drops podman-adguardhome's start job, AdGuard never comes up and the
      ## box has no DNS ("no internet"). AdGuard bootstraps its own image
      ## pull via the temporary adguardhome-dns-proxy (preStartInit below),
      ## so it doesn't need the dns-ready gate.
      dnsReady = false;

      ## preStart anchors the admin password, splices the bcrypt hash
      ## into the config YAML, and manages a temporary DNS proxy for
      ## image pulls — all of which goes in preStartInit (dataDir = null).
      dataDir = null;
      preStartInit = ''
        mkdir -p ${containerDataPath}/conf
        mkdir -p ${containerDataPath}/work
        mkdir -p ${adguardSecretsDir}
        chmod 700 ${adguardSecretsDir}

        ${anchor.preamble}

        ## ── Random per-install admin password ──────────────────────────
        ## The plaintext password is anchored into encrypted
        ## /etc/nixos/secrets so it survives a restore
        ## (lib/secrets-anchor.nix). Stored mode 0400 for emergency LAN
        ## access; the bcrypt hash (spliced into AdGuardHome.yaml) is a
        ## DERIVATIVE — re-derived via extraInstall whenever it is missing,
        ## not anchored itself (its random salt would change every boot).
        ${anchor.anchorSecret {
          service = "adguard";
          key = "admin-password";
          dir = adguardSecretsDir;
          mkdirMode = null;
          mode = "400";
          generate = "${pkgs.openssl}/bin/openssl rand -base64 32 | tr -d '\\n'";
          extraInstall = ''
            if [ ! -s ${adguardSecretsDir}/admin-password.bcrypt ]; then
              # htpasswd -bnBC 10 produces `username:$2y$10$...`; we want
              # only the hash. -b takes the password on the command line.
              HASH=$(${pkgs.apacheHttpd}/bin/htpasswd -bnBC 10 "" \
                "$(cat ${adguardSecretsDir}/admin-password)" \
                | tr -d '\n' \
                | sed 's/^://')
              printf '%s' "$HASH" > ${adguardSecretsDir}/admin-password.bcrypt
              chmod 400 ${adguardSecretsDir}/admin-password.bcrypt
            fi
          '';
        }}

        ## Splice the bcrypt hash into the generated YAML. We can't put
        ## the real hash in the Nix expression because (a) it's random per
        ## install and (b) Nix store contents are world-readable, which
        ## would defeat the secrecy.
        HASH=$(cat ${adguardSecretsDir}/admin-password.bcrypt)
        # Escape characters that have meaning to sed's replacement side:
        # &, /, and our delimiter |. The hash contains $ and . which are
        # fine in the replacement context.
        ESCAPED_HASH=$(printf '%s' "$HASH" | sed -e 's/[&|]/\\&/g')
        ${pkgs.gnused}/bin/sed \
          "s|@@ADGUARD_PASSWORD_HASH@@|$ESCAPED_HASH|" \
          ${config-yaml} > ${containerDataPath}/conf/AdGuardHome.yaml${lib.optionalString (!lan-address-assigned) ''

        ## Non-router DHCP mode only: the DNS listener carries an
        ## @@ADGUARD_LAN_IP@@ placeholder because the box's leased LAN IP isn't
        ## known at eval time. Resolve it in a second pass — the src of the
        ## default route is the leased address and never the podman bridge
        ## (10.88.0.1). If there's no lease yet, drop the placeholder line so
        ## AdGuard still starts on 127.0.0.1 instead of failing to parse a
        ## literal "@@...@@". This whole block is ABSENT in router/static mode,
        ## so their prestart script (and its unit hash) is byte-for-byte unchanged.
        ADGUARD_LAN_IP=$(${pkgs.iproute2}/bin/ip -4 route get 1.1.1.1 2>/dev/null \
          | ${pkgs.gnugrep}/bin/grep -oP 'src \K[0-9.]+' \
          | ${pkgs.coreutils}/bin/head -1 || true)
        if [ -n "$ADGUARD_LAN_IP" ]; then
          ${pkgs.gnused}/bin/sed -i "s|@@ADGUARD_LAN_IP@@|$ADGUARD_LAN_IP|g" ${containerDataPath}/conf/AdGuardHome.yaml
        else
          ${pkgs.gnused}/bin/sed -i "/@@ADGUARD_LAN_IP@@/d" ${containerDataPath}/conf/AdGuardHome.yaml
        fi''}
        chmod 600 ${containerDataPath}/conf/AdGuardHome.yaml

        ## After (re)generating the AdGuard admin password, refresh
        ## Caddy's Basic-Auth bridge so the reverse-proxy header reflects
        ## the current credential. Two-step:
        ##   1. Restart the bridge (rewrites the env file).
        ##   2. Reload Caddy so it re-reads EnvironmentFile.
        ##
        ## `--no-block` everywhere so we never deadlock on Caddy's own
        ## activation. If Caddy isn't running yet (initial boot), both
        ## commands silently no-op and Caddy will pick up the file when
        ## systemd starts it next.
        systemctl restart --no-block caddy-adguard-basic-auth.service \
          2>/dev/null || true
        systemctl reload --no-block caddy.service 2>/dev/null || true

        ## Pull the image ONLY when it isn't already present locally.
        ##
        ## AdGuard IS the box's LAN resolver, so making its startup depend on
        ## a working DNS lookup is a circular dependency: on a cold boot the
        ## WAN path (default route / upstream DoT reachability) often isn't
        ## usable yet even after network-online.target fires, so unbound can't
        ## resolve registry-1.docker.io and an unconditional `podman pull`
        ## dies with "no such host". That fails the unit and crash-loops it,
        ## leaving the whole LAN without DNS until the retries happen to land
        ## after the network settles (or someone restarts it by hand).
        ##
        ## The image only needs to be fetched on the FIRST boot or after a
        ## version bump (the pinned, immutable tag changes, so `image exists`
        ## returns false and we pull the new one). On every ordinary reboot
        ## the image is already cached, so we skip the pull entirely and
        ## AdGuard comes up immediately with NO dependency on DNS/WAN. The
        ## ExecStart `podman run` uses pull policy "missing", so it never
        ## reaches the registry when the image is present either.
        ##
        ## When we DO need to fetch (image absent), there is no DNS at :53
        ## yet, so stand up the temporary dns-proxy for the pull. If the pull
        ## fails here (genuinely cold network on a first boot), the unit fails
        ## and systemd retries — the intended behaviour for that case.
        if ! ${pkgs.podman}/bin/podman image exists ${image}; then
          # Start the DNS proxy service (systemd manages its lifecycle)
          systemctl start adguardhome-dns-proxy.service

          # Ensure the proxy is stopped even if the script fails
          trap "systemctl stop adguardhome-dns-proxy.service 2>/dev/null || true" EXIT

          # Give the proxy a moment to start listening
          sleep 1

          # Pull the container image (DNS now available via proxy)
          ${pkgs.podman}/bin/podman pull ${image}

          # Stop the proxy service (AdGuard Home will take over port 53)
          systemctl stop adguardhome-dns-proxy.service
        fi
      '';

      extraOptions = [
        # "--pull=never"
        # "--pull=always"
        "--network=host"
        "--cap-add=NET_BIND_SERVICE"
        "--ulimit=host"
      ];

      ports = [
        ## Web UI
        "0.0.0.0:${toString port}:${toString port}"
      ]
      ## Standard DNS
      ## Must specify interfaces, otherwise it conflicts with podman.
      ## (See dns-publish-ports — never 0.0.0.0, which collides with
      ## systemd-resolved / aardvark-dns on :53.)
      ++ dns-publish-ports
      ++ [
        ## DNS-over-TLS
        "853:853/tcp"

        ## DNS-over-QUIC
        "784:784/udp"
        "853:853/udp"
        "8853:8853/udp"

        ## DNSCrypt
        "5443:5443/tcp"
        "5443:5443/udp"

        ## DHCP
        # "67:67/udp"
        # "68:68/udp"
        # "80:80/tcp"

        ## HTTPS/DNS-over-HTTPS
        # "443:443/tcp"
        # "443:443/udp"
      ];

      volumes = [
        "/etc/localtime:/etc/localtime:ro"
        "${containerDataPath}/conf:/opt/adguardhome/conf"
        "${containerDataPath}/work:/opt/adguardhome/work"
      ];

      environment = {
        TZ = config.homefree.system.timeZone;
      };
    };

    environment.etc."podman-adguardhome-dns.conf".text = ''
      nameserver 127.0.0.1:53530
    '';

    # Dedicated systemd service for temporary DNS proxy during image pull
    # Not auto-started; manually controlled by preStart script
    systemd.services.adguardhome-dns-proxy = lib.mkIf config.homefree.service-options.adguard.enable {
      description = "Temporary DNS proxy for AdGuard Home startup";
      after = [ "unbound.service" ];
      wants = [ "unbound.service" ];
      serviceConfig = {
        Type = "simple";
        # Use dnsmasq instead of socat - properly handles concurrent UDP DNS queries
        ExecStart = "${pkgs.dnsmasq}/bin/dnsmasq --no-daemon --bind-interfaces --listen-address=127.0.0.1 --listen-address=::1 --port=53 --server=127.0.0.1#53530 --no-resolv --no-hosts --log-queries";
        Restart = "no";
        # Clean shutdown
        KillMode = "process";
        KillSignal = "SIGTERM";
        TimeoutStopSec = 5;
        SuccessExitStatus = 143;
      };
    };

    ## Extra unit properties for the generated podman-adguardhome unit, merged
    ## with the dns-ready ordering and ExecStartPre from the primitive.
    systemd.services.podman-adguardhome = lib.mkIf config.homefree.service-options.adguard.enable {
      after = [ "unbound.service" ];
      wants = [ "unbound.service" ];
      ## AdGuard is the front-end resolver and caches whatever unbound
      ## returns. With `cache_optimistic = true` and `cache_ttl_min =
      ## 3600` it will keep serving a stale answer for up to 12h. When a
      ## service is toggled public<->private, unbound's local-zone /
      ## local-data records change (e.g. a private service's AAAA flips
      ## between the inside LAN ULA and the public WAN address) — but
      ## AdGuard would go on handing clients the old record, so the service
      ## appears unreachable (IPv6-preferring clients connect to the wrong
      ## address and get a blank page). Restarting AdGuard whenever unbound's
      ## config changes flushes its cache so the new records take effect
      ## immediately.
      restartTriggers = [
        (builtins.toJSON config.services.unbound.settings)
      ];
      ## StartLimitBurst / StartLimitIntervalSec are [Unit]-section directives;
      ## putting them under serviceConfig renders them into [Service] where
      ## systemd silently ignores them ("Unknown key '...' in section [Service]").
      ## They must go under unitConfig to take effect.
      ##
      ## Bumped from the default-ish 5×60s to 30×600s so a cold-boot pull-retry
      ## window (~7.5 min at RestartSec=15s) can ride out the period during
      ## which unbound's upstream DoT path (TCP/853 to public resolvers) is
      ## not yet reachable post-`network-online.target`. The previous values
      ## were never effective anyway because of the section-placement bug, so
      ## adguardhome was inheriting systemd defaults; this both fixes the
      ## placement and chooses values that actually survive a cold-cache boot.
      unitConfig = {
        StartLimitBurst = 30;
        StartLimitIntervalSec = 600;
      };
      serviceConfig = {
        ExecStopPost = [
          "${pkgs.writeShellScript "adguardhome-cleanup" ''
            # Stop the DNS proxy service if it's still running
            systemctl stop adguardhome-dns-proxy.service 2>/dev/null || true
            # Kill any leftover dnsmasq processes on port 53 (belt and suspenders)
            ${pkgs.procps}/bin/pkill -f "dnsmasq.*--port=53.*--server=127.0.0.1#53530" || true
          ''}"
        ];
        ## Bump ulimit
        LimitNOFILE = 65535;
        Restart = lib.mkForce "on-failure";
        RestartSec = 15;
      };
    };

    homefree.service-config = [{
      inherit (config.homefree.service-options.adguard) label name project-name;
      port-request = null;
      enable = config.homefree.service-options.adguard.enable;
      ## Pinned to AdGuard Home's beta channel (v…-b.NN); each beta build
      ## is its own tag shape, so track the pre-release LINE explicitly
      ## (advances b.88 -> b.90, and would jump to a newer stable too).
      version-tracking = {
        strategy = "docker-hub";
        repo = "adguard/adguardhome";
        channel = "prerelease";
      };
      systemd-service-names = [
        "podman-adguardhome"
      ];
      sso = {
        kind = "basic_auth";
        ## Dev context (intentionally not surfaced in the admin UI):
        ## AdGuard has no native OIDC. Caddy SSO gate validates the
        ## user, then injects an HTTP Basic Auth header with the
        ## AdGuard admin credential so the user never sees AdGuard's
        ## local login.
      };
      reverse-proxy = {
        enable = config.homefree.service-options.adguard.enable;
        subdomains = [ "adguard" ];
        http-domains = [ "homefree.lan" config.homefree.system.localDomain ];
        https-domains = [ config.homefree.system.domain ];
        host = caddy-upstream-host;
        port = port;
        public = config.homefree.service-options.adguard.public;
        ## AdGuard Home has no native OIDC support, so we gate it
        ## entirely at the Caddy layer via oauth2-proxy. The actual
        ## SSO check is enforced at request time by the @no_auth
        ## matcher in services/caddy.nix — pre-provisioning, AdGuard
        ## remains accessible (you can still hit it from the LAN
        ## directly via http://<lan>:3000 too); post-provisioning,
        ## any visit to https://adguard.<domain> requires a valid
        ## Zitadel cookie. Per-service opt-out via
        ## homefree.sso.per-service.adguard.enable=false.
        oauth2 = config.homefree.sso.per-service.adguard.enable or true;
        ## AdGuard manages DNS filtering, blocklists, and client
        ## rules — strictly admin operations. Restrict access to
        ## users carrying the homefree-admin project role. Non-
        ## admin authenticated users hit a 403 at the Caddy gate
        ## without ever reaching AdGuard.
        require-admin-role = true;
        ## After SSO succeeds, inject AdGuard's own admin creds as
        ## HTTP Basic Auth so the user never sees AdGuard's local
        ## login form. The env var is populated by
        ## caddy-adguard-basic-auth.service (services/caddy.nix)
        ## from /var/lib/homefree-secrets/adguard/admin-password.
        inject-basic-auth-env = "ADGUARD_BASIC_AUTH";
        ## AdGuard's UI "Sign out" button POSTs to /control/logout.
        ## Without this intercept it's a no-op: AdGuard clears its
        ## session, Caddy's Basic-Auth injection re-auths the next
        ## request, and the user lands right back where they were.
        ## Caddy catches the path and redirects into the full SSO
        ## sign-out chain. See services/caddy.nix for the redir.
        upstream-logout-paths = [
          "/control/logout"
        ];
      };
      backup = {
        paths = [
          containerDataPath
        ];
      };
      options-metadata = [
        {
          path = "enable";
          type = "bool";
          default = true;
          description = "Enable AdGuard Home Ad Blocking";
        }
        {
          path = "public";
          type = "bool";
          default = false;
          description = "Make service accessible from WAN";
        }
      ];
    }
    {
      label = "adguard-dns";
      name = "AdGuard DNS";
      project-name = "AdGuard Home";
      enable = config.homefree.service-options.adguard.enable;
      port-request = 53;
      reverse-proxy.enable = false;
      admin.show = false;
      systemd-service-names = [];
    }];
  };
}
