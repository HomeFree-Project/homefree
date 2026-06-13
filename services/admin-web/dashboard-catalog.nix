# Home-dashboard catalog: per-service `category` (grouping), `description`
# (tagline), and optional `hidden` default, for the home.<domain> app
# launcher. Keyed by service-config `label`.
#
# ┌─────────────────────────────────────────────────────────────────────┐
# │ FIRST-PARTY APPS ONLY. This file ships in the core homefree repo, so  │
# │ it must contain ONLY apps that also ship here (apps/* and core        │
# │ services/*). NEVER add a plugin or an External Proxy label here —     │
# │ that is instance/plugin-specific data and does not belong in core:    │
# │   • Plugins (separate repos) declare their own category/description/  │
# │     icon in their OWN service-config.                                 │
# │   • External Proxies set category/description in homefree-config.json │
# │     (the External Proxies admin form), read by the loader.            │
# │ The admin-config merge prefers an entry's own category over this, so  │
# │ a plugin/proxy that self-declares always wins regardless.             │
# └─────────────────────────────────────────────────────────────────────┘
#
# Child instances (mediawiki_grimoire, minecraft_*) fall back to their
# parent label's entry. The user's own AI-built apps are force-grouped
# into "My Apps" by the backend regardless of what is here.
#
# Categories are display-ordered by the frontend (CATEGORY_ORDER in
# web-platform/frontend/src/components/user/user-app.js). An unlisted
# label renders ungrouped under "Misc".
{
  # ── Media ────────────────────────────────────────────────────────
  immich    = { category = "Media"; description = "Self-hosted photo and video library with automatic phone backup."; };
  jellyfin  = { category = "Media"; description = "Stream your movies, shows, and music to any device."; };
  azuracast = { category = "Media"; description = "Run your own internet radio station with streaming and scheduling."; };
  lidarr    = { category = "Media"; description = "Automatically find, download, and organize your music."; };
  nzbget    = { category = "Media"; description = "Fast Usenet downloader for your media library."; };
  nomad     = { category = "Media"; description = "Offline knowledge server — download and browse content libraries offline."; };

  # ── Smart Home ───────────────────────────────────────────────────
  home-assistant   = { category = "Smart Home"; description = "Automate and control all your smart-home devices from one hub."; };
  zwave-js-ui      = { category = "Smart Home"; description = "Manage and control your Z-Wave smart-home network."; };
  frigate          = { category = "Smart Home"; description = "AI camera NVR with real-time object detection."; };
  opensprinkler-ui = { category = "Smart Home"; description = "Schedule and control your irrigation system."; hidden = true; };
  opensprinkler    = { category = "Smart Home"; description = "Schedule and control your irrigation system."; };

  # ── Office & Productivity ────────────────────────────────────────
  grocy      = { category = "Office & Productivity"; description = "Track groceries, chores, recipes, and household tasks."; };
  homebox    = { category = "Office & Productivity"; description = "Catalog your belongings, warranties, and where things live."; };
  snipe-it   = { category = "Office & Productivity"; description = "IT asset management for hardware, licenses, and accessories."; };
  odoo       = { category = "Office & Productivity"; description = "All-in-one business suite: CRM, invoicing, inventory, and more."; };
  linkwarden = { category = "Office & Productivity"; description = "Save, archive, and organize bookmarks and articles."; };
  freshrss   = { category = "Office & Productivity"; description = "Follow all your news and sites in one RSS reader."; };
  mediawiki  = { category = "Office & Productivity"; description = "Self-hosted wiki for documentation and knowledge."; };
  trilium    = { category = "Office & Productivity"; description = "Build a personal knowledge base of linked notes."; };
  joplin     = { category = "Office & Productivity"; description = "Encrypted notes and to-dos that sync across devices."; };
  cryptpad   = { category = "Office & Productivity"; description = "End-to-end encrypted documents, sheets, and collaboration."; };
  nextcloud  = { category = "Office & Productivity"; description = "Your private cloud for files, calendars, and contacts."; };
  webdav     = { category = "Office & Productivity"; description = "Simple WebDAV file access and sync."; };
  baikal     = { category = "Office & Productivity"; description = "Calendar (CalDAV) and contacts (CardDAV) server."; };
  radicale   = { category = "Office & Productivity"; description = "Lightweight calendar and contacts (CalDAV/CardDAV) server."; };

  # ── Communication ────────────────────────────────────────────────
  matrix = { category = "Communication"; description = "Secure, decentralized chat and messaging."; };
  ntfy   = { category = "Communication"; description = "Push notifications to your phone from any script or service."; };

  # ── Security & Identity ──────────────────────────────────────────
  vaultwarden = { category = "Security & Identity"; description = "Self-hosted password manager, compatible with Bitwarden."; };
  zitadel     = { category = "Security & Identity"; description = "Single sign-on and identity provider for your apps."; };

  # ── Games ────────────────────────────────────────────────────────
  minecraft = { category = "Games"; description = "Host your own Minecraft world."; };

  # ── AI ───────────────────────────────────────────────────────────
  ollama = { category = "AI"; description = "Run large language models locally on your own hardware."; };

  # ── Network & VPN ────────────────────────────────────────────────
  adguard   = { category = "Network & VPN"; description = "Network-wide ad and tracker blocking."; };
  headscale = { category = "Network & VPN"; description = "Self-hosted control server for your Tailscale VPN."; };
  netbird   = { category = "Network & VPN"; description = "Peer-to-peer WireGuard VPN mesh for your devices."; };
  unifi     = { category = "Network & VPN"; description = "Manage your UniFi network gear and Wi-Fi."; };

  # ── Developer ────────────────────────────────────────────────────
  forgejo   = { category = "Developer"; description = "Self-hosted Git forge for code, issues, and releases."; };
  radicle   = { category = "Developer"; description = "Peer-to-peer, sovereign code collaboration."; };
  screeenly = { category = "Developer"; description = "Capture website screenshots via a simple API."; };

  # ── Infrastructure ───────────────────────────────────────────────
  cockpit       = { category = "Infrastructure"; description = "Web console to administer the server."; };
  backup-canary = { category = "Infrastructure"; description = "Confirms your backups are restorable."; };
}
