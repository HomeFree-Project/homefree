"""
fwupd update job runner — runs `fwupdmgr update` inside a transient
systemd unit so a long-running firmware update is independent of
admin-api's blue/green flips and restarts.

Mirrors the rebuild-job pattern in services/nix_operations.py but
stripped down: no flake state, no per-service flip markers, no
service-state JSON. Just "start a unit, tail its log, report exit
code."

State on disk
-------------
    /var/lib/homefree-admin/fwupd-logs/<timestamp>.log
        per-invocation log file (stdout + stderr appended by systemd).
    /var/lib/homefree-admin/fwupd-update.log
        symlink-style pointer file containing the path of the active /
        most-recent log so admin-api restarts can reattach.
    /var/lib/homefree-admin/fwupd-update.offset
        byte offset already streamed to the frontend.
    /var/lib/homefree-admin/fwupd-update.devices
        space-separated device IDs the current job is updating (so the
        UI can highlight the active rows even after a page reload).

Only the last 3 logs are kept; older ones are pruned at job start.
"""

import json
import logging
import os
import shlex
import subprocess
import time
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

logger = logging.getLogger(__name__)

# The transient systemd unit's name — single in-flight job by design.
# A second start_update() while the unit is active is rejected.
UPDATE_UNIT = "homefree-fwupd-update.service"

STATE_DIR = Path("/var/lib/homefree-admin")
LOG_DIR = STATE_DIR / "fwupd-logs"
LOG_REF_FILE = STATE_DIR / "fwupd-update.log"
OFFSET_FILE = STATE_DIR / "fwupd-update.offset"
DEVICES_FILE = STATE_DIR / "fwupd-update.devices"
LATEST_STATUS = STATE_DIR / "fwupd-update.status.json"

MAX_LOGS_TO_KEEP = 3
SYSTEMD_RUN_TIMEOUT_S = 15.0


def _unit_active() -> bool:
    """True iff the fwupd-update unit is currently running."""
    try:
        proc = subprocess.run(
            ["systemctl", "is-active", "--quiet", UPDATE_UNIT],
            timeout=5,
        )
        return proc.returncode == 0
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return False


def _unit_result() -> Tuple[Optional[int], Optional[str]]:
    """Look up the exit code of the most recent run of the unit.
    Returns (exit_code, result) where `result` is systemd's
    'success'/'failed'/'timeout'/… string. Both None if no record."""
    try:
        proc = subprocess.run(
            ["systemctl", "show", UPDATE_UNIT,
             "--property=ExecMainStatus", "--property=Result"],
            capture_output=True, text=True, timeout=5,
        )
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return None, None
    if proc.returncode != 0:
        return None, None
    exit_code: Optional[int] = None
    result: Optional[str] = None
    for line in proc.stdout.splitlines():
        if "=" not in line:
            continue
        k, v = line.split("=", 1)
        if k == "ExecMainStatus":
            try:
                exit_code = int(v)
            except ValueError:
                pass
        elif k == "Result":
            result = v
    return exit_code, result


def _prune_logs() -> None:
    """Keep only the last MAX_LOGS_TO_KEEP log files."""
    try:
        LOG_DIR.mkdir(parents=True, exist_ok=True)
        logs = sorted(LOG_DIR.glob("*.log"), key=lambda p: p.stat().st_mtime)
        for old in logs[:-MAX_LOGS_TO_KEEP]:
            try:
                old.unlink()
            except OSError:
                pass
    except OSError as e:
        logger.debug("fwupd job: log prune failed: %s", e)


def _save_active_ref(log_path: Path, device_ids: List[str]) -> None:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    LOG_REF_FILE.write_text(str(log_path))
    OFFSET_FILE.write_text("0")
    DEVICES_FILE.write_text(" ".join(device_ids))
    # Clear any previous final-status file — fresh run.
    try:
        LATEST_STATUS.unlink()
    except FileNotFoundError:
        pass


def _read_active_log_path() -> Optional[Path]:
    try:
        p = LOG_REF_FILE.read_text().strip()
        return Path(p) if p else None
    except (OSError, FileNotFoundError):
        return None


def _read_offset() -> int:
    try:
        return int(OFFSET_FILE.read_text().strip())
    except (OSError, ValueError, FileNotFoundError):
        return 0


def _write_offset(n: int) -> None:
    try:
        OFFSET_FILE.write_text(str(n))
    except OSError:
        pass


def _read_devices() -> List[str]:
    try:
        return DEVICES_FILE.read_text().strip().split()
    except (OSError, FileNotFoundError):
        return []


def _persist_final_status(exit_code: int, result: str) -> None:
    try:
        LATEST_STATUS.write_text(json.dumps({
            "exit_code": exit_code,
            "result": result,
            "finished_at": int(time.time()),
        }))
    except OSError:
        pass


class FwupdJob:

    @staticmethod
    def is_running() -> bool:
        return _unit_active()

    @staticmethod
    def active_devices() -> List[str]:
        """Device IDs the current/last job is/was updating."""
        return _read_devices()

    @staticmethod
    def start_update(device_ids: List[str]) -> Dict[str, Any]:
        """Spawn the transient unit. Refuses if one is already active."""
        if _unit_active():
            return {"success": False, "message": "Already updating."}

        # Sanity-check device IDs — they're hex-ish strings from fwupd;
        # rejecting anything with shell metacharacters keeps the wrapper
        # command safe even though we shlex.quote() below.
        safe_ids: List[str] = []
        for did in device_ids:
            did = did.strip()
            if not did or not all(c.isalnum() or c in "-_" for c in did):
                return {"success": False, "message": f"Invalid device id: {did!r}"}
            safe_ids.append(did)

        _prune_logs()
        LOG_DIR.mkdir(parents=True, exist_ok=True)
        timestamp = time.strftime("%Y%m%d-%H%M%S")
        log_path = LOG_DIR / f"{timestamp}.log"

        # Build the inline shell wrapper. fwupdmgr's --assume-yes skips
        # the interactive 'continue?' prompt; --no-reboot-check skips
        # the post-install 'reboot now?' question (we surface that in
        # the UI via the pending-reboot signal in get_status instead).
        # Sequential per device — fwupdmgr won't run multiple updates
        # concurrently and ordering matters when one applies offline.
        # systemd-run units inherit a clean PATH that doesn't include
        # /run/current-system/sw/bin where NixOS installs fwupdmgr from
        # services.fwupd. Prepend it so the wrapper can find the binary.
        update_lines = [
            'export PATH="/run/current-system/sw/bin:$PATH"',
        ]
        for did in safe_ids:
            quoted = shlex.quote(did)
            update_lines.append(
                f"echo '==> updating {quoted}'; "
                f"fwupdmgr update --assume-yes --no-reboot-check {quoted} || exit $?"
            )
        wrapper = "set -e; " + "; ".join(update_lines) + "; echo '==> done'"

        # Same systemd-run shape as NixOperations.rebuild_switch:
        # append stdout+stderr to a file, run in its own cgroup so
        # admin-api restarts can't kill it, generous TimeoutStopSec
        # so a SIGTERM during a flash gets a chance to clean up.
        cmd = [
            "systemd-run",
            "--unit", UPDATE_UNIT,
            "--property=KillMode=mixed",
            "--property=TimeoutStopSec=300",
            f"--property=StandardOutput=append:{log_path}",
            f"--property=StandardError=append:{log_path}",
            "/bin/sh", "-c", wrapper,
        ]
        try:
            proc = subprocess.run(
                cmd, capture_output=True, text=True,
                timeout=SYSTEMD_RUN_TIMEOUT_S,
            )
        except subprocess.TimeoutExpired:
            return {"success": False, "message": "systemd-run timed out."}
        except FileNotFoundError:
            return {"success": False, "message": "systemd-run not available."}

        if proc.returncode != 0:
            err = (proc.stderr or proc.stdout or "unknown error").strip()
            logger.error("fwupd-update systemd-run failed: %s", err)
            return {"success": False, "message": f"systemd-run failed: {err}"}

        _save_active_ref(log_path, safe_ids)
        logger.info("fwupd-update started as %s, logging to %s", UPDATE_UNIT, log_path)
        return {"success": True, "message": "Update started.", "device_ids": safe_ids}

    @staticmethod
    def get_status() -> Dict[str, Any]:
        """Return the current/last update job's state.

        Shape mirrors NixOperations.get_rebuild_status:
            { running, output, exit_code, device_ids, finished_at }
        `output` is incremental — the bytes since the last call.
        """
        active = _unit_active()
        log_path = _read_active_log_path()
        device_ids = _read_devices()

        if log_path is None:
            # Never started, or state wiped.
            return {
                "running": False,
                "output": "",
                "exit_code": None,
                "device_ids": [],
                "finished_at": None,
            }

        new_output = ""
        if log_path.exists():
            try:
                offset = _read_offset()
                with open(log_path, "r") as f:
                    f.seek(offset)
                    new_output = f.read()
                    _write_offset(f.tell())
            except OSError as e:
                logger.warning("fwupd-update: log read failed: %s", e)

        if active:
            return {
                "running": True,
                "output": new_output,
                "exit_code": None,
                "device_ids": device_ids,
                "finished_at": None,
            }

        # Unit isn't active — recover the final exit code from systemd
        # if available, then memoise it in LATEST_STATUS so subsequent
        # polls (after systemd forgets the unit) still see the result.
        exit_code: Optional[int] = None
        finished_at: Optional[int] = None
        if LATEST_STATUS.exists():
            try:
                saved = json.loads(LATEST_STATUS.read_text())
                exit_code = saved.get("exit_code")
                finished_at = saved.get("finished_at")
            except (OSError, json.JSONDecodeError):
                pass
        if exit_code is None:
            ec, result = _unit_result()
            if ec is not None:
                exit_code = ec
                finished_at = int(time.time())
                _persist_final_status(ec, result or "")

        return {
            "running": False,
            "output": new_output,
            "exit_code": exit_code,
            "device_ids": device_ids,
            "finished_at": finished_at,
        }
