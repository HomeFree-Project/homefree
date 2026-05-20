"""
Hardware resolver — backs the admin "Hardware" page.

Three responsibilities today:

  * `get_overview()`  — point-in-time per-drive SMART + a small set of
    motherboard sensor temps (CPU, memory, NVMe controller), all in
    one round-trip so the page renders without a chart of pending
    requests.

  * `get_drive_temp_history()` — read-only over the drive-temperature
    SQLite written by `homefree-drive-temp-sampler`.

The split mirrors dashboard.py's overview/history split. Room to grow
into more sensor surface (fan RPMs, ACPI thermal zones, per-NVMe
controller throttling state) without changing the route shape.
"""

import logging
from pathlib import Path
from typing import Any, Dict, List, Optional

from resolvers.physical_drives import PhysicalDrivesResolver
from services.drive_temp_history_store import (
    DriveTempHistoryStore,
    DEFAULT_DB_PATH as DRIVE_TEMP_DB_PATH,
    HISTORY_SECONDS as DRIVE_TEMP_HISTORY_SECONDS,
    SAMPLE_INTERVAL as DRIVE_TEMP_SAMPLE_INTERVAL,
)

logger = logging.getLogger(__name__)

# /sys/class/hwmon entries the kernel exposes. Each entry holds a
# `name` file (driver name like "k10temp", "nvme", "spd5118", "amdgpu")
# and one or more temp{N}_input files in millidegrees C. Reading these
# is cheap and free of privilege — they're just sysfs scalars.
_HWMON_ROOT = Path("/sys/class/hwmon")


def _read_int(path: Path) -> Optional[int]:
    try:
        return int(path.read_text().strip())
    except (OSError, ValueError):
        return None


def _read_str(path: Path) -> Optional[str]:
    try:
        return path.read_text().strip() or None
    except OSError:
        return None


def _scan_hwmon() -> List[Dict[str, Any]]:
    """Walk /sys/class/hwmon, return a flat list of temperature readings.

    Each item: {name, label, temp_c, kind} where `kind` is a coarse
    bucket the UI can group by — cpu / memory / nvme / gpu / other.
    Skips sensors that report 0 (NVMe controllers do this for unused
    sensor slots).
    """
    if not _HWMON_ROOT.exists():
        return []
    out: List[Dict[str, Any]] = []
    for entry in sorted(_HWMON_ROOT.iterdir()):
        driver = _read_str(entry / "name") or "unknown"
        for temp_input in sorted(entry.glob("temp*_input")):
            millideg = _read_int(temp_input)
            if millideg is None or millideg == 0:
                # Unused sensor slot — common on multi-sensor NVMes.
                continue
            label = _read_str(temp_input.with_name(
                temp_input.name.replace("_input", "_label")
            )) or ""
            kind = _classify_hwmon(driver)
            out.append({
                "name": driver,
                "label": label,
                "temp_c": round(millideg / 1000.0, 1),
                "kind": kind,
            })
    return out


def _classify_hwmon(driver: str) -> str:
    # k10temp / coretemp / zenpower / k8temp are AMD/Intel CPU drivers.
    if driver in ("k10temp", "coretemp", "zenpower", "k8temp"):
        return "cpu"
    # spd5118 is the in-DIMM SPD hub thermal sensor (DDR5).
    if driver in ("spd5118", "jc42"):
        return "memory"
    if driver == "nvme":
        return "nvme"
    if driver in ("amdgpu", "i915", "nouveau", "radeon"):
        return "gpu"
    return "other"


class HardwareResolver:

    @staticmethod
    def get_overview() -> Dict[str, Any]:
        """Snapshot for the Hardware page: drives + sensors."""
        return {
            "physical_drives": PhysicalDrivesResolver.get_all(),
            "sensors": _scan_hwmon(),
        }

    @staticmethod
    def get_drive_temp_history() -> Dict[str, Any]:
        """24h of per-drive temperature samples from the dedicated DB."""
        store = DriveTempHistoryStore(DRIVE_TEMP_DB_PATH)
        return {
            "sample_interval": DRIVE_TEMP_SAMPLE_INTERVAL,
            "window_seconds": DRIVE_TEMP_HISTORY_SECONDS,
            "by_device": store.get_history(DRIVE_TEMP_HISTORY_SECONDS),
        }
