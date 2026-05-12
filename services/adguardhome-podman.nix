{ config, lib, pkgs, ... }:
let
  version = "v0.107.73";
  image = "adguard/adguardhome:${version}";
  containerDataPath = "/var/lib/adguardhome-podman";
  port = 3000;

  settings = {
    http = {
      address = "${config.homefree.network.lan-address}:${toString port}";
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
      ## Must specify interfaces, otherwise it conflicts with podman
      bind_hosts = [ "${config.homefree.network.lan-address}" "127.0.0.1" "fd01::1" ];
      port = 53;
      anonymize_client_ip = false;
      ratelimit = 0;
      ratelimit_subnet_len_ipv4 = 24;
      ratelimit_subnet_len_ipv6 = 56;
      ratelimit_whitelist = [];
      refuse_any = true;
      upstream_dns = [
        # "127.0.0.1:53530"
        "${config.homefree.network.lan-address}:53530"
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

  preStart = ''
    mkdir -p ${containerDataPath}/conf
    mkdir -p ${containerDataPath}/work
    mkdir -p ${adguardSecretsDir}
    chmod 700 ${adguardSecretsDir}

    ## ── Random per-install admin password ──────────────────────────
    ## Generate once and reuse across restarts so existing sessions
    ## (if any) don't get invalidated. Stored as plaintext in the
    ## secrets dir (mode 0400) for emergency LAN access; the bcrypt
    ## hash is what gets spliced into AdGuardHome.yaml.
    if [ ! -s ${adguardSecretsDir}/admin-password ] \
       || [ ! -s ${adguardSecretsDir}/admin-password.bcrypt ]; then
      ${pkgs.openssl}/bin/openssl rand -base64 32 \
        | tr -d '\n' \
        > ${adguardSecretsDir}/admin-password
      chmod 400 ${adguardSecretsDir}/admin-password
      # htpasswd -bnBC 10 produces `username:$2y$10$...`; we want
      # only the hash. -i reads from stdin; we use -b with the
      # password on the command line because htpasswd doesn't
      # accept a hash-only output mode.
      HASH=$(${pkgs.apacheHttpd}/bin/htpasswd -bnBC 10 "" \
        "$(cat ${adguardSecretsDir}/admin-password)" \
        | tr -d '\n' \
        | sed 's/^://')
      printf '%s' "$HASH" > ${adguardSecretsDir}/admin-password.bcrypt
      chmod 400 ${adguardSecretsDir}/admin-password.bcrypt
    fi

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
      ${config-yaml} > ${containerDataPath}/conf/AdGuardHome.yaml
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

    ## There is no DNS running yet at port 53, so start a temporary
    ## proxy service (managed by systemd) so that podman pull works

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
  '';
in
{
  options.homefree.service-options.adguard = {
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
    virtualisation.oci-containers.containers = lib.optionalAttrs config.homefree.service-options.adguard.enable {
    adguardhome = {
      image = image;

      autoStart = true;

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

        ## Standard DNS
        ## Must specify interfaces, otherwise it conflicts with podman
        "${config.homefree.network.lan-address}:53:53/tcp"
        "${config.homefree.network.lan-address}:53:53/udp"
        "127.0.0.1:53:53/tcp"
        "127.0.0.1:53:53/udp"

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
  };

  environment.etc."podman-adguardhome-dns.conf".text = ''
    nameserver 127.0.0.1:53530
  '';

  # Dedicated systemd service for temporary DNS proxy during image pull
  # Not auto-started; manually controlled by preStart script
  systemd.services.adguardhome-dns-proxy = lib.optionalAttrs config.homefree.service-options.adguard.enable {
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

  systemd.services.podman-adguardhome =lib.optionalAttrs config.homefree.service-options.adguard.enable {
    after = [ "unbound.service" ];
    wants = [ "unbound.service" ];
    serviceConfig = {
      ExecStartPre = [ "!${pkgs.writeShellScript "adguardhome-prestart" preStart}" ];
      # Cleanup any leftover DNS proxy processes on service stop/restart/failure
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
      ## Limit restart attempts to prevent socat accumulation
      StartLimitBurst = 5;
      StartLimitIntervalSec = 60;
      Restart = lib.mkForce "on-failure";
      RestartSec = 10;
    };
  };

    homefree.service-config = [{
      inherit (config.homefree.service-options.adguard) label name project-name;
      systemd-service-names = [
        "podman-adguardhome"
      ];
      reverse-proxy = {
        enable = config.homefree.service-options.adguard.enable;
        subdomains = [ "adguard" ];
        http-domains = [ "homefree.lan" config.homefree.system.localDomain ];
        https-domains = [ config.homefree.system.domain ];
        host = config.homefree.network.lan-address;
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
    }];
  };
}

