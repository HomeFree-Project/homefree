"""
Mode detection service - determines if running in installer or admin mode
"""

import json
from pathlib import Path
from enum import Enum
from typing import Dict, List


class Mode(Enum):
    """Application mode"""
    INSTALLER = "installer"
    ADMIN = "admin"


class ModeService:
    """Service for detecting and managing application mode"""

    # Config file paths
    CONFIG_FILE = Path("/etc/nixos/homefree-configuration.nix")
    FLAKE_FILE = Path("/etc/nixos/flake.nix")
    HOMEFREE_CONFIG = Path("/etc/nixos/homefree-config.json")

    @staticmethod
    def get_mode() -> Mode:
        """
        Detect current application mode.

        Returns:
            Mode.INSTALLER if config doesn't exist (fresh install)
            Mode.ADMIN if config exists (installed system)
        """
        if ModeService.CONFIG_FILE.exists() and ModeService.FLAKE_FILE.exists():
            return Mode.ADMIN
        return Mode.INSTALLER

    @staticmethod
    def is_installer() -> bool:
        """Check if running in installer mode"""
        return ModeService.get_mode() == Mode.INSTALLER

    @staticmethod
    def is_admin() -> bool:
        """Check if running in admin mode"""
        return ModeService.get_mode() == Mode.ADMIN

    @staticmethod
    def get_pending_setup_items() -> List[str]:
        """
        Return the list of post-install setup items that are still missing.

        The ISO installer cannot collect secret-bearing config (the kiosk has
        no way to paste keys/tokens), so a freshly-installed box ships without:
          - "ssh-key": an SSH authorized key. Required before ANY secret can be
            saved, since SOPS encrypts to the system host key plus the first
            user authorized key.
          - "dns-01": a DNS-01 wildcard-cert provider. Without it Caddy cannot
            issue a cert for admin.<domain>, so the admin UI is HTTPS-unreachable.

        ddclient is intentionally NOT treated as required — HomeFree runs its
        own internal DNS and ddclient only matters for public pages.

        Returns an empty list once setup is complete, or in installer mode.
        """
        if not ModeService.is_admin():
            return []

        items: List[str] = []

        try:
            with open(ModeService.HOMEFREE_CONFIG, "r") as f:
                config = json.load(f)
        except (OSError, json.JSONDecodeError):
            # Can't read config — don't claim setup is incomplete on a guess.
            return []

        authorized_keys = config.get("system", {}).get("authorizedKeys", [])
        if not authorized_keys:
            items.append("ssh-key")

        cert_mgmt = config.get("dns", {}).get("cert-management")
        provider = (cert_mgmt or {}).get("provider")
        if not provider:
            items.append("dns-01")

        return items

    @staticmethod
    def is_setup_incomplete() -> bool:
        """True when post-install setup still has required items pending."""
        return len(ModeService.get_pending_setup_items()) > 0
