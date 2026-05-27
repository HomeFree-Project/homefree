{ config, lib, pkgs, ... }:
let
  lan-interface = config.homefree.network.lan-interface;
  wan-interface = config.homefree.network.wan-interface;
  lan-address = config.homefree.network.lan-address;
  lan-netmask = config.homefree.network.lan-netmask;
  dhcp-range-start = config.homefree.network.dhcp-range-start;
  dhcp-range-end = config.homefree.network.dhcp-range-end;
  dhcp-lease-time = config.homefree.network.dhcp-lease-time;
  localDomain = config.homefree.system.localDomain;
  guest-networks = config.homefree.network.guest-networks;

  ## CIDR prefix length → dotted-decimal netmask. Per-octet lookup;
  ## the 9-element table covers every prefix from 0..32 by clamping.
  prefixToNetmask = prefix:
    let
      bitsToOctet = n:
        if n >= 8 then 255
        else if n <= 0 then 0
        else builtins.elemAt [ 0 128 192 224 240 248 252 254 ] n;
      o1 = bitsToOctet prefix;
      o2 = bitsToOctet (prefix - 8);
      o3 = bitsToOctet (prefix - 16);
      o4 = bitsToOctet (prefix - 24);
    in
    "${toString o1}.${toString o2}.${toString o3}.${toString o4}";
  cidrPrefix = subnet:
    lib.toInt (builtins.elemAt (lib.splitString "/" subnet) 1);
  dhcp-script = pkgs.writeShellScript "dhcp-script" ''
    # $1 = action (add, del, old)
    # $2 = MAC address
    # $3 = IP address
    # $4 = hostname

    if [ "$1" = "add" ]; then
      ${pkgs.dnsutils}/bin/nsupdate -l <<EOF
      server 127.0.0.1
      zone ${localDomain}
      update delete $4.${localDomain} A
      update add $4.${localDomain} 3600 A $3
      send
    EOF
      ${pkgs.dnsutils}/bin/nsupdate -l <<EOF
      server 127.0.0.1
      update delete $4 A
      update add $4 3600 A $3
      send
    EOF
    fi
  '';
in
{
  services.dnsmasq = {
    enable = true;

    settings = {
      ## @TODO
      ## @WARNING - changes to this do not clear out old entries from /etc/dnsmasq-conf.conf

      ## Only DHCP server on network
      dhcp-authoritative = true;

      ## Don't listen to anything on wan interface
      except-interface = wan-interface;

      ## Never forward addresses in the non-routed address spaces (don't send bogus requests to internet)
      bogus-priv = true;

      ## Enable Router Advertising for ipv6
      enable-ra = true;

      ## Ipv6
      # ra-param = "${lan-interface},0,0";  ## This disables router-advertisements
      ## Send out advertisements every 10 seconds, and make sure they are valid for 7200 seconds (2h)
       ra-param = "${lan-interface},10,7200";

      ## DNS servers to pass to clients
      server = [ lan-address ];

      ## Which interfaces to bind to — main LAN plus every guest-network
      ## VLAN sub-interface (created in profiles/router.nix from
      ## config.homefree.network.guest-networks).
      interface = [ lan-interface ] ++ (lib.map (gn: gn.id) guest-networks);

      ## IP ranges to hand out — one entry per interface. Each guest
      ## network's dhcp-range is bound to its sub-interface; dnsmasq
      ## picks the right scope by the interface the request arrived on
      ## (and by IP-in-subnet match for static reservations).
      dhcp-range = [
        ## "constructor" gets the ipv6 range from the WAN interface since it's dynamic can't be hard coded here.
        ## "ra-names" includes the hostname in router advertisement messages for local name resolution
        ## "slaac" specifies how addresses are allocated. In this case, it tells clients to create
        ## their own address by using the advertised prefix + MAC address, and then the clients send
        ## a message to validate that it's not a duplicate with another address.
        "tag:${lan-interface},::1,constructor:${lan-interface},ra-names,slaac,12h"                        # ipv6
        "${lan-interface},${dhcp-range-start},${dhcp-range-end},${lan-netmask},${dhcp-lease-time}"       # ipv4
      ] ++ (lib.map (gn:
        "${gn.id},${gn.dhcp-range-start},${gn.dhcp-range-end},${prefixToNetmask (cidrPrefix gn.subnet)},${dhcp-lease-time}"
      ) guest-networks);

      ## Disable DNS, since Unbound is handling DNS
      port = 0;

      cache-size = 500;

      ## Additional DHCP options
      dhcp-option = [
        "option6:dns-server,[fd01::1]"  # Points to AdGuard on fd01::1 (which forwards to Unbound)
        "option:dns-server,${lan-address}"
      ];

      dhcp-host = lib.map (ip-config:
        "${ip-config.mac-address},${ip-config.hostname},${ip-config.ip},${config.homefree.network.static-ip-expiration}")
        config.homefree.network.static-ips;

      dhcp-script = "${dhcp-script}";
    };
  };

  ## dhcpd6 is obsolete
  # services.dhcpd6 = {};
}

