{ homefree-inputs, config, lib, pkgs, ... }:
let
  lan-address = config.homefree.network.lan-address;
  lan-subnet = config.homefree.network.lan-subnet;
  adlist = homefree-inputs.adblock-unbound.packages.${pkgs.system};
  proxiedHostConfig = lib.filter (service-config: service-config.reverse-proxy.enable == true) config.homefree.service-config;
  proxiedDomains = config.homefree.proxied-domains;
  zones = [config.homefree.system.domain] ++ config.homefree.system.additionalDomains;

  # Process proxied domains to extract non-public domains
  nonPublicProxiedDomains = lib.flatten (lib.map (domain-mapping:
    if domain-mapping.public == false then
      domain-mapping.domains
    else
      []
  ) proxiedDomains);

  # Extract unique base domains from non-public proxied domains (handle wildcards like *.example.com)
  nonPublicBaseDomains = lib.unique (lib.map (domain:
    let
      parts = lib.splitString "." domain;
      # Filter out "*" from wildcard entries, then take last 2 parts
      cleanParts = lib.filter (p: p != "*") parts;
      len = lib.length cleanParts;
    in
      lib.concatStringsSep "." (lib.sublist (if len > 2 then len - 2 else 0) 2 cleanParts)
  ) nonPublicProxiedDomains);

  preStart = ''
    touch /run/unbound/include.conf
    cat > /run/unbound/dynamic.zone<< EOF
    \$ORIGIN ${config.homefree.system.localDomain}.
    \$TTL 3600
    @       IN      SOA     localhost. root.localhost. (
                            2023100101 ; serial
                            3600       ; refresh
                            1800       ; retry
                            604800     ; expire
                            86400      ; minimum
                            )
            IN      NS      localhost.
    EOF
    # cp /run/unbound/dynamic.zone /tmp
  '';
in
{
  ## See: https://blog.josefsson.org/2015/10/26/combining-dnsmasq-and-unbound/

  ## Unbound is a caching resolver, not meant to be used as authoritative.
  ## nbound does support simple authoritative hosting with local-zone config.
  ## For a proper authoritative DNS, look at NSD.

  systemd.services.unbound = {
    after = [ "nftables.service" ];
    wants = [ "nftables.service" ];
    serviceConfig = {
      ExecStartPre = [ "!${pkgs.writeShellScript "unbound-prestart" preStart}" ];
      # Allow Unbound to use configured outgoing-range (8192 ports)
      # Fixes: "cannot increase max open fds from 4096 to 33046"
      LimitNOFILE = 65536;
    };
  };

  systemd.services.dns-ready = {
    description = "Wait for DNS services to be ready";
    # bindsTo = [ "unbound.service" ]
    # ++ (if config.homefree.services.adguard.enable == true then [ "adguardhome.service" ] else []);
    # after = [ "network.target" "network-online.target" "unbound.service" ]
    # ++ (if config.homefree.services.adguard.enable == true then [ "adguardhome.service" ] else []);
    # requires = [ "network-online.target" "unbound.service" ]
    # ++ (if config.homefree.services.adguard.enable == true then [ "adguardhome.service" ] else []);
    after = [ "network.target" "network-online.target" "unbound.service" ]
    ++ (if config.homefree.services.adguard.enable == true then [ "adguardhome.service" ] else []);
    wants = [ "network-online.target" "unbound.service" ]
    ++ (if config.homefree.services.adguard.enable == true then [ "adguardhome.service" ] else []);
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.writeShellScript "wait-for-dns" ''
        # Wait for LAN interface to have 10.0.0.1 assigned (required for Caddy to bind)
        until ${pkgs.iproute2}/bin/ip addr show | ${pkgs.gnugrep}/bin/grep -q "inet 10.0.0.1/"; do
          ${pkgs.coreutils}/bin/sleep 1
        done
        # Wait for DNS resolution to work
        until ${pkgs.dnsutils}/bin/dig +short ${config.homefree.system.domain} >/dev/null 2>&1; do
          ${pkgs.coreutils}/bin/sleep 1
        done
      ''}";
      RemainAfterExit = true;
      TimeoutStartSec = 60;
    };
  };

  services.unbound = {
    enable = true;

    user = "root";

    resolveLocalQueries = true;

    settings = {
      ## Make Unbound default DNS server if adguard is disabled
      server = {
        port = if config.homefree.services.adguard.enable == true
        then
          53530
        else
          53
        ;
        include = [
          ## Leave ad-blocking to AdGuard, as it can be disabled by the client
          # "\"${adlist.unbound-adblockStevenBlack}\""

          ## Include run-time config, such as WAN ip mappings
          ## @TODO: Update this with ddclient scripts
          ## @TODO: Remove WAN entries from bare hostname maps below
          "\"/run/unbound/include.conf\""
        ];
        ## Set in services/adguardhome.nix
        ## if adguard is disabled, this is set to 53 to make it the default DNS
        # port = 53530;
        interface = [
          "127.0.0.1"
          "::1"
          "${lan-address}"
          "100.64.0.2"       # headscale
        ];
        access-control = [
          "127.0.0.1/24 allow"
          "::1 allow"
          "${lan-subnet} allow"
          "100.64.0.2/24 allow"
        ];
        # outgoing-interface = [
        #   ## @TODO: should be WAN IP - how to get this automatically?
        #   "10.0.2.15"
        #   # @TODO: need ipv6 address
        # ];
        local-zone =
        # static - fully authoritative, e.g. Local domain
        # transparent - returns local data if matched, otherwise forwards to upstream DNS
        # redirect - redirect all queries for a domain to an single IP
        [
          "\"homefree.${config.homefree.system.localDomain}\" static"
        ]
        ++
        # Primary domain and additional domains are transparent (local data + forward upstream)
        (lib.map (zone: "\"${zone}\" transparent") zones)
        ++
        # Non-public proxied base domains use redirect to handle wildcards (all subdomains -> same IP)
        # Only add if not already in zones to avoid conflicts
        (lib.map (domain: "\"${domain}\" redirect") (lib.filter (d: !(lib.elem d zones)) nonPublicBaseDomains))
        ;
        ## @TODO: Add config.homefree.network.blocked-domains as such:
        # local-zone: "example.org" always_nxdomain

        ## Record format:
        ## NAME             CLASS (default: IN)   TYPE  RDATA
        ## localhost        IN                    A     127.0.0.1
        local-data =
        [
          "\"localhost A 127.0.0.1\""
          "\"localhost AAAA ::1\""
        ]
        ++
        ## add localhost.<zone> for all configured zones
        (lib.map (zone: "\"localhost.${zone} IN A 127.0.0.1\"") zones)
        ++
        ## add <hostname>.<zone> for all configured zones
        (lib.map (zone: "\"${config.homefree.system.hostName}.${zone} IN A 127.0.0.1\"") zones)
        ++
        # Add DNS overrides
        (lib.map (local-data-config:
          if builtins.hasAttr "domain" local-data-config then
            "\"${local-data-config.hostname}.${local-data-config.domain} IN A ${local-data-config.ip}\""
          else
            "\"${local-data-config.hostname} IN A ${local-data-config.ip}\""
          ) config.homefree.dns.local.overrides
        )
        ++
        # Point proxy URLs to internal IP when on LAN
        (lib.map
          (fqn: "\"${fqn} IN A ${lan-address}\"")
          ## Flatten to single list
          ## e.g. [ "hij.lmnop" "hij.xyz" "abc.lmnop" "abc.xyz"  "def.lmnop" "def.xyz" ]
          (lib.flatten
            ## Map across all proxy configs
            ## creating list of lists
            ## e.g. [ [ "hij.lmnop" "hij.xyz" ] [ "abc.lmnop" "abc.xyz"  "def.lmnop" "def.xyz" ] ]
            (lib.map
              (service-config:
                ## Flatten subdomain-domain combinations for individual proxy into single list
                ## e.g. [ "abc.lmnop" "abc.xyz"  "def.lmnop" "def.xyz" ]
                lib.flatten
                ## Create all subdomain-domain combinations, grouped by subdomain
                ## e.g. [ [ "abc.lmnop" "abc.xyz" ] [ "def.lmnop" "def.xyz" ]]
                (lib.map
                  (subdomain:
                    # Create <subdomain>.<domain> fqn string
                    (lib.map
                      (domain: "${subdomain}.${domain}")
                      (service-config.reverse-proxy.http-domains ++ service-config.reverse-proxy.https-domains)
                    )
                  )
                  service-config.reverse-proxy.subdomains
                )
              )
              ## @TODO: Get rid of this filter
              ## See: https://caddy.community/t/caddy-not-handling-requests-when-listening-on-all-interfaces-serving-a-hostname-mapped-to-an-internal-ip/26384
              # (lib.filter (proxy-config: proxy-config.public == false) proxiedHostConfig)

              ## For services that always need a public IP, e.g. headscale, filter out those with public set to true
              (lib.filter (service-config: service-config.reverse-proxy.public == false) proxiedHostConfig)
              # proxiedHostConfig
            )
          )
        )
        ++
        # Point non-public proxied domains to internal IP
        # For redirect zones, only the base domain is needed (wildcards handled automatically)
        # For transparent zones (domains also in additionalDomains), we need explicit entries
        (lib.map
          (domain: "\"${domain} IN A 10.0.0.1\"")
          nonPublicBaseDomains
        )
        # @TODO: Headscale subdomains need internal DNS for DERP connectivity
        # but adding them breaks mobile clients (Tailscale app gets stuck loading).
        # Need to investigate why internal DNS for public services causes issues.
        # See: https://caddy.community/t/caddy-not-handling-requests-when-listening-on-all-interfaces-serving-a-hostname-mapped-to-an-internal-ip/26384
        # Related bug: https://github.com/tailscale/tailscale/issues/18441
        # NOTE: Commented out - this was preventing vpn.homefree.host from resolving to WAN IP,
        # which broke access to /admin panel. Watch for DERP connectivity issues.
        # ++
        # (let
        #   headscaleConfig = lib.findFirst
        #     (sc: sc.label == "headscale")
        #     null
        #     proxiedHostConfig;
        # in
        #   if headscaleConfig != null then
        #     lib.flatten (lib.map (subdomain:
        #       lib.map (zone: "\"${subdomain}.${zone} IN A 10.0.0.1\"")
        #         (headscaleConfig.reverse-proxy.http-domains ++ headscaleConfig.reverse-proxy.https-domains)
        #     ) headscaleConfig.reverse-proxy.subdomains)
        #   else []
        # )
        ++
        ## router lan ip with public domains
        (lib.map (zone: "\"${config.homefree.system.hostName}.${zone} IN A ${lan-address}\"") zones)
        ++
        ## @TODO: Move to config for gateway IP
        [
          ## router lan IP
          "\"${config.homefree.system.hostName} IN A ${lan-address}\""
          ## router lan IP with local domain
          "\"${config.homefree.system.hostName}.${config.homefree.system.localDomain} IN A ${lan-address}\""
        ]
        ++
        ## @TODO: How to configure these at runtime?
        ## router wan IP with public domain
        (lib.map (zone: "\"${config.homefree.system.hostName}.${zone} IN A 104.182.229.64\"") zones)
        ++
        ## Bare hostname maps
        [
          ## router wan IP - @TODO - THIS NEEDS TO BE DYNAMIC
          "\"${config.homefree.system.hostName} IN A 104.182.229.64\""
          ## router wan ipv6 IP - @TODO - THESE ARE WRONG
          "\"${config.homefree.system.hostName} IN AAAA 2600:1700:ab00:4650:2e0:67ff:fe22:3e62\""
          ## ??? @TODO - WHAT IS THIS?
          "\"${config.homefree.system.hostName} IN AAAA 2600:1700:ab00:465f:2e0:67ff:fe22:3e63\""
        ]
        ++
        ## router wan IPv6 with public domain
        (lib.map (zone: "\"${config.homefree.system.hostName}.${zone} IN AAAA 2600:1700:ab00:4650:2e0:67ff:fe22:3e62\"") zones)
        ++
        (lib.map (zone: "\"${config.homefree.system.hostName}.${zone} IN AAAA 2600:1700:ab00:465f:2e0:67ff:fe22:3e64\"") zones)
        ++
        (lib.map (ip-config:
        "\"${ip-config.hostname} IN A ${ip-config.ip}\"")
        config.homefree.network.static-ips)
        ++
        (lib.map (ip-config:
        "\"${ip-config.hostname}.${config.homefree.system.localDomain} IN A ${ip-config.ip}\"")
        config.homefree.network.static-ips)
        ;

        local-data-ptr = [
          "\"::1 localhost\""
          "\"127.0.0.1 localhost\""
        ]
        ++
        (lib.map (ip-config:
        "\"${ip-config.ip} ${ip-config.hostname}\"")
        config.homefree.network.static-ips)
        ++
        (lib.map (ip-config:
        "\"${ip-config.ip} ${ip-config.hostname}.${config.homefree.system.localDomain}\"")
        config.homefree.network.static-ips)

        ## @TODO: Add caddy domains to zones, e.g.:
        ## "${lan-address} auth.rahh.al"
        ;

        hide-identity = true;
        hide-version = true;

        # Based on recommended settings in https://doc.pi-hole.net/guides/dns/unbound/#configure-unbound
        harden-glue = true;
        harden-dnssec-stripped = true;
        use-caps-for-id = false;
        prefetch = true;
        edns-buffer-size = 1232;
        # Performance tuning to prevent request list overflow
        num-threads = 4;
        outgoing-range = 8192;
        num-queries-per-thread = 4096;
        msg-cache-size = "128m";
        rrset-cache-size = "256m";
        key-cache-size = "128m";
        so-rcvbuf = "4m";
        so-sndbuf = "4m";
      };
      #
      # range-lan = {
      #   start = "10.0.0.200";
      #   end = "10.0.0.254";
      #   domain = config.homefree.system.localDomain;
      # };

      forward-zone = [
        {
          name = ".";
          forward-addr = [
            "9.9.9.9#dns.quad9.net"
            "1.1.1.1@853#cloudflare-dns.com"
            "1.0.0.1@853#cloudflare-dns.com"
          ];
          forward-tls-upstream = "yes";
        }
        # {
        #   name = "example.org.";
        #   forward-addr = [
        #     "1.1.1.1@853#cloudflare-dns.com"
        #     "1.0.0.1@853#cloudflare-dns.com"
        #   ];
        # }
      ];

      ## Enable dynamic updates from dnsmasq
      auth-zone = {
        name = "\"${config.homefree.system.localDomain}\"";
        master = "yes";
        allow-notify = "no";
        for-downstream = "no";
        for-upstream = "yes";
        zonefile = "\"/run/unbound/dynamic.zone\"";
      };

      remote-control.control-enable = true;
    };
  };
}
