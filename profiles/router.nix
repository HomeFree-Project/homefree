{ config, lib, pkgs, ... }:

let
  # @TODO: How to determine interface names?
  wan-interface = config.homefree.network.wan-interface;
  lan-interface = config.homefree.network.lan-interface;
  lan-address = config.homefree.network.lan-address;
  lan-subnet = config.homefree.network.lan-subnet;
  static-ip-config = config.homefree.network.static-ips;
  blocked-ips = lib.filter (ip-config: ip-config.wan-access == false) static-ip-config;
  blocked-ip-rules = lib.concatStrings (lib.map (entry: ''
    iifname ${wan-interface} ip saddr ${entry.ip} drop
    iifname ${wan-interface} ip daddr ${entry.ip} drop
  '') blocked-ips);

  ## Guest networks (VLANs). Each entry creates a sub-interface on
  ## lan-interface, an IP on the router, its own DHCP scope (dnsmasq),
  ## and per-VLAN nftables forward rules below.
  guest-networks = config.homefree.network.guest-networks;
  cidr-prefix = subnet:
    lib.toInt (builtins.elemAt (lib.splitString "/" subnet) 1);

  ## Per-VLAN forward-chain rules. Each block:
  ##   - allows or drops VLAN→WAN egress (internet-access)
  ##   - allows or drops VLAN↔LAN (lan-access, both directions)
  ##   - allows or drops VLAN↔every-other-VLAN (inter-network-access)
  ## Pattern mirrors the existing podman0/tailscale0/wt0 rules below.
  guest-network-forward-rules = lib.concatStringsSep "\n" (lib.map (gn:
    let ifn = gn.id; in
    ''
    ## --- ${gn.name} (${ifn}, vlan ${toString gn.vlan-id}) ---
    ''
    + (if gn.internet-access then ''
      iifname { "${ifn}" } oifname { "${wan-interface}" } accept comment "Allow ${ifn} to WAN"
      iifname { "${wan-interface}" } oifname { "${ifn}" } ct state established, related accept comment "Allow established back to ${ifn}"
    '' else ''
      iifname { "${ifn}" } oifname { "${wan-interface}" } counter drop comment "Block ${ifn} from WAN"
    '')
    + (if gn.lan-access then ''
      iifname { "${ifn}" } oifname { "${lan-interface}" } accept comment "Allow ${ifn} to main LAN"
      iifname { "${lan-interface}" } oifname { "${ifn}" } accept comment "Allow main LAN to ${ifn}"
    '' else ''
      iifname { "${ifn}" } oifname { "${lan-interface}" } counter drop comment "Isolate ${ifn} from main LAN"
      iifname { "${lan-interface}" } oifname { "${ifn}" } counter drop comment "Isolate main LAN from ${ifn}"
    '')
    + lib.concatStringsSep "" (lib.map (other:
      if other.id == gn.id then ""
      else if gn.inter-network-access then ''
        iifname { "${ifn}" } oifname { "${other.id}" } accept comment "Allow ${ifn} to ${other.id}"
      ''
      else ''
        iifname { "${ifn}" } oifname { "${other.id}" } counter drop comment "Isolate ${ifn} from ${other.id}"
      ''
    ) guest-networks)
  ) guest-networks);

  ## Input-chain accept list: every VLAN sub-interface is part of "our"
  ## network and clients legitimately need to reach the router for
  ## DHCP/DNS/gateway. (lan-interface gets the same blanket accept on
  ## line ~292 below.)
  guest-network-input-rules = lib.concatStringsSep "\n" (lib.map (gn:
    ''iifname { "${gn.id}" } accept comment "Allow ${gn.id} VLAN to access the router"''
  ) guest-networks);

  ## Static abuse blocklist for the abusive_nets4 / abusive_nets6
  ## nftables sets. Fully driven by config.homefree.network.
  ## abuseBlockCidrs — a user-owned list (seeded once with Alibaba
  ## Cloud scraper ranges by modules/abuse-blocking.nix, then editable
  ## in the admin UI). Only entries with enabled == true are enforced;
  ## a disabled entry stays in config for reference but is left out of
  ## the set. The combined list carries both IPv4 and IPv6 CIDRs; each
  ## entry is routed to the matching set by address family (an IPv6
  ## CIDR contains a ":").
  enabled-abuse-cidrs = lib.map (e: e.cidr)
    (lib.filter (e: e.enabled) config.homefree.network.abuseBlockCidrs);
  enabled-abuse-cidrs4 = lib.filter (c: !(lib.hasInfix ":" c)) enabled-abuse-cidrs;
  enabled-abuse-cidrs6 = lib.filter (c:  (lib.hasInfix ":" c)) enabled-abuse-cidrs;
  abuse-cidrs4-str = lib.concatStringsSep ", " enabled-abuse-cidrs4;
  abuse-cidrs6-str = lib.concatStringsSep ", " enabled-abuse-cidrs6;

  ## Per-IP concurrent-connection cap (homefree.network.perIpConnection-
  ## Limit). `0` disables the cap. Emitted into the input chain BEFORE
  ## the http/https accept rule so excess connections are dropped before
  ## conntrack accepts them. Applies only on the WAN interface; LAN
  ## clients are unrestricted.
  ##
  ## Uses nftables `meter` (anonymous dynamic set) — the canonical form
  ## documented on the nftables wiki for per-source `ct count` limits.
  ## A previous attempt with a named-set `add @set { ip saddr ct count
  ## over N }` was rejected by the kernel ("Operation not supported");
  ## `meter` creates the backing set implicitly and avoids whatever
  ## combo of set-flag / `add`-statement bits the kernel doesn't accept
  ## with `ct count`. IPv6 keys by the source's /64 prefix (the rule
  ## ANDs `ip6 saddr` before counting) so SLAAC privacy addresses on
  ## one client's /64 don't artificially fill the cap.
  perIpConnLimit = config.homefree.network.perIpConnectionLimit;
  perIpConnRules =
    if perIpConnLimit == 0 then ""
    else ''
      iifname "${wan-interface}" tcp dport { http, https } meta nfproto ipv4 ct state new meter conn_count_v4 size 65535 { ip saddr ct count over ${toString perIpConnLimit} } counter drop comment "Per-IP conn cap v4 (>${toString perIpConnLimit})"
      iifname "${wan-interface}" tcp dport { http, https } meta nfproto ipv6 ct state new meter conn_count_v6 size 65535 { ip6 saddr and ffff:ffff:ffff:ffff:: ct count over ${toString perIpConnLimit} } counter drop comment "Per-IP conn cap v6 (>${toString perIpConnLimit}, /64)"
    '';

  # Firewall rules to open up ports for services
  public-service-configs = lib.filter (service-config: service-config.reverse-proxy.enable == true && service-config.reverse-proxy.public == true) config.homefree.service-config;
  service-input-rules = lib.concatStringsSep "\n" (lib.map (service-config:
    lib.concatStringsSep "\n" (lib.map (tcp-port: "tcp dport { ${toString tcp-port} } ct state new accept;") service-config.firewall.open-ports.tcp)
    +
    lib.concatStringsSep "\n" (lib.map (udp-port: "udp dport { ${toString udp-port} } ct state new accept;") service-config.firewall.open-ports.udp)
  ) public-service-configs);
  service-forward-rules = lib.concatStringsSep "\n" (lib.map (service-config:
    lib.concatStringsSep "\n" (lib.map (tcp-port: ''iifname "${wan-interface}" oifname "podman0" tcp dport ${toString tcp-port} ct state new accept;'') service-config.firewall.open-ports.tcp)
    +
    lib.concatStringsSep "\n" (lib.map (udp-port: ''iifname "${wan-interface}" oifname "podman0" udp dport ${toString udp-port} ct state new accept;'') service-config.firewall.open-ports.udp)
  ) public-service-configs);
in
{

  # REFERENCES:
  # https://github.com/chayleaf/nixos-router
  #   https://github.com/chayleaf/dotfiles/blob/master/system/hosts/router/default.nix
  # https://francis.begyn.be/blog/nixos-home-router
  # https://discourse.nixos.org/t/do-you-use-nixos-on-your-router-firewall/18998
  # https://homenetworkguy.com/how-to/set-up-a-fully-functioning-home-network-using-opnsense/

  #-----------------------------------------------------------------------------------------------------
  # IP Forwarding
  #-----------------------------------------------------------------------------------------------------

  boot.kernel.sysctl = lib.optionalAttrs config.homefree.network.router.enable {
    # enable ipv4 forwarding
    "net.ipv4.conf.all.forwarding" = true;

    # enable ipv6 forwarding
    "net.ipv6.conf.all.forwarding" = true;

    # On WAN, allow IPv6 autoconfiguration and tempory address use.
    "net.ipv6.conf.${wan-interface}.accept_ra" = 2;
    "net.ipv6.conf.${wan-interface}.autoconf" = 1;
    "net.ipv6.conf.${lan-interface}.accept_ra" = 2;
    "net.ipv6.conf.${lan-interface}.autoconf" = 1;

    # Allow services (AdGuardHome) to bind to LAN-side IPv6 addresses even when
    # the LAN interface has no carrier — otherwise the address stays tentative
    # (DAD can't complete on a down link) and AdGuardHome fatals on startup,
    # taking out DNS for the whole host.
    "net.ipv6.ip_nonlocal_bind" = 1;

    # Phase 5 M6: loose-mode reverse-path filter. NixOS default is 0
    # (disabled) which lets a packet with a source IP that doesn't
    # match any reachable route in via *any* interface — useful for
    # asymmetric routing setups, but on a router with well-defined
    # WAN/LAN/podman bridges it's just a spoofing assist. Mode 2
    # (loose) accepts the packet if the source is reachable via ANY
    # interface — tolerates asymmetric routing (so this doesn't
    # break netbird/headscale tunnel return paths) while rejecting
    # obviously spoofed traffic. Mode 1 (strict) would be tighter
    # but does break asymmetric paths. See
    # docs/agent-notes/security-audit-phase-5.md M6.
    "net.ipv4.conf.all.rp_filter" = 2;
    "net.ipv4.conf.default.rp_filter" = 2;
  };

  # ip6table_nat: required so netavark's IPv6 DNAT rules for podman containers
  # actually load. Without this, inbound IPv6 to forwarded ports (e.g. forgejo
  # ssh on 3022) is silently dropped, causing dual-stack clients to wait the
  # full TCP SYN timeout before falling back to IPv4.
  # 8021q: networking.vlans below generates Kind=vlan netdev units, but the
  # systemd-networkd path doesn't auto-modprobe and nothing else pulls 8021q in,
  # so VLAN interfaces silently never come up. Only needed when guest networks
  # are configured.
  boot.kernelModules =
    [
      "ip6table_nat"
      ## Connection-counter for `ct count over N` in the per-IP
      ## connection-cap meter rules above (perIpConnRules). NixOS
      ## usually auto-modprobes nft modules referenced by rules, but
      ## we list it explicitly so a kernel that has it as a separate
      ## module loads it deterministically at boot rather than racing
      ## the first nftables ruleset apply.
      "nf_conncount"
    ]
    ++ lib.optional (config.homefree.network.guest-networks != []) "8021q";

  ## @TODO: Is this overlapping/conflicting with "interfaces" settings?
  systemd.network = lib.optionalAttrs config.homefree.network.router.enable {
    links = {
      "01-${wan-interface}" = {
        matchConfig.Name = wan-interface;
        linkConfig = {
          ## @TODO: Make this configurable, or automatically detectable
          ## @TODO: Determine if this is even necessary, or the lost carrier issues were due to a bad cable.
          Advertise = "1000baset-full";
          AutoNegotiation = "yes";
          TransmitQueues = 128;
          ReceiveQueues = 128;
          RxBufferSize = 2048;
          TxBufferSize = 2048;
        };
      };
    };
    networks = {
      "01-${lan-interface}" = {
        name = lan-interface;
        # VLAN= entries attach guest-network sub-interfaces to this trunk.
        # The auto-generated 40-${lan-interface}.network (from
        # networking.interfaces + networking.vlans below) ALSO declares
        # these, but networkd picks the lowest-priority matching file and
        # ignores the rest, so without this line the VLAN bindings are
        # silently dropped and 8021q sub-interfaces never come up.
        vlan = map (gn: gn.id) guest-networks;
        networkConfig = {
          Description = "LAN link";
          Address = [ "${lan-address}/${builtins.elemAt (lib.splitString "/" lan-subnet) 1}" "fd01::1/64" ];
          LinkLocalAddressing = "yes";
          IPv6AcceptRA = "no";
          # Announce a prefix here and act as a router.
          IPv6SendRA = "yes";
          # Use a DHCPv6-PD delegated prefix (DHCPv6PrefixDelegation.SubnetId)
          # from the pool and assigns one /64 to this network.
          DHCPPrefixDelegation = "yes";
          ## @TODO: This was set to "no" before, but changed to "yes" so that adguardhome could start even if the LAN
          ##        port is not connected. Are there ramifications of keeping this set to "yes"?
          ConfigureWithoutCarrier = "yes";
        };
        ipv6SendRAConfig = {
          # Currently dnsmasq manages DNS servers.
          EmitDNS = "no";
          EmitDomains = "no";
        };
        ipv6Prefixes = [
          {
            Prefix = "::/64";
          }
        ];
      };
    };
  };

  networking = lib.optionalAttrs config.homefree.network.router.enable {
    #-----------------------------------------------------------------------------------------------------
    # Interface config
    #-----------------------------------------------------------------------------------------------------

    useDHCP = false;
    nameservers = [ lan-address ];

    ## VLAN sub-interfaces — one per homefree.network.guest-networks
    ## entry. Each is an 802.1Q-tagged sub-interface on the LAN NIC.
    ## Reaching client devices on a given VLAN still requires an
    ## 802.1Q-aware AP/switch downstream that maps clients onto the
    ## right tagged segment.
    ## https://www.breakds.org/post/vlan-configuration-by-examples/
    vlans = lib.listToAttrs (lib.map (gn: {
      name = gn.id;
      value = {
        id = gn.vlan-id;
        interface = lan-interface;
      };
    }) guest-networks);

    interfaces = {
      ${wan-interface} = {
        useDHCP = true;
      };
      ${lan-interface} = {
        useDHCP = false;
        ipv4.addresses = [{
          address = lan-address;
          prefixLength = lib.toInt (builtins.elemAt (lib.splitString "/" lan-subnet) 1);
        }];
      };
    } // (lib.listToAttrs (lib.map (gn: {
      name = gn.id;
      value = {
        useDHCP = false;
        ipv4.addresses = [{
          address = gn.gateway;
          prefixLength = cidr-prefix gn.subnet;
        }];
      };
    }) guest-networks));

    #-----------------------------------------------------------------------------------------------------
    # Firewall
    #-----------------------------------------------------------------------------------------------------

    ## Use explicit firewall rules
    firewall.enable = false;

    ## ipv6 reference:
    ## https://superuser.com/questions/1617415/how-to-use-ipv6-internet-addresses-on-linux-with-systemd-networkd
    nftables = {
      enable = true;
      ruleset = ''
        flush ruleset

        # add table inet filter
        # add table ip nat
        # flush table inet filter
        # flush table ip nat

        ## "inet" indicates both ipv4 and ipv6
        table inet filter {
          ## Static abusive-network blocklist, driven by the
          ## user-owned config.homefree.network.abuseBlockCidrs list
          ## (only enabled entries land here). Editable in the admin
          ## UI; changing it requires a rebuild. For adaptive bans
          ## see `f2b_banned4` below.
          ##
          ## The `elements = { ... }` line is emitted only when the
          ## enabled list is non-empty — nftables rejects an empty
          ## `{ }` initializer. An element-less set is still valid
          ## and the @abusive_nets4 lookups below simply never match.
          set abusive_nets4 {
            type ipv4_addr
            flags interval${lib.optionalString (enabled-abuse-cidrs4 != []) "\n            elements = { ${abuse-cidrs4-str} }"}
          }

          ## IPv6 counterpart of abusive_nets4. Same user-owned list,
          ## IPv6 entries routed here. Elements line emitted only when
          ## the enabled v6 list is non-empty (nftables rejects an
          ## empty initializer).
          set abusive_nets6 {
            type ipv6_addr
            flags interval${lib.optionalString (enabled-abuse-cidrs6 != []) "\n            elements = { ${abuse-cidrs6-str} }"}
          }

          ## Dynamic ban set populated by fail2ban via the
          ## nftables-multiport action. Entries time out
          ## automatically (bantime configured in modules/abuse-
          ## blocking.nix); fail2ban refreshes them as needed.
          ## We declare the set here so the nftables ruleset
          ## reload (on every nixos-rebuild switch) doesn't
          ## wipe an existing fail2ban-populated set's *schema*
          ## — fail2ban will re-populate elements on restart if
          ## the kernel set is empty.
          set f2b_banned4 {
            type ipv4_addr
            flags timeout
          }
          set f2b_banned6 {
            type ipv6_addr
            flags timeout
          }

          ## Per-source-IP conntrack count: the backing dynamic set is
          ## created INLINE by the `meter conn_count_v{4,6} { ip[6]
          ## saddr ct count over N } drop` rules in the input chain
          ## (see profiles/router.nix near `perIpConnRules`). No
          ## named-set declaration is needed — and an earlier attempt
          ## with named sets + `add @set { ... ct count over N }` was
          ## rejected by the kernel as "Operation not supported."

          ## allow all packets sent by the firewall machine itself
          chain output {
            type filter hook output priority 100; policy accept;
          }

          ## allow LAN to firewall, disallow WAN to firewall
          chain input {
            type filter hook input priority 0; policy drop;

            ${blocked-ip-rules}

            ## Drop traffic from statically-banned scraper
            ## networks and dynamically-banned IPs. Counter
            ## helps quantify abuse pressure via `nft list
            ## ruleset`.
            iifname "${wan-interface}" ip saddr @abusive_nets4 counter drop comment "Static abuse block"
            iifname "${wan-interface}" ip6 saddr @abusive_nets6 counter drop comment "Static abuse block v6"
            iifname "${wan-interface}" ip saddr @f2b_banned4 counter drop comment "fail2ban v4"
            iifname "${wan-interface}" ip6 saddr @f2b_banned6 counter drop comment "fail2ban v6"

            ## Allow ICMPv6 neighbor/router discovery + multicast
            ## listener discovery from anywhere — these are required
            ## for IPv6 to work and are sourced from anywhere by
            ## design. nd-redirect is split out below because it's
            ## the one ICMPv6 message that can be abused for
            ## off-link traffic redirection.
            icmpv6 type { echo-request, echo-reply, nd-neighbor-solicit, nd-neighbor-advert, nd-router-solicit, nd-router-advert, ind-neighbor-solicit, ind-neighbor-advert, router-renumbering, mld-listener-query, mld-listener-report, mld-listener-done, mld-listener-reduction, mld2-listener-report } accept;

            ## Phase 5 M5: nd-redirect only from link-local sources.
            ## Legitimate ND redirects come from a router on the same
            ## L2 link and use a fe80::/10 source. Accepting from
            ## arbitrary sources (the previous rule did) lets a WAN
            ## attacker who can spoof ICMPv6 redirect traffic to
            ## attacker-controlled hosts. See
            ## docs/agent-notes/security-audit-phase-5.md M5.
            icmpv6 type nd-redirect ip6 saddr fe80::/10 accept comment "ND redirect — link-local source only"
            meta l4proto ipv6-icmp accept comment "Accept ICMPv6"
            meta l4proto icmp accept comment "Accept ICMP"
            ip protocol igmp accept comment "Accept IGMP"

            ## Interface specific rules
            iifname { "lo" } accept comment "Allow localhost to access the router"
            iifname { "${lan-interface}" } accept comment "Allow local network to access the router"
            iifname { "tailscale0" } accept comment "Allow tailscale network to access the router"
            iifname { "wt0" } accept comment "Allow netbird network to access the router"
            iifname { "podman0" } accept comment "Allow podman network to access the router"
            ${guest-network-input-rules}

            ## Per-IP concurrent-connection cap on web ports.
            ## Drops connections from a single WAN source once it
            ## holds more than `homefree.network.perIpConnectionLimit`
            ## concurrent connections to http/https — protection
            ## against scrapers, slowloris, and opportunistic floods
            ## that fail2ban can't catch in time (fail2ban is
            ## reactive; this is structural). Empty when the limit
            ## is 0.
            ${perIpConnRules}

            ## Allow for web traffic
            ## http is needed for headscale relaying
            tcp dport { http, https } ct state new accept;

            ${service-input-rules}

            ${lib.optionalString config.homefree.development ''
            tcp dport { 22, 2022 } ct state new accept; # Accept SSH and Eternal Terminal connections
            ''}

            # DHCPv6
            ip6 saddr fe80::/10 ip6 daddr fe80::/10 udp sport 547 udp dport 546 accept

            # DHCP client traffic (for WAN interface to get IP address from modem)
            iifname "${wan-interface}" udp sport 67 udp dport 68 accept comment "Allow DHCP from WAN"

            iifname "${wan-interface}" ct state { established, related } accept comment "Allow established traffic"
            iifname "${wan-interface}" icmp type { echo-request, destination-unreachable, time-exceeded } counter accept comment "Allow select ICMP"
            ## Logging is interesting but fills up dmesg. @TODO: log to another file, with reverse IP lookup and geoip
            # iifname "${wan-interface}" counter log prefix "WAN_DROP: " drop comment "Drop all other unsolicited traffic from wan"
            iifname "${wan-interface}" counter drop comment "Drop all other unsolicited traffic from wan"

          }

          ## allow packets from LAN to WAN, and WAN to LAN if LAN initiated the connection
          chain forward {
            type filter hook forward priority 0; policy drop;

            ${blocked-ip-rules}

            ## Same abuse blocks at the forwarding hook so that
            ## traffic destined for podman-hosted services (which
            ## is routed, not input-ed to the host) is also
            ## dropped early. Without this, the input-chain block
            ## above only protects services bound to the host.
            iifname "${wan-interface}" ip saddr @abusive_nets4 counter drop comment "Static abuse block (fwd)"
            iifname "${wan-interface}" ip6 saddr @abusive_nets6 counter drop comment "Static abuse block v6 (fwd)"
            iifname "${wan-interface}" ip saddr @f2b_banned4 counter drop comment "fail2ban v4 (fwd)"
            iifname "${wan-interface}" ip6 saddr @f2b_banned6 counter drop comment "fail2ban v6 (fwd)"

            ## LAN-WAN
            iifname { "${lan-interface}" } oifname { "${wan-interface}" } accept comment "Allow trusted LAN to WAN"
            iifname { "${wan-interface}" } oifname { "${lan-interface}" } ct state established, related accept comment "Allow established back to LANs"

            ## podman-LAN
            iifname { "podman0" } oifname { "${lan-interface}" } accept comment "Allow trusted podman to LAN"
            iifname { "${lan-interface}" } oifname { "podman0" } ct state established, related accept comment "Allow established back to podman"

            ## LAN-podman - Needed for SSH to git/forgejo
            iifname { "${lan-interface}" } oifname { "podman0" } accept comment "Allow trusted LAN to podman"
            iifname { "podman0" } oifname {  "${lan-interface}" } ct state established, related accept comment "Allow established back to LAN"

            ## podman-WAN
            iifname { "podman0" } oifname { "${wan-interface}" } accept comment "Allow trusted podman to WAN"
            iifname { "${wan-interface}" } oifname { "podman0" } ct state established, related accept comment "Allow established back to podman"

            ## WAN-Podman
            ${service-forward-rules}
            iifname { "podman0" } oifname { "${wan-interface}" } ct state established, related accept comment "Allow established back to podman"

            ## @TODO: Confirm which, if any, of these are needed.

            ## Headscale-WAN
            iifname { "tailscale0" } oifname { "${wan-interface}" } accept comment "Allow trusted tailscale to WAN"
            iifname { "${wan-interface}" } oifname { "tailscale0" } ct state established, related accept comment "Allow established back to tailscale"

            ## WAN-Headscale (neded for relaying?)
            iifname { "${wan-interface}" } oifname { "tailscale0" } accept comment "Allow trusted tailscale to WAN"
            iifname { "tailscale0" } oifname { "${wan-interface}" } ct state established, related accept comment "Allow established back to tailscale"

            ## Headscale-LAN
            iifname { "tailscale0" } oifname { "${lan-interface}" } accept comment "Allow trusted tailscale to LAN"
            iifname { "${lan-interface}" } oifname { "tailscale0" } ct state established, related accept comment "Allow established back to tailscale"

            ## LAN-Headscale
            iifname { "${lan-interface}" } oifname { "tailscale0" } accept comment "Allow trusted LAN to tailscale"
            iifname { "tailscale0" } oifname { "${lan-interface}" } ct state established, related accept comment "Allow established back to lan"

            ## Podman-Headscale
            iifname { "podman0" } oifname { "tailscale0" } accept comment "Allow trusted podman to tailscale"
            iifname { "tailscale0" } oifname { "podman0" } ct state established, related accept comment "Allow established back to podman"

            ## Headscale-Podman
            iifname { "tailscale0" } oifname { "podman0" } accept comment "Allow trusted tailscale to podman"
            iifname { "podman0" } oifname { "tailscale0" } ct state established, related accept comment "Allow established back to tailscale"

            ## Netbird-WAN
            iifname { "wt0" } oifname { "${wan-interface}" } accept comment "Allow trusted netbird to WAN"
            iifname { "${wan-interface}" } oifname { "wt0" } ct state established, related accept comment "Allow established back to netbird"

            ## Netbird-LAN
            iifname { "wt0" } oifname { "${lan-interface}" } accept comment "Allow trusted netbird to LAN"
            iifname { "${lan-interface}" } oifname { "wt0" } ct state established, related accept comment "Allow established back to netbird"

            ## LAN-Netbird
            iifname { "${lan-interface}" } oifname { "wt0" } accept comment "Allow trusted LAN to netbird"
            iifname { "wt0" } oifname { "${lan-interface}" } ct state established, related accept comment "Allow established back to lan"

            ## Podman-Netbird
            iifname { "podman0" } oifname { "wt0" } accept comment "Allow trusted podman to netbird"
            iifname { "wt0" } oifname { "podman0" } ct state established, related accept comment "Allow established back to netbird"

            ## Netbird-Podman
            iifname { "wt0" } oifname { "podman0" } accept comment "Allow trusted netbird to podman"
            iifname { "podman0" } oifname { "wt0" } ct state established, related accept comment "Allow established back to netbird"

            ## Per-guest-network isolation policy (internet-access /
            ## lan-access / inter-network-access). Generated from
            ## config.homefree.network.guest-networks. Postrouting NAT
            ## above (`oifname wan masquerade`) catches outbound from
            ## any VLAN automatically, so no per-VLAN NAT rules needed.
            ${guest-network-forward-rules}
          }
        }

        ## only need "ip" (ipv4), not "inet" (ipv4+ipv6) as it breaks ipv6 on clients. NAT is not needed for ipv6.
        table ip nat {
          chain prerouting {
            ## Lower priority number indicates higher priority
            type nat hook prerouting priority 0; policy accept;
          }

          # for all packets to WAN, after routing, replace source address with primary IP of WAN interface
          chain postrouting {
            type nat hook postrouting priority 100; policy accept;
            ## This handles tailscale0 and the lan interface
            oifname "${wan-interface}" masquerade
          }
        }
      '';
    };
  };

  #-----------------------------------------------------------------------------------------------------
  # Performance Tuning
  #-----------------------------------------------------------------------------------------------------

  systemd.services.configure-ethernet = lib.optionalAttrs config.homefree.network.router.enable {
    wantedBy = [ "multi-user.target" ];
    ## Disabled as it should be handled by systemd.network.links above
    enable = false;
    serviceConfig = {
      User = "root";
      Group = "root";
    };
    # script = builtins.readFile ../scripts/tune_router_performance.sh;
    script = ''
      ETHTOOL=${pkgs.ethtool}/bin/ethtool

      # In case interface is plugged into port that is faster than 1Gbps
      $ETHTOOL -s ${wan-interface} speed 1000 duplex full autoneg on
      $ETHTOOL -s ${wan-interface} rx 2048 tx 2048
    '';
  };

  ## @TODO: This was cargo-culted. Evaluate it for efficacy and correctness.
  systemd.services.tune-router-performance = lib.optionalAttrs config.homefree.network.router.enable {
    wantedBy = [ "multi-user.target" ];
    ## CURRENTLY DISABLED - Need to stabilize network first before enabling this
    enable = false;
    serviceConfig = {
      User = "root";
      Group = "root";
    };
    # script = builtins.readFile ../scripts/tune_router_performance.sh;
    script = ''
      GREP=${pkgs.gnugrep}/bin/grep
      AWK=${pkgs.gawk}/bin/awk
      # SMP - Symmetric MultiProcessing
      # RPS - Receive Packet Steering

      smp1=3
      rps1=2
      smp2=3
      rps2=2

      wan_irq=$($GREP ${wan-interface} /proc/interrupts | $AWK '{ print $1+0 }')

      # set balancer for enp1s0
      echo $smp1 > /proc/irq/$wan_irq/smp_affinity

      # set rps for wan interface
      echo $rps1 > /sys/class/net/${wan-interface}/queues/rx-0/rps_cpus

      lan_irq=$($GREP ${lan-interface} /proc/interrupts | $AWK '{ print $1+0 }')

      # set balancer for enp2s0
      # echo $smp2 > /proc/irq/$lan_irq/smp_affinity

      # set rps for lan interface
      echo $rps2 > /sys/class/net/${lan-interface}/queues/rx-0/rps_cpus
    '';
  };

  #-----------------------------------------------------------------------------------------------------
  # DHCP/DNS
  #-----------------------------------------------------------------------------------------------------

  # See: https://nixos.wiki/wiki/Systemd-resolved
  ## Disabled as Unbound + Adguard is used instead
  services.resolved = lib.optionalAttrs config.homefree.network.router.enable {
    enable = false;
    settings.Resolve = {
      DNSSEC = "true";
      Domains = [ "~." ];
      FallbackDNS = [ "1.1.1.1#one.one.one.one" "1.0.0.1#one.one.one.one" ];
      DNSOverTLS = "true";
    };
  };

  #-----------------------------------------------------------------------------------------------------
  # Service Discovery
  #-----------------------------------------------------------------------------------------------------

  services.avahi = lib.optionalAttrs config.homefree.network.router.enable {
    enable = true;
    reflector = true;
    allowInterfaces = [
      # "lan"
      # "iot"
      # "guest"
      lan-interface
    ];

    # network locator e.g. scanners and printers
    nssmdns4 = true;
  };

  #-----------------------------------------------------------------------------------------------------
  # Packages
  #-----------------------------------------------------------------------------------------------------

  environment.systemPackages = with pkgs; [
    ethtool             # manage NIC settings (offload, NIC feeatures, ...)
    tcpdump             # view network traffic
    conntrack-tools     # view network connection states
  ];
}
