# Home-dashboard catalog: per-service `category` (grouping), `description`
# (tagline), and optional `hidden` (default for the "hide from dashboard"
# toggle) for the home.<domain> app launcher.
#
# Keyed by service-config `label`. Merged into each service-config entry
# at serialization time (services/admin-web/default.nix admin-config), as
# a DEFAULT only — an app/plugin that sets its own `category`/`description`
# on its service-config wins. Child instances (mediawiki_grimoire,
# minecraft_*) fall back to their parent label's entry.
#
# The user's own AI-built apps are force-grouped into "My Apps" by the
# backend regardless of what is here (web-platform/backend/simple_main.py).
#
# Categories are display-ordered by the frontend (CATEGORY_ORDER in
# web-platform/frontend/src/components/user/user-app.js): Media, Smart
# Home, Office & Productivity, Communication, Security & Identity, Games,
# AI, Network & VPN, Developer, Infrastructure. A category not in that
# list still renders (after the known ones); an unlisted label renders
# ungrouped under "Misc".
#
# `hidden = true` makes an app default to hidden on the dashboard (the
# per-app "Hide from dashboard" toggle in App Configuration defaults to
# this and the operator can override per deployment).
{
  # ── Media ────────────────────────────────────────────────────────
  immich    = { category = "Media"; description = "Self-hosted photo and video library with automatic phone backup."; };
  jellyfin  = { category = "Media"; description = "Stream your movies, shows, and music to any device."; };
  navidrome = { category = "Media"; description = "Stream your personal music collection from anywhere."; };
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
  rtl-sdr          = { category = "Smart Home"; description = "Software-defined radio receiver for your antenna."; };

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
  documenso  = { category = "Office & Productivity"; description = "Sign and send documents — a self-hosted DocuSign."; };
  grampsweb  = { category = "Office & Productivity"; description = "Family tree, genealogy records, and relationships."; };
  nextcloud  = { category = "Office & Productivity"; description = "Your private cloud for files, calendars, and contacts."; };
  webdav     = { category = "Office & Productivity"; description = "Simple WebDAV file access and sync."; };
  baikal     = { category = "Office & Productivity"; description = "Calendar (CalDAV) and contacts (CardDAV) server."; };
  radicale   = { category = "Office & Productivity"; description = "Lightweight calendar and contacts (CalDAV/CardDAV) server."; };
  cal-diy    = { category = "Office & Productivity"; description = "Self-hosted shared calendar."; };

  # ── Communication ────────────────────────────────────────────────
  matrix = { category = "Communication"; description = "Secure, decentralized chat and messaging."; };
  ntfy   = { category = "Communication"; description = "Push notifications to your phone from any script or service."; };

  # ── Security & Identity ──────────────────────────────────────────
  vaultwarden = { category = "Security & Identity"; description = "Self-hosted password manager, compatible with Bitwarden."; };
  zitadel     = { category = "Security & Identity"; description = "Single sign-on and identity provider for your apps."; };

  # ── Games ────────────────────────────────────────────────────────
  minecraft = { category = "Games"; description = "Host your own Minecraft world."; };

  # ── AI ───────────────────────────────────────────────────────────
  ollama      = { category = "AI"; description = "Run large language models locally on your own hardware."; };
  imagegen    = { category = "AI"; description = "Generate images with AI."; };
  homefree-ai = { category = "AI"; description = "Build your own apps by chatting with AI."; };
  bonsai      = { category = "AI"; description = "AI image studio for generating and editing images."; };

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
  cockpit              = { category = "Infrastructure"; description = "Web console to administer the server."; };
  backup-canary        = { category = "Infrastructure"; description = "Confirms your backups are restorable."; };
  homefree-aoostar-lcd = { category = "Infrastructure"; description = "Front-panel LCD status display."; };
}
