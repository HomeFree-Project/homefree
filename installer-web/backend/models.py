"""
Type definitions for HomeFree Web Installer
Plain Python dataclasses (no strawberry/GraphQL dependency)
"""

from dataclasses import dataclass
from typing import List, Optional


@dataclass
class DiskInfo:
    """Information about a disk device"""
    name: str
    size: int
    model: str
    removable: bool = False


@dataclass
class SystemInfo:
    """System information"""
    hostname: str
    cpu_info: str
    memory_total: int
    disks: List[DiskInfo]


@dataclass
class NetworkInterface:
    """Network interface information"""
    name: str
    mac: str
    speed: str
    carrier: bool
    is_ethernet: bool


@dataclass
class TimezoneRegion:
    """Timezone region with available zones"""
    region: str
    zones: List[str]


@dataclass
class KeyboardLayout:
    """Keyboard layout option"""
    name: str
    description: str


@dataclass
class PartitioningConfig:
    """Disk partitioning configuration"""
    device: str
    mode: str
    encryption: bool = False
    swap: bool = True


@dataclass
class InstallSummary:
    """Installation configuration summary"""
    hostname: str
    timezone: str
    locale: str
    keymap: str
    username: str
    fullname: str
    wan_interface: str
    lan_interface: str
    partitioning: Optional[PartitioningConfig]


@dataclass
class InstallProgress:
    """Installation progress status"""
    step: str
    progress: float
    message: str
    completed: bool
    error: Optional[str] = None


@dataclass
class MutationResult:
    """Result of a configuration mutation/action"""
    success: bool
    message: str
