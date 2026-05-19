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
class SystemCapabilities:
    """Hardware capabilities relevant to disk setup and encryption.

    Probed in the installer ISO so the partitioning UI can decide what
    encryption modes are viable (TPM2 auto-unlock vs. passphrase) and
    whether the Secure Boot opt-in can be offered.
    """
    uefi: bool = False
    tpm2_available: bool = False


@dataclass
class SystemInfo:
    """System information"""
    hostname: str
    cpu_info: str
    memory_total: int
    disks: List[DiskInfo]
    capabilities: Optional["SystemCapabilities"] = None


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
    """Disk partitioning configuration.

    The installer accepts a list of disks plus a RAID level so a
    mirror/stripe can be set up across multiple disks. LUKS encryption
    is on by default; `use_lanzaboote` is an advanced opt-in that
    enables Secure Boot (requires a one-time BIOS Setup-Mode step).
    """
    disks: List[str]
    raid: str = "none"          # none | raid0 | raid1
    use_encryption: bool = True
    use_swap: bool = True
    use_lanzaboote: bool = False
    # Legacy single-disk field, kept so older summary code still renders.
    device: str = ""
    mode: str = "automatic"


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
    # LUKS recovery passphrase, surfaced once disk encryption secrets
    # have been generated so the UI can show it on the completion screen.
    recovery_passphrase: Optional[str] = None


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
class UnitState:
    """Per-unit systemd state, for surfacing partial failures in the UI."""
    name: str
    active_state: str
    sub_state: str
    # Role within a blue/green pair: "active" (the colour serving
    # traffic), "standby" (the dormant colour — inactive is EXPECTED,
    # not an error), or None (not blue/green, or the pair is mid-flip /
    # down). Lets the UI avoid painting a healthy dormant standby as a
    # red error chip. Set by _collapse_blue_green in resolvers/services.py.
    bg_role: Optional[str] = None


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
    parent: Optional[str] = None  # Label of parent service (for instances)
    partial: bool = False  # True if parent service has some instances disabled
    # Per-unit breakdown so the UI can flag specific units that aren't
    # running when the aggregate is "degraded".
    unit_states: Optional[List[UnitState]] = None
    # SSO surfacing — folds the old /api/sso/state per-service table
    # into the main services list. sso_kind is one of
    # native_oidc | caddy_gated | basic_auth | infra | none.
    sso_kind: str = "none"
    sso_notes: str = ""
    sso_provisioned: bool = False
    # Only meaningful when sso_kind == "none": True ⇒ integration is
    # pending, False ⇒ SSO deliberately not applicable to this service.
    sso_applicable: bool = True
