# DLNA media server (minidlna)

How HomeFree exposes media folders to DLNA/UPnP clients (smart TVs, AV
receivers) — the capability that replaces a Synology "Media Server". Driven from
the admin UI **Shared Folders** page.

## Shape of the feature

- A row on Shared Folders is a *folder* (`name` + `path`). Each protocol toggles
  independently on that folder:
  - **NFS** — the existing `enabled` + `allowed`/`read-only`/`squash`/`anon-*`.
  - **Media server (DLNA)** — the `media` bool + `media-type`
    (`all`/`audio`/`video`/`pictures`).
  This mirrors the OpenMediaVault model (a shared folder referenced by multiple
  services), not a single "share = NFS export".
- Config path: per-folder `homefree.storage.shares.*.{media,media-type}` and the
  page-level `homefree.storage.media-server.friendly-name`. Schema in
  `module.nix`, JSON→Nix in `modules/homefree-config-loader.nix` (both with
  `or`-defaults, so old `homefree-config.json` files keep working — rule 11).
- Backend: `modules/media-server.nix` filters shares to
  `enabled && media`, maps each `path` to a `services.minidlna` `media_dir`
  entry with the `A,`/`V,`/`P,` type prefix (`all` ⇒ no prefix), and is inert
  (minidlna off) when no folder opts in. Wired into `configuration.nix`'s
  explicit host-modules `imports` (modules/ are NOT auto-discovered).

## Why a HOST service, not a podman container

DLNA discovery is SSDP over **UDP 1900 multicast** on the LAN. A podman bridge
network cannot carry LAN multicast, so a containerised DLNA server is
undiscoverable. minidlna therefore runs as the native NixOS
`services.minidlna` (host systemd unit) using the upstream-managed `minidlna`
system user (`config.ids.uids.minidlna`) — do NOT allocate an 800–899 UID, that
range is for container app users (rule 13).

This is the same reason **Jellyfin's DLNA ports are deliberately omitted**
(`apps/jellyfin/default.nix`). Jellyfin stays a separate streaming app consumed
via its own clients; minidlna is the DLNA engine. There is intentionally no
"flip between Jellyfin and minidlna as the DLNA server": Jellyfin's DLNA is a
deprecated plugin, needs host networking (same 1900 collision below), and its
libraries are not declaratively configurable.

## SSDP 1900 coexistence with Home Assistant ⚠️

If `apps/home-assistant` is enabled it runs with `--network=host` and its SSDP
integration **already binds UDP 1900**. minidlna also binds 1900 for SSDP. Both
set `SO_REUSEADDR` on the multicast listener, so they generally coexist
(incoming M-SEARCH multicast fans out to every bound socket; each responds) —
running HA alongside a DLNA server is a common setup. But it is **not
guaranteed**. After enabling, verify:

```
ss -ulnp | grep 1900           # minidlna (and HA) bound, no exclusivity error
journalctl -u minidlna         # no bind failure on 1900
```

`notify_interval = 60` is set so devices that miss the initial multicast still
get periodic announces. If the two genuinely conflict on a box, that is a
maintainer decision — do NOT silently work around it (rule 9).

## Firewall / privacy

DLNA is **LAN-only and unauthenticated** — any LAN device can read an exposed
folder, so it is opt-in per folder (default off). No firewall rule is added:
the router input chain (`profiles/router.nix`, nftables) already accepts
LAN→host and drops unsolicited WAN traffic, so 8200/tcp + 1900/udp are reachable
on the LAN and never the WAN. `services.minidlna.openFirewall` is left **off**
on purpose — it would add a global rule that could reach the WAN.

## Gotcha: folder must be readable by the `minidlna` user

minidlna scans as the `minidlna` system user. If the status page
(`http://<lan-address>:8200/`) shows zero audio/video/image counts, it is almost
always permissions on the media `path` — the files/dirs aren't readable by
`minidlna`. (No automatic `chown` — that would be a surprising mutation of the
user's data; fix permissions deliberately.)

## Verify on a real device

- `systemctl status minidlna` active; `journalctl -u minidlna` shows it scanning
  each `media_dir`.
- `curl -s http://<lan-address>:8200/` lists non-zero media counts.
- LG TV (Home Dashboard / external media) and Yamaha receiver (Server/DLNA
  input) show the server under its friendly name; browse and play a file.
- Drop a new file into an exposed folder → it appears without a manual rescan
  (`inotify = "yes"`).
