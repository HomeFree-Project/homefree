"""
Shared hwmon scanner — reads /sys/class/hwmon and returns a flat list
of temperature readings.

Used by both the dashboard sampler (writer) and the Hardware resolver
(reader). Living in services/ rather than under resolvers/ so the
sampler can import it without pulling in smartctl-shouldered code.

Pure sysfs reads — no privileges required, no subprocesses.
"""

import logging
from pathlib import Path
from typing import Any, Dict, List, Optional

logger = logging.getLogger(__name__)

# /sys/class/hwmon entries. Each entry holds a `name` file (driver
# name like "k10temp", "nvme", "spd5118", "amdgpu") and one or more
# temp{N}_input files in millidegrees C.
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


def classify(driver: str) -> str:
    """Coarse bucket for a hwmon driver — used for UI grouping and as
    the persisted `kind` column in the history DB."""
    if driver in ("k10temp", "coretemp", "zenpower", "k8temp"):
        return "cpu"
    if driver in ("spd5118", "jc42"):
        return "memory"
    if driver == "nvme":
        return "nvme"
    if driver in ("amdgpu", "i915", "nouveau", "radeon"):
        return "gpu"
    return "other"


def scan() -> List[Dict[str, Any]]:
    """Return every active hwmon temperature input.

    Schema per item:
      name   : driver (k10temp, nvme, spd5118, amdgpu, …)
      label  : the temp{N}_label string if present, else ""
      temp_c : current temperature (°C, one decimal)
      kind   : classify(name) bucket
      key    : "<driver>:<label or tempN>" — stable identity for this
               sensor, used as the SQLite primary-key fragment.

    Skips sensors that report 0 (NVMe controllers leave unused sensor
    slots zeroed) so the history DB doesn't accumulate fake rows.
    """
    if not _HWMON_ROOT.exists():
        return []
    out: List[Dict[str, Any]] = []
    # Sort by hwmon{N} so the order is stable across reboots; the
    # kernel doesn't guarantee enumeration order so we sort
    # alphanumerically (hwmon10 sorts after hwmon2, but for the typical
    # 5–10 sensor count this is fine).
    #
    # Multiple devices of the same driver (e.g. two nvme controllers,
    # two spd5118 DIMMs) have identical (driver, label) tuples — to
    # keep their history rows distinct we attach a per-driver instance
    # index based on enumeration order. This index is stable within a
    # boot but may shuffle if the kernel re-enumerates hwmon devices in
    # a different order (rare; e.g. a PCIe topology change). That's the
    # same robustness ceiling /sys/class/hwmon-based tooling generally
    # has.
    entries = sorted(_HWMON_ROOT.iterdir())
    # Pre-scan: count entries per driver so the loop below knows
    # whether to include an instance suffix in the display name.
    drivers_by_entry = [(e, _read_str(e / "name") or "unknown") for e in entries]
    driver_total: Dict[str, int] = {}
    for _, driver in drivers_by_entry:
        driver_total[driver] = driver_total.get(driver, 0) + 1

    driver_seen: Dict[str, int] = {}
    for entry, driver in drivers_by_entry:
        instance = driver_seen.get(driver, 0)
        driver_seen[driver] = instance + 1
        multi = driver_total[driver] > 1
        display_name = f"{driver} #{instance}" if multi else driver
        # Always include the instance in the persisted key when the
        # driver is multi-instance; single-instance drivers get the
        # bare driver name for cleaner keys.
        key_driver = f"{driver}#{instance}" if multi else driver

        for temp_input in sorted(entry.glob("temp*_input")):
            millideg = _read_int(temp_input)
            if millideg is None or millideg == 0:
                continue
            label = _read_str(temp_input.with_name(
                temp_input.name.replace("_input", "_label")
            )) or ""
            key_suffix = label or temp_input.name.replace("_input", "")
            out.append({
                "key": f"{key_driver}:{key_suffix}",
                "name": display_name,
                "label": label,
                "temp_c": round(millideg / 1000.0, 1),
                "kind": classify(driver),
            })
    return out
