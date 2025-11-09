"""
Config writer service - updates NixOS configuration files
"""

from pathlib import Path
from typing import Dict, Any, List, Optional
import logging
import shutil
from datetime import datetime

logger = logging.getLogger(__name__)


class ConfigWriter:
    """Service for writing NixOS configuration files"""

    CONFIG_FILE = Path("/etc/nixos/homefree-configuration.nix")
    BACKUP_DIR = Path("/var/lib/homefree-admin/config-backups")

    @staticmethod
    def write_config(config: Dict[str, Any]) -> bool:
        """
        Write configuration changes to homefree-configuration.nix

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
            content = ConfigWriter.CONFIG_FILE.read_text()

            # Update each section
            if 'system' in config:
                content = ConfigWriter._update_system_section(content, config['system'])

            if 'network' in config:
                content = ConfigWriter._update_network_section(content, config['network'])

            if 'dns' in config:
                content = ConfigWriter._update_dns_section(content, config['dns'])

            if 'services' in config:
                content = ConfigWriter._update_services_section(content, config['services'])

            if 'backups' in config:
                content = ConfigWriter._update_backups_section(content, config['backups'])

            # Write updated config
            ConfigWriter.CONFIG_FILE.write_text(content)
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
            backup_file = ConfigWriter.BACKUP_DIR / f"homefree-configuration.{timestamp}.nix"
            shutil.copy2(ConfigWriter.CONFIG_FILE, backup_file)
            logger.info(f"Config backed up to: {backup_file}")
        except Exception as e:
            logger.warning(f"Failed to backup config: {e}")

    @staticmethod
    def _update_system_section(content: str, system_config: Dict[str, Any]) -> str:
        """Update homefree.system section"""
        import re

        # Update simple string fields
        string_fields = {
            'hostName': 'homefree.system.hostName',
            'timeZone': 'homefree.system.timeZone',
            'defaultLocale': 'homefree.system.defaultLocale',
            'keyMap': 'homefree.system.keyMap',
            'localDomain': 'homefree.system.localDomain',
            'domain': 'homefree.system.domain',
            'adminUsername': 'homefree.system.adminUsername',
            'countryCode': 'homefree.system.countryCode',
        }

        for key, nix_path in string_fields.items():
            if key in system_config and system_config[key] is not None:
                value = system_config[key]
                pattern = rf'({re.escape(nix_path)}\s*=\s*)"[^"]*"'
                replacement = rf'\1"{value}"'
                content = re.sub(pattern, replacement, content, flags=re.MULTILINE)

        # Update lists
        if 'additionalDomains' in system_config:
            domains = system_config['additionalDomains']
            domains_str = ' '.join([f'"{d}"' for d in domains])
            pattern = r'(homefree\.system\.additionalDomains\s*=\s*\[)[^\]]*(\];)'
            replacement = rf'\1 {domains_str} \2'
            content = re.sub(pattern, replacement, content, flags=re.MULTILINE)

        if 'authorizedKeys' in system_config:
            keys = system_config['authorizedKeys']
            keys_str = '\n        '.join([f'"{k}"' for k in keys])
            pattern = r'(homefree\.system\.authorizedKeys\s*=\s*\[)[^\]]*(\];)'
            replacement = rf'\1\n        {keys_str}\n      \2'
            content = re.sub(pattern, replacement, content, flags=re.MULTILINE | re.DOTALL)

        return content

    @staticmethod
    def _update_network_section(content: str, network_config: Dict[str, Any]) -> str:
        """Update homefree.network section"""
        import re

        # Update simple string fields
        string_fields = {
            'wan_interface': 'homefree.network.wan-interface',
            'lan_interface': 'homefree.network.lan-interface',
            'lan_address': 'homefree.network.lan-address',
            'lan_subnet': 'homefree.network.lan-subnet',
            'dhcp_range_start': 'homefree.network.dhcp-range-start',
            'dhcp_range_end': 'homefree.network.dhcp-range-end',
        }

        for key, nix_path in string_fields.items():
            if key in network_config and network_config[key] is not None:
                value = network_config[key]
                pattern = rf'({re.escape(nix_path)}\s*=\s*)"[^"]*"'
                replacement = rf'\1"{value}"'
                content = re.sub(pattern, replacement, content, flags=re.MULTILINE)

        # Update boolean fields
        if 'enable_adblock' in network_config:
            value = 'true' if network_config['enable_adblock'] else 'false'
            pattern = r'(homefree\.network\.enable-adblock\s*=\s*)(true|false)'
            replacement = rf'\1{value}'
            content = re.sub(pattern, replacement, content, flags=re.MULTILINE)

        if 'router_enable' in network_config:
            value = 'true' if network_config['router_enable'] else 'false'
            pattern = r'(homefree\.network\.router\.enable\s*=\s*)(true|false)'
            replacement = rf'\1{value}'
            content = re.sub(pattern, replacement, content, flags=re.MULTILINE)

        # Update integer fields
        if 'wan_bitrate_mbps_down' in network_config and network_config['wan_bitrate_mbps_down']:
            value = network_config['wan_bitrate_mbps_down']
            pattern = r'(homefree\.network\.wan-bitrate-mbps-down\s*=\s*)\d+'
            replacement = rf'\1{value}'
            content = re.sub(pattern, replacement, content, flags=re.MULTILINE)

        if 'wan_bitrate_mbps_up' in network_config and network_config['wan_bitrate_mbps_up']:
            value = network_config['wan_bitrate_mbps_up']
            pattern = r'(homefree\.network\.wan-bitrate-mbps-up\s*=\s*)\d+'
            replacement = rf'\1{value}'
            content = re.sub(pattern, replacement, content, flags=re.MULTILINE)

        # Update static IPs
        if 'static_ips' in network_config:
            static_ips = network_config['static_ips']
            static_ips_nix = ConfigWriter._format_static_ips(static_ips)
            pattern = r'(homefree\.network\.static-ips\s*=\s*\[)[^\]]*(\];)'
            replacement = rf'\1{static_ips_nix}\2'
            content = re.sub(pattern, replacement, content, flags=re.MULTILINE | re.DOTALL)

        return content

    @staticmethod
    def _format_static_ips(static_ips: List[Dict[str, Any]]) -> str:
        """Format static IPs as Nix attribute sets"""
        if not static_ips:
            return ''

        formatted = []
        for ip_config in static_ips:
            mac = ip_config.get('mac_address', '')
            hostname = ip_config.get('hostname', '')
            ip = ip_config.get('ip', '')
            wan_access = ip_config.get('wan_access', True)

            entry = f'''
        {{
          mac-address = "{mac}";
          hostname = "{hostname}";
          ip = "{ip}";'''

            if not wan_access:
                entry += f'\n          wan-access = false;'

            entry += '\n        }'
            formatted.append(entry)

        return ''.join(formatted) + '\n      '

    @staticmethod
    def _update_dns_section(content: str, dns_config: Dict[str, Any]) -> str:
        """Update homefree.dns section"""
        import re

        # Update DNS overrides
        if 'overrides' in dns_config:
            overrides = dns_config['overrides']
            overrides_nix = ConfigWriter._format_dns_overrides(overrides)
            pattern = r'(homefree\.dns\.local\.overrides\s*=\s*\[)[^\]]*(\];)'
            replacement = rf'\1{overrides_nix}\2'
            content = re.sub(pattern, replacement, content, flags=re.MULTILINE | re.DOTALL)

        return content

    @staticmethod
    def _format_dns_overrides(overrides: List[Dict[str, str]]) -> str:
        """Format DNS overrides as Nix attribute sets"""
        if not overrides:
            return ''

        formatted = []
        for override in overrides:
            hostname = override.get('hostname', '')
            domain = override.get('domain', '')
            ip = override.get('ip', '')

            entry = f'''
          {{
            hostname = "{hostname}";
            domain = "{domain}";
            ip = "{ip}";
          }}'''
            formatted.append(entry)

        return ''.join(formatted) + '\n        '

    @staticmethod
    def _update_services_section(content: str, services_config: Dict[str, Dict[str, Any]]) -> str:
        """Update homefree.services section"""
        import re

        for service_name, service_settings in services_config.items():
            # Update enable flag
            if 'enable' in service_settings:
                value = 'true' if service_settings['enable'] else 'false'
                pattern = rf'(homefree\.services\.{re.escape(service_name)}\.enable\s*=\s*)(true|false)'
                replacement = rf'\1{value}'
                content = re.sub(pattern, replacement, content, flags=re.MULTILINE)

            # Update public flag if present
            if 'public' in service_settings:
                value = 'true' if service_settings['public'] else 'false'
                pattern = rf'(homefree\.services\.{re.escape(service_name)}\.public\s*=\s*)(true|false)'
                replacement = rf'\1{value}'
                content = re.sub(pattern, replacement, content, flags=re.MULTILINE)

        return content

    @staticmethod
    def _update_backups_section(content: str, backups_config: Dict[str, Any]) -> str:
        """Update homefree.backups section"""
        import re

        # Update enable flag
        if 'enable' in backups_config:
            value = 'true' if backups_config['enable'] else 'false'
            pattern = r'(homefree\.backups\.enable\s*=\s*)(true|false)'
            replacement = rf'\1{value}'
            content = re.sub(pattern, replacement, content, flags=re.MULTILINE)

        # Update to-path
        if 'to_path' in backups_config and backups_config['to_path']:
            value = backups_config['to_path']
            pattern = r'(homefree\.backups\.to-path\s*=\s*)"[^"]*"'
            replacement = rf'\1"{value}"'
            content = re.sub(pattern, replacement, content, flags=re.MULTILINE)

        # Update backblaze settings
        if 'backblaze_enable' in backups_config:
            value = 'true' if backups_config['backblaze_enable'] else 'false'
            pattern = r'(homefree\.backups\.backblaze\.enable\s*=\s*)(true|false)'
            replacement = rf'\1{value}'
            content = re.sub(pattern, replacement, content, flags=re.MULTILINE)

        if 'backblaze_bucket' in backups_config and backups_config['backblaze_bucket']:
            value = backups_config['backblaze_bucket']
            pattern = r'(homefree\.backups\.backblaze\.bucket\s*=\s*)"[^"]*"'
            replacement = rf'\1"{value}"'
            content = re.sub(pattern, replacement, content, flags=re.MULTILINE)

        return content
