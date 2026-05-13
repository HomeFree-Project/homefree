"""
Installation service - handles the actual NixOS installation process
Ported from Calamares nixos module
"""

import os
import subprocess
import threading
import logging
import psutil
from pathlib import Path
from typing import Dict, Any, Optional

from services.config import ConfigService
from services.network import NetworkService
from utils.privileged import run_privileged, popen_privileged, write_file_privileged, mkdir_privileged

logger = logging.getLogger(__name__)


class InstallationService:
    """Service for managing the NixOS installation process"""

    _status: Dict[str, Any] = {
        'step': 'Not started',
        'progress': 0.0,
        'message': '',
        'completed': False,
        'error': None,
    }

    _install_thread: Optional[threading.Thread] = None
    _running = False

    # Templates for configuration files
    FLAKE_TEMPLATE = """{
  description = "HomeFree NixOS Configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    homefree-base.url = "git+https://git.homefree.host/homefree/homefree.git?ref=build-image-admin-ui";@@dev_input@@
  };

  outputs = { self, nixpkgs, homefree-base@@dev_output_arg@@, ... }@inputs:
  let
    system = "x86_64-linux";@@dev_let@@
  in {
    nixosConfigurations = {
      @@hostname@@ = nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [
          @@homefree_module@@
          ./configuration.nix
          ./homefree-configuration.nix
        ];
        specialArgs = {
          inherit system;
          homefree-inputs = @@homefree_inputs@@;
        };
      };
    };
  };
}
"""

    # JSON configuration template - this is written to homefree-config.json
    HOMEFREE_JSON_TEMPLATE = """{
  "system": {
    "domain": "@@domain@@",
    "hostName": "@@hostname@@",
    "timeZone": "@@timezone@@",
    "defaultLocale": "@@locale@@",
    "countryCode": "@@country_code@@",
    "elevation": @@elevation@@,
    "latitude": @@latitude@@,
    "longitude": @@longitude@@,
    "unitSystem": "@@unit_system@@",
    "currency": @@currency_json@@,
    "language": @@language_json@@,
    "keyMap": "@@vconsole@@",
    "adminUsername": "@@username@@",
    "adminDescription": "@@fullname@@",
    "adminEmail": "@@email@@",
    "localDomain": "lan",
    "additionalDomains": [],
    "authorizedKeys": []
  },
  "network": {
    "wan_interface": "@@wan_interface@@",
    "lan_interface": "@@lan_interface@@",
    "router_enable": @@router_enable@@,
    "lan_address": "@@lan_address@@",
    "lan_subnet": "@@lan_subnet@@",
    "dhcp_range_start": "@@dhcp_range_start@@",
    "dhcp_range_end": "@@dhcp_range_end@@",
    "enable_adblock": false,
    "wan_bitrate_mbps_down": null,
    "wan_bitrate_mbps_up": null,
    "static_ips": []
  },
  "dns": {
    "overrides": [],
    "dynamic_dns": {
      "interval": "10m",
      "usev4": "webv4, webv4=ipinfo.io/ip",
      "usev6": "webv6, webv6=v6.ipinfo.io/ip",
      "zones": []
    },
    "cert_management": null
  },
  "mounts": [],
  "sso": {
    "allowUserRegistration": false,
    "per-service": {}
  },
  "services": {
    "adguard": {
      "enable": true,
      "public": false
    },
    "admin": {
      "enable": true,
      "public": false
    },
    "landing-page": {
      "enable": true,
      "public": false
    },
    "headscale": {
      "enable": false,
      "public": false
    },
    "postgres-vectorchord": {
      "enable": true,
      "public": false
    },
    "lidarr": {
      "enable": false,
      "public": false
    },
    "vaultwarden": {
      "enable": false,
      "public": false
    },
    "webdav": {
      "enable": false,
      "public": false
    },
    "linkwarden": {
      "enable": false,
      "public": false
    },
    "joplin": {
      "enable": false,
      "public": false
    },
    "homeassistant": {
      "enable": false,
      "public": false
    },
    "nextcloud": {
      "enable": false,
      "public": false
    },
    "snipe-it": {
      "enable": false,
      "public": false
    },
    "frigate": {
      "enable": false,
      "public": false
    },
    "unifi": {
      "enable": false,
      "public": false
    },
    "cryptpad": {
      "enable": false,
      "public": false,
      "adminKeys": []
    },
    "forgejo": {
      "enable": false,
      "public": false
    },
    "jellyfin": {
      "enable": false,
      "public": false
    },
    "nzbget": {
      "enable": false,
      "public": false
    },
    "radicale": {
      "enable": false,
      "public": false
    },
    "freshrss": {
      "enable": false,
      "public": false
    },
    "minecraft": {
      "enable": false,
      "public": false
    },
    "homebox": {
      "enable": false,
      "public": false
    },
    "ollama": {
      "enable": false,
      "public": false
    },
    "grocy": {
      "enable": false,
      "public": false
    },
    "zitadel": {
      "enable": false,
      "public": false
    },
    "immich": {
      "enable": false,
      "public": false
    },
    "matrix": {
      "enable": false,
      "public": false,
      "enable_federation": false,
      "federation_domain_whitelist": [ "matrix.org", "nixos.org", "homefree.host", "rycee.net", "gnome.org" ],
      "admin_account": null,
      "server_name": null
    },
    "mediawiki": {
      "enable": false,
      "public": false
    },
    "screeenly": {
      "enable": false,
      "public": false
    },
    "baikal": {
      "enable": false,
      "public": false
    },
    "trilium": {
      "enable": false,
      "public": false
    },
    "azuracast": {
      "enable": false,
      "public": false
    },
    "odoo": {
      "enable": false,
      "public": false
    },
    "unifi-os": {
      "enable": false,
      "public": false
    }
  },
  "service_config": [],
  "backups": {
    "enable": false,
    "to_path": "",
    "extra_from_paths": [],
    "backblaze_enable": false,
    "backblaze_bucket": ""
  }
}
"""

    # Nix configuration template - imports JSON configuration
    HOMEFREE_CONFIG_TEMPLATE = """{ config, lib, pkgs, ... }:

let
  # Load configuration from JSON file in the same directory as flake.nix
  # This uses a relative path which works in pure evaluation mode
  jsonData = builtins.fromJSON (builtins.readFile ./homefree-config.json);

  # Helper to convert snake_case to camelCase for Nix attribute names
  # Note: We'll keep the JSON in snake_case for Python compatibility
  # and convert here for Nix
in
{
  homefree = {
    system = {
      domain = jsonData.system.domain;
      hostName = jsonData.system.hostName;
      timeZone = jsonData.system.timeZone;
      defaultLocale = jsonData.system.defaultLocale;
      countryCode = jsonData.system.countryCode;
      ## Localization extras — `or null`/default so an older JSON
      ## file (pre-2026-05) without these keys evals cleanly.
      elevation = jsonData.system.elevation or null;
      latitude = jsonData.system.latitude or null;
      longitude = jsonData.system.longitude or null;
      unitSystem = jsonData.system.unitSystem or "metric";
      currency = jsonData.system.currency or null;
      language = jsonData.system.language or null;
      keyMap = jsonData.system.keyMap;
      adminUsername = jsonData.system.adminUsername;
      adminDescription = jsonData.system.adminDescription;
      adminEmail = jsonData.system.adminEmail;
      localDomain = jsonData.system.localDomain;
      additionalDomains = jsonData.system.additionalDomains;
      authorizedKeys = jsonData.system.authorizedKeys;
    };

    network = {
      wan-interface = jsonData.network.wan_interface;
      lan-interface = jsonData.network.lan_interface;
      router.enable = jsonData.network.router_enable;
      lan-address = jsonData.network.lan_address;
      lan-subnet = jsonData.network.lan_subnet;
      dhcp-range-start = jsonData.network.dhcp_range_start;
      dhcp-range-end = jsonData.network.dhcp_range_end;
      enable-adblock = jsonData.network.enable_adblock;
      wan-bitrate-mbps-down = jsonData.network.wan_bitrate_mbps_down;
      wan-bitrate-mbps-up = jsonData.network.wan_bitrate_mbps_up;

      # Static IPs conversion
      static-ips = map (ip: {
        mac-address = ip.mac_address;
        hostname = ip.hostname;
        ip = ip.ip;
        wan-access = ip.wan_access or true;
      }) jsonData.network.static_ips;
    };

    dns = {
      local = {
        overrides = map (override: {
          hostname = override.hostname;
          domain = override.domain;
          ip = override.ip;
        }) jsonData.dns.overrides;
      };

      ## Remote DNS / dynamic-dns / wildcard cert acquisition. The
      ## JSON carries non-secret metadata (zone names, protocol,
      ## username, etc.) plus a *secret key* per zone — never the
      ## password itself. The actual secret file lives at
      ## /var/lib/homefree-secrets/ddclient/<key> (zone passwords)
      ## and /var/lib/homefree-secrets/dns/api-token (DNS-01 API
      ## token). Users either copy these in from the existing
      ## SOPS-managed source on the previous host or populate them
      ## via the secrets UI.
      remote = {
        cert-management.dns-01 = {
          provider = jsonData.dns.cert_management.provider or null;
          resolvers = jsonData.dns.cert_management.resolvers or [ "1.1.1.1" ];
          secrets.api-token =
            if (jsonData.dns.cert_management.provider or null) == null
            then null
            else /var/lib/homefree-secrets/dns/api-token;
        };
        dynamic-dns = {
          interval = jsonData.dns.dynamic_dns.interval or "10m";
          usev4    = jsonData.dns.dynamic_dns.usev4 or "webv4, webv4=ipinfo.io/ip";
          usev6    = jsonData.dns.dynamic_dns.usev6 or "webv6, webv6=v6.ipinfo.io/ip";
          zones = map (z: {
            disable  = z.disable or false;
            zone     = z.zone;
            protocol = z.protocol or "hetzner";
            username = z.username;
            domains  = z.domains or [ "@" "*" ];
            passwordFile =
              ## Allow callers to skip the path-existence check on
              ## the schema side by emitting a /run/keys-style
              ## non-existent stub when the secret hasn't been
              ## dropped yet. Once the file is in place at
              ## /var/lib/homefree-secrets/ddclient/<key>, ddclient
              ## will pick it up.
              /var/lib/homefree-secrets/ddclient + ("/" + (z.password_secret_key or "password"));
          }) (jsonData.dns.dynamic_dns.zones or []);
        };
      };
    };

    mounts = map (m: {
      mount-point   = m.mount_point;
      device        = m.device;
      fs-type       = m.fs_type or "nfs";
      nfs-version   = m.nfs_version or "3";
      automount     = m.automount or true;
      idle-timeout  = m.idle_timeout or "600";
      extra-options = m.extra_options or [];
    }) (jsonData.mounts or []);

    ## Per-service SSO opt-out toggles. The JSON stores
    ##   { "per-service": { "adguard": { "enable": false }, ... } }
    ## We map it 1:1 to homefree.sso.per-service. Missing entries fall
    ## through to the option's default (enable = true) defined in
    ## services/sso.nix, so a missing key means "SSO on" rather than
    ## a build error.
    sso = {
      allowUserRegistration = jsonData.sso.allowUserRegistration or false;
      per-service = lib.mapAttrs (_: v: {
        enable = v.enable or true;
      }) (jsonData.sso.per-service or {});
    };

    services = {
      adguard.enable = jsonData.services.adguard.enable or false;
      adguard.public = jsonData.services.adguard.public or false;

      admin.enable = jsonData.services.admin.enable or false;
      admin.public = jsonData.services.admin.public or false;

      landing-page.enable = jsonData.services.landing-page.enable or false;
      landing-page.public = jsonData.services.landing-page.public or false;

      headscale.enable = jsonData.services.headscale.enable or false;
      headscale.public = jsonData.services.headscale.public or false;

      postgres-vectorchord.enable = jsonData.services.postgres-vectorchord.enable or false;
      postgres-vectorchord.public = jsonData.services.postgres-vectorchord.public or false;

      lidarr.enable = jsonData.services.lidarr.enable or false;
      lidarr.public = jsonData.services.lidarr.public or false;
      lidarr.media-path = jsonData.services.lidarr.media_path or null;
      lidarr.downloads-path = jsonData.services.lidarr.downloads_path or null;

      vaultwarden.enable = jsonData.services.vaultwarden.enable or false;
      vaultwarden.public = jsonData.services.vaultwarden.public or false;

      webdav.enable = jsonData.services.webdav.enable or false;
      webdav.public = jsonData.services.webdav.public or false;

      linkwarden.enable = jsonData.services.linkwarden.enable or false;
      linkwarden.public = jsonData.services.linkwarden.public or false;

      joplin.enable = jsonData.services.joplin.enable or false;
      joplin.public = jsonData.services.joplin.public or false;

      homeassistant.enable = jsonData.services.homeassistant.enable or false;
      homeassistant.public = jsonData.services.homeassistant.public or false;

      nextcloud.enable = jsonData.services.nextcloud.enable or false;
      nextcloud.public = jsonData.services.nextcloud.public or false;

      snipe-it.enable = jsonData.services.snipe-it.enable or false;
      snipe-it.public = jsonData.services.snipe-it.public or false;

      frigate.enable = jsonData.services.frigate.enable or false;
      frigate.public = jsonData.services.frigate.public or false;
      frigate.media-path = jsonData.services.frigate.media_path or null;
      frigate.hwaccel-args = jsonData.services.frigate.hwaccel_args or "preset-intel-qsv-h264";
      frigate.cameras = map (camera: {
        enable = camera.enable or true;
        direct-stream = camera.direct_stream or false;
        name = camera.name;
        path = camera.path;
        width = camera.width or 1920;
        height = camera.height or 1080;
      }) (jsonData.services.frigate.cameras or []);

      unifi.enable = jsonData.services.unifi.enable or false;
      unifi.public = jsonData.services.unifi.public or false;

      cryptpad.enable = jsonData.services.cryptpad.enable or false;
      cryptpad.public = jsonData.services.cryptpad.public or false;
      cryptpad.adminKeys = jsonData.services.cryptpad.adminKeys or [];

      forgejo.enable = jsonData.services.forgejo.enable or false;
      forgejo.public = jsonData.services.forgejo.public or false;

      jellyfin.enable = jsonData.services.jellyfin.enable or false;
      jellyfin.public = jsonData.services.jellyfin.public or false;
      jellyfin.media-path = jsonData.services.jellyfin.media_path or null;

      nzbget.enable = jsonData.services.nzbget.enable or false;
      nzbget.public = jsonData.services.nzbget.public or false;
      nzbget.downloads-path = jsonData.services.nzbget.downloads_path or null;

      radicale.enable = jsonData.services.radicale.enable or false;
      radicale.public = jsonData.services.radicale.public or false;

      freshrss.enable = jsonData.services.freshrss.enable or false;
      freshrss.public = jsonData.services.freshrss.public or false;

      minecraft.enable = jsonData.services.minecraft.enable or false;
      minecraft.public = jsonData.services.minecraft.public or false;
      minecraft.instances = map (instance: {
        enable = instance.enable or true;
        public = instance.public or false;
        subdomain = instance.subdomain;
        name = instance.name;
        memory = if (instance.memory or null) == null || instance.memory == "" then null else instance.memory;
        image-tag = if (instance."image-tag" or null) == null || instance."image-tag" == "" then null else instance."image-tag";
        mode = instance.mode or "survival";
        type = if (instance.type or null) == null || instance.type == "" then null else instance.type;
        mods = map (mod: {
          download-url = mod."download-url";
          project-slug = mod."project-slug";
        }) (instance.mods or []);
      } // (if (instance."mod-pack" or null) == null then {} else {
        mod-pack = {
          download-url = instance."mod-pack"."download-url";
          project-slug = instance."mod-pack"."project-slug";
        };
      })) (jsonData.services.minecraft.instances or []);

      homebox.enable = jsonData.services.homebox.enable or false;
      homebox.public = jsonData.services.homebox.public or false;

      ollama.enable = jsonData.services.ollama.enable or false;
      ollama.public = jsonData.services.ollama.public or false;

      grocy.enable = jsonData.services.grocy.enable or false;
      grocy.public = jsonData.services.grocy.public or false;

      zitadel.enable = jsonData.services.zitadel.enable or false;
      zitadel.public = jsonData.services.zitadel.public or false;

      immich.enable = jsonData.services.immich.enable or false;
      immich.public = jsonData.services.immich.public or false;

      matrix.enable = jsonData.services.matrix.enable or false;
      matrix.public = jsonData.services.matrix.public or false;
      matrix.enable-federation = jsonData.services.matrix.enable_federation or false;
      matrix.federation-domain-whitelist =
        jsonData.services.matrix.federation_domain_whitelist
        or [ "matrix.org" "nixos.org" "homefree.host" "rycee.net" "gnome.org" ];
      matrix.admin-account = jsonData.services.matrix.admin_account or null;
      matrix.server-name = jsonData.services.matrix.server_name or null;

      mediawiki.enable = jsonData.services.mediawiki.enable or false;
      mediawiki.public = jsonData.services.mediawiki.public or false;
      mediawiki.instances = map (instance: {
        enable = instance.enable or true;
        public = instance.public or false;
        subdomain = instance.subdomain;
        name = instance.name;
        logo-path =
          let raw = instance."logo-path" or null; in
          if raw == null || raw == "" then null
          else
            ## Path is interpreted relative to /etc/nixos (the flake source
            ## root). A leading "/etc/nixos/" prefix is stripped so legacy
            ## absolute paths still resolve. Using ./. + "/relative" makes
            ## the result a flake-relative path literal, which pure-eval
            ## accepts and Nix imports into the store automatically.
            let
              stripped =
                if lib.strings.hasPrefix "/etc/nixos/" raw
                then lib.strings.removePrefix "/etc/nixos/" raw
                else raw;
            in (./. + ("/" + stripped));
        readonly = instance.readonly or false;
        disable-anonymous-editing = instance."disable-anonymous-editing" or false;
        disable-anonymous-viewing = instance."disable-anonymous-viewing" or false;
        disable-user-editing = instance."disable-user-editing" or false;
        disable-user-registration = instance."disable-user-registration" or false;
      }) (jsonData.services.mediawiki.instances or []);

      screeenly.enable = jsonData.services.screeenly.enable or false;
      screeenly.public = jsonData.services.screeenly.public or false;

      baikal.enable = jsonData.services.baikal.enable or false;
      baikal.public = jsonData.services.baikal.public or false;

      trilium.enable = jsonData.services.trilium.enable or false;
      trilium.public = jsonData.services.trilium.public or false;

      azuracast.enable = jsonData.services.azuracast.enable or false;
      azuracast.public = jsonData.services.azuracast.public or false;

      odoo.enable = jsonData.services.odoo.enable or false;
      odoo.public = jsonData.services.odoo.public or false;

      unifi-os.enable = jsonData.services."unifi-os".enable or false;
      unifi-os.public = jsonData.services."unifi-os".public or false;
    };

    backups = {
      enable = jsonData.backups.enable;
      to-path = if jsonData.backups.to_path == "" then null else jsonData.backups.to_path;
      extra-from-paths = jsonData.backups.extra_from_paths or [];
      backblaze = {
        enable = jsonData.backups.backblaze_enable;
        bucket = if jsonData.backups.backblaze_bucket == "" then null else jsonData.backups.backblaze_bucket;
      };
    };

    ## Extra reverse-proxy entries for non-HomeFree hardware (NAS UI,
    ## solar inverter admin, smart-plug PSU, router admin, etc.).
    ## Each entry contributes one item to homefree.service-config; the
    ## existing Caddy generator iterates that list and adds a route.
    ## In-tree HomeFree services have their own service-config entries
    ## emitted by their respective .nix files — those entries are
    ## merged with these via NixOS list-merge semantics.
    service-config = map (e: {
      label = e.label;
      name = e.name or e.label;
      reverse-proxy = {
        enable    = e.enable or true;
        subdomains = e.subdomains or [ e.label ];
        ## https-domains is the user's public domains. When empty,
        ## services/caddy.nix falls back to system.domain +
        ## additionalDomains. Same default behavior in-tree services
        ## use, so external entries get the same coverage automatically.
        https-domains = e.https_domains or [];
        host      = e.host;
        port      = e.port or 80;
        ssl       = e.ssl or false;
        ssl-no-verify = e.ssl_no_verify or false;
        public    = e.public or false;
        oauth2    = e.oauth2 or false;
        basic-auth = e.basic_auth or false;
        require-admin-role = e.require_admin_role or false;
      };
    }) (jsonData.service_config or []);
  };

  # Set admin user password
  users.users.@@username@@ = {
    hashedPassword = "@@hashed_password@@";
  };
}
"""

    CONFIGURATION_TEMPLATE = """# Local system configuration overrides for HomeFree
# Most system configuration is managed by HomeFree (see homefree-configuration.nix)
# This file is for system-specific settings only.
#
# To rebuild: sudo nixos-rebuild switch --flake /etc/nixos#@@hostname@@
# See: https://git.homefree.host/homefree/homefree

{ config, pkgs, ... }:

{
  imports = [
    ./hardware-configuration.nix
    ./homefree-configuration.nix@@dev_import@@
  ];

@@bootloader@@

  # NixOS Release Version
  system.stateVersion = "@@nixosversion@@";
}
"""

    DEVELOPMENT_OVERRIDES_TEMPLATE = """# Development mode overrides
# This file is automatically generated when development mode is enabled
# It configures the system to use a local homefree codebase for development

{ pkgs, ... }:

{
  # Mark development mode as enabled
  homefree.development = true;

  # Mount the shared folder from QEMU virtiofs (much faster than 9p)
  fileSystems."/mnt/homefree-virtiofs" = {
    device = "mount_homefree_source";
    fsType = "virtiofs";
    options = [ "rw" "nofail" ];
  };

  # Use bindfs to remap ownership so all files appear owned by the VM user
  # This allows full read/write access including in-place edits
  # Files created in VM will preserve the host's original ownership
  fileSystems."/home/@@username@@/homefree" = {
    device = "/mnt/homefree-virtiofs";
    fsType = "fuse.bindfs";
    options = [
      "force-user=@@username@@"
      "force-group=users"
      "chown-ignore"
      "chgrp-ignore"
    ];
  };

  environment.systemPackages = with pkgs; [
    bindfs
    claude-code
  ];

  # Note: The flake.nix already configures homefree-local input
  # This file is available for additional development-specific overrides
  #
  # The virtfs mount uses security_model=none which passes through host
  # filesystem permissions. The host directory must have group write
  # permissions (chmod -R g+w) for the VM user to be able to create and
  # edit files. This is suitable for development environments.
}
"""

    @staticmethod
    def initialize():
        """Initialize the installation service"""
        logger.info("Installation service initialized")

    @staticmethod
    def start() -> bool:
        """Start the installation process in a background thread"""
        if InstallationService._running:
            logger.warning("Installation already in progress")
            return False

        InstallationService._running = True
        InstallationService._status = {
            'step': 'Starting installation...',
            'progress': 0.0,
            'message': 'Preparing to install HomeFree',
            'completed': False,
            'error': None,
        }

        # Start installation in background thread
        InstallationService._install_thread = threading.Thread(
            target=InstallationService._run_installation,
            daemon=True
        )
        InstallationService._install_thread.start()

        return True

    @staticmethod
    def get_status() -> Dict[str, Any]:
        """Get current installation status"""
        return InstallationService._status.copy()

    @staticmethod
    def _update_status(step: str, progress: float, message: str):
        """Update installation status"""
        InstallationService._status.update({
            'step': step,
            'progress': progress,
            'message': message,
        })
        logger.info(f"[{progress:.0f}%] {step}: {message}")

    @staticmethod
    def _set_error(error: str):
        """Set installation error"""
        InstallationService._status['error'] = error
        InstallationService._status['completed'] = False
        InstallationService._running = False
        logger.error(f"Installation error: {error}")

    @staticmethod
    def _set_completed():
        """Mark installation as completed"""
        InstallationService._status['completed'] = True
        InstallationService._status['progress'] = 100.0
        InstallationService._running = False
        logger.info("Installation completed successfully")

    @staticmethod
    def _get_partition_path(disk: str, partition_number: int) -> str:
        """Get correct partition device path for the given disk and partition number

        Args:
            disk: Device path (e.g., /dev/sda, /dev/nvme0n1, /dev/vda)
            partition_number: Partition number (1, 2, 3, etc.)

        Returns:
            Complete partition path (e.g., /dev/sda1, /dev/nvme0n1p1, /dev/vda1)
        """
        # NVMe devices use 'p' notation: /dev/nvme0n1p1
        if 'nvme' in disk:
            return f"{disk}p{partition_number}"
        # Standard SATA/SCSI/virtio devices: /dev/sda1, /dev/vda1, etc.
        else:
            return f"{disk}{partition_number}"

    @staticmethod
    def _run_installation():
        """Run the installation process"""
        try:
            root_mount_point = "/mnt"

            # Step 1: Partition and format disks
            InstallationService._update_status(
                "Partitioning disks",
                5.0,
                "Creating partitions and filesystems"
            )
            InstallationService._partition_disks(root_mount_point)

            # Step 2: Generate hardware configuration
            InstallationService._update_status(
                "Generating hardware configuration",
                15.0,
                "Detecting hardware and generating configuration"
            )
            InstallationService._generate_hardware_config(root_mount_point)

            # Step 3: Generate NixOS configuration
            InstallationService._update_status(
                "Generating HomeFree configuration",
                25.0,
                "Creating flake.nix and configuration files"
            )
            InstallationService._generate_configs(root_mount_point)

            # Step 4: Initialize git repository
            InstallationService._update_status(
                "Initializing git repository",
                30.0,
                "Setting up git for flake management"
            )
            InstallationService._init_git(root_mount_point)

            # Step 4.5: Setup development mode (before nixos-install)
            config = ConfigService.get_config()
            is_dev_mode = config.get('development_mode', False)
            if is_dev_mode:
                InstallationService._update_status(
                    "Setting up development mode",
                    32.0,
                    "Creating symlinks for shared folder access"
                )
                InstallationService._setup_dev_mode(root_mount_point)

            # Step 5: Run nixos-install
            InstallationService._update_status(
                "Installing HomeFree",
                35.0,
                "Building and installing packages...  (this may take 15-30 minutes)"
            )
            InstallationService._nixos_install(root_mount_point)

            # Step 6: Post-install configuration
            InstallationService._update_status(
                "Finishing installation",
                95.0,
                "Finalizing system configuration"
            )
            InstallationService._post_install(root_mount_point)

            # Complete
            InstallationService._update_status(
                "Installation complete",
                100.0,
                "HomeFree has been successfully installed!"
            )
            InstallationService._set_completed()

        except Exception as e:
            logger.exception("Installation failed")
            InstallationService._set_error(str(e))

    @staticmethod
    def _partition_disks(root_mount_point: str):
        """Partition and format disks with btrfs"""
        config = ConfigService.get_config()
        partitioning = config.get('partitioning')

        if not partitioning or not partitioning.get('disk'):
            raise Exception("No disk selected for installation")

        disk = partitioning.get('disk')
        use_swap = partitioning.get('use_swap', True)
        use_encryption = partitioning.get('use_encryption', False)

        if use_encryption:
            raise Exception("LUKS encryption not yet implemented")

        logger.info(f"Partitioning disk {disk} with btrfs")

        # Detect firmware type
        fw_type = "efi" if Path("/sys/firmware/efi").exists() else "bios"

        try:
            # Unmount any existing partitions on the disk
            run_privileged(
                f"umount {disk}* 2>/dev/null || true",
                shell=True,
                check=False
            )

            # Wipe filesystem signatures
            run_privileged(
                ["wipefs", "-a", disk],
                check=True,
                capture_output=True
            )

            # Create GPT partition table
            run_privileged(
                ["parted", "-s", disk, "mklabel", "gpt"],
                check=True,
                capture_output=True
            )

            if fw_type == "efi":
                # UEFI: Create EFI partition (512MB) and root partition
                run_privileged(
                    ["parted", "-s", disk, "mkpart", "ESP", "fat32", "1MiB", "513MiB"],
                    check=True
                )
                run_privileged(
                    ["parted", "-s", disk, "set", "1", "esp", "on"],
                    check=True
                )

                if use_swap:
                    # Create swap partition (RAM size)
                    mem_total = psutil.virtual_memory().total
                    swap_size_mb = int(mem_total / (1024 * 1024))
                    swap_end = 513 + swap_size_mb

                    run_privileged(
                        ["parted", "-s", disk, "mkpart", "swap", "linux-swap", "513MiB", f"{swap_end}MiB"],
                        check=True
                    )

                    # Root partition starts after swap
                    run_privileged(
                        ["parted", "-s", disk, "mkpart", "root", "btrfs", f"{swap_end}MiB", "100%"],
                        check=True
                    )

                    efi_part = InstallationService._get_partition_path(disk, 1)
                    swap_part = InstallationService._get_partition_path(disk, 2)
                    root_part = InstallationService._get_partition_path(disk, 3)
                else:
                    # Root partition takes rest of disk
                    run_privileged(
                        ["parted", "-s", disk, "mkpart", "root", "btrfs", "513MiB", "100%"],
                        check=True
                    )

                    efi_part = InstallationService._get_partition_path(disk, 1)
                    swap_part = None
                    root_part = InstallationService._get_partition_path(disk, 2)

                # Format EFI partition
                run_privileged(
                    ["mkfs.vfat", "-F32", "-n", "EFI", efi_part],
                    check=True
                )
            else:
                # BIOS: Just create root partition
                if use_swap:
                    mem_total = psutil.virtual_memory().total
                    swap_size_mb = int(mem_total / (1024 * 1024))
                    swap_end = 1 + swap_size_mb

                    run_privileged(
                        ["parted", "-s", disk, "mkpart", "swap", "linux-swap", "1MiB", f"{swap_end}MiB"],
                        check=True
                    )
                    run_privileged(
                        ["parted", "-s", disk, "mkpart", "root", "btrfs", f"{swap_end}MiB", "100%"],
                        check=True
                    )

                    swap_part = InstallationService._get_partition_path(disk, 1)
                    root_part = InstallationService._get_partition_path(disk, 2)
                else:
                    run_privileged(
                        ["parted", "-s", disk, "mkpart", "root", "btrfs", "1MiB", "100%"],
                        check=True
                    )

                    swap_part = None
                    root_part = InstallationService._get_partition_path(disk, 1)

                efi_part = None

            # Format swap if enabled
            if swap_part:
                run_privileged(
                    ["mkswap", "-L", "swap", swap_part],
                    check=True
                )
                run_privileged(
                    ["swapon", swap_part],
                    check=True
                )

            # Format root partition with btrfs
            run_privileged(
                ["mkfs.btrfs", "-f", "-L", "nixos", root_part],
                check=True
            )

            # Mount root partition
            run_privileged(
                ["mount", root_part, root_mount_point],
                check=True
            )

            # Create btrfs subvolumes for better snapshot management
            run_privileged(
                ["btrfs", "subvolume", "create", f"{root_mount_point}/@"],
                check=True
            )
            run_privileged(
                ["btrfs", "subvolume", "create", f"{root_mount_point}/@home"],
                check=True
            )
            run_privileged(
                ["btrfs", "subvolume", "create", f"{root_mount_point}/@nix"],
                check=True
            )

            # Unmount and remount with subvolumes
            run_privileged(
                ["umount", root_mount_point],
                check=True
            )

            # Mount root subvolume
            run_privileged(
                ["mount", "-o", "subvol=@,compress=zstd,noatime", root_part, root_mount_point],
                check=True
            )

            # Create mount points
            mkdir_privileged(f"{root_mount_point}/home")
            mkdir_privileged(f"{root_mount_point}/nix")

            # Mount home subvolume
            run_privileged(
                ["mount", "-o", "subvol=@home,compress=zstd,noatime", root_part, f"{root_mount_point}/home"],
                check=True
            )

            # Mount nix subvolume
            run_privileged(
                ["mount", "-o", "subvol=@nix,compress=zstd,noatime", root_part, f"{root_mount_point}/nix"],
                check=True
            )

            # Mount EFI partition if UEFI
            if efi_part:
                mkdir_privileged(f"{root_mount_point}/boot")
                run_privileged(
                    ["mount", efi_part, f"{root_mount_point}/boot"],
                    check=True
                )

            logger.info(f"Successfully partitioned and mounted {disk}")

        except subprocess.CalledProcessError as e:
            raise Exception(f"Failed to partition disk: {e}")

    @staticmethod
    def _generate_hardware_config(root_mount_point: str):
        """Generate hardware-configuration.nix"""
        try:
            run_privileged(
                ["nixos-generate-config", "--root", root_mount_point],
                check=True,
                capture_output=True
            )
        except subprocess.CalledProcessError as e:
            raise Exception(f"Failed to generate hardware config: {e.stderr.decode()}")

    @staticmethod
    def _generate_configs(root_mount_point: str):
        """Generate flake.nix, homefree-configuration.nix, and configuration.nix"""
        config = ConfigService.get_config()
        nixos_dir = Path(root_mount_point) / "etc/nixos"
        mkdir_privileged(str(nixos_dir))

        # Get NixOS version
        try:
            version = subprocess.check_output(["nixos-version"]).decode().strip()
            version = '.'.join(version.split('.')[:2])[:5]
        except:
            version = "24.05"

        # Detect firmware type
        fw_type = "efi" if Path("/sys/firmware/efi").exists() else "bios"

        # Generate bootloader config
        if fw_type == "efi":
            bootloader = """  # Bootloader (UEFI)
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
"""
        else:
            bootloader = """  # Bootloader (BIOS)
  boot.loader.grub.enable = true;
  boot.loader.grub.device = "/dev/sda";  # TODO: Auto-detect boot device
  boot.loader.grub.useOSProber = true;
"""

        # Get network interfaces
        wan_interface = NetworkService.get_wan_interface() or ''
        lan_interface = NetworkService.get_lan_interface() or ''

        # Check if development mode is enabled
        is_dev_mode = config.get('development_mode', False)
        username = config.get('username', 'admin')

        # Generate router config only if both interfaces are configured
        if wan_interface and lan_interface:
            router_base = f"""      # Network interfaces
      wan-interface = "{wan_interface}";
      lan-interface = "{lan_interface}";

      # Enable router functionality
      router.enable = true;
"""
            # Add development mode network configuration if enabled
            if is_dev_mode:
                # In router mode with dev mode, use 10.1.2.x for LAN subnet (bridge network)
                router_config = router_base + """
      # Development mode network configuration (QEMU bridge networking for router mode)
      lan-address = "10.1.2.1";
      lan-subnet = "10.1.2.0/24";
      dhcp-range-start = "10.1.2.100";
      dhcp-range-end = "10.1.2.200";
"""
            else:
                router_config = router_base
        else:
            # Router mode disabled, but still include dev mode network config if enabled
            if is_dev_mode:
                # In non-router mode with dev mode, use 10.0.2.x (QEMU user networking)
                router_config = """      # Router mode disabled - insufficient network interfaces
      router.enable = false;

      # Development mode network configuration (QEMU user networking)
      lan-address = "10.0.2.15";
      lan-subnet = "10.0.2.0/24";
      dhcp-range-start = "10.0.2.100";
      dhcp-range-end = "10.0.2.200";
"""
            else:
                router_config = """      # Router mode disabled - insufficient network interfaces
      router.enable = false;
"""

        # Generate hashed password using mkpasswd
        password = config.get('password', '')
        if not password:
            raise Exception(
                "No password configured for the admin user; cannot generate "
                "hashedPassword for NixOS configuration"
            )

        # Pass the password via stdin to keep it out of /proc/<pid>/cmdline
        # and to avoid a leading '-' being parsed as a flag.
        try:
            result = subprocess.run(
                ['mkpasswd', '-m', 'sha-512', '--stdin'],
                input=password,
                capture_output=True,
                text=True,
                check=True
            )
        except subprocess.CalledProcessError as e:
            logger.error(f"Failed to hash password: {e.stderr}")
            raise Exception(f"Failed to hash admin password with mkpasswd: {e.stderr.strip() or e}") from e

        hashed_password = result.stdout.strip()
        if not hashed_password:
            raise Exception("mkpasswd produced an empty hash for the admin password")
        logger.info("Generated hashed password for user")

        # Development mode template variables
        if is_dev_mode:
            # Use /home/nixos/homefree during install (where virtfs is mounted)
            # After install, _post_install will update this to /home/<username>/homefree
            dev_input = f"""
    homefree-local.url = "git+file:///home/nixos/homefree";"""
            dev_output_arg = ", homefree-local"
            dev_let = """
    # Use local homefree in development mode
    homefree = homefree-local;"""
            homefree_module = "homefree.nixosModules.homefree"
            homefree_inputs = "homefree.inputs"
            dev_import = "\n    ./development-overrides.nix"
        else:
            dev_input = ""
            dev_output_arg = ""
            dev_let = ""
            homefree_module = "homefree-base.nixosModules.homefree"
            homefree_inputs = "homefree-base.inputs"
            dev_import = ""

        # Determine network configuration values for JSON
        if wan_interface and lan_interface:
            router_enable = "true"
            if is_dev_mode:
                # In router mode with dev mode, use 10.1.2.x for LAN subnet (bridge network)
                lan_address = "10.1.2.1"
                lan_subnet = "10.1.2.0/24"
                dhcp_range_start = "10.1.2.100"
                dhcp_range_end = "10.1.2.200"
            else:
                # Default router mode values
                lan_address = "10.0.0.1"
                lan_subnet = "10.0.0.0/24"
                dhcp_range_start = "10.0.0.100"
                dhcp_range_end = "10.0.0.200"
        else:
            # Router mode disabled
            router_enable = "false"
            if is_dev_mode:
                # In non-router mode with dev mode, use 10.0.2.x (QEMU user networking)
                lan_address = "10.0.2.15"
                lan_subnet = "10.0.2.0/24"
                dhcp_range_start = "10.0.2.100"
                dhcp_range_end = "10.0.2.200"
            else:
                # Fallback values when router is disabled
                lan_address = "10.0.0.1"
                lan_subnet = "10.0.0.0/24"
                dhcp_range_start = "10.0.0.100"
                dhcp_range_end = "10.0.0.200"

        # Template variables. Localization fields use helpers so an
        # unset (None / "") value renders as JSON `null` rather than
        # the string "None" — homefree-config.json must be valid JSON.
        def _json_or_null(v):
            return "null" if v in (None, "") else str(v)
        def _json_or_quoted_str(v):
            return "null" if v in (None, "") else '"%s"' % str(v).replace('"', '\\"')

        variables = {
            'hostname': config.get('hostname', 'homefree'),
            'domain': config.get('domain', 'homefree.host'),
            'timezone': config.get('timezone', 'America/Los_Angeles'),
            'locale': config.get('locale', 'en_US.UTF-8'),
            'country_code': config.get('country_code', 'US'),
            'elevation': _json_or_null(config.get('elevation')),
            'latitude': _json_or_null(config.get('latitude')),
            'longitude': _json_or_null(config.get('longitude')),
            'unit_system': config.get('unit_system', 'metric'),
            'currency_json': _json_or_quoted_str(config.get('currency')),
            'language_json': _json_or_quoted_str(config.get('language')),
            'vconsole': config.get('vconsole', 'us'),
            'username': username,
            'fullname': config.get('fullname', 'HomeFree Admin'),
            'email': config.get('email', ''),
            'wan_interface': wan_interface,
            'lan_interface': lan_interface,
            'router_enable': router_enable,
            'lan_address': lan_address,
            'lan_subnet': lan_subnet,
            'dhcp_range_start': dhcp_range_start,
            'dhcp_range_end': dhcp_range_end,
            'nixosversion': version,
            'bootloader': bootloader,
            'router_config': router_config,
            'hashed_password': hashed_password,
            'dev_input': dev_input,
            'dev_output_arg': dev_output_arg,
            'dev_let': dev_let,
            'homefree_module': homefree_module,
            'homefree_inputs': homefree_inputs,
            'dev_import': dev_import,
        }

        # Generate homefree-config.json first
        json_content = InstallationService.HOMEFREE_JSON_TEMPLATE
        for key, value in variables.items():
            json_content = json_content.replace(f"@@{key}@@", str(value))

        write_file_privileged(str(nixos_dir / "homefree-config.json"), json_content)
        logger.info("Generated homefree-config.json")

        # Generate flake.nix
        flake_content = InstallationService.FLAKE_TEMPLATE
        for key, value in variables.items():
            flake_content = flake_content.replace(f"@@{key}@@", str(value))

        write_file_privileged(str(nixos_dir / "flake.nix"), flake_content)

        # Generate homefree-configuration.nix (now imports from JSON)
        homefree_config = InstallationService.HOMEFREE_CONFIG_TEMPLATE
        for key, value in variables.items():
            homefree_config = homefree_config.replace(f"@@{key}@@", str(value))

        write_file_privileged(str(nixos_dir / "homefree-configuration.nix"), homefree_config)

        # Generate configuration.nix
        configuration = InstallationService.CONFIGURATION_TEMPLATE
        for key, value in variables.items():
            configuration = configuration.replace(f"@@{key}@@", str(value))

        write_file_privileged(str(nixos_dir / "configuration.nix"), configuration)

        # Generate development-overrides.nix if in development mode
        if is_dev_mode:
            dev_overrides = InstallationService.DEVELOPMENT_OVERRIDES_TEMPLATE.replace("@@username@@", username)
            write_file_privileged(str(nixos_dir / "development-overrides.nix"), dev_overrides)
            logger.info("Generated development-overrides.nix for development mode")

        logger.info(f"Generated configuration files in {nixos_dir}")

    @staticmethod
    def _init_git(root_mount_point: str):
        """Initialize git repository for flake"""
        nixos_dir = Path(root_mount_point) / "etc/nixos"

        try:
            # Git operations on /mnt need privilege escalation
            run_privileged(["git", "init", str(nixos_dir)], check=True)
            run_privileged(["git", "-C", str(nixos_dir), "add", "."], check=True)
            run_privileged(
                ["git", "-C", str(nixos_dir), "config", "user.email", "installer@homefree.local"],
                check=True
            )
            run_privileged(
                ["git", "-C", str(nixos_dir), "config", "user.name", "HomeFree Installer"],
                check=True
            )
            run_privileged(
                ["git", "-C", str(nixos_dir), "commit", "-m", "Initial configuration"],
                check=True
            )
            logger.info("Initialized git repository")
        except subprocess.CalledProcessError as e:
            raise Exception(f"Failed to initialize git: {e}")

    @staticmethod
    def _nixos_install(root_mount_point: str):
        """Run nixos-install"""
        import os

        config = ConfigService.get_config()
        hostname = config.get('hostname', 'homefree')

        try:
            # nixos-install automatically prepends 'nixosConfigurations.' so just pass the hostname
            flake_ref = f"{root_mount_point}/etc/nixos#{hostname}"
            logger.info(f"Installing NixOS with flake reference: {flake_ref}")

            # Log the generated flake.nix content for debugging
            # Note: We can't read the file directly from /mnt as nixos user,
            # but we can use cat via pkexec or just skip this debug step
            try:
                flake_path = Path(root_mount_point) / "etc/nixos/flake.nix"
                # Use privileged read via cat
                result = run_privileged(
                    ["cat", str(flake_path)],
                    capture_output=True,
                    text=True,
                    check=True
                )
                logger.info(f"Flake content:\n{result.stdout}")
            except Exception as e:
                logger.warning(f"Could not read flake.nix: {e}")

            # DEBUG: Test what the flake reference resolves to
            import subprocess as sp
            try:
                test_cmd = [
                    "nix", "--extra-experimental-features", "nix-command flakes",
                    "flake", "show", flake_ref, "--json"
                ]
                test_result = sp.run(test_cmd, capture_output=True, text=True, timeout=30)
                logger.info(f"DEBUG flake show output: {test_result.stdout[:500]}")
                logger.info(f"DEBUG flake show stderr: {test_result.stderr[:500]}")
            except Exception as e:
                logger.warning(f"DEBUG flake show failed: {e}")

            # Build nixos-install command with --show-trace for better error messages
            cmd = [
                "nixos-install",
                "--debug",  # Enable bash set -x for detailed debugging
                "--flake", flake_ref,
                "--no-root-passwd",
                "--root", root_mount_point,
                "--show-trace"  # Add detailed error tracing
            ]

            # Log the exact command being run
            logger.info(f"Running command: {' '.join(cmd)}")
            logger.info(f"Inheriting environment from systemd service (preserves PATH with Nix tools)")

            # Run nixos-install inheriting the systemd service environment
            # This preserves the PATH that includes all necessary Nix commands
            process = popen_privileged(
                cmd,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                universal_newlines=True
            )

            # Stream output and update progress
            progress = 35.0
            output_lines = []
            for line in process.stdout:
                output_lines.append(line)
                line_stripped = line.strip()
                logger.info(f"nixos-install: {line_stripped}")

                # Update progress based on different types of output
                updated = False

                # Evaluating/preparing (early phase)
                if any(keyword in line.lower() for keyword in ["evaluating", "preparing"]):
                    progress = min(progress + 0.1, 50.0)
                    InstallationService._update_status(
                        "Preparing installation",
                        progress,
                        line_stripped[:100]
                    )
                    updated = True

                # Nix operations (copying, downloading, fetching, building) - treat all equally
                elif any(keyword in line.lower() for keyword in ["copying", "downloading", "fetching", "building"]):
                    progress = min(progress + 0.2, 85.0)

                    # Determine the action and extract details
                    if "building" in line.lower():
                        step_name = "Building packages"
                        # Try to extract package name
                        if "'" in line:
                            parts = line.split("'")
                            if len(parts) >= 2:
                                pkg_name = parts[1].split("/")[-1] if "/" in parts[1] else parts[1]
                                message = f"Building {pkg_name}"
                            else:
                                message = line_stripped[:100]
                        else:
                            message = line_stripped[:100]
                    elif "copying" in line.lower():
                        step_name = "Installing HomeFree"
                        message = line_stripped[:100]
                    elif "downloading" in line.lower() or "fetching" in line.lower():
                        step_name = "Downloading packages"
                        message = line_stripped[:100]
                    else:
                        step_name = "Installing HomeFree"
                        message = line_stripped[:100]

                    InstallationService._update_status(
                        step_name,
                        progress,
                        message
                    )
                    updated = True

                # Installing/setting up packages
                elif "installing" in line.lower() or "setting up" in line.lower():
                    progress = min(progress + 0.2, 90.0)
                    InstallationService._update_status(
                        "Installing packages",
                        progress,
                        line_stripped[:100]
                    )
                    updated = True

                # Activating system
                elif "activating" in line.lower() or "systemd" in line.lower():
                    progress = min(progress + 0.3, 92.0)
                    InstallationService._update_status(
                        "Activating system",
                        progress,
                        line_stripped[:100]
                    )
                    updated = True

            process.wait()

            # Log full output if failed for debugging
            if process.returncode != 0:
                logger.error(f"nixos-install failed with exit code {process.returncode}")
                logger.error(f"Full output:\n{''.join(output_lines[-100:])}")  # Last 100 lines
                raise Exception(f"nixos-install failed with code {process.returncode}")

            logger.info("nixos-install completed successfully")

        except Exception as e:
            raise Exception(f"Failed to install HomeFree: {e}")

    @staticmethod
    def _setup_dev_mode(root_mount_point: str):
        """Setup development mode before nixos-install"""
        config = ConfigService.get_config()
        username = config.get('username', 'admin')

        try:
            logger.info("Setting up development mode")

            # Create symlink from /home/<username>/homefree to /home/nixos/homefree
            # This makes the nixos user's mounted folder accessible at the final user's path
            homefree_link = f"/home/{username}/homefree"
            try:
                # Create parent directory if needed (needs sudo for /home)
                run_privileged(["mkdir", "-p", f"/home/{username}"], check=True)
                # Create symlink
                run_privileged(["ln", "-sf", "/home/nixos/homefree", homefree_link], check=True)
                logger.info(f"Created symlink {homefree_link} -> /home/nixos/homefree")

                # Configure git to trust these directories (needed for git+file:// URLs in flake)
                run_privileged(["git", "config", "--global", "--add", "safe.directory", "/home/nixos/homefree"], check=True)
                run_privileged(["git", "config", "--global", "--add", "safe.directory", homefree_link], check=True)
                logger.info("Configured git safe.directory for homefree paths")
            except Exception as e:
                logger.error(f"Failed to create homefree symlink: {e}")
                raise Exception("Cannot proceed with development mode installation")

            # Create the actual directory in /mnt for after reboot
            # This directory will be the mount point for the shared folder
            homefree_dir = f"{root_mount_point}/home/{username}/homefree"
            mkdir_privileged(homefree_dir)

            # Set ownership on the directory (default first user UID/GID)
            uid = "1000"
            gid = "100"
            run_privileged(["chown", f"{uid}:{gid}", homefree_dir], check=True)

            # Note: The filesystem mount is now configured in development-overrides.nix
            # NixOS will handle mounting via fileSystems configuration

            logger.info("Development mode setup complete")

        except Exception as e:
            logger.error(f"Failed to setup development mode: {e}")
            raise

    @staticmethod
    def _post_install(root_mount_point: str):
        """Post-installation tasks"""
        config = ConfigService.get_config()
        username = config.get('username', 'admin')
        password = config.get('password', '')

        # Set password using chpasswd in the installed system
        # This matches the standard NixOS installer behavior
        if not password:
            raise Exception(
                "No password configured for the admin user; cannot run chpasswd "
                "in the installed system"
            )

        logger.info(f"Setting password for user {username} using chpasswd")

        # Format: username:password (chpasswd splits on the first colon, so a
        # colon in the password is preserved). Password has already been
        # validated to contain no newlines.
        passwd_input = f"{username}:{password}\n"

        process = popen_privileged(
            ["nixos-enter", "--root", root_mount_point, "--", "chpasswd"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True
        )
        stdout, stderr = process.communicate(input=passwd_input)

        if process.returncode != 0:
            logger.error(f"chpasswd failed: {stderr}")
            raise Exception(
                f"Failed to set password for user {username} via chpasswd: "
                f"{stderr.strip() or 'exit code ' + str(process.returncode)}"
            )
        logger.info(f"Successfully set password for user {username} via chpasswd")

        # Stash the plaintext password where Zitadel's first-instance
        # bootstrap can find it. The Zitadel container's preStart reads
        # this file to populate ZITADEL_FIRSTINSTANCE_ORG_HUMAN_PASSWORD,
        # so the human user created on first boot has the same password
        # as the OS admin user. Future password changes propagate via
        # the PAM bridge (see services/zitadel-pam-bridge.nix).
        zitadel_secrets_dir = f"{root_mount_point}/var/lib/homefree-secrets/zitadel"
        zitadel_password_file = f"{zitadel_secrets_dir}/admin-password"
        try:
            mkdir_privileged(zitadel_secrets_dir)
            run_privileged(["chmod", "700", zitadel_secrets_dir], check=True)
            write_file_privileged(zitadel_password_file, password)
            run_privileged(["chmod", "600", zitadel_password_file], check=True)
            logger.info(f"Stashed admin password for Zitadel bootstrap at {zitadel_password_file}")
        except Exception as e:
            # Non-fatal: if this fails Zitadel just falls back to its
            # initial-password default and the admin needs to set it
            # manually on first login. We don't want a missing secrets
            # dir to block the entire install.
            logger.warning(f"Failed to stash Zitadel admin password (non-fatal): {e}")

        # Update flake.nix for development mode
        if ConfigService.is_development_mode():
            try:
                logger.info("Updating flake.nix for development mode post-install")
                flake_path = f"{root_mount_point}/etc/nixos/flake.nix"

                # Read current flake.nix
                with open(flake_path, 'r') as f:
                    flake_content = f.read()

                # Replace /home/nixos/homefree with /home/<username>/homefree
                # This path will be valid after reboot when fstab mounts the shared folder
                updated_content = flake_content.replace(
                    'git+file:///home/nixos/homefree',
                    f'git+file:///home/{username}/homefree'
                )

                # Write back (using write_file_privileged since /mnt requires root)
                write_file_privileged(flake_path, updated_content)

                logger.info(f"Updated flake.nix to use /home/{username}/homefree")

                # Configure git to trust the homefree directory in the installed system
                # This is needed because the shared folder may have different ownership
                try:
                    run_privileged(
                        ["nixos-enter", "--root", root_mount_point, "--",
                         "git", "config", "--global", "--add", "safe.directory", f"/home/{username}/homefree"],
                        check=True
                    )
                    logger.info(f"Configured git safe.directory for /home/{username}/homefree in installed system")
                except Exception as git_error:
                    logger.warning(f"Failed to configure git safe.directory: {git_error}")
                    logger.info("You may need to run: git config --global --add safe.directory /home/{username}/homefree")

            except Exception as e:
                logger.error(f"Failed to update flake.nix for development mode: {e}")
                logger.warning("Development mode may not work after reboot")

        logger.info(f"Post-install complete for user {username}")
