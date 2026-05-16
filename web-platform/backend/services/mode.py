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

    # Explicit "post-install setup is finished" marker. Written ONLY by the
    # finish-setup wizard's final step (POST /api/finish-setup/complete),
    # after the finishing rebuild succeeds. This is the single source of
    # truth for "is the wizard done" — it is NEVER inferred from config
    # state. Inferring it (authorizedKeys + DNS-01 both present) is wrong:
    # the wizard writes those on its EARLY pages, so the inference flips to
    # "done" while the user is still mid-wizard, and the admin UI wrongly
    # swaps the wizard for the full dashboard.
    SETUP_COMPLETE_MARKER = Path("/var/lib/homefree-secrets/.setup-complete")

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
    def is_setup_complete() -> bool:
        """
        True once the finish-setup wizard has explicitly completed.

        This is the ONLY thing that decides wizard-vs-dashboard. It is the
        presence of the .setup-complete marker — never an inference from
        config. The marker is written solely by POST /api/finish-setup/complete
        on the wizard's final step.
        """
        return ModeService.SETUP_COMPLETE_MARKER.exists()

    @staticmethod
    def is_setup_incomplete() -> bool:
        """
        True when the box is installed but the finish-setup wizard has not
        been completed. Drives whether the admin UI shows the wizard.
        """
        return ModeService.is_admin() and not ModeService.is_setup_complete()

    @staticmethod
    def get_pending_setup_items() -> List[str]:
        """
        Return which finish-setup items still need attention.

        IMPORTANT: this is NOT the wizard-vs-dashboard gate — that is
        is_setup_incomplete() / the .setup-complete marker. This list is
        only a hint the wizard uses to decide which step to open on (e.g.
        skip the SSH-key page if a key is already present). It is derived
        from config and so will go empty mid-wizard — which is exactly why
        it must not gate whether the wizard shows.

        Returns [] if setup is already complete or we are in installer mode.
        """
        # Setup explicitly finished — nothing pending.
        if ModeService.is_setup_complete():
            return []
        if not ModeService.is_admin():
            return []

        items: List[str] = []

        try:
            with open(ModeService.HOMEFREE_CONFIG, "r") as f:
                config = json.load(f)
        except (OSError, json.JSONDecodeError):
            # Can't read config — fall back to "everything pending" so the
            # wizard at least starts at the beginning.
            return ["ssh-key", "dns-01"]

        authorized_keys = config.get("system", {}).get("authorizedKeys", [])
        if not authorized_keys:
            items.append("ssh-key")

        cert_mgmt = config.get("dns", {}).get("cert-management")
        provider = (cert_mgmt or {}).get("provider")
        if not provider:
            items.append("dns-01")

        return items
