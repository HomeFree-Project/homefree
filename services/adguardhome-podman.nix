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
    users = [
      {
        name = config.homefree.system.adminUsername;
        password = "$2a$10$Tt4QvbLQxnspv2TbcLMP7ug8eJ0NqMsGyVPbpEqtmkyCVrFpvh4GS";
        # password = config.homefree.system.adminHashedPassword;
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

  preStart = ''
    mkdir -p ${containerDataPath}/conf
    mkdir -p ${containerDataPath}/work

    cp ${config-yaml} ${containerDataPath}/conf/AdGuardHome.yaml

    ## Kill any existing socat instances from previous failed starts
    pkill -f "socat.*127.0.0.1:53.*127.0.0.1:53530" || true

    ## There is no DNS running yet at port 53, so create a temporary
    ## proxy so that podman pull works
    # Start a temporary socat proxy from 53 to 53530
    ${pkgs.socat}/bin/socat UDP4-LISTEN:53,fork,bind=127.0.0.1 UDP4:127.0.0.1:53530 &
    SOCAT_PID=$!

    # Ensure socat is killed even if the script fails
    trap "kill $SOCAT_PID 2>/dev/null || true" EXIT

    # Give the proxy a moment to start
    sleep 1

    ${pkgs.podman}/bin/podman pull ${image}

    # Kill socat (trap will also handle this on exit)
    kill $SOCAT_PID 2>/dev/null || true
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

  systemd.services.podman-adguardhome =lib.optionalAttrs config.homefree.service-options.adguard.enable {
    after = [ "unbound.service" ];
    wants = [ "unbound.service" ];
    serviceConfig = {
      ExecStartPre = [ "!${pkgs.writeShellScript "adguardhome-prestart" preStart}" ];
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
      };
      backup = {
        paths = [
          containerDataPath
        ];
      };
    }];
  };
}

