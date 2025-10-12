"""
GraphQL Schema for HomeFree Web Installer
"""

import strawberry
from typing import List, Optional

from resolvers.system import SystemResolver
from resolvers.network import NetworkResolver
from resolvers.config import ConfigResolver
from resolvers.install import InstallResolver


# Type Definitions

@strawberry.type
class DiskInfo:
    name: str
    size: int
    model: str
    removable: bool = False

@strawberry.type
class SystemInfo:
    hostname: str
    cpu_info: str
    memory_total: int
    disks: List[DiskInfo]

@strawberry.type
class NetworkInterface:
    name: str
    mac: str
    speed: str
    carrier: bool
    is_ethernet: bool

@strawberry.type
class TimezoneRegion:
    region: str
    zones: List[str]

@strawberry.type
class KeyboardLayout:
    name: str
    description: str

@strawberry.type
class PartitioningConfig:
    device: str
    mode: str
    encryption: bool = False
    swap: bool = True

@strawberry.type
class InstallSummary:
    hostname: str
    timezone: str
    locale: str
    keymap: str
    username: str
    fullname: str
    wan_interface: str
    lan_interface: str
    partitioning: Optional[PartitioningConfig]

@strawberry.type
class InstallProgress:
    step: str
    progress: float
    message: str
    completed: bool
    error: Optional[str] = None

@strawberry.type
class MutationResult:
    success: bool
    message: str


# Query Type

@strawberry.type
class Query:
    @strawberry.field
    def system_info(self) -> SystemInfo:
        """Get system information"""
        return SystemResolver.get_system_info()

    @strawberry.field
    def network_interfaces(self) -> List[NetworkInterface]:
        """Get list of network interfaces"""
        return NetworkResolver.get_interfaces()

    @strawberry.field
    def timezones(self) -> List[TimezoneRegion]:
        """Get available timezones"""
        return ConfigResolver.get_timezones()

    @strawberry.field
    def keyboard_layouts(self) -> List[KeyboardLayout]:
        """Get available keyboard layouts"""
        return ConfigResolver.get_keyboard_layouts()

    @strawberry.field
    def install_summary(self) -> InstallSummary:
        """Get current installation configuration summary"""
        return ConfigResolver.get_install_summary()

    @strawberry.field
    def install_progress(self) -> InstallProgress:
        """Get current installation progress"""
        return InstallResolver.get_progress()


# Mutation Type

@strawberry.type
class Mutation:
    @strawberry.mutation
    def set_network_config(self, wan_interface: str, lan_interface: str) -> MutationResult:
        """Configure WAN and LAN network interfaces"""
        return NetworkResolver.set_config(wan_interface, lan_interface)

    @strawberry.mutation
    def set_location(self, timezone: str, locale: str) -> MutationResult:
        """Set timezone and locale"""
        return ConfigResolver.set_location(timezone, locale)

    @strawberry.mutation
    def set_keyboard(self, layout: str, vconsole: str) -> MutationResult:
        """Set keyboard layout"""
        return ConfigResolver.set_keyboard(layout, vconsole)

    @strawberry.mutation
    def set_user(self, username: str, fullname: str, password: str) -> MutationResult:
        """Set user account information"""
        return ConfigResolver.set_user(username, fullname, password)

    @strawberry.mutation
    def set_hostname(self, hostname: str) -> MutationResult:
        """Set system hostname"""
        return ConfigResolver.set_hostname(hostname)

    @strawberry.mutation
    def set_partitioning(self, config: str) -> MutationResult:
        """Set partitioning configuration"""
        return ConfigResolver.set_partitioning(config)

    @strawberry.mutation
    def start_installation(self) -> MutationResult:
        """Start the installation process"""
        return InstallResolver.start_installation()

    @strawberry.mutation
    def reboot_system(self) -> MutationResult:
        """Reboot the system"""
        return SystemResolver.reboot()
