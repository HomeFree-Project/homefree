"""
Firmware resolver — backs the Hardware page's Firmware section.

Responsibilities
----------------
* point-in-time snapshot of installed firmware (versions, vendors,
  pending updates, pending-reboot state) for the Hardware overview,
* metadata refresh (`fwupdmgr refresh --force`),
* triggering an update via the homefree-fwupd-update.service transient
  systemd unit (the actual job lives in services/fwupd_job.py).

fwupd is enabled globally in profiles/common.nix. admin-api runs as
root so fwupdmgr subprocesses inherit the privilege directly — no
pkexec wrapping needed.
"""

import json
import logging
import shutil
import subprocess
import time
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

from services.fwupd_job import FwupdJob

logger = logging.getLogger(__name__)


def _fwupdmgr_bin() -> str:
    """Absolute path to fwupdmgr. The admin-api unit ships a restricted
    PATH that doesn't include the system profile bin dir where
    services.fwupd installs the binary, so shutil.which() returns None.
    Mirrors the _resolve_bin pattern in physical_drives.py."""
    found = shutil.which("fwupdmgr")
    if found:
        return found
    for c in ("/run/current-system/sw/bin/fwupdmgr",
              "/usr/bin/fwupdmgr", "/usr/local/bin/fwupdmgr"):
        if Path(c).exists():
            return c
    return "fwupdmgr"


_FWUPDMGR = _fwupdmgr_bin()

# fwupdmgr's get-devices / get-updates calls take ~1-3s in practice;
# the overview endpoint is hit every 5s by the page. 60s TTL is the
# same compromise PhysicalDrivesResolver makes.
_CACHE_TTL_S = 60.0
_GET_DEVICES_TIMEOUT_S = 8.0
_GET_UPDATES_TIMEOUT_S = 8.0
_GET_HISTORY_TIMEOUT_S = 5.0
_REFRESH_TIMEOUT_S = 30.0

_cache: Optional[Tuple[float, Dict[str, Any]]] = None


def _run_fwupd(args: List[str], timeout: float) -> Tuple[int, str, str]:
    """Run fwupdmgr with a hard timeout. Returns (rc, stdout, stderr).
    Never raises — a wedged fwupd daemon is reported as rc=124 with an
    empty stdout."""
    try:
        proc = subprocess.run(
            [_FWUPDMGR, *args],
            capture_output=True, text=True, timeout=timeout,
        )
        return proc.returncode, proc.stdout or "", proc.stderr or ""
    except subprocess.TimeoutExpired:
        return 124, "", f"timeout after {timeout}s"
    except FileNotFoundError:
        return 127, "", "fwupdmgr not found"
    except Exception as e:  # noqa: BLE001
        return 1, "", f"{type(e).__name__}: {e}"


def _parse_devices_json(stdout: str) -> List[Dict[str, Any]]:
    """Extract the Devices array from `fwupdmgr get-devices --json`.
    Returns [] on any parse failure (an empty / error response from
    fwupd serialises as `{"Error":{...}}` which we treat as no devices).
    """
    try:
        data = json.loads(stdout or "{}")
    except json.JSONDecodeError:
        return []
    if not isinstance(data, dict):
        return []
    devices = data.get("Devices")
    return devices if isinstance(devices, list) else []


def _has_pending_activation(history_stdout: str) -> bool:
    """Inspect `fwupdmgr get-history --json` for releases that have been
    installed but not yet activated. UpdateState == 'pending' (libfwupd
    enum 4) is the canonical 'reboot to finish installing' signal.

    fwupd emits `{"Error":{"Message":"No history"}}` on a clean system;
    we treat that as 'nothing pending'.
    """
    try:
        data = json.loads(history_stdout or "{}")
    except json.JSONDecodeError:
        return False
    if not isinstance(data, dict):
        return False
    devices = data.get("Devices") or []
    if not isinstance(devices, list):
        return False
    for d in devices:
        # History entries embed releases; an entry with UpdateState
        # 'pending' or 'needs-reboot' has been applied but is awaiting
        # the reboot that activates it.
        state = (d.get("UpdateState") or "").lower()
        if state in ("pending", "needs-reboot"):
            return True
        # Some plugins report it via the embedded Release.
        for r in (d.get("Releases") or []):
            if (r.get("Flags") or []) and "blocked-version" in r.get("Flags", []):
                continue
            if (r.get("UpdateState") or "").lower() in ("pending", "needs-reboot"):
                return True
    return False


def _shape_device(dev: Dict[str, Any]) -> Optional[Dict[str, Any]]:
    """Project a fwupd device dict into the small, stable shape the
    frontend uses. Skips entries that aren't meaningful firmware:
    no name, no version, or device-level flag `updatable-hidden`
    (fwupd's own marker for don't-show-this-to-users devices)."""
    name = dev.get("Name")
    version = dev.get("Version")
    if not name or not version:
        return None
    flags = dev.get("Flags") or []
    if "updatable-hidden" in flags:
        return None
    return {
        "device_id": dev.get("DeviceId", ""),
        "name": name,
        "vendor": dev.get("Vendor") or "",
        "version": version,
        "plugin": dev.get("Plugin") or "",
        "summary": dev.get("Summary") or "",
        "flags": flags,
        # Filled in by _annotate_updates() if a release is available.
        "update_available": False,
        "update_version": None,
        "update_summary": None,
        "update_needs_reboot": False,
        # Per-row state used by the frontend to disable buttons; set
        # only when we know this specific device has an in-flight
        # update (the resolver doesn't know, but the frontend can
        # derive from the running-job's device list).
    }


def _annotate_updates(devices: List[Dict[str, Any]],
                      updates_stdout: str) -> None:
    """In-place annotate each device with update_available, etc."""
    try:
        data = json.loads(updates_stdout or "{}")
    except json.JSONDecodeError:
        return
    if not isinstance(data, dict):
        return
    available = data.get("Devices") or []
    if not isinstance(available, list):
        return
    by_id = {d["device_id"]: d for d in devices}
    for entry in available:
        did = entry.get("DeviceId")
        if not did or did not in by_id:
            continue
        releases = entry.get("Releases") or []
        if not releases:
            continue
        # First release in get-updates is the recommended one.
        r = releases[0]
        target = by_id[did]
        target["update_available"] = True
        target["update_version"] = r.get("Version")
        target["update_summary"] = r.get("Summary") or ""
        # Release-level flag list. fwupd uses 'is-upgrade' for normal
        # upgrades; reboot requirement is normally inherited from the
        # device's own Flags rather than the release.
        release_flags = r.get("Flags") or []
        target["update_needs_reboot"] = (
            "needs-reboot" in (entry.get("Flags") or [])
            or "needs-reboot" in release_flags
        )


class FirmwareResolver:

    @staticmethod
    def get_status() -> Dict[str, Any]:
        """Snapshot suitable for embedding in /api/hardware/overview."""
        global _cache
        now = time.monotonic()
        if _cache is not None and (now - _cache[0]) < _CACHE_TTL_S:
            return _cache[1]

        rc_d, out_d, err_d = _run_fwupd(["get-devices", "--json"], _GET_DEVICES_TIMEOUT_S)
        rc_u, out_u, err_u = _run_fwupd(["get-updates", "--json"], _GET_UPDATES_TIMEOUT_S)
        rc_h, out_h, _err_h = _run_fwupd(["get-history", "--json"], _GET_HISTORY_TIMEOUT_S)

        if rc_d != 0:
            payload = {
                "available": False,
                "error": (err_d or out_d or "fwupdmgr failed").strip(),
                "devices": [],
                "pending_reboot": False,
                "update_in_progress": FwupdJob.is_running(),
                "last_check_ts": int(time.time()),
            }
            _cache = (now, payload)
            return payload

        raw_devices = _parse_devices_json(out_d)
        devices: List[Dict[str, Any]] = []
        for d in raw_devices:
            shaped = _shape_device(d)
            if shaped is not None:
                devices.append(shaped)
        # get-updates exits non-zero on "no updates available" — that's
        # not an error to surface; we just don't annotate anything.
        if rc_u == 0:
            _annotate_updates(devices, out_u)

        # get-history exits 2 on "no history", which is the common case.
        pending_reboot = _has_pending_activation(out_h) if rc_h == 0 else False

        # Stable sort: devices with available updates first, then by name.
        devices.sort(key=lambda d: (
            0 if d["update_available"] else 1,
            (d["name"] or "").lower(),
        ))

        payload = {
            "available": True,
            "error": None,
            "devices": devices,
            "update_count": sum(1 for d in devices if d["update_available"]),
            "pending_reboot": pending_reboot,
            "update_in_progress": FwupdJob.is_running(),
            "last_check_ts": int(time.time()),
        }
        _cache = (now, payload)
        return payload

    @staticmethod
    def invalidate_cache() -> None:
        global _cache
        _cache = None

    @staticmethod
    def refresh_metadata() -> Dict[str, Any]:
        """Run `fwupdmgr refresh --force`. Exit code 2 means metadata
        was already up to date — that's success from a user POV."""
        rc, stdout, stderr = _run_fwupd(["refresh", "--force"], _REFRESH_TIMEOUT_S)
        FirmwareResolver.invalidate_cache()
        if rc == 0:
            return {"success": True, "message": "Metadata refreshed."}
        if rc == 2:
            return {"success": True, "message": "Metadata already up to date."}
        return {
            "success": False,
            "message": (stderr or stdout or f"fwupdmgr refresh failed (rc={rc})").strip(),
        }

    @staticmethod
    def update(device_ids: List[str]) -> Dict[str, Any]:
        """Spawn the transient update unit. Returns immediately; the
        frontend polls /api/firmware/update-status for progress."""
        if not device_ids:
            return {"success": False, "message": "No devices specified."}
        result = FwupdJob.start_update(device_ids)
        if result.get("success"):
            FirmwareResolver.invalidate_cache()
        return result
