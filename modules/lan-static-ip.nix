# Static IP for the box itself when running in NON-router mode (HomeFree
# sitting behind someone else's router). In router mode profiles/router.nix
# owns all interface/IP config; in non-router mode nothing assigns an address
# and the box falls back to systemd-networkd DHCP (configuration.nix
# useNetworkd + hardware-configuration.nix useDHCP). This module fills that
# gap, driven by homefree.network.static.* (homefree-config.json
# network.static-ip-*).
#
# The address itself is lan-address/lan-subnet (NOT a separate field): in
# non-router mode the rest of the stack still keys off lan-address as "the
# box's own LAN IP" — Caddy binds private vhosts to `${lan-address}
# ${lan-address-v6}` (services/caddy/default.nix), unbound advertises internal
# names at lan-address, and the dns-ready gate (services/unbound/default.nix)
# blocks until `inet ${lan-address}` appears on the box. So we assign exactly
# lan-address (+ the lan-address-v6 ULA Caddy also binds) here, and add the two
# things router mode never needs: a default gateway and upstream resolvers.
# This mirrors the static-assignment shape from profiles/router.nix.
#
# Any incomplete/contradictory combination (enabled while router mode is on,
# enabled with no interface / no address / a malformed subnet) is a NO-OP plus
# a soft warning — NEVER a failed assertion or an eval error. A nixos-rebuild
# is the box's recovery surface (rule 10); a stale or half-filled config value
# from the UI must not be able to brick it. In particular the CIDR prefix is
# parsed defensively: a cleared "Subnet" field would otherwise make
# `elemAt (splitString "/" "") 1` throw at eval.
{ config, lib, ... }:
let
  net = config.homefree.network;
  s = net.static;
  iface = if s.interface != "" then s.interface else net.lan-interface;

  # Defensive CIDR parse: only valid when the subnet is "<addr>/<digits>".
  subnetParts = lib.splitString "/" net.lan-subnet;
  validSubnet =
    (builtins.length subnetParts == 2)
    && (builtins.match "[0-9]+" (builtins.elemAt subnetParts 1) != null);
  prefixLength = if validSubnet then lib.toInt (builtins.elemAt subnetParts 1) else 0;

  haveInterface = iface != "";
  haveAddress = net.lan-address != "";
  fieldsOk = haveInterface && haveAddress && validSubnet;

  # Act only in non-router mode AND with a complete, well-formed config — never
  # fight the router profile, and never half-configure networking (which could
  # cut the box off or fail to evaluate).
  active = s.enable && !net.router.enable && fieldsOk;

  # What's missing when static is on but not usable — for the warning below.
  missing =
    lib.optional (!haveInterface) "an interface (network.static-ip-interface or network.lan-interface)"
    ++ lib.optional (!haveAddress) "an IP address (network.lan-address)"
    ++ lib.optional (!validSubnet) "a CIDR subnet such as 192.168.1.0/24 (network.lan-subnet)";
in
{
  networking = lib.mkIf active ({
    # Turn off the networkd DHCP catch-all so the static address sticks.
    useDHCP = false;
    interfaces.${iface} = {
      useDHCP = false;
      ipv4.addresses = [{
        address = net.lan-address;
        prefixLength = prefixLength;
      }];
      # The inside ULA Caddy also binds for IPv6 split-horizon on private
      # vhosts; without it `bind ${lan-address-v6}` fails and Caddy dies.
      ipv6.addresses = [{
        address = net.lan-address-v6;
        prefixLength = 64;
      }];
    };
  }
  // lib.optionalAttrs (s.gateway != "") { defaultGateway = s.gateway; }
  // lib.optionalAttrs (s.nameservers != []) { nameservers = s.nameservers; });

  # Soft warnings only (printed at eval, never fatal) — see the header note.
  warnings =
    lib.optional (s.enable && net.router.enable)
      ("homefree.network.static.enable is ignored while router mode is on "
       + "(network.router-enable); the router profile owns the interfaces. "
       + "Turn off router mode to assign the box a static IP.")
    ++ lib.optional (s.enable && !net.router.enable && missing != [ ])
      ("homefree.network.static is enabled but missing "
       + builtins.concatStringsSep ", " missing
       + "; the box is left on DHCP.")
    ++ lib.optional (active && s.gateway == "")
      ("homefree.network.static has no gateway set (network.static-ip-gateway); "
       + "the box will have no default route and cannot reach the internet.");
}
