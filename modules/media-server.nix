{ config, lib, ... }:

# DLNA/UPnP media server (ReadyMedia / minidlna) — the same lineage Synology's
# "Media Server" is built on. Lets smart TVs and AV receivers on the LAN browse
# and play media straight off this box (Phase 2c of the Storage & NAS feature).
#
# Runs as a HOST systemd service (the native NixOS `services.minidlna`), NOT a
# podman container: DLNA discovery needs SSDP multicast on the LAN (UDP 1900),
# which podman bridge networking cannot do. This is the same reason Jellyfin's
# DLNA ports are deliberately omitted (apps/jellyfin/default.nix) — Jellyfin
# stays a separate streaming app; minidlna is the DLNA engine.
#
# Driven by the per-folder `media` flag on homefree.storage.shares (set from the
# admin UI "Shared Folders" page). Inert (minidlna stays off) when no folder
# opts in.
#
# LAN-only and UNAUTHENTICATED by design: DLNA has no login, so any device on
# the LAN can read an exposed folder. Reachability comes from the router input
# chain (profiles/router.nix) accepting LAN->host and dropping unsolicited WAN
# traffic — exactly like the NFS exports in modules/storage-shares.nix. So no
# port opening is needed and `openFirewall` is left off (it would add a global
# rule that could reach the WAN).
#
# See docs/agent-notes/dlna-media-server.md for the SSDP 1900 coexistence with
# Home Assistant and the minidlna-user read-permission gotcha.

let
  inherit (lib) mkIf;

  # minidlna media_dir type prefixes; "all" emits the bare path so a folder
  # contributes audio + video + images.
  prefixFor = t:
    if t == "audio" then "A,"
    else if t == "video" then "V,"
    else if t == "pictures" then "P,"
    else "";

  # A folder is served whenever its media toggle is on. This is INDEPENDENT of
  # the NFS `enabled` flag (which is now purely the NFS-export toggle): a
  # media-only folder has NFS off (`enabled = false`) and `media = true`, and
  # must still be served.
  mediaShares = lib.filter (s: s.media or false) config.homefree.storage.shares;

  mediaDirs = lib.map (s: "${prefixFor (s.media-type or "all")}${s.path}") mediaShares;

  friendlyName =
    let n = config.homefree.storage.media-server.friendly-name or null;
    in if n != null && n != "" then n else config.homefree.system.hostName;
in
{
  # Register minidlna's HTTP/SOAP port with the HomeFree port allocator so
  # it can never silently collide with a pinned app port. Its upstream
  # default (8200) is the SAME fixed port NOMAD's FlatNotes content service
  # hardcodes (apps/nomad/default.nix) — two servers fighting over 8200 left
  # flatnotes.<domain> proxying into minidlna and returning HTTP 400. minidlna
  # is the movable side: DLNA clients discover the HTTP port via SSDP, so it
  # can live anywhere. Registered unconditionally (and STABLE-reserved) so the
  # slot is held even while no folder opts into media serving.
  homefree.internal.port-requests = [{ label = "minidlna"; port-request = null; }];

  services.minidlna = mkIf (mediaDirs != []) {
    enable = true;
    # LAN reachability is handled by the router firewall; never expose to WAN.
    openFirewall = false;
    settings = {
      # Allocator-assigned, off the upstream default 8200 (which collides with
      # NOMAD FlatNotes — see the port-requests note above).
      port = config.homefree.allocPort "minidlna";
      media_dir = mediaDirs;
      friendly_name = friendlyName;
      # Pick up newly-copied files without a manual rescan (Synology behaviour:
      # drop a file and it shows up on the TV).
      inotify = "yes";
      # Periodic SSDP announce so devices that missed the initial multicast
      # still discover the server on a quiet network.
      notify_interval = 60;
    };
  };
}
