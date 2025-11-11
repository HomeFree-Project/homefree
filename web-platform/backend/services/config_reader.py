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
