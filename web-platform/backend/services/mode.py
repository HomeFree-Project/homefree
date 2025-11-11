"""
Mode detection service - determines if running in installer or admin mode
"""

from pathlib import Path
from enum import Enum


class Mode(Enum):
    """Application mode"""
    INSTALLER = "installer"
    ADMIN = "admin"


class ModeService:
    """Service for detecting and managing application mode"""

    # Config file paths
    CONFIG_FILE = Path("/etc/nixos/homefree-configuration.nix")
    FLAKE_FILE = Path("/etc/nixos/flake.nix")

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
