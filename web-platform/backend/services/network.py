"""
Network detection service
Ported from Calamares network detection logic
"""

import os
import subprocess
from pathlib import Path
from typing import List, Optional
import pyudev

from models import NetworkInterface


class NetworkService:
    """Service for detecting and configuring network interfaces"""

    # Storage for installation configuration
    _config = {
        'wan_interface': None,
        'lan_interface': None,
    }

    @staticmethod
    def detect_interfaces() -> List[NetworkInterface]:
        """
        Detect ethernet network interfaces
        Returns list of NetworkInterface objects for physical ethernet adapters
        """
        interfaces = []
        context = pyudev.Context()

        # Find all network devices
        for device in context.list_devices(subsystem='net'):
            interface_name = device.sys_name

            # Skip loopback interface
            if interface_name == 'lo':
                continue

            # Check if it's a physical ethernet device
            # This filters out virtual interfaces (podman, veth, bridges, etc.)
            if not NetworkService._is_ethernet(device):
                continue

            # Get MAC address
            mac = NetworkService._get_mac_address(interface_name)
            if not mac:
                continue

            # Get link speed and carrier status
            speed = NetworkService._get_link_speed(interface_name)
            carrier = NetworkService._has_carrier(interface_name)

            interfaces.append(NetworkInterface(
                name=interface_name,
                mac=mac,
                speed=speed,
                carrier=carrier,
                is_ethernet=True
            ))

        # Sort by interface name
        interfaces.sort(key=lambda x: x.name)

        return interfaces

    @staticmethod
    def _is_physical_interface(interface_name: str) -> bool:
        """
        Check if interface is a physical (not virtual) network device.

        Physical interfaces have a 'device' symlink in /sys/class/net/ that
        points to the actual hardware (PCI, USB, etc.). Virtual interfaces
        (bridges, veth pairs, tun/tap, podman, docker, etc.) do not have this.

        Returns:
            True if physical hardware interface, False if virtual or doesn't exist
        """
        device_path = Path(f'/sys/class/net/{interface_name}/device')
        return device_path.exists()

    @staticmethod
    def _is_ethernet(device) -> bool:
        """Check if device is a physical ethernet adapter"""
        interface_name = device.sys_name

        # First check: Must be a physical interface (not virtual)
        if not NetworkService._is_physical_interface(interface_name):
            return False

        # Second check: Filter out wireless devices
        devtype = device.get('DEVTYPE')
        if devtype == 'wlan':
            return False

        # Third check: Must be ethernet type (type == 1, ARPHRD_ETHER)
        sys_path = Path(device.sys_path)
        if (sys_path / 'type').exists():
            try:
                net_type = int((sys_path / 'type').read_text().strip())
                return net_type == 1
            except:
                pass

        return False

    @staticmethod
    def _get_mac_address(interface_name: str) -> Optional[str]:
        """Get MAC address for interface"""
        address_path = Path(f'/sys/class/net/{interface_name}/address')
        if address_path.exists():
            try:
                return address_path.read_text().strip()
            except:
                pass
        return None

    @staticmethod
    def _get_link_speed(interface_name: str) -> str:
        """Get link speed for interface"""
        speed_path = Path(f'/sys/class/net/{interface_name}/speed')
        if speed_path.exists():
            try:
                speed = int(speed_path.read_text().strip())
                if speed > 0:
                    return f"{speed} Mbps"
            except:
                pass
        return "Unknown"

    @staticmethod
    def _has_carrier(interface_name: str) -> bool:
        """Check if interface has carrier (cable connected)"""
        carrier_path = Path(f'/sys/class/net/{interface_name}/carrier')
        if carrier_path.exists():
            try:
                return carrier_path.read_text().strip() == '1'
            except:
                pass
        return False

    @staticmethod
    def set_wan_interface(interface: str):
        """Store WAN interface configuration"""
        NetworkService._config['wan_interface'] = interface

    @staticmethod
    def set_lan_interface(interface: str):
        """Store LAN interface configuration"""
        NetworkService._config['lan_interface'] = interface

    @staticmethod
    def get_wan_interface() -> Optional[str]:
        """Get configured WAN interface"""
        return NetworkService._config.get('wan_interface')

    @staticmethod
    def get_lan_interface() -> Optional[str]:
        """Get configured LAN interface"""
        return NetworkService._config.get('lan_interface')
