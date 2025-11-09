"""
Validation service - validates configuration before applying
"""

import re
import ipaddress
from typing import Dict, Any, List, Tuple
import logging

logger = logging.getLogger(__name__)


class ValidationService:
    """Service for validating configuration changes"""

    @staticmethod
    def validate_config(config: Dict[str, Any]) -> Tuple[bool, List[str]]:
        """
        Validate entire configuration.

        Args:
            config: Configuration dictionary to validate

        Returns:
            Tuple of (is_valid, list_of_errors)
        """
        errors = []

        # Validate each section
        if 'system' in config:
            errors.extend(ValidationService._validate_system(config['system']))

        if 'network' in config:
            errors.extend(ValidationService._validate_network(config['network']))

        if 'dns' in config:
            errors.extend(ValidationService._validate_dns(config['dns']))

        if 'services' in config:
            errors.extend(ValidationService._validate_services(config['services']))

        if 'backups' in config:
            errors.extend(ValidationService._validate_backups(config['backups']))

        return len(errors) == 0, errors

    @staticmethod
    def _validate_system(system_config: Dict[str, Any]) -> List[str]:
        """Validate system configuration"""
        errors = []

        # Validate hostname
        if 'hostName' in system_config:
            hostname = system_config['hostName']
            if not hostname:
                errors.append("Hostname cannot be empty")
            elif not re.match(r'^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$', hostname, re.IGNORECASE):
                errors.append(f"Invalid hostname: {hostname}. Must be alphanumeric with optional hyphens")

        # Validate domain
        if 'domain' in system_config:
            domain = system_config['domain']
            if domain and not re.match(r'^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)*$', domain, re.IGNORECASE):
                errors.append(f"Invalid domain: {domain}")

        # Validate timezone
        if 'timeZone' in system_config:
            timezone = system_config['timeZone']
            if not timezone:
                errors.append("Timezone cannot be empty")

        # Validate locale
        if 'defaultLocale' in system_config:
            locale = system_config['defaultLocale']
            if locale and not re.match(r'^[a-z]{2}_[A-Z]{2}\.[A-Z0-9-]+$', locale):
                errors.append(f"Invalid locale format: {locale}. Expected format: en_US.UTF-8")

        # Validate username
        if 'adminUsername' in system_config:
            username = system_config['adminUsername']
            if not username:
                errors.append("Admin username cannot be empty")
            elif not re.match(r'^[a-z_]([a-z0-9_-]{0,31}|[a-z0-9_-]{0,30}\$)$', username):
                errors.append(f"Invalid username: {username}. Must start with letter or underscore")

        return errors

    @staticmethod
    def _validate_network(network_config: Dict[str, Any]) -> List[str]:
        """Validate network configuration"""
        errors = []

        # Validate interfaces
        if 'wan_interface' in network_config:
            if not network_config['wan_interface']:
                errors.append("WAN interface cannot be empty")

        if 'lan_interface' in network_config:
            if not network_config['lan_interface']:
                errors.append("LAN interface cannot be empty")

        # Check for same interface
        if ('wan_interface' in network_config and 'lan_interface' in network_config):
            if network_config['wan_interface'] == network_config['lan_interface']:
                errors.append("WAN and LAN interfaces must be different")

        # Validate IP addresses
        if 'lan_address' in network_config:
            try:
                ipaddress.ip_address(network_config['lan_address'])
            except ValueError:
                errors.append(f"Invalid LAN address: {network_config['lan_address']}")

        # Validate subnet
        if 'lan_subnet' in network_config:
            try:
                network = ipaddress.ip_network(network_config['lan_subnet'])
            except ValueError:
                errors.append(f"Invalid LAN subnet: {network_config['lan_subnet']}")

        # Validate DHCP range
        if 'dhcp_range_start' in network_config and 'dhcp_range_end' in network_config:
            try:
                start_ip = ipaddress.ip_address(network_config['dhcp_range_start'])
                end_ip = ipaddress.ip_address(network_config['dhcp_range_end'])

                if start_ip >= end_ip:
                    errors.append("DHCP range start must be less than end")

                # Validate range is within subnet
                if 'lan_subnet' in network_config:
                    subnet = ipaddress.ip_network(network_config['lan_subnet'])
                    if start_ip not in subnet or end_ip not in subnet:
                        errors.append("DHCP range must be within LAN subnet")

            except ValueError as e:
                errors.append(f"Invalid DHCP range: {e}")

        # Validate static IPs
        if 'static_ips' in network_config:
            errors.extend(ValidationService._validate_static_ips(
                network_config['static_ips'],
                network_config.get('lan_subnet')
            ))

        # Validate bitrates
        for field in ['wan_bitrate_mbps_down', 'wan_bitrate_mbps_up']:
            if field in network_config and network_config[field] is not None:
                if not isinstance(network_config[field], int) or network_config[field] <= 0:
                    errors.append(f"{field} must be a positive integer")

        return errors

    @staticmethod
    def _validate_static_ips(static_ips: List[Dict[str, Any]], lan_subnet: str = None) -> List[str]:
        """Validate static IP configurations"""
        errors = []
        seen_macs = set()
        seen_ips = set()
        seen_hostnames = set()

        subnet = None
        if lan_subnet:
            try:
                subnet = ipaddress.ip_network(lan_subnet)
            except ValueError:
                pass

        for idx, ip_config in enumerate(static_ips):
            prefix = f"Static IP #{idx + 1}"

            # Validate MAC address
            mac = ip_config.get('mac_address', '')
            if not mac:
                errors.append(f"{prefix}: MAC address required")
            elif not re.match(r'^([0-9a-f]{2}:){5}[0-9a-f]{2}$', mac, re.IGNORECASE):
                errors.append(f"{prefix}: Invalid MAC address format: {mac}")
            elif mac.lower() in seen_macs:
                errors.append(f"{prefix}: Duplicate MAC address: {mac}")
            else:
                seen_macs.add(mac.lower())

            # Validate hostname
            hostname = ip_config.get('hostname', '')
            if not hostname:
                errors.append(f"{prefix}: Hostname required")
            elif not re.match(r'^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$', hostname, re.IGNORECASE):
                errors.append(f"{prefix}: Invalid hostname: {hostname}")
            elif hostname.lower() in seen_hostnames:
                errors.append(f"{prefix}: Duplicate hostname: {hostname}")
            else:
                seen_hostnames.add(hostname.lower())

            # Validate IP address
            ip = ip_config.get('ip', '')
            if not ip:
                errors.append(f"{prefix}: IP address required")
            else:
                try:
                    ip_addr = ipaddress.ip_address(ip)

                    # Check for duplicates
                    if ip in seen_ips:
                        errors.append(f"{prefix}: Duplicate IP address: {ip}")
                    else:
                        seen_ips.add(ip)

                    # Check if in subnet
                    if subnet and ip_addr not in subnet:
                        errors.append(f"{prefix}: IP {ip} is not in LAN subnet {lan_subnet}")

                except ValueError:
                    errors.append(f"{prefix}: Invalid IP address: {ip}")

        return errors

    @staticmethod
    def _validate_dns(dns_config: Dict[str, Any]) -> List[str]:
        """Validate DNS configuration"""
        errors = []

        if 'overrides' in dns_config:
            for idx, override in enumerate(dns_config['overrides']):
                prefix = f"DNS Override #{idx + 1}"

                # Validate hostname
                if not override.get('hostname'):
                    errors.append(f"{prefix}: Hostname required")

                # Validate domain
                if not override.get('domain'):
                    errors.append(f"{prefix}: Domain required")

                # Validate IP
                ip = override.get('ip', '')
                if not ip:
                    errors.append(f"{prefix}: IP address required")
                else:
                    try:
                        ipaddress.ip_address(ip)
                    except ValueError:
                        errors.append(f"{prefix}: Invalid IP address: {ip}")

        return errors

    @staticmethod
    def _validate_services(services_config: Dict[str, Dict[str, Any]]) -> List[str]:
        """Validate services configuration"""
        errors = []

        # Basic validation - ensure enable/public are boolean
        for service_name, service_settings in services_config.items():
            if 'enable' in service_settings:
                if not isinstance(service_settings['enable'], bool):
                    errors.append(f"Service {service_name}: enable must be boolean")

            if 'public' in service_settings:
                if not isinstance(service_settings['public'], bool):
                    errors.append(f"Service {service_name}: public must be boolean")

        return errors

    @staticmethod
    def _validate_backups(backups_config: Dict[str, Any]) -> List[str]:
        """Validate backups configuration"""
        errors = []

        # Validate backup path
        if 'to_path' in backups_config:
            path = backups_config['to_path']
            if not path:
                errors.append("Backup path cannot be empty when backups are enabled")
            elif not path.startswith('/'):
                errors.append(f"Backup path must be absolute: {path}")

        # Validate Backblaze config
        if backups_config.get('backblaze_enable'):
            if not backups_config.get('backblaze_bucket'):
                errors.append("Backblaze bucket required when Backblaze backups are enabled")

        return errors

    @staticmethod
    def check_network_change_warning(old_config: Dict[str, Any], new_config: Dict[str, Any]) -> List[str]:
        """
        Check if network changes could cause connectivity loss.

        Returns:
            List of warning messages
        """
        warnings = []

        # Check for interface changes
        if old_config.get('wan_interface') != new_config.get('wan_interface'):
            warnings.append(
                "⚠️ WARNING: Changing WAN interface may cause loss of internet connectivity. "
                "Ensure you have console access to the system."
            )

        if old_config.get('lan_interface') != new_config.get('lan_interface'):
            warnings.append(
                "⚠️ WARNING: Changing LAN interface may cause loss of local network connectivity. "
                "Ensure you have console access to the system."
            )

        # Check for LAN address changes
        if old_config.get('lan_address') != new_config.get('lan_address'):
            warnings.append(
                "⚠️ WARNING: Changing LAN address will disconnect current admin session. "
                "You will need to reconnect at the new address."
            )

        # Check for subnet changes
        if old_config.get('lan_subnet') != new_config.get('lan_subnet'):
            warnings.append(
                "⚠️ WARNING: Changing LAN subnet will affect all connected devices. "
                "They will need to obtain new IP addresses."
            )

        return warnings
