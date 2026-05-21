"""
Config reader service - reads configuration from JSON file
"""

from pathlib import Path
from typing import Dict, Any
import json
import logging

logger = logging.getLogger(__name__)


class ConfigReader:
    """Service for reading HomeFree configuration from JSON file"""

    CONFIG_FILE = Path("/etc/nixos/homefree-config.json")

    @staticmethod
    def read_config() -> Dict[str, Any]:
        """
        Read configuration from homefree-config.json

        Returns:
            Dictionary with current homefree configuration values
        """
        if not ConfigReader.CONFIG_FILE.exists():
            logger.warning(f"Config file not found: {ConfigReader.CONFIG_FILE}")
            return {}

        try:
            content = ConfigReader.CONFIG_FILE.read_text()
            config = json.loads(content)
            logger.info(f"Successfully loaded config from {ConfigReader.CONFIG_FILE}")
            return config
        except json.JSONDecodeError as e:
            logger.error(f"Invalid JSON in config file: {e}")
            return {}
        except Exception as e:
            logger.error(f"Error reading config file: {e}")
            return {}

    @staticmethod
    def read_config_strict() -> Dict[str, Any]:
        """
        Read configuration from homefree-config.json, RAISING on a parse error.

        Unlike read_config() — which swallows a malformed file and returns {},
        a safe default for best-effort callers — this variant lets a
        json.JSONDecodeError propagate so the API can tell the UI that the
        on-disk file is broken (e.g. a hand-edit typo) instead of silently
        returning {} and blanking the displayed config.

        Returns {} only when the file genuinely does not exist.
        Raises json.JSONDecodeError when the file exists but is not valid JSON.
        """
        if not ConfigReader.CONFIG_FILE.exists():
            logger.warning(f"Config file not found: {ConfigReader.CONFIG_FILE}")
            return {}
        return json.loads(ConfigReader.CONFIG_FILE.read_text())
