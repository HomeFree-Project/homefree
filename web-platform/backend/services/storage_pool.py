"""
Storage pool create / forget — the imperative half of the Storage feature.

Pool creation is a one-time destructive act: `wipefs` + `mkfs.btrfs` across the
selected drives, after which the pool's identity (members by-id, profile,
fs-UUID) is recorded into homefree-config.json. modules/storage-pools.nix turns
that record into a declarative `fileSystems` mount on the next Apply.

We deliberately do NOT trigger a rebuild here. Writing the record makes the
pool a normal pending change, so the user mounts it via the standard Apply flow
(which builds from disk). That keeps two promises: creating a pool never
silently deploys other pending changes, and the job never races the rebuild
lock.

Safety (AGENTS.md rule 10): the drive selection is re-validated against the
LIVE box at job start — never trust the client — and nothing touches a disk
unless every selected member is currently eligible. The pool record is written
only after `mkfs.btrfs` fully succeeds, so a failed/partial create never leaves
a mountable half-built pool. The admin-web backend runs as root, so the disk
commands run directly (no polkit).
"""

import logging
import os
import re
import subprocess
import threading
import time
from typing import Any, Dict, List, Optional

from resolvers.storage import (
    StorageResolver,
    PROFILE_MIN_MEMBERS,
    _resolve_bin,
    _proc_mount_points,
)
from services.config_reader import ConfigReader
from services.config_writer import ConfigWriter

logger = logging.getLogger(__name__)

_WIPEFS = _resolve_bin("wipefs")
_MKFS_BTRFS = _resolve_bin("mkfs.btrfs")
_BLKID = _resolve_bin("blkid")

# btrfs (-d data, -m metadata) profile args. Metadata stays redundant even for
# a stripe (raid0 data + raid1 metadata) — cheap, and it protects the trees.
# "single" is restricted to exactly one drive, so dup metadata is valid.
_PROFILE_ARGS = {
    "single": ("single", "dup"),
    "raid0":  ("raid0", "raid1"),
    "raid1":  ("raid1", "raid1"),
    "raid10": ("raid10", "raid10"),
}

# Pool name doubles as the btrfs label: conservative, shell-safe charset.
_NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_-]{0,31}$")

# mkfs across multi-TB spinners can take a while; bound it generously.
_CREATE_TIMEOUT_S = 600


class StoragePoolBusy(Exception):
    """Raised when a create cannot start because the system is rebuilding."""


class StoragePoolService:
    """Single-flight background create job (mirrors InstallationService)."""

    _status: Dict[str, Any] = {
        "step": "idle", "progress": 0.0, "message": "",
        "completed": False, "error": None,
    }
    _thread: Optional[threading.Thread] = None
    _running = False

    # ---------------------------------------------------------- status

    @staticmethod
    def get_status() -> Dict[str, Any]:
        return StoragePoolService._status.copy()

    @staticmethod
    def _update(step: str, progress: float, message: str) -> None:
        StoragePoolService._status.update(
            {"step": step, "progress": progress, "message": message})
        logger.info("storage-pool [%.0f%%] %s: %s", progress, step, message)

    @staticmethod
    def _error(msg: str) -> None:
        StoragePoolService._status["error"] = msg
        StoragePoolService._status["completed"] = False
        StoragePoolService._running = False
        logger.error("storage-pool error: %s", msg)

    @staticmethod
    def _done(message: str) -> None:
        StoragePoolService._status.update(
            {"completed": True, "progress": 100.0, "message": message})
        StoragePoolService._running = False

    # -------------------------------------------------- shape validation

    @staticmethod
    def validate_request(req: Dict[str, Any]) -> List[str]:
        """Pre-flight checks on the request shape (run before touching disks).
        Eligibility against the live box is re-checked again inside the job."""
        errs: List[str] = []
        name = (req.get("name") or "").strip()
        mountpoint = (req.get("mountpoint") or "").strip()
        profile = req.get("profile")
        members = req.get("members") or []

        if not _NAME_RE.match(name):
            errs.append(
                "Pool name must be 1–32 characters: letters, digits, '-' or "
                "'_', starting with a letter or digit.")
        if not mountpoint.startswith("/"):
            errs.append("Mount point must be an absolute path (e.g. /mnt/tank).")

        if profile not in PROFILE_MIN_MEMBERS:
            errs.append(f"Unsupported profile: {profile}")
        elif profile == "single" and len(members) != 1:
            errs.append("A single-disk volume uses exactly one drive; "
                        "choose stripe or mirror for multiple drives.")
        else:
            need = PROFILE_MIN_MEMBERS[profile]
            if len(members) < need:
                errs.append(f"{profile} needs at least {need} drives; "
                            f"{len(members)} selected.")
            if profile == "raid10" and len(members) % 2:
                errs.append("raid10 needs an even number of drives.")

        if len(set(members)) != len(members):
            errs.append("The same drive is selected more than once.")
        if req.get("encrypted"):
            errs.append("Encrypted volumes are not supported yet.")

        # Collisions with existing pools / mounts.
        try:
            cfg = ConfigReader.read_config()
        except Exception:  # noqa: BLE001
            cfg = {}
        existing = ((cfg.get("storage") or {}).get("pools")) or []
        if any(p.get("name") == name for p in existing):
            errs.append(f"A volume named '{name}' already exists.")
        used = {p.get("mountpoint") for p in existing}
        used |= {m.get("mount-point") for m in (cfg.get("mounts") or [])}
        used |= _proc_mount_points()
        if mountpoint and mountpoint in used:
            errs.append(f"Mount point '{mountpoint}' is already in use.")
        return errs

    # ------------------------------------------------------------- start

    @staticmethod
    def start(req: Dict[str, Any]) -> bool:
        """Spawn the create job. Returns False if one is already running;
        raises StoragePoolBusy if a system rebuild is in progress."""
        if StoragePoolService._running:
            return False

        # Don't format/record while a rebuild is mounting/deploying config.
        try:
            from services.nix_operations import NixOperations
            if NixOperations.get_rebuild_status().get("running"):
                raise StoragePoolBusy("A system rebuild is in progress.")
        except StoragePoolBusy:
            raise
        except Exception:  # noqa: BLE001
            pass  # status unavailable — proceed

        StoragePoolService._running = True
        StoragePoolService._status = {
            "step": "starting", "progress": 0.0,
            "message": "Preparing to create pool",
            "completed": False, "error": None,
        }
        StoragePoolService._thread = threading.Thread(
            target=StoragePoolService._run_create, args=(req,), daemon=True)
        StoragePoolService._thread.start()
        return True

    @staticmethod
    def _run_create(req: Dict[str, Any]) -> None:
        try:
            name = req["name"].strip()
            mountpoint = req["mountpoint"].strip()
            profile = req["profile"]
            members = req["members"]

            # 1. Re-validate eligibility against the LIVE box (never trust the
            #    client — the disk set may have changed since the UI fetched).
            #    `force` permits a SOFT block (inactive ESP) the owner has
            #    explicitly confirmed; a HARD block is never overridable.
            force = bool(req.get("force"))
            StoragePoolService._update("validate", 5.0, "Re-checking drive eligibility")
            drives = {d.get("by_id"): d
                      for d in StorageResolver.list_drives() if d.get("by_id")}
            member_models: List[str] = []
            for m in members:
                d = drives.get(m)
                if d is None:
                    return StoragePoolService._error(f"Drive {m} is no longer present.")
                if not d.get("eligible") and not (force and d.get("overridable")):
                    return StoragePoolService._error(
                        f"Drive {m} is not eligible: "
                        f"{d.get('ineligible_reason') or 'in use'}.")
                member_models.append(d.get("model") or "Unknown")

            dev_paths = [f"/dev/disk/by-id/{m}" for m in members]
            for p in dev_paths:
                if not os.path.exists(p):
                    return StoragePoolService._error(f"Device path missing: {p}")

            # 2. Wipe old filesystem signatures.
            StoragePoolService._update("wipe", 20.0, "Wiping old filesystem signatures")
            for p in dev_paths:
                rc, out = StoragePoolService._cmd([_WIPEFS, "-a", p])
                if rc != 0:
                    return StoragePoolService._error(f"wipefs failed on {p}: {out}")

            # 3. Create the btrfs filesystem (the one destructive, irreversible
            #    step). No record is written until this succeeds.
            data, meta = _PROFILE_ARGS[profile]
            StoragePoolService._update("format", 55.0,
                                       f"Creating btrfs {profile} filesystem")
            rc, out = StoragePoolService._cmd(
                [_MKFS_BTRFS, "-f", "-L", name, "-d", data, "-m", meta] + dev_paths)
            if rc != 0:
                return StoragePoolService._error(f"mkfs.btrfs failed: {out}")

            # 4. Capture the filesystem UUID — the mount keys on this.
            StoragePoolService._update("identify", 70.0, "Reading filesystem UUID")
            uuid = StoragePoolService._fs_uuid(dev_paths[0])
            if not uuid:
                return StoragePoolService._error("Could not read the new filesystem UUID.")

            # 5. Record the pool. modules/storage-pools.nix mounts it on Apply.
            StoragePoolService._update("record", 85.0, "Recording pool configuration")
            record = {
                "enabled": True,
                "name": name,
                "mountpoint": mountpoint,
                "profile": profile,
                "members": members,
                "fs-uuid": uuid,
                "encrypted": False,
                "luks-mappers": [],
                "mount-options": ["compress=zstd", "noatime"],
                "device-timeout": "15s",
                "created-at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                "member-models": member_models,
            }
            if not StoragePoolService._append_pool(record):
                return StoragePoolService._error(
                    "Volume formatted but failed to write homefree-config.json.")

            StoragePoolService._done(
                f"Volume '{name}' created. Apply changes to mount it at {mountpoint}.")
        except Exception as e:  # noqa: BLE001
            logger.exception("storage-pool create crashed")
            StoragePoolService._error(f"Unexpected error: {e}")

    # ----------------------------------------------------------- forget

    @staticmethod
    def forget(name: str) -> bool:
        """Remove a pool's record. NON-destructive — the btrfs and its data
        stay on the disks; only the mount config is dropped. The user Applies
        afterward to unmount."""
        try:
            cfg = ConfigReader.read_config()
        except Exception:  # noqa: BLE001
            return False
        storage = cfg.get("storage") or {}
        pools = [p for p in (storage.get("pools") or []) if p.get("name") != name]
        return ConfigWriter.write_config({"storage": {"pools": pools}})

    # ----------------------------------------------------------- helpers

    @staticmethod
    def _cmd(cmd: List[str]) -> tuple:
        try:
            p = subprocess.run(cmd, capture_output=True, text=True,
                               timeout=_CREATE_TIMEOUT_S)
            return p.returncode, (p.stderr or p.stdout or "").strip()
        except subprocess.TimeoutExpired:
            return 1, f"timed out after {_CREATE_TIMEOUT_S}s"
        except (FileNotFoundError, OSError) as e:
            return 1, str(e)

    @staticmethod
    def _fs_uuid(dev: str) -> Optional[str]:
        try:
            p = subprocess.run([_BLKID, "-o", "value", "-s", "UUID", dev],
                               capture_output=True, text=True, timeout=10)
            return (p.stdout or "").strip() or None
        except (subprocess.SubprocessError, OSError):
            return None

    @staticmethod
    def _append_pool(record: Dict[str, Any]) -> bool:
        try:
            cfg = ConfigReader.read_config()
        except Exception:  # noqa: BLE001
            return False
        storage = cfg.get("storage") or {}
        pools = list(storage.get("pools") or [])
        pools.append(record)
        return ConfigWriter.write_config({"storage": {"pools": pools}})
