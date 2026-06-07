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

  # Extract unique base domains from non-public proxied domains
  # (strip wildcard prefix so a domain like `*.apps.example.com`
  # becomes `apps.example.com`, the actual zone we want unbound to
  # `redirect` for). The old code took only the last 2 labels, which
  # truncated `*.apps.example.com` to `example.com` — already in
  # `zones` (transparent) — and the redirect zone was filtered out,
  # so deeper wildcards silently fell through to public DNS.
  nonPublicBaseDomains = lib.unique (lib.map (domain:
    let
      parts = lib.splitString "." domain;
      cleanParts = lib.filter (p: p != "*") parts;
    in
      lib.concatStringsSep "." cleanParts
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
    ## Order unbound after the network is actually ONLINE — not merely
    ## after `network.target` (interfaces configured). unbound forwards
    ## all recursion to its DoT upstreams (Quad9 / Cloudflare on :853)
    ## and, with DNSSEC validation enabled (`auto-trust-anchor-file`
    ## below), it must fetch the root `. DNSKEY` rrset from one of them to
    ## PRIME the validator before it will answer ANY recursive query. The
    ## upstream NixOS module orders unbound only after `network.target`,
    ## so on a fresh box it started ~5s BEFORE `network-online.target` was
    ## reached, tried to prime while the WAN/DoT path was still
    ## unreachable, and logged "failed to prime trust anchor -- could not
    ## fetch DNSKEY rrset . DNSKEY IN" — SERVFAILing every recursive query
    ## until a later retry happened to land after the network came up
    ## ("DNS wasn't working for a while" right after first boot). Gating
    ## on `network-online.target` makes the first prime attempt land once
    ## upstream is reachable. No dependency cycle: network-online does not
    ## depend on DNS (wait-online only needs an interface with an IP).
    after = [ "nftables.service" "network-online.target" ];
    wants = [ "nftables.service" "network-online.target" ];
    serviceConfig = {
      ExecStartPre = [ "!${pkgs.writeShellScript "unbound-prestart" preStart}" ];
      # Allow Unbound to use configured outgoing-range (8192 ports)
      # Fixes: "cannot increase max open fds from 4096 to 33046"
      LimitNOFILE = 65536;
    };
  };

  ## dns-ready is the gate every container app orders itself after, so it
  ## can pull its image. It must re-prove DNS *every time DNS restarts* —
  ## not just once at boot. unbound (and adguardhome, when enabled) get
  ## restarted on most rebuilds (e.g. enabling any service rewrites the
  ## proxied-host zone), and there is a window during that restart where
  ## name resolution fails. A oneshot+RemainAfterExit gate proven once at
  ## boot stays green through that window, so podman units ordered after
  ## it start mid-outage and fail their image pull with "no such host".
  ##
  ## partOf + after on the DNS units makes a *restart* of a DNS unit
  ## propagate to dns-ready: when unbound or podman-adguardhome restarts,
  ## systemd restarts dns-ready too, re-executing the wait loop. Any
  ## podman unit started in the same rebuild transaction is then ordered
  ## after the *re-run*, so it only starts once resolution genuinely
  ## works again.
  ##
  ## partOf, not bindsTo: bindsTo would also tear dns-ready down (and
  ## cascade-stop every container ordered `requires dns-ready`) the
  ## instant the adguard *container* merely failed. partOf propagates
  ## restarts/stops without coupling dns-ready to a DNS unit's failure,
  ## which is the behaviour we want — re-arm on restart, don't collapse
  ## the whole app stack on a transient container crash.
  systemd.services.dns-ready =
  let
    ## The real LAN resolver container is `podman-adguardhome.service`
    ## (there is no `adguardhome.service` — the old commented-out code
    ## referenced a unit that never existed). podman-adguardhome carries
    ## a restartTrigger on unbound's settings, so it restarts on every
    ## rebuild that changes the proxied zone (i.e. enabling any service)
    ## — exactly the window this gate must cover.
    dnsUnits = [ "unbound.service" ]
      ++ lib.optional (config.homefree.services.adguard.enable) "podman-adguardhome.service";
    ## `partOf` is intentionally narrower than `dnsUnits`: only
    ## `unbound.service` triggers re-arming. A restart of unbound on a
    ## rebuild reflects a real config change (proxied-zone rewrite), and
    ## the wait loop should re-run so downstream container apps see the
    ## new resolver before they start. But propagating restarts from
    ## `podman-adguardhome.service` would cause a transient adguard
    ## restart-cycle (e.g. cold-boot image pull failing 5× over 50s
    ## before its start-limit cools off) to SIGTERM dns-ready every 10s
    ## — observed on a real boot where unbound's upstream DoT was still
    ## warming up. dns-ready's wait loop should run uninterrupted in
    ## that window, not get torn down by an upstream container's flap.
    ## adguardhome being a *dependency* (`after`/`wants`) is still
    ## enforced via `dnsUnits` above.
    partOfUnits = [ "unbound.service" ];
  in {
    description = "Wait for DNS services to be ready";
    after = [ "network.target" "network-online.target" ] ++ dnsUnits;
    wants = [ "network-online.target" ] ++ dnsUnits;
    ## partOf: a restart of unbound propagates a restart to dns-ready,
    ## re-running the wait loop. See the comment block above for why
    ## this is partOf and not bindsTo, and why podman-adguardhome is
    ## intentionally excluded.
    partOf = partOfUnits;
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.writeShellScript "wait-for-dns" ''
        # Wait for LAN interface to have IP assigned (required for Caddy to bind)
        until ${pkgs.iproute2}/bin/ip addr show | ${pkgs.gnugrep}/bin/grep -q "inet ${lan-address}/"; do
          ${pkgs.coreutils}/bin/sleep 1
        done
        # Wait for LOCAL DNS (our own zone resolves via unbound/adguard).
        # Unbounded: the local resolver is on-box and must come up.
        until ${pkgs.dnsutils}/bin/dig +short ${config.homefree.system.domain} >/dev/null 2>&1; do
          ${pkgs.coreutils}/bin/sleep 1
        done
        # Wait for EXTERNAL recursion. Container apps pull images from
        # public registries AND, in HA's case, pip-install from PyPI at
        # startup with no in-session retry. The gate must therefore prove
        # the recursive path is reliably serving fresh queries, not just
        # that ONE cached name happens to resolve.
        #
        # A single dig cloudflare.com cleared in the past while unbound's
        # DoT upstream (1.1.1.1@853 / 1.0.0.1@853) was still warming up,
        # because either the answer came from a previous-boot cache or one
        # lucky query won the race. Downstream containers then hit
        # SERVFAIL/EAGAIN on fresh names a minute later (HA pyscript
        # croniter regression, 2026-05-30). Tightened to:
        #   - Three distinct names across three different authoritative
        #     providers (Cloudflare, Google, Debian) — a single stale
        #     cache entry can't satisfy all three.
        #   - Two consecutive sweeps required — defeats a single transient
        #     answer flapping through a still-warming upstream.
        #
        # BOUNDED (~55s worst case), then fall through regardless: if WAN
        # is genuinely down, a rebuild must still succeed and container
        # apps must still start (podman's own pull-retry handles a
        # still-down WAN). Best case ~4s once external recursion is solid.
        probes="cloudflare.com www.google.com debian.org"
        need=2
        have=0
        gate_cleared=0
        for i in $(${pkgs.coreutils}/bin/seq 1 11); do
          ok=1
          for n in $probes; do
            if [ -z "$(${pkgs.dnsutils}/bin/dig +short +time=1 +tries=1 $n 2>/dev/null)" ]; then
              ok=0
              break
            fi
          done
          if [ "$ok" = 1 ]; then
            have=$(( have + 1 ))
            if [ "$have" -ge "$need" ]; then
              gate_cleared=1
              break
            fi
          else
            have=0
          fi
          ${pkgs.coreutils}/bin/sleep 2
        done
        if [ "$gate_cleared" = 0 ]; then
          echo "wait-for-dns: external recursion still unstable after ~55s;" \
               "proceeding anyway (WAN may be down)." >&2
        fi
      ''}";
      RemainAfterExit = true;
      TimeoutStartSec = 120;
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
          ## Include run-time config, such as WAN ip mappings
          ## @TODO: Update this with ddclient scripts
          ## @TODO: Remove WAN entries from bare hostname maps below
          "\"/run/unbound/include.conf\""
        ]
        ++ lib.optional
          config.homefree.network.enable-unbound-adblock
          "\"${adlist.unbound-adblockStevenBlack}\"";
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
        ] ++ (lib.map (gn: "${gn.subnet} allow")
          config.homefree.network.guest-networks);
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
        ++
        # Per-FQDN `static` zones for every non-public reverse-proxy name.
        # Without this, `<zone> transparent` lets unknown record types
        # (e.g. AAAA) fall through to upstream public DNS — which has a
        # wildcard AAAA pointing at the WAN. IPv6-preferring clients then
        # connect over WAN and hit a vhost that only binds the LAN
        # interface, producing empty 200 responses. `static` makes unbound
        # authoritative for these FQDNs: queries for any type without a
        # matching `local-data` entry return NODATA instead of leaking.
        (lib.flatten
          (lib.map
            (service-config:
              lib.map
                (subdomain:
                  lib.map
                    (domain: "\"${subdomain}.${domain}\" static")
                    (service-config.reverse-proxy.http-domains ++ service-config.reverse-proxy.https-domains)
                )
                service-config.reverse-proxy.subdomains
            )
            (lib.filter (sc: sc.reverse-proxy.public == false) proxiedHostConfig)
          )
        )
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
          (domain: "\"${domain} IN A ${lan-address}\"")
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

        # Phase 5 L5 — bootstrap the root DNSSEC trust anchor so
        # validation is fully enabled, not just "harden against
        # stripped sigs." Unbound writes the IANA root key to this
        # path on first run (uses the bundled `unbound-anchor` tool)
        # and refreshes it via RFC 5011 thereafter. Without an
        # explicit anchor, unbound only catches downgrade attacks
        # against pre-validated chains — it doesn't independently
        # validate from the root. See
        # docs/agent-notes/security-audit-phase-5.md L5.
        auto-trust-anchor-file = "/var/lib/unbound/root.key";
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
