"""
Network interface detection and configuration resolvers
"""

import subprocess
from pathlib import Path
from typing import List

from models import NetworkInterface, MutationResult
from services.network import NetworkService


class NetworkResolver:
    @staticmethod
    def get_interfaces() -> List[NetworkInterface]:
        """Get list of network interfaces"""
        return NetworkService.detect_interfaces()

    @staticmethod
    def set_config(wan_interface: str, lan_interface: str) -> MutationResult:
        """Set WAN and LAN interface configuration"""
        try:
            # Validate interfaces exist
            interfaces = NetworkService.detect_interfaces()
            interface_names = [iface.name for iface in interfaces]

            if wan_interface not in interface_names:
                return MutationResult(
                    success=False,
                    message=f"WAN interface {wan_interface} not found"
                )

            if lan_interface not in interface_names:
                return MutationResult(
                    success=False,
                    message=f"LAN interface {lan_interface} not found"
                )

            if wan_interface == lan_interface:
                return MutationResult(
                    success=False,
                    message="WAN and LAN interfaces must be different"
                )

            # Store configuration
            NetworkService.set_wan_interface(wan_interface)
            NetworkService.set_lan_interface(lan_interface)

            return MutationResult(
                success=True,
                message=f"Network configured: WAN={wan_interface}, LAN={lan_interface}"
            )

        except Exception as e:
            return MutationResult(
                success=False,
                message=f"Failed to set network config: {str(e)}"
            )
