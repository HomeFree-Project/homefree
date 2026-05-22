{ config, lib, ... }:

# Exports the NFS shares recorded in `homefree.storage.shares` (Phase 2a of the
# Storage & NAS feature). Declarative and host/subnet-trust only — no per-user
# auth, because file protocols can't do OIDC SSO (SMB + per-user auth are a
# later phase). Shares are reachable only from the LAN: the router firewall
# (profiles/router.nix) accepts LAN->host and drops WAN, so no extra port
# opening is needed on a router-mode box. Inert (NFS server stays off) when no
# enabled shares exist.

let
  inherit (lib) mkIf;

  shares = lib.filter (s: s.enabled or true) config.homefree.storage.shares;

  lanSubnet = config.homefree.network.lan-subnet or null;

  # Split the free-form allowed-clients string into tokens; default to the LAN
  # subnet when empty so a share is never accidentally exported to the world.
  clientsFor = s:
    let
      spaced = builtins.replaceStrings [ "," ] [ " " ] s.allowed;
      toks = lib.filter (t: t != "") (lib.splitString " " spaced);
    in
      if toks != [] then toks
      else lib.optional (lanSubnet != null && lanSubnet != "") lanSubnet;

  # SAFETY: only export shares with at least one explicit client. A share with
  # no resolvable clients is dropped rather than emitted as a bare path (an
  # /etc/exports line with no client spec exports to every host).
  exportable = lib.filter (s: clientsFor s != []) shares;

  mkExportLine = s:
    let
      opts = (if s.read-only then "ro" else "rw") + ",sync,no_subtree_check,root_squash";
      clientStr = lib.concatMapStringsSep " " (c: "${c}(${opts})") (clientsFor s);
    in
      "${s.path} ${clientStr}";

  exportsText = lib.concatMapStringsSep "\n" mkExportLine exportable;
in
{
  services.nfs.server = mkIf (exportable != []) {
    enable = true;
    exports = exportsText + "\n";
  };
}
