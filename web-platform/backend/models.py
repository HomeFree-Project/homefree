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


# Admin mode models

@dataclass
class ValidationResult:
    """Result of configuration validation"""
    valid: bool
    errors: List[str]
    warnings: List[str]


@dataclass
class PreviewResult:
    """Result of configuration preview (dry-activate)"""
    success: bool
    changes: List[str]
    errors: List[str]
    output: str
    warnings: List[str]


@dataclass
class ApplyResult:
    """Result of configuration apply (rebuild)"""
    success: bool
    message: str
    pid: Optional[int] = None


@dataclass
class RebuildStatus:
    """Status of rebuild operation"""
    running: bool
    output: str
    exit_code: Optional[int]
    success: bool
    partial_success: bool = False


@dataclass
class ConfigDiff:
    """Configuration diff"""
    has_changes: bool
    diff: str


@dataclass
class ServiceStatus:
    """Service runtime status"""
    label: str
    name: str
    project_name: str
    enabled: bool
    public: bool
    active_state: str
    sub_state: str
    systemd_services: List[str]
    url: Optional[str] = None
