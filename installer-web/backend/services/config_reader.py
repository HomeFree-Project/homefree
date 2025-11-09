"""
Config reader service - parses existing NixOS configuration files
"""

from pathlib import Path
from typing import Dict, Any, List, Optional
import re
import logging

logger = logging.getLogger(__name__)


class ConfigReader:
    """Service for reading NixOS configuration files"""

    CONFIG_FILE = Path("/etc/nixos/homefree-configuration.nix")

    @staticmethod
    def read_config() -> Dict[str, Any]:
        """
        Parse homefree-configuration.nix and extract current settings.

        Returns:
            Dictionary with current homefree configuration values
        """
        if not ConfigReader.CONFIG_FILE.exists():
            logger.warning(f"Config file not found: {ConfigReader.CONFIG_FILE}")
            return {}

        try:
            content = ConfigReader.CONFIG_FILE.read_text()
            config = ConfigReader._parse_nix_config(content)
            return config
        except Exception as e:
            logger.error(f"Error reading config file: {e}")
            return {}

    @staticmethod
    def _parse_nix_config(content: str) -> Dict[str, Any]:
        """
        Parse Nix configuration content into a dictionary.

        This is a simplified parser that extracts homefree.* settings.
        For complex nested structures, we may need a proper Nix parser.

        Args:
            content: Nix configuration file content

        Returns:
            Dictionary with parsed configuration
        """
        config = {
            'system': {},
            'network': {},
            'dns': {},
            'services': {},
            'backups': {},
            'service_config': [],
            'proxied_domains': []
        }

        # Extract the homefree section first
        # We need to properly handle nested braces, so find the starting point
        # and count braces to find the matching closing brace
        homefree_start = content.find('homefree = {')
        if homefree_start == -1:
            logger.warning("Could not find 'homefree = {' in config")
            return config

        # Start after the opening brace
        start_pos = content.find('{', homefree_start) + 1
        brace_count = 1
        pos = start_pos

        # Count braces to find the matching closing brace
        while pos < len(content) and brace_count > 0:
            if content[pos] == '{':
                brace_count += 1
            elif content[pos] == '}':
                brace_count -= 1
            pos += 1

        if brace_count != 0:
            logger.warning("Could not find matching closing brace for homefree section")
            return config

        # Extract the content between braces (pos-1 is the closing brace)
        homefree_content = content[start_pos:pos-1]
        logger.debug(f"Found homefree content ({len(homefree_content)} chars, first 200): {homefree_content[:200]}")

        # Extract system section
        system_content = ConfigReader._extract_section(homefree_content, 'system')
        if system_content:
            config['system']['hostName'] = ConfigReader._extract_string_value(
                system_content, r'hostName\s*=\s*"([^"]+)"'
            )
            config['system']['timeZone'] = ConfigReader._extract_string_value(
                system_content, r'timeZone\s*=\s*"([^"]+)"'
            )
            config['system']['defaultLocale'] = ConfigReader._extract_string_value(
                system_content, r'defaultLocale\s*=\s*"([^"]+)"'
            )
            config['system']['keyMap'] = ConfigReader._extract_string_value(
                system_content, r'keyMap\s*=\s*"([^"]+)"'
            )
            config['system']['localDomain'] = ConfigReader._extract_string_value(
                system_content, r'localDomain\s*=\s*"([^"]+)"'
            )
            config['system']['domain'] = ConfigReader._extract_string_value(
                system_content, r'domain\s*=\s*"([^"]+)"'
            )
            config['system']['adminUsername'] = ConfigReader._extract_string_value(
                system_content, r'adminUsername\s*=\s*"([^"]+)"'
            )
            config['system']['countryCode'] = ConfigReader._extract_string_value(
                system_content, r'countryCode\s*=\s*"([^"]+)"'
            )

            # Extract additional domains list
            config['system']['additionalDomains'] = ConfigReader._extract_list_values(
                system_content, r'additionalDomains\s*=\s*\[(.*?)\]'
            )

            # Extract authorized keys
            config['system']['authorizedKeys'] = ConfigReader._extract_list_values(
                system_content, r'authorizedKeys\s*=\s*\[(.*?)\]'
            )

        # Extract network section
        network_content = ConfigReader._extract_section(homefree_content, 'network')
        if network_content:
            config['network']['wan_interface'] = ConfigReader._extract_string_value(
                network_content, r'wan-interface\s*=\s*"([^"]+)"'
            )
            config['network']['lan_interface'] = ConfigReader._extract_string_value(
                network_content, r'lan-interface\s*=\s*"([^"]+)"'
            )
            config['network']['lan_address'] = ConfigReader._extract_string_value(
                network_content, r'lan-address\s*=\s*"([^"]+)"'
            )
            config['network']['lan_subnet'] = ConfigReader._extract_string_value(
                network_content, r'lan-subnet\s*=\s*"([^"]+)"'
            )
            config['network']['dhcp_range_start'] = ConfigReader._extract_string_value(
                network_content, r'dhcp-range-start\s*=\s*"([^"]+)"'
            )
            config['network']['dhcp_range_end'] = ConfigReader._extract_string_value(
                network_content, r'dhcp-range-end\s*=\s*"([^"]+)"'
            )
            config['network']['enable_adblock'] = ConfigReader._extract_bool_value(
                network_content, r'enable-adblock\s*=\s*(true|false)'
            )
            config['network']['router_enable'] = ConfigReader._extract_bool_value(
                network_content, r'router\.enable\s*=\s*(true|false)'
            )

            # Extract WAN bitrates (can be null)
            config['network']['wan_bitrate_mbps_down'] = ConfigReader._extract_int_value(
                network_content, r'wan-bitrate-mbps-down\s*=\s*(\d+)'
            )
            config['network']['wan_bitrate_mbps_up'] = ConfigReader._extract_int_value(
                network_content, r'wan-bitrate-mbps-up\s*=\s*(\d+)'
            )

            # Extract static IPs (list of attribute sets)
            config['network']['static_ips'] = ConfigReader._extract_static_ips(network_content)

        # Extract DNS section
        dns_content = ConfigReader._extract_section(homefree_content, 'dns')
        if dns_content:
            config['dns']['overrides'] = ConfigReader._extract_dns_overrides(dns_content)

        # Extract services section
        services_content = ConfigReader._extract_section(homefree_content, 'services')
        if services_content:
            config['services'] = ConfigReader._extract_services(services_content)

        # Extract backups section
        backups_content = ConfigReader._extract_section(homefree_content, 'backups')
        if backups_content:
            config['backups']['enable'] = ConfigReader._extract_bool_value(
                backups_content, r'enable\s*=\s*(true|false)'
            )
            config['backups']['to_path'] = ConfigReader._extract_string_value(
                backups_content, r'to-path\s*=\s*"([^"]+)"'
            )
            config['backups']['backblaze_enable'] = ConfigReader._extract_bool_value(
                backups_content, r'backblaze\.enable\s*=\s*(true|false)'
            )
            config['backups']['backblaze_bucket'] = ConfigReader._extract_string_value(
                backups_content, r'backblaze\.bucket\s*=\s*"([^"]+)"'
            )

        return config

    @staticmethod
    def _extract_section(content: str, section_name: str) -> Optional[str]:
        """
        Extract a section's content by properly counting braces.

        Args:
            content: The content to search in
            section_name: The name of the section (e.g., 'system', 'network')

        Returns:
            The content between the section's braces, or None if not found
        """
        # Find the section start pattern
        pattern = f'{section_name}\\s*=\\s*{{'
        match = re.search(pattern, content)
        if not match:
            return None

        # Start after the opening brace
        start_pos = match.end()
        brace_count = 1
        pos = start_pos

        # Count braces to find the matching closing brace
        while pos < len(content) and brace_count > 0:
            if content[pos] == '{':
                brace_count += 1
            elif content[pos] == '}':
                brace_count -= 1
            pos += 1

        if brace_count != 0:
            return None

        # Return content between braces (pos-1 is the closing brace)
        return content[start_pos:pos-1]

    @staticmethod
    def _extract_string_value(content: str, pattern: str) -> Optional[str]:
        """Extract a string value using regex pattern"""
        match = re.search(pattern, content, re.MULTILINE)
        return match.group(1) if match else None

    @staticmethod
    def _extract_bool_value(content: str, pattern: str) -> Optional[bool]:
        """Extract a boolean value using regex pattern"""
        match = re.search(pattern, content, re.MULTILINE)
        if match:
            return match.group(1) == 'true'
        return None

    @staticmethod
    def _extract_int_value(content: str, pattern: str) -> Optional[int]:
        """Extract an integer value using regex pattern"""
        match = re.search(pattern, content, re.MULTILINE)
        return int(match.group(1)) if match else None

    @staticmethod
    def _extract_list_values(content: str, pattern: str) -> List[str]:
        """Extract a list of string values"""
        match = re.search(pattern, content, re.MULTILINE | re.DOTALL)
        if not match:
            return []

        list_content = match.group(1)
        # Extract quoted strings
        values = re.findall(r'"([^"]+)"', list_content)
        return values

    @staticmethod
    def _extract_static_ips(content: str) -> List[Dict[str, Any]]:
        """Extract static IP configurations"""
        static_ips = []

        # Find the static-ips list
        pattern = r'static-ips\s*=\s*\[(.*?)\];'
        match = re.search(pattern, content, re.MULTILINE | re.DOTALL)

        if not match:
            return static_ips

        list_content = match.group(1)

        # Extract each IP entry (attribute set)
        entry_pattern = r'\{\s*mac-address\s*=\s*"([^"]+)";\s*hostname\s*=\s*"([^"]+)";\s*ip\s*=\s*"([^"]+)";\s*(?:wan-access\s*=\s*(true|false);)?\s*\}'

        for entry_match in re.finditer(entry_pattern, list_content):
            mac = entry_match.group(1)
            hostname = entry_match.group(2)
            ip = entry_match.group(3)
            wan_access = entry_match.group(4)

            static_ips.append({
                'mac_address': mac,
                'hostname': hostname,
                'ip': ip,
                'wan_access': wan_access != 'false' if wan_access else True
            })

        return static_ips

    @staticmethod
    def _extract_dns_overrides(content: str) -> List[Dict[str, str]]:
        """Extract DNS override configurations"""
        overrides = []

        # Find the local.overrides list within dns section
        pattern = r'local\.overrides\s*=\s*\[(.*?)\];'
        match = re.search(pattern, content, re.MULTILINE | re.DOTALL)

        if not match:
            return overrides

        list_content = match.group(1)

        # Extract each override entry
        entry_pattern = r'\{\s*hostname\s*=\s*"([^"]+)";\s*domain\s*=\s*"([^"]+)";\s*ip\s*=\s*"([^"]+)";\s*\}'

        for entry_match in re.finditer(entry_pattern, list_content):
            overrides.append({
                'hostname': entry_match.group(1),
                'domain': entry_match.group(2),
                'ip': entry_match.group(3)
            })

        return overrides

    @staticmethod
    def _extract_services(content: str) -> Dict[str, Dict[str, Any]]:
        """Extract service configurations (enable, public flags)"""
        services = {}

        # List of known services from module.nix
        service_names = [
            'adguard', 'authentik', 'baikal', 'cryptpad', 'freshrss', 'forgejo',
            'frigate', 'gitea', 'grocy', 'headscale', 'homeassistant', 'homebox',
            'immich', 'jellyfin', 'joplin', 'kanidm', 'lidarr', 'logseq',
            'linkwarden', 'matrix', 'mediawiki', 'minecraft', 'nextcloud',
            'nzbget', 'oauth2-proxy', 'ollama', 'radicale', 'screeenly',
            'snipe-it', 'unifi', 'vaultwarden', 'webdav', 'zitadel'
        ]

        for service in service_names:
            # Extract enable flag
            enable_pattern = rf'{service}\s*=\s*\{{\s*enable\s*=\s*(true|false)'
            enable_match = re.search(enable_pattern, content, re.MULTILINE | re.DOTALL)

            # Extract public flag (if exists)
            public_pattern = rf'{service}\s*=\s*\{{[^}}]*public\s*=\s*(true|false)'
            public_match = re.search(public_pattern, content, re.MULTILINE | re.DOTALL)

            if enable_match or public_match:
                services[service] = {
                    'enable': enable_match.group(1) == 'true' if enable_match else False,
                    'public': public_match.group(1) == 'true' if public_match else False
                }

        return services
