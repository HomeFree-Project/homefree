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
import socket
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
_MDADM = _resolve_bin("mdadm")
_UDEVADM = _resolve_bin("udevadm")

# btrfs (-d data, -m metadata) profile args. Metadata stays redundant even for
# a stripe (raid0 data + raid1 metadata) — cheap, and it protects the trees.
# "single" is restricted to exactly one drive, so dup metadata is valid.
# Parity profiles (raid5/raid6) run btrfs SINGLE on the assembled md device —
# md provides the redundancy; btrfs keeps dup metadata so localized corruption
# md hands back is still caught and repaired from the second metadata copy.
_PROFILE_ARGS = {
    "single": ("single", "dup"),
    "raid0":  ("raid0", "raid1"),
    "raid1":  ("raid1", "raid1"),
    "raid10": ("raid10", "raid10"),
    "raid5":  ("single", "dup"),
    "raid6":  ("single", "dup"),
}

# Profiles built as btrfs-on-mdadm (Linux md owns parity, btrfs sits on top).
_MD_PROFILES = ("raid5", "raid6")

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
        # Mutually exclusive with a reclaim (don't format while disks are being
        # torn down/wiped).
        try:
            from services.storage_reclaim import StorageReclaimService
            if StorageReclaimService._running:
                return False
        except Exception:  # noqa: BLE001
            pass

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

            # 3. For a PARITY volume, assemble the md array first; btrfs then
            #    sits on the single resulting /dev/md device. md --create returns
            #    immediately and the array is usable straight away — the parity
            #    resync runs in the background (surfaced via /proc/mdstat).
            md_uuid = ""
            md_name = ""
            mkfs_targets = dev_paths
            if profile in _MD_PROFILES:
                md_name = name
                level = "5" if profile == "raid5" else "6"
                member_knames = [os.path.basename(os.path.realpath(p)) for p in dev_paths]
                StoragePoolService._update(
                    "md-create", 40.0,
                    f"Building RAID{level} array across {len(dev_paths)} drives")
                # wipefs already cleared signatures; also zero any residual md
                # superblock so `mdadm --create` never stalls on a tty prompt.
                for p in dev_paths:
                    StoragePoolService._cmd([_MDADM, "--zero-superblock", "--force", p])
                rc, out = StoragePoolService._cmd([
                    _MDADM, "--create", f"/dev/md/{name}",
                    "--level", level,
                    "--raid-devices", str(len(dev_paths)),
                    "--metadata", "1.2",
                    "--bitmap", "internal",
                    "--homehost", socket.gethostname(),
                    "--name", name,
                    "--run",
                ] + dev_paths)
                if rc != 0:
                    return StoragePoolService._error(f"mdadm --create failed: {out}")
                # The /dev/md/<name> by-name symlink is created by udev and is
                # NOT reliably present right after --create (it depends on the
                # mdadm udev naming rules / homehost — e.g. /dev/md/ may not even
                # exist yet). Resolve the actual kernel device (/dev/mdN) from the
                # assembled members and mkfs on THAT; the mount keys on the btrfs
                # UUID, so the array's name never matters downstream.
                StoragePoolService._cmd([_UDEVADM, "settle"])
                md_dev = StoragePoolService._await_md_device(member_knames)
                if not md_dev:
                    return StoragePoolService._error(
                        "RAID array was created but its device node did not "
                        "appear; check `cat /proc/mdstat`.")
                md_name = os.path.basename(md_dev)   # kernel name, e.g. md127
                md_uuid = StoragePoolService._md_uuid(md_dev)
                mkfs_targets = [md_dev]

            # 4. Create the btrfs filesystem (the one destructive, irreversible
            #    step). No record is written until this succeeds.
            data, meta = _PROFILE_ARGS[profile]
            StoragePoolService._update("format", 55.0, "Creating btrfs filesystem")
            rc, out = StoragePoolService._cmd(
                [_MKFS_BTRFS, "-f", "-L", name, "-d", data, "-m", meta] + mkfs_targets)
            if rc != 0:
                return StoragePoolService._error(f"mkfs.btrfs failed: {out}")

            # 5. Capture the filesystem UUID — the mount keys on this.
            StoragePoolService._update("identify", 70.0, "Reading filesystem UUID")
            uuid = StoragePoolService._fs_uuid(mkfs_targets[0])
            if not uuid:
                return StoragePoolService._error("Could not read the new filesystem UUID.")

            # 5b. Ensure /dev/disk/by-uuid/<uuid> exists (the mount keys on it).
            StoragePoolService._update("settle", 75.0, "Registering the filesystem")
            if not StoragePoolService._ensure_by_uuid(uuid, mkfs_targets):
                logger.warning(
                    "storage-pool: by-uuid for %s did not appear after create; "
                    "the volume is built but its mount may need a udev trigger.", uuid)

            # 6. Record the pool. modules/storage-pools.nix mounts it on Apply.
            StoragePoolService._update("record", 85.0, "Recording pool configuration")
            record = {
                "enabled": True,
                "name": name,
                "mountpoint": mountpoint,
                "profile": profile,
                "members": members,
                "fs-uuid": uuid,
                "md-uuid": md_uuid,
                "md-device": md_name,
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
        afterward to unmount.

        Critical: spread the existing `storage` object when writing so
        sibling sub-keys (notably `shares` for NFS exports) survive.
        ConfigWriter does a whole-`storage` REPLACE — sending only
        `{pools: …}` would silently wipe `shares`."""
        try:
            cfg = ConfigReader.read_config()
        except Exception:  # noqa: BLE001
            return False
        storage = cfg.get("storage") or {}
        pools = [p for p in (storage.get("pools") or []) if p.get("name") != name]
        return ConfigWriter.write_config({"storage": {**storage, "pools": pools}})

    # ----------------------------------------------------------- restore

    @staticmethod
    def restore_pool(record: Dict[str, Any]) -> List[str]:
        """Re-add a pool record to storage.pools verbatim. Used by the
        frontend's Undo Remove flow — the record passed in is the one
        from applied-config.json, so writing it back byte-for-byte
        means the post-undo state has no pending diff vs. applied
        (which is what makes the volume card stop reading 'undeployed'
        after the undo). Less rigorous than create/import (no mkfs, no
        live-fs validation) because the caller already has a known-good
        applied record.

        Preserves any sibling subkeys under `storage` (e.g. `shares`)
        by spreading the existing object — ConfigWriter does a
        whole-storage replace, so we must include them explicitly."""
        name = (record.get("name") or "").strip()
        if not _NAME_RE.match(name):
            return ["Volume name must be 1–32 characters: letters, digits, "
                    "'-' or '_', starting with a letter or digit."]
        try:
            cfg = ConfigReader.read_config()
        except Exception:  # noqa: BLE001
            cfg = {}
        storage = cfg.get("storage") or {}
        pools = list(storage.get("pools") or [])
        if any(p.get("name") == name for p in pools):
            return [f"A volume named '{name}' already exists."]
        pools.append(record)
        new_storage = {**storage, "pools": pools}
        if not ConfigWriter.write_config({"storage": new_storage}):
            return ["Failed to write homefree-config.json."]
        return []

    # ----------------------------------------------------------- import

    @staticmethod
    def import_pool(fs_uuid: str, name: str, mountpoint: str) -> List[str]:
        """Re-attach an existing on-disk btrfs volume — the inverse of Remove.
        NON-destructive: validates against the live importable set and writes the
        pool record (no format). Returns a list of errors ([] on success); the
        volume then mounts via the normal Apply."""
        from resolvers.storage import StorageResolver
        name = (name or "").strip()
        mountpoint = (mountpoint or "").strip()
        errs: List[str] = []
        if not _NAME_RE.match(name):
            errs.append("Volume name must be 1–32 characters: letters, digits, "
                        "'-' or '_', starting with a letter or digit.")
        if not mountpoint.startswith("/"):
            errs.append("Mount point must be an absolute path (e.g. /mnt/data).")

        cand = next((v for v in StorageResolver.list_importable()
                     if v.get("fs_uuid") == fs_uuid), None)
        if cand is None:
            errs.append("That volume is no longer available to import.")

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
        if errs:
            return errs
        assert cand is not None  # guaranteed: a missing cand would be in errs

        # An already-assembled md array's btrfs may have no by-uuid symlink yet
        # (udev never probed it) — ensure it exists so the volume mounts on Apply
        # instead of reading "Drive(s) not present".
        StoragePoolService._ensure_by_uuid(fs_uuid, [cand.get("device")], timeout_s=20)

        record = {
            "enabled": True,
            "name": name,
            "mountpoint": mountpoint,
            "profile": cand["profile"],
            "members": cand["members"],
            "fs-uuid": fs_uuid,
            "md-uuid": "",
            "md-device": cand.get("md_device") or "",
            "encrypted": False,
            "luks-mappers": [],
            "mount-options": ["compress=zstd", "noatime"],
            "device-timeout": "15s",
            "created-at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "imported-at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        }
        if not StoragePoolService._append_pool(record):
            return ["Imported the volume but failed to write homefree-config.json."]
        return []

    # ----------------------------------------------------------- promote

    @staticmethod
    def promote_volume(fs_uuid: str, name: str, mountpoint: str) -> List[str]:
        """Add an existing unmanaged btrfs filesystem to
        `homefree.storage.pools`. Non-destructive — no format, no
        device-identity change, same `fs-uuid`. If the same filesystem is
        currently mounted via a `homefree.mounts` row, drop that row in the
        same atomic config write so the volume isn't double-mounted on Apply.

        Looking up the candidate by `fs_uuid` (vs. mount-point in round 1) lets
        the same call promote a mounted *or* unmounted filesystem with no extra
        branching at the call site."""
        from resolvers.storage import StorageResolver, _resolve_mount_spec, _fs_uuid_of
        fs_uuid = (fs_uuid or "").strip()
        name = (name or "").strip()
        mountpoint = (mountpoint or "").strip()
        errs: List[str] = []
        if not _NAME_RE.match(name):
            errs.append("Volume name must be 1–32 characters: letters, digits, "
                        "'-' or '_', starting with a letter or digit.")
        if not mountpoint.startswith("/"):
            errs.append("Mount point must be an absolute path.")

        cand = next((v for v in StorageResolver.list_promotable_btrfs()
                     if v.get("fs_uuid") == fs_uuid), None)
        if cand is None:
            errs.append("That filesystem is no longer promotable.")

        try:
            cfg = ConfigReader.read_config()
        except Exception:  # noqa: BLE001
            cfg = {}
        existing_pools = ((cfg.get("storage") or {}).get("pools")) or []
        if any(p.get("name") == name for p in existing_pools):
            errs.append(f"A volume named '{name}' already exists.")
        if any(p.get("mountpoint") == mountpoint for p in existing_pools):
            errs.append(f"Mount point '{mountpoint}' is already a managed volume.")

        # Defensive parallel of the modal's read-only-when-mounted rule: if
        # the candidate is already mounted, a caller is not allowed to move
        # it to a different path during promotion (would force an unmount +
        # remount-elsewhere we don't want hiding inside an Apply). Renaming
        # the mount path is a separate, explicit flow.
        if cand is not None and cand.get("mount_point") \
                and mountpoint != cand["mount_point"]:
            errs.append("Cannot change mount point during promotion of an "
                        "already-mounted filesystem; promote first, then move.")
        if errs:
            return errs
        assert cand is not None  # guaranteed: a missing cand would be in errs

        # Make sure /dev/disk/by-uuid/<fs-uuid> exists so the new pool's
        # nofail mount on Apply doesn't silently fail (same precaution as
        # create + import).
        StoragePoolService._ensure_by_uuid(
            fs_uuid, [cand.get("device")], timeout_s=15)

        pool = {
            "enabled": True,
            "name": name,
            "mountpoint": mountpoint,
            "profile": cand["profile"],
            "members": cand["members"],
            "fs-uuid": fs_uuid,
            "md-uuid": "",
            "md-device": cand.get("md_device") or "",
            "encrypted": False,
            "luks-mappers": [],
            "mount-options": ["compress=zstd", "noatime"],
            "device-timeout": "15s",
            "imported-at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        }

        # Atomic write: pools-with-new + mounts-without-any-row-that-points-at-fs_uuid.
        # We match by fs-uuid (not mount-point) because a row can have a
        # different mount-point yet still target the same filesystem (e.g.
        # `UUID=<X>` typed in by hand) — mount-point alone would leak a stale
        # duplicate that fights the new pool on the next Apply.
        def _row_targets_fs(m: Dict[str, Any]) -> bool:
            spec = (m.get("device") or "").strip()
            if not spec:
                return False
            if spec.startswith("UUID="):
                return spec[5:] == fs_uuid
            if spec.startswith("/dev/disk/by-uuid/"):
                return spec.rsplit("/", 1)[-1] == fs_uuid
            resolved = _resolve_mount_spec(spec)
            if not resolved:
                return False
            return _fs_uuid_of(os.path.realpath(resolved)) == fs_uuid

        new_pools = list(existing_pools) + [pool]
        new_mounts = [m for m in (cfg.get("mounts") or [])
                      if not _row_targets_fs(m)]
        # Spread the existing `storage` object on write — ConfigWriter does
        # a whole-`storage` REPLACE, so passing only `{pools: …}` would
        # silently wipe sibling sub-keys (notably `shares` for NFS exports).
        existing_storage = cfg.get("storage") or {}
        ok = ConfigWriter.write_config({
            "storage": {**existing_storage, "pools": new_pools},
            "mounts": new_mounts,
        })
        if not ok:
            return ["Failed to write homefree-config.json."]
        return []

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
    def _ensure_by_uuid(fs_uuid: str, devices: List[str], timeout_s: int = 60) -> bool:
        """Make /dev/disk/by-uuid/<fs_uuid> appear — the mount keys on it. udev
        does not reliably create it after mkfs on (or assembly of) an md device,
        so re-trigger a change uevent on the backing device(s) and poll until the
        symlink exists. Used by both create and import. Returns True if present."""
        link = f"/dev/disk/by-uuid/{fs_uuid}"
        deadline = time.time() + timeout_s
        while time.time() < deadline:
            if os.path.exists(link):
                return True
            for d in devices:
                if d:
                    StoragePoolService._cmd(
                        [_UDEVADM, "trigger", "--settle", "--action=change", d])
            if os.path.exists(link):
                return True
            time.sleep(1)
        return os.path.exists(link)

    @staticmethod
    def _await_md_device(member_knames: List[str], timeout_s: int = 30) -> Optional[str]:
        """The kernel md device (/dev/mdN) assembled from exactly these member
        disks, polled from /proc/mdstat until present (udev can lag --create)."""
        want = set(member_knames)
        deadline = time.time() + timeout_s
        while time.time() < deadline:
            try:
                with open("/proc/mdstat") as f:
                    lines = f.read().splitlines()
            except OSError:
                lines = []
            for line in lines:
                if " : " not in line:
                    continue
                md = line.split(" : ", 1)[0].strip()
                if not md.startswith("md"):
                    continue
                members = {m.group(1) for m in
                           (re.match(r"^([A-Za-z0-9]+)\[\d+\]", t)
                            for t in line.split(" : ", 1)[1].split()) if m}
                if members == want and os.path.exists(f"/dev/{md}"):
                    return f"/dev/{md}"
            time.sleep(0.5)
        return None

    @staticmethod
    def _md_uuid(md_dev: str) -> str:
        """md array UUID via `mdadm --detail --export` (MD_UUID=...). Recorded
        for display / health / reclaim; assembly itself is by homehost."""
        try:
            p = subprocess.run([_MDADM, "--detail", "--export", md_dev],
                               capture_output=True, text=True, timeout=15)
            for line in (p.stdout or "").splitlines():
                if line.startswith("MD_UUID="):
                    return line.split("=", 1)[1].strip()
        except (subprocess.SubprocessError, OSError):
            pass
        return ""

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
        """Used by create_pool + import_pool. Spread the existing `storage`
        object on write — ConfigWriter does a whole-`storage` REPLACE, so
        sending only `{pools: …}` would silently wipe sibling sub-keys
        (notably `shares` for NFS exports)."""
        try:
            cfg = ConfigReader.read_config()
        except Exception:  # noqa: BLE001
            return False
        storage = cfg.get("storage") or {}
        pools = list(storage.get("pools") or [])
        pools.append(record)
        return ConfigWriter.write_config({"storage": {**storage, "pools": pools}})
