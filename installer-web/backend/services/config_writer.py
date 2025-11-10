"""
Config writer service - updates NixOS configuration files
"""

from pathlib import Path
from typing import Dict, Any, List, Optional
import logging
import shutil
import json
from datetime import datetime

logger = logging.getLogger(__name__)


class ConfigWriter:
    """Service for writing NixOS configuration files"""

    CONFIG_FILE = Path("/etc/nixos/homefree-config.json")
    BACKUP_DIR = Path("/var/lib/homefree-admin/config-backups")

    @staticmethod
    def write_config(config: Dict[str, Any]) -> bool:
        """
        Write configuration changes to homefree-config.json

        Args:
            config: Configuration dictionary with new values

        Returns:
            True if successful, False otherwise
        """
        if not ConfigWriter.CONFIG_FILE.exists():
            logger.error(f"Config file not found: {ConfigWriter.CONFIG_FILE}")
            return False

        try:
            # Backup current config
            ConfigWriter._backup_config()

            # Read current config
            current_config = json.loads(ConfigWriter.CONFIG_FILE.read_text())

            # Update each section (deep merge)
            if 'system' in config:
                current_config['system'].update(config['system'])

            if 'network' in config:
                current_config['network'].update(config['network'])

            if 'dns' in config:
                current_config['dns'].update(config['dns'])

            if 'services' in config:
                # Special services that shouldn't be saved to config (no user-configurable options)
                # admin-api is for monitoring only and has no config options
                special_services = {'admin-api'}

                # Merge services - add new ones, update existing ones
                # Filter out special services that aren't configurable
                for service_name, service_config in config['services'].items():
                    if service_name in special_services:
                        continue  # Skip special services

                    if service_name not in current_config['services']:
                        current_config['services'][service_name] = {}
                    current_config['services'][service_name].update(service_config)

            if 'backups' in config:
                current_config['backups'].update(config['backups'])

            # Write updated config with pretty formatting
            ConfigWriter.CONFIG_FILE.write_text(
                json.dumps(current_config, indent=2, sort_keys=False) + '\n'
            )
            logger.info("Configuration file updated successfully")
            return True

        except Exception as e:
            logger.error(f"Error writing config file: {e}")
            return False

    @staticmethod
    def _backup_config():
        """Create a timestamped backup of the current config"""
        try:
            ConfigWriter.BACKUP_DIR.mkdir(parents=True, exist_ok=True)
            timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
            backup_file = ConfigWriter.BACKUP_DIR / f"homefree-config.{timestamp}.json"
            shutil.copy2(ConfigWriter.CONFIG_FILE, backup_file)
            logger.info(f"Config backed up to: {backup_file}")
        except Exception as e:
            logger.warning(f"Failed to backup config: {e}")
