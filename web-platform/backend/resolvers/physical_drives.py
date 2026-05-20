"""
Physical drives resolver — per-block-device health for the Dashboard.

Distinct from `dashboard._disks()`, which is filesystem-centric (mount
points, %used). This module opens the underlying *block devices* and
reads SMART so the Dashboard can show temperature with class-appropriate
thresholds, power-on hours, and wear/health indicators.

Collection model
----------------
On-demand from admin-api with a 60s in-memory TTL. The Dashboard overview
endpoint is polled every 5s; running `smartctl` per drive on every poll
would be heavy and pointless — SMART values change on the order of
minutes, not seconds.

USB bridges
-----------
A drive in a USB enclosure (Synology / generic JMicron / ASMedia) often
doesn't accept `-d auto`. We try `auto`, then `sat`, then `usbjmicron`,
and surface the first one that returns parseable JSON with smartctl
exit-status bits below the "command failed" threshold. If all three
fail, the row still renders with `smart_available=False` so the user
can at least see the drive exists.

Thresholds
----------
Per drive class, hardcoded:

  HDD  : warn 45°C / err 50°C   (NAS-spinner derating range)
  SSD  : warn 60°C / err 70°C
  NVMe : warn 70°C / err 80°C

These are sensible defaults; no config knob today. Drive class is
detected for free from `/sys/block/<name>/queue/rotational` and the
device name (`/dev/nvme*`), so the shared-repo code carries no
hostname/VID:PID assumptions.

Privilege
---------
admin-api already runs as root (services/admin-web/default.nix), so
`smartctl` is invoked directly — no setuid wrapper, no polkit detour.

Safety
------
`smartctl` against a wedged USB bridge can hang for tens of seconds, so
every invocation runs in a thread pool with a hard wall-clock timeout
(same shape as `_disk_usage_safe` in dashboard.py). A wedged drive does
not freeze the overview endpoint.
"""

import concurrent.futures
import json
import logging
import shutil
import subprocess
import time
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

logger = logging.getLogger(__name__)


# A bad USB bridge can keep smartctl in an uninterruptible read for
# tens of seconds. Bound it.
_SMARTCTL_TIMEOUT_S = 3.0
_LSBLK_TIMEOUT_S = 2.0

# Cache the full result list. The overview endpoint polls at 5s; SMART
# values move on the scale of minutes.
_CACHE_TTL_S = 60.0
_cache: Optional[Tuple[float, List[Dict[str, Any]]]] = None

# Bounded so a storm of wedged drives can't spawn unbounded threads. A
# wedged worker leaks (Python can't kill a thread blocked in the
# kernel), but new submissions queue and the pool stays small.
_SMARTCTL_POOL = concurrent.futures.ThreadPoolExecutor(
    max_workers=2, thread_name_prefix="smartctl_safe",
)


# Per-class temperature thresholds (°C).
_TEMP_THRESHOLDS = {
    "hdd":  {"warn": 45, "err": 50},
    "ssd":  {"warn": 60, "err": 70},
    "nvme": {"warn": 70, "err": 80},
}


def _resolve_bin(name: str) -> str:
    """Absolute path to a binary. The admin-api systemd unit ships with
    a restricted PATH that excludes util-linux (lsblk) and smartmontools
    (smartctl) even though both are installed system-wide via
    environment.systemPackages. shutil.which() would return None and
    subprocess.run([name, …]) would raise FileNotFoundError. Resolve
    via /run/current-system/sw/bin as the canonical NixOS location,
    matching the same fallback pattern used by _ip_bin in dashboard.py."""
    found = shutil.which(name)
    if found:
        return found
    for c in (f"/run/current-system/sw/bin/{name}",
              f"/usr/sbin/{name}", f"/usr/bin/{name}"):
        if Path(c).exists():
            return c
    return name


_SMARTCTL = _resolve_bin("smartctl")
_LSBLK = _resolve_bin("lsblk")


def _lsblk_disks() -> List[Dict[str, str]]:
    """Enumerate non-removable disks. Mirrors system.py's exclusion mask
    (`-e 7,11` = loop + sr) and adds TRAN/ROTA so we can detect USB and
    HDD-vs-SSD without re-reading /sys."""
    try:
        result = subprocess.run(
            [
                _LSBLK, "-d", "-n", "-J",
                "-o", "NAME,SIZE,MODEL,VENDOR,TYPE,TRAN,ROTA,RM",
                "-e", "7,11",
                "-b",  # bytes — no unit parsing
            ],
            capture_output=True, text=True, timeout=_LSBLK_TIMEOUT_S,
        )
    except (subprocess.TimeoutExpired, FileNotFoundError) as e:
        logger.warning("physical_drives: lsblk failed: %s", e)
        return []
    try:
        payload = json.loads(result.stdout or "{}")
    except json.JSONDecodeError as e:
        logger.warning("physical_drives: lsblk JSON parse failed: %s", e)
        return []
    out: List[Dict[str, str]] = []
    for d in payload.get("blockdevices", []):
        if d.get("type") != "disk":
            continue
        # Removable disks (USB sticks, SD readers) are out — same rule
        # as system.py. The Synology *enclosure* drives are not flagged
        # `rm` by the kernel; they show up here.
        if d.get("rm"):
            continue
        out.append({
            "name": d.get("name") or "",
            "size_bytes": int(d.get("size") or 0),
            "model": (d.get("model") or "").strip() or "Unknown",
            "vendor": (d.get("vendor") or "").strip(),
            "tran": (d.get("tran") or "").lower(),  # usb/sata/nvme/…
            # lsblk -J emits ROTA as a JSON bool (true/false), NOT the
            # string "1"/"0" that the column-formatted output uses.
            # Coerce defensively in case a future lsblk changes the shape.
            "rota": bool(d.get("rota")) if isinstance(d.get("rota"), bool) else str(d.get("rota")) == "1",
        })
    out.sort(key=lambda x: x["name"])
    return out


def _classify(name: str, rota: bool) -> str:
    if name.startswith("nvme"):
        return "nvme"
    return "hdd" if rota else "ssd"


def _smartctl_run(device: str, dtype: str) -> Tuple[Optional[Dict[str, Any]], Optional[str]]:
    """Run smartctl once with a specific `-d` type. Returns (json_data, err).

    smartctl's exit status is a bitmask: bits 0–1 mean a real command
    failure, bits 2+ mean SMART asserted some condition (still valuable
    data). We accept anything where bits 0–1 are clear.
    """
    cmd = [_SMARTCTL, "--json=c", "-a", "-d", dtype, device]

    def _do() -> subprocess.CompletedProcess:
        return subprocess.run(
            cmd, capture_output=True, text=True,
            # The outer ThreadPool already enforces a wall-clock bound,
            # but pass timeout here too so a hung subprocess gets killed.
            timeout=_SMARTCTL_TIMEOUT_S,
        )

    try:
        fut = _SMARTCTL_POOL.submit(_do)
        proc = fut.result(timeout=_SMARTCTL_TIMEOUT_S + 0.5)
    except concurrent.futures.TimeoutError:
        return None, f"timeout after {_SMARTCTL_TIMEOUT_S}s (-d {dtype})"
    except subprocess.TimeoutExpired:
        return None, f"subprocess timeout (-d {dtype})"
    except Exception as e:  # noqa: BLE001
        return None, f"{type(e).__name__}: {e}"

    # Bit 0 = command line did not parse; bit 1 = device open / ATA cmd
    # failed. Either of those = no usable data.
    if proc.returncode & 0x03:
        # Even on a "real" error smartctl still emits JSON describing
        # the failure mode, so parse it for the messages array.
        try:
            data = json.loads(proc.stdout)
            msgs = data.get("smartctl", {}).get("messages") or []
            text = "; ".join(m.get("string", "") for m in msgs).strip()
        except (json.JSONDecodeError, AttributeError):
            text = (proc.stderr or "").strip().splitlines()
            text = text[0] if text else ""
        return None, text or f"smartctl rc={proc.returncode} (-d {dtype})"

    try:
        return json.loads(proc.stdout), None
    except json.JSONDecodeError as e:
        return None, f"JSON parse: {e}"


def _read_smart(name: str, drive_class: str, tran: str) -> Tuple[Optional[Dict[str, Any]], Optional[str]]:
    """Pick a `-d` type sequence and return the first run that yields data."""
    device = f"/dev/{name}"
    if drive_class == "nvme":
        types_to_try = ["nvme"]
    elif tran == "usb":
        # Most USB-SATA bridges accept `-d sat`; some Synology/JMicron
        # enclosures want `usbjmicron`. Auto rarely works for these.
        types_to_try = ["auto", "sat", "usbjmicron"]
    else:
        types_to_try = ["auto"]

    last_err = None
    for dtype in types_to_try:
        data, err = _smartctl_run(device, dtype)
        if data is not None:
            return data, None
        last_err = err
    return None, last_err


def _find_ata_attr(data: Dict[str, Any], attr_id: int) -> Optional[int]:
    """Look up a SATA SMART attribute by ID. Returns the raw value or None."""
    table = (data.get("ata_smart_attributes") or {}).get("table") or []
    for row in table:
        if row.get("id") == attr_id:
            raw = (row.get("raw") or {}).get("value")
            if isinstance(raw, int):
                return raw
            # Some entries surface only the string form.
            rs = (row.get("raw") or {}).get("string")
            try:
                return int((rs or "").split()[0])
            except (ValueError, AttributeError):
                return None
    return None


def _ssd_wear_percent(data: Dict[str, Any]) -> Optional[int]:
    """SATA SSD life-used % from whichever vendor attribute is present.

    Different SSD vendors put wear in different attribute IDs:
      169 (Intel Remaining_Life — *remaining*, not used)
      173 (Wear_Leveling_Count — many)
      177 (Crucial/SanDisk Wear_Leveling_Count — value field is %used)
      231 (SSD_Life_Left — *remaining*)

    For the *-used* attributes we return the raw; for the *-remaining*
    ones we return 100 - raw. Heuristic: prefer the `value` (normalized
    0–100) field for IDs 177/231; raw for 173.
    """
    table = (data.get("ata_smart_attributes") or {}).get("table") or []
    by_id = {row.get("id"): row for row in table}
    # Used directly
    if 173 in by_id:
        v = (by_id[173].get("raw") or {}).get("value")
        if isinstance(v, int) and 0 <= v <= 100:
            return v
    # Remaining (normalized "value" is 100→0)
    for aid in (177, 231, 169):
        if aid in by_id:
            v = by_id[aid].get("value")
            if isinstance(v, int) and 0 <= v <= 100:
                return max(0, 100 - v)
    return None


def _classify_temp(drive_class: str, temp_c: Optional[int]) -> str:
    if temp_c is None:
        return "unknown"
    thr = _TEMP_THRESHOLDS[drive_class]
    if temp_c >= thr["err"]:
        return "err"
    if temp_c >= thr["warn"]:
        return "warn"
    return "ok"


def _classify_wear(drive_class: str, used_pct: Optional[int], hdd_realloc: Optional[int],
                   hdd_pending: Optional[int]) -> str:
    """Wear/health status: ok | warn | err | unknown."""
    if drive_class == "hdd":
        # Any reallocated or pending sector is a yellow flag; growing
        # counts merit red. We don't track history here, so use a tiered
        # absolute threshold.
        realloc = hdd_realloc or 0
        pending = hdd_pending or 0
        if realloc >= 50 or pending >= 5:
            return "err"
        if realloc > 0 or pending > 0:
            return "warn"
        if hdd_realloc is None and hdd_pending is None:
            return "unknown"
        return "ok"
    # SSD / NVMe — % life used
    if used_pct is None:
        return "unknown"
    if used_pct >= 95:
        return "err"
    if used_pct >= 80:
        return "warn"
    return "ok"


def _build_row(disk: Dict[str, Any]) -> Dict[str, Any]:
    name = disk["name"]
    drive_class = _classify(name, disk["rota"])
    thresholds = _TEMP_THRESHOLDS[drive_class]

    row: Dict[str, Any] = {
        "device": f"/dev/{name}",
        "model": disk["model"],
        "vendor": disk["vendor"],
        "size_bytes": disk["size_bytes"],
        "drive_class": drive_class,             # hdd | ssd | nvme
        "transport": disk["tran"] or None,      # usb | sata | nvme | …
        "temp_c": None,
        "temp_status": "unknown",               # ok | warn | err | unknown
        "temp_warn_c": thresholds["warn"],
        "temp_err_c": thresholds["err"],
        "power_on_hours": None,
        "smart_passed": None,                    # True | False | None
        "smart_available": False,
        "smart_error": None,
        # HDD wear
        "reallocated_sectors": None,
        "pending_sectors": None,
        "uncorrectable_sectors": None,
        # SSD/NVMe wear
        "life_used_percent": None,
        "available_spare_percent": None,
        "wear_status": "unknown",                # ok | warn | err | unknown
    }

    data, err = _read_smart(name, drive_class, disk["tran"])
    if data is None:
        row["smart_error"] = err
        return row

    row["smart_available"] = True

    # Common fields. The exact key set differs between SATA and NVMe
    # JSON shapes but smartmontools normalises a lot of it.
    smart_status = data.get("smart_status") or {}
    if "passed" in smart_status:
        row["smart_passed"] = bool(smart_status["passed"])

    temp = data.get("temperature") or {}
    if isinstance(temp.get("current"), int):
        row["temp_c"] = temp["current"]

    pot = data.get("power_on_time") or {}
    if isinstance(pot.get("hours"), int):
        row["power_on_hours"] = pot["hours"]

    cap = data.get("user_capacity") or data.get("nvme_total_capacity") or {}
    if isinstance(cap, dict) and isinstance(cap.get("bytes"), int) and cap["bytes"] > 0:
        # Prefer the smartctl-reported capacity over lsblk's (they agree
        # in practice, but smartctl knows the *device* capacity even when
        # the kernel has only seen a partial probe).
        row["size_bytes"] = cap["bytes"]

    if drive_class == "nvme":
        nvme_log = data.get("nvme_smart_health_information_log") or {}
        used = nvme_log.get("percentage_used")
        if isinstance(used, int):
            row["life_used_percent"] = used
        spare = nvme_log.get("available_spare")
        if isinstance(spare, int):
            row["available_spare_percent"] = spare
    elif drive_class == "ssd":
        row["life_used_percent"] = _ssd_wear_percent(data)
    else:  # hdd
        row["reallocated_sectors"] = _find_ata_attr(data, 5)
        row["pending_sectors"] = _find_ata_attr(data, 197)
        row["uncorrectable_sectors"] = _find_ata_attr(data, 198)

    row["temp_status"] = _classify_temp(drive_class, row["temp_c"])
    row["wear_status"] = _classify_wear(
        drive_class,
        row["life_used_percent"],
        row["reallocated_sectors"],
        row["pending_sectors"],
    )
    return row


class PhysicalDrivesResolver:

    @staticmethod
    def get_all() -> List[Dict[str, Any]]:
        """Return the cached or freshly-computed list of physical drives."""
        global _cache
        now = time.monotonic()
        if _cache is not None and (now - _cache[0]) < _CACHE_TTL_S:
            return _cache[1]

        disks = _lsblk_disks()
        rows = [_build_row(d) for d in disks]
        _cache = (now, rows)
        return rows

    @staticmethod
    def invalidate_cache() -> None:
        """For tests / future refresh endpoints."""
        global _cache
        _cache = None
