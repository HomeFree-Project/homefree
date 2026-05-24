"""
Storage reclaim — tear down an in-use storage structure and wipe its disks back
to eligible, so they can be used in a new volume.

This is the destructive counterpart to drive *eligibility*: `resolvers/storage.py`
hard-blocks any disk that belongs to an mdadm array, an LVM PV, or another dm
consumer, and tags such disks with a `reclaim` group descriptor. This service
executes that teardown for a complete group:

    deactivate LVM VGs  →  stop md arrays  →  per disk: zero md superblocks,
    wipefs, sgdisk --zap-all  →  udevadm settle

It is fully generic (mdadm/LVM facts only — nothing vendor- or box-specific) and
self-protecting: the group is re-derived from the LIVE box at job start, every
target disk must still be `reclaimable` (which already excludes OS / mounted-
btrfs / mounted / swap disks), and the job refuses if any filesystem on a target
disk is still mounted. Writes no config — reclaim only frees disks; the user then
creates a volume through the normal wizard.

The admin-web backend runs as root, so the commands run directly (no polkit).
Mutually exclusive with pool creation (one storage operation at a time).
"""

import logging
import subprocess
import threading
from pathlib import Path
from typing import Any, Dict, List, Optional

from resolvers.storage import (
    StorageResolver,
    _resolve_bin,
    _underlying_disks,
)

logger = logging.getLogger(__name__)

_MDADM = _resolve_bin("mdadm")
_WIPEFS = _resolve_bin("wipefs")
_SGDISK = _resolve_bin("sgdisk")
_VGCHANGE = _resolve_bin("vgchange")
_UDEVADM = _resolve_bin("udevadm")
_CRYPTSETUP = _resolve_bin("cryptsetup")

_CMD_TIMEOUT_S = 180


class StorageReclaimBusy(Exception):
    """Raised when a reclaim cannot start because the system is rebuilding."""


class StorageReclaimService:
    """Single-flight background reclaim job (mirrors StoragePoolService)."""

    _status: Dict[str, Any] = {
        "step": "idle", "progress": 0.0, "message": "",
        "completed": False, "error": None,
    }
    _thread: Optional[threading.Thread] = None
    _running = False

    # ---------------------------------------------------------- status

    @staticmethod
    def get_status() -> Dict[str, Any]:
        return StorageReclaimService._status.copy()

    @staticmethod
    def _update(step: str, progress: float, message: str) -> None:
        StorageReclaimService._status.update(
            {"step": step, "progress": progress, "message": message})
        logger.info("storage-reclaim [%.0f%%] %s: %s", progress, step, message)

    @staticmethod
    def _error(msg: str) -> None:
        StorageReclaimService._status["error"] = msg
        StorageReclaimService._status["completed"] = False
        StorageReclaimService._running = False
        logger.error("storage-reclaim error: %s", msg)

    @staticmethod
    def _done(message: str) -> None:
        StorageReclaimService._status.update(
            {"completed": True, "progress": 100.0, "message": message})
        StorageReclaimService._running = False

    # -------------------------------------------------- shape validation

    @staticmethod
    def validate_request(members: List[str]) -> List[str]:
        """The requested by-ids must form exactly ONE complete reclaim group:
        all present, all reclaimable, all the same group, and the full member
        set (no partial-array wipe). Re-derived again inside the job."""
        members = members or []
        if not members:
            return ["No drives selected to reclaim."]
        drives = {d.get("by_id"): d
                  for d in StorageResolver.list_drives() if d.get("by_id")}
        recs: List[Dict[str, Any]] = []
        errs: List[str] = []
        for m in members:
            d = drives.get(m)
            if d is None:
                errs.append(f"Drive {m} is no longer present.")
            elif not d.get("reclaimable") or not d.get("reclaim"):
                errs.append(f"Drive {m} cannot be reclaimed "
                            f"({d.get('ineligible_reason') or 'in use'}).")
            else:
                recs.append(d["reclaim"])
        if errs:
            return errs
        if len({r["id"] for r in recs}) != 1:
            return ["Selected drives belong to different storage groups — "
                    "reclaim one group at a time."]
        want = set(recs[0].get("member_ids") or [])
        missing = want - set(members)
        if missing:
            return ["Reclaiming this group requires all of its drives. "
                    "Also select: " + ", ".join(sorted(missing)) + "."]
        return []

    # ------------------------------------------------------------- start

    @staticmethod
    def start(members: List[str]) -> bool:
        """Spawn the reclaim job. False if a storage op is already running;
        raises StorageReclaimBusy if a system rebuild is in progress."""
        if StorageReclaimService._running:
            return False
        # Mutually exclusive with pool creation.
        try:
            from services.storage_pool import StoragePoolService
            if StoragePoolService._running:
                return False
        except Exception:  # noqa: BLE001
            pass
        # Don't wipe disks while a rebuild is mounting/deploying config.
        try:
            from services.nix_operations import NixOperations
            if NixOperations.get_rebuild_status().get("running"):
                raise StorageReclaimBusy("A system rebuild is in progress.")
        except StorageReclaimBusy:
            raise
        except Exception:  # noqa: BLE001
            pass

        StorageReclaimService._running = True
        StorageReclaimService._status = {
            "step": "starting", "progress": 0.0,
            "message": "Preparing to reclaim drives",
            "completed": False, "error": None,
        }
        StorageReclaimService._thread = threading.Thread(
            target=StorageReclaimService._run, args=(members,), daemon=True)
        StorageReclaimService._thread.start()
        return True

    @staticmethod
    def _run(members: List[str]) -> None:
        try:
            # 1. Re-derive the group from the LIVE box — never trust the client.
            StorageReclaimService._update("validate", 5.0, "Re-checking drives")
            errs = StorageReclaimService.validate_request(members)
            if errs:
                return StorageReclaimService._error("; ".join(errs))
            drives = {d.get("by_id"): d
                      for d in StorageResolver.list_drives() if d.get("by_id")}
            group = drives[members[0]]["reclaim"]
            knames: List[str] = group["member_knames"]
            arrays: List[str] = group["arrays"]
            vgs: List[str] = group["vgs"]
            target_disks = set(knames)

            # 2. Refuse if any filesystem backed by a target disk is mounted.
            if StorageReclaimService._mounted_on(target_disks):
                return StorageReclaimService._error(
                    "A filesystem on these drives is still mounted — unmount it "
                    "first, then retry.")

            # 3. Close any LUKS mappers sitting on the target disks or arrays
            #    BEFORE the mdadm/LVM teardown — an open mapper holds its
            #    backing device, which makes `mdadm --stop` and `vgchange -an`
            #    fail with "device in use". Covers both encrypted layouts:
            #    per-disk LUKS (mapper sits on a member disk) and LUKS-on-md
            #    (mapper sits on the assembled array).
            crypt_devs = sorted(set(knames) | set(arrays))
            open_mappers = StorageReclaimService._crypt_mappers_on(crypt_devs)
            for mapper in open_mappers:
                StorageReclaimService._update(
                    "luks-close", 15.0, f"Closing LUKS mapper {mapper}")
                rc, out = StorageReclaimService._cmd(
                    [_CRYPTSETUP, "close", mapper])
                if rc != 0:
                    return StorageReclaimService._error(
                        f"Could not close LUKS mapper {mapper}: {out}")

            # 4. Deactivate LVM volume groups layered on top.
            for vg in vgs:
                StorageReclaimService._update("lvm", 25.0,
                                              f"Deactivating LVM group {vg}")
                rc, out = StorageReclaimService._cmd([_VGCHANGE, "-an", vg])
                if rc != 0:
                    return StorageReclaimService._error(
                        f"Could not deactivate LVM group {vg}: {out}")

            # 5. Stop the md arrays.
            for md in arrays:
                StorageReclaimService._update("md-stop", 45.0,
                                              f"Stopping array {md}")
                rc, out = StorageReclaimService._cmd([_MDADM, "--stop", md])
                if rc != 0:
                    return StorageReclaimService._error(
                        f"Could not stop array {md}: {out}")

            # 6. Wipe each disk: zero md superblocks on its partitions + itself
            #    (must precede the zap, which removes the partitions), clear
            #    signatures, then destroy the partition table.
            for dk in knames:
                disk = f"/dev/{dk}"
                StorageReclaimService._update("wipe", 70.0, f"Wiping {disk}")
                for part in StorageReclaimService._disk_partitions(dk) + [disk]:
                    StorageReclaimService._cmd(
                        [_MDADM, "--zero-superblock", "--force", part])  # no-op if none
                StorageReclaimService._cmd([_WIPEFS, "-a", disk])
                rc, out = StorageReclaimService._cmd([_SGDISK, "--zap-all", disk])
                if rc != 0:
                    return StorageReclaimService._error(
                        f"Could not clear the partition table on {disk}: {out}")

            StorageReclaimService._cmd([_UDEVADM, "settle"])
            StorageReclaimService._done(
                f"Reclaimed {len(knames)} drive(s). They are now available to "
                "create a new volume.")
        except Exception as e:  # noqa: BLE001
            logger.exception("storage-reclaim crashed")
            StorageReclaimService._error(f"Unexpected error: {e}")

    # ----------------------------------------------------------- helpers

    @staticmethod
    def _mounted_on(target_disks: set) -> bool:
        """True if any mounted /dev source ultimately sits on a target disk."""
        try:
            lines = Path("/proc/mounts").read_text().splitlines()
        except OSError:
            return False
        for line in lines:
            parts = line.split()
            if not parts or not parts[0].startswith("/dev/"):
                continue
            if _underlying_disks(parts[0]) & target_disks:
                return True
        return False

    @staticmethod
    def _disk_partitions(dk: str) -> List[str]:
        """/dev paths of the disk's partitions (children with a `partition`
        attribute under /sys/block/<dk>)."""
        out: List[str] = []
        try:
            for child in Path(f"/sys/block/{dk}").iterdir():
                if child.name.startswith(dk) and (child / "partition").exists():
                    out.append(f"/dev/{child.name}")
        except OSError:
            pass
        return out

    @staticmethod
    def _crypt_mappers_on(devs: List[str]) -> List[str]:
        """Open LUKS mapper names whose backing device is one of `devs`
        (kernel names like 'sdb' or 'md127'). Walks `/sys/block/<dev>/holders`
        and filters to holders whose `dm/uuid` starts with `CRYPT-`. Returns
        de-duplicated names suitable for `cryptsetup close`. Pure /sys read —
        no subprocess (safe even when cryptsetup is missing)."""
        out: List[str] = []
        for d in devs:
            holders = Path(f"/sys/block/{d}/holders")
            if not holders.is_dir():
                continue
            try:
                children = list(holders.iterdir())
            except OSError:
                continue
            for h in children:
                try:
                    uuid = (h / "dm" / "uuid").read_text().strip()
                except OSError:
                    continue
                if not uuid.startswith("CRYPT-"):
                    continue
                try:
                    name = (h / "dm" / "name").read_text().strip()
                except OSError:
                    continue
                if name and name not in out:
                    out.append(name)
        return out

    @staticmethod
    def _cmd(cmd: List[str]) -> tuple:
        try:
            p = subprocess.run(cmd, capture_output=True, text=True,
                               timeout=_CMD_TIMEOUT_S)
            return p.returncode, (p.stderr or p.stdout or "").strip()
        except subprocess.TimeoutExpired:
            return 1, f"timed out after {_CMD_TIMEOUT_S}s"
        except (FileNotFoundError, OSError) as e:
            return 1, str(e)
