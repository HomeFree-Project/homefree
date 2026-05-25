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
import tempfile
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
_CRYPTSETUP = _resolve_bin("cryptsetup")
_SYSTEMD_CRYPTENROLL = _resolve_bin("systemd-cryptenroll")
_SHRED = _resolve_bin("shred")

# LUKS recovery passphrase persisted by the installer. Same value as the
# system disk's keyslot 2; this is the SINGLE MASTER KEY for every data-pool
# LUKS container too (one master across system + data, per the plan). For
# pre-feature unencrypted-system boxes it's seeded by the admin UI's
# "set up master encryption key" flow.
_RECOVERY_PP_PATH = "/etc/nixos/secrets/recovery-passphrase.txt"

# Either node indicates a usable TPM2. When absent, encryption falls back to
# passphrase-only unlock (boot-time prompt) — still legitimate, just attended.
_TPM_DEV_PATHS = ("/dev/tpmrm0", "/dev/tpm0")

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
            # The pool create job uses the file content as the master LUKS
            # passphrase; refuse early (before any disk touch) if it's missing
            # or empty so the UI can route the user to the master-key setup
            # flow without leaving a half-built array behind.
            try:
                if not os.path.isfile(_RECOVERY_PP_PATH):
                    raise FileNotFoundError
                with open(_RECOVERY_PP_PATH, "rb") as _f:
                    if not _f.read().rstrip(b"\n"):
                        raise ValueError("empty")
            except (FileNotFoundError, PermissionError):
                errs.append(
                    "Encryption requested but the master encryption key is "
                    "not configured. Set up the master key on the Storage "
                    "page first.")
            except (ValueError, OSError):
                errs.append(
                    "Encryption requested but the master encryption key "
                    f"file at {_RECOVERY_PP_PATH} is empty or unreadable.")

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

    # ------------------------------------------------------ reformat validation
    #
    # Reformat is "use this existing mdadm array, put a NEW filesystem on it"
    # — for the case where an admin has e.g. a 4×12TB RAID6 that already
    # resynced (which takes a DAY or more) and wants to throw away whatever
    # filesystem is on top and start fresh, optionally encrypted, WITHOUT
    # re-creating the array (which would force another day of resync). The
    # member disks are NOT wiped; only /dev/md<N> is reformatted.

    @staticmethod
    def validate_reformat_request(req: Dict[str, Any]) -> List[str]:
        """Pre-flight checks for `reformat`. Validates the new pool's name +
        mountpoint + encryption shape, and that the target md array exists +
        no filesystem on it is currently mounted. Underlying member disks
        are NOT validated as `eligible` — they're already in an md array,
        so the normal eligibility check would (correctly) refuse them."""
        errs: List[str] = []
        name = (req.get("name") or "").strip()
        mountpoint = (req.get("mountpoint") or "").strip()
        md_device = (req.get("md_device") or "").strip()
        members = req.get("members") or []
        profile = req.get("profile")

        if not _NAME_RE.match(name):
            errs.append(
                "Pool name must be 1–32 characters: letters, digits, '-' or "
                "'_', starting with a letter or digit.")
        if not mountpoint.startswith("/"):
            errs.append("Mount point must be an absolute path (e.g. /mnt/tank).")
        if profile not in _MD_PROFILES:
            errs.append(
                f"Reformat only supports parity profiles (raid5/raid6); got "
                f"'{profile}'. For btrfs-native arrays the existing data is "
                "the array — there is no separate md layer to preserve.")
        if not md_device:
            errs.append("Reformat requires the target md device name (e.g. md127).")
        if not members:
            errs.append("Reformat requires the array's member by-id list.")

        # Refuse if any filesystem backed by the md device is currently mounted.
        if md_device:
            md_kname = os.path.basename(md_device)
            try:
                with open("/proc/mounts") as f:
                    for line in f:
                        parts = line.split()
                        if len(parts) < 2 or not parts[0].startswith("/dev/"):
                            continue
                        # Resolve the source through /sys/block holders so a
                        # mounted LUKS mapper on top of /dev/md<N> also counts.
                        src_kname = os.path.basename(os.path.realpath(parts[0]))
                        if src_kname == md_kname:
                            errs.append(
                                f"/dev/{md_kname} (or a filesystem on top of it) "
                                f"is currently mounted at {parts[1]}. Unmount "
                                "first, then retry.")
                            break
                        # Walk up: is parts[0] a dm device whose slave is the md?
                        slaves_dir = f"/sys/block/{src_kname}/slaves"
                        if os.path.isdir(slaves_dir):
                            if md_kname in os.listdir(slaves_dir):
                                errs.append(
                                    f"A filesystem on top of /dev/{md_kname} is "
                                    f"currently mounted at {parts[1]} (via "
                                    f"{parts[0]}). Unmount first, then retry.")
                                break
            except OSError:
                pass

        if req.get("encrypted"):
            try:
                if not os.path.isfile(_RECOVERY_PP_PATH):
                    raise FileNotFoundError
                with open(_RECOVERY_PP_PATH, "rb") as _f:
                    if not _f.read().rstrip(b"\n"):
                        raise ValueError("empty")
            except (FileNotFoundError, PermissionError):
                errs.append(
                    "Encryption requested but the master encryption key is "
                    "not configured. Set up the master key on the Storage "
                    "page first.")
            except (ValueError, OSError):
                errs.append(
                    "Encryption requested but the master encryption key "
                    f"file at {_RECOVERY_PP_PATH} is empty or unreadable.")

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
    def start_reformat(req: Dict[str, Any]) -> bool:
        """Spawn the reformat job. Same single-flight slot + rebuild guard
        as `start`; the in-flight status is reported via the same
        `/api/storage/pools/create-status` endpoint."""
        if StoragePoolService._running:
            return False
        try:
            from services.storage_reclaim import StorageReclaimService
            if StorageReclaimService._running:
                return False
        except Exception:  # noqa: BLE001
            pass
        try:
            from services.nix_operations import NixOperations
            if NixOperations.get_rebuild_status().get("running"):
                raise StoragePoolBusy("A system rebuild is in progress.")
        except StoragePoolBusy:
            raise
        except Exception:  # noqa: BLE001
            pass
        StoragePoolService._running = True
        StoragePoolService._status = {
            "step": "starting", "progress": 0.0,
            "message": "Preparing to reformat array",
            "completed": False, "error": None,
        }
        StoragePoolService._thread = threading.Thread(
            target=StoragePoolService._run_reformat, args=(req,), daemon=True)
        StoragePoolService._thread.start()
        return True

    @staticmethod
    def _run_create(req: Dict[str, Any]) -> None:
        # Track LUKS state for rollback. If anything in the create flow fails
        # after a member has been luksFormat'd / luksOpen'd, the except branch
        # closes the mappers and erases the LUKS headers so a retry isn't
        # blocked by "device is mapped" / "exists already".
        opened_mappers: List[str] = []
        formatted_devs: List[str] = []
        master_pp_file: Optional[str] = None
        encrypted = bool(req.get("encrypted"))
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
                    raise RuntimeError(f"Drive {m} is no longer present.")
                if not d.get("eligible") and not (force and d.get("overridable")):
                    raise RuntimeError(
                        f"Drive {m} is not eligible: "
                        f"{d.get('ineligible_reason') or 'in use'}.")
                member_models.append(d.get("model") or "Unknown")

            dev_paths = [f"/dev/disk/by-id/{m}" for m in members]
            for p in dev_paths:
                if not os.path.exists(p):
                    raise RuntimeError(f"Device path missing: {p}")

            # 1b. If encrypted, materialize the master passphrase into a /run
            #     tempfile BEFORE any disk is touched, so a missing/empty key
            #     surface as an error with the pool fully un-modified. The
            #     rstrip(b"\n") matters: cryptsetup binds the keyslot to the
            #     bytes the user types at the boot prompt — newline-stripped.
            if encrypted:
                master_pp_file = StoragePoolService._materialize_master_passphrase()

            # 2. Wipe old filesystem signatures.
            StoragePoolService._update("wipe", 20.0, "Wiping old filesystem signatures")
            for p in dev_paths:
                rc, out = StoragePoolService._cmd([_WIPEFS, "-a", p])
                if rc != 0:
                    raise RuntimeError(f"wipefs failed on {p}: {out}")

            luks_records: List[Dict[str, Any]] = []

            # 2b. Per-disk LUKS for btrfs-native encrypted volumes. The btrfs
            #     IS the multi-device layer, so each disk gets its own mapper
            #     and btrfs spans them. Parity volumes (raid5/raid6) instead
            #     do LUKS-on-md after step 3 — single mapper per pool.
            tpm_avail = StoragePoolService._tpm_present() if encrypted else False
            if encrypted and profile not in _MD_PROFILES:
                assert master_pp_file is not None  # set above under `if encrypted`
                StoragePoolService._update(
                    "encrypt", 30.0,
                    f"Encrypting {len(members)} drive(s) (LUKS2)")
                for i, m in enumerate(members):
                    mapper = f"cryptd-{name}-{i + 1}"
                    dev = f"/dev/disk/by-id/{m}"
                    StoragePoolService._luks_format(dev, master_pp_file)
                    formatted_devs.append(dev)
                    StoragePoolService._luks_open(dev, mapper, master_pp_file)
                    opened_mappers.append(mapper)
                    # Track the actual TPM2 enrollment result per disk —
                    # crypttab generation gates `tpm2-device=auto` on this
                    # (segfaults systemd-cryptsetup when the LUKS has no
                    # TPM2 slot to unseal).
                    tpm2_enrolled = (tpm_avail
                        and StoragePoolService._tpm_enroll_best_effort(dev, master_pp_file))
                    luks_records.append({
                        "mapper": mapper,
                        "by-id": m,
                        "luks-uuid": StoragePoolService._luks_uuid(dev),
                        "keyfile": "",
                        "tpm2-enrolled": tpm2_enrolled,
                    })

            # 3. For a PARITY volume, assemble the md array first; btrfs then
            #    sits on the single resulting /dev/md device. md --create returns
            #    immediately and the array is usable straight away — the parity
            #    resync runs in the background (surfaced via /proc/mdstat).
            md_uuid = ""
            md_name = ""
            if encrypted and profile not in _MD_PROFILES:
                # btrfs spans the per-disk mappers.
                mkfs_targets = [f"/dev/mapper/{r['mapper']}" for r in luks_records]
            else:
                mkfs_targets = list(dev_paths)
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
                    raise RuntimeError(f"mdadm --create failed: {out}")
                # The /dev/md/<name> by-name symlink is created by udev and is
                # NOT reliably present right after --create (it depends on the
                # mdadm udev naming rules / homehost — e.g. /dev/md/ may not even
                # exist yet). Resolve the actual kernel device (/dev/mdN) from the
                # assembled members and mkfs on THAT; the mount keys on the btrfs
                # UUID, so the array's name never matters downstream.
                StoragePoolService._cmd([_UDEVADM, "settle"])
                md_dev = StoragePoolService._await_md_device(member_knames)
                if not md_dev:
                    raise RuntimeError(
                        "RAID array was created but its device node did not "
                        "appear; check `cat /proc/mdstat`.")
                md_name = os.path.basename(md_dev)   # kernel name, e.g. md127
                md_uuid = StoragePoolService._md_uuid(md_dev)
                mkfs_targets = [md_dev]

                # 3b. LUKS-on-md for encrypted parity volumes. One LUKS
                # container per pool (not per disk) — RHEL/Fedora's default
                # encrypted-RAID layout. The header sits on the md device and
                # is striped + parity-protected just like data.
                if encrypted:
                    assert master_pp_file is not None  # set above under `if encrypted`
                    StoragePoolService._update(
                        "encrypt", 50.0,
                        "Encrypting the assembled array (LUKS2)")
                    mapper = f"cryptd-{name}"
                    StoragePoolService._luks_format(md_dev, master_pp_file)
                    formatted_devs.append(md_dev)
                    StoragePoolService._luks_open(md_dev, mapper, master_pp_file)
                    opened_mappers.append(mapper)
                    tpm2_enrolled = (tpm_avail
                        and StoragePoolService._tpm_enroll_best_effort(md_dev, master_pp_file))
                    luks_records.append({
                        "mapper": mapper,
                        # /dev/disk/by-id/md-uuid-<X> appears via mdadm udev
                        # rules once assembled — used by /etc/crypttab so the
                        # unlock fires after homehost-driven assembly at boot.
                        "by-id": f"md-uuid-{md_uuid}",
                        "luks-uuid": StoragePoolService._luks_uuid(md_dev),
                        "keyfile": "",
                        "tpm2-enrolled": tpm2_enrolled,
                    })
                    mkfs_targets = [f"/dev/mapper/{mapper}"]

            # 4. Create the btrfs filesystem (the one destructive, irreversible
            #    step). No record is written until this succeeds.
            data, meta = _PROFILE_ARGS[profile]
            StoragePoolService._update("format", 60.0, "Creating btrfs filesystem")
            rc, out = StoragePoolService._cmd(
                [_MKFS_BTRFS, "-f", "-L", name, "-d", data, "-m", meta] + mkfs_targets)
            if rc != 0:
                raise RuntimeError(f"mkfs.btrfs failed: {out}")

            # 5. Capture the filesystem UUID — the mount keys on this.
            StoragePoolService._update("identify", 70.0, "Reading filesystem UUID")
            uuid = StoragePoolService._fs_uuid(mkfs_targets[0])
            if not uuid:
                raise RuntimeError("Could not read the new filesystem UUID.")

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
                "encrypted": encrypted,
                "luks-mappers": luks_records,
                "mount-options": ["compress=zstd", "noatime"],
                "device-timeout": "15s",
                "created-at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                "member-models": member_models,
            }
            if not StoragePoolService._append_pool(record):
                raise RuntimeError(
                    "Volume formatted but failed to write homefree-config.json.")

            msg = f"Volume '{name}' created. Apply changes to mount it at {mountpoint}."
            if encrypted and not tpm_avail:
                msg += (
                    " No TPM2 found — the recovery passphrase will be required "
                    "at every boot to unlock this volume.")
            StoragePoolService._done(msg)
        except Exception as e:  # noqa: BLE001
            logger.exception("storage-pool create crashed")
            # Roll back LUKS state in reverse order so the next attempt finds a
            # clean disk set. `close` first (mappers cannot be erased while
            # open), then erase the LUKS2 primary header, then wipefs to clear
            # the secondary header at the disk tail.
            for mapper in reversed(opened_mappers):
                StoragePoolService._luks_close(mapper)
            for dev in formatted_devs:
                StoragePoolService._luks_erase(dev)
            StoragePoolService._error(str(e) if str(e) else f"Unexpected error: {e}")
        finally:
            StoragePoolService._shred_tempfile(master_pp_file)

    # ----------------------------------------------------------- reformat

    @staticmethod
    def _run_reformat(req: Dict[str, Any]) -> None:
        """Re-format an existing mdadm parity array with a fresh filesystem
        (optionally LUKS-encrypted), WITHOUT tearing down + re-syncing the
        array. The motivating case: a 4×12TB RAID6 took a day to resync;
        the admin wants to scrap its current filesystem (e.g. unmanaged
        btrfs, or one created without encryption) and start fresh — they
        should not have to pay that resync cost again.

        Steps:
          1. Materialize the master passphrase if encrypted.
          2. Locate /dev/md<N> + verify it is assembled.
          3. Close any LUKS mapper currently sitting on /dev/md<N> so we
             can re-format it (an open mapper holds the device).
          4. wipefs /dev/md<N> to clear the existing filesystem / LUKS
             signature.
          5. If encrypted: luksFormat + luksOpen + TPM-enroll on /dev/md<N>.
          6. mkfs.btrfs on the (LUKS mapper or) md device.
          7. Capture the new fs-uuid + ensure /dev/disk/by-uuid/<uuid>.
          8. Record the pool. Same shape as a fresh raid5/6 create except
             `members`/`md-uuid`/`md-device` come from the EXISTING array
             (not recomputed via mdadm --create).

        Rollback mirrors _run_create: any failure after LUKS state is set
        up closes the mapper + erases the LUKS header on /dev/md<N>.
        """
        opened_mappers: List[str] = []
        formatted_devs: List[str] = []
        master_pp_file: Optional[str] = None
        encrypted = bool(req.get("encrypted"))
        try:
            name = req["name"].strip()
            mountpoint = req["mountpoint"].strip()
            profile = req["profile"]
            members = req["members"]
            md_device_in = req["md_device"].strip()
            md_kname = os.path.basename(md_device_in)  # accept "md127" OR "/dev/md127"
            md_dev = f"/dev/{md_kname}"

            StoragePoolService._update("validate", 5.0, "Validating the array")
            if not os.path.exists(md_dev):
                raise RuntimeError(
                    f"{md_dev} does not exist or is not assembled. The array "
                    "must be present to reformat in place.")
            # Re-read the live md-uuid (don't trust the client value).
            md_uuid = StoragePoolService._md_uuid(md_dev)
            if not md_uuid:
                raise RuntimeError(
                    f"Could not read the md UUID for {md_dev}; refusing to "
                    "reformat without a stable array identifier.")

            # Look up member models for the pool record (cosmetic but matches
            # _run_create's record shape). Best-effort.
            member_models: List[str] = []
            drives = {d.get("by_id"): d
                      for d in StorageResolver.list_drives() if d.get("by_id")}
            for m in members:
                d = drives.get(m)
                member_models.append((d or {}).get("model") or "Unknown")

            if encrypted:
                master_pp_file = StoragePoolService._materialize_master_passphrase()

            # Close any LUKS mapper currently holding /dev/md<N>. Without this,
            # `wipefs` on the md device fails with EBUSY. The helper is the
            # same /sys/block/<X>/holders walk that storage_reclaim uses; we
            # call cryptsetup close on every CRYPT- holder we find.
            holders_dir = f"/sys/block/{md_kname}/holders"
            if os.path.isdir(holders_dir):
                for h in sorted(os.listdir(holders_dir)):
                    try:
                        uuid = open(
                            f"{holders_dir}/{h}/dm/uuid").read().strip()
                        mapper_name = open(
                            f"{holders_dir}/{h}/dm/name").read().strip()
                    except OSError:
                        continue
                    if uuid.startswith("CRYPT-") and mapper_name:
                        StoragePoolService._update(
                            "luks-close", 15.0,
                            f"Closing existing LUKS mapper {mapper_name}")
                        StoragePoolService._luks_close(mapper_name)

            StoragePoolService._update(
                "wipe", 25.0, f"Wiping existing filesystem signatures on {md_dev}")
            rc, out = StoragePoolService._cmd([_WIPEFS, "-a", md_dev])
            if rc != 0:
                raise RuntimeError(f"wipefs failed on {md_dev}: {out}")

            mkfs_target = md_dev
            luks_records: List[Dict[str, Any]] = []
            if encrypted:
                assert master_pp_file is not None
                tpm_avail = StoragePoolService._tpm_present()
                mapper = f"cryptd-{name}"
                StoragePoolService._update(
                    "encrypt", 40.0,
                    "Encrypting the array (LUKS2 on the md device)")
                StoragePoolService._luks_format(md_dev, master_pp_file)
                formatted_devs.append(md_dev)
                StoragePoolService._luks_open(md_dev, mapper, master_pp_file)
                opened_mappers.append(mapper)
                tpm2_enrolled = (tpm_avail
                    and StoragePoolService._tpm_enroll_best_effort(md_dev, master_pp_file))
                luks_records.append({
                    "mapper": mapper,
                    "by-id": f"md-uuid-{md_uuid}",
                    "luks-uuid": StoragePoolService._luks_uuid(md_dev),
                    "keyfile": "",
                    "tpm2-enrolled": tpm2_enrolled,
                })
                mkfs_target = f"/dev/mapper/{mapper}"

            data, meta = _PROFILE_ARGS[profile]
            StoragePoolService._update(
                "format", 60.0, "Creating btrfs filesystem on the array")
            rc, out = StoragePoolService._cmd(
                [_MKFS_BTRFS, "-f", "-L", name, "-d", data, "-m", meta, mkfs_target])
            if rc != 0:
                raise RuntimeError(f"mkfs.btrfs failed: {out}")

            StoragePoolService._update("identify", 75.0, "Reading filesystem UUID")
            uuid = StoragePoolService._fs_uuid(mkfs_target)
            if not uuid:
                raise RuntimeError("Could not read the new filesystem UUID.")

            StoragePoolService._update("settle", 85.0, "Registering the filesystem")
            if not StoragePoolService._ensure_by_uuid(uuid, [mkfs_target]):
                logger.warning(
                    "storage-pool: by-uuid for %s did not appear after reformat; "
                    "the volume is built but its mount may need a udev trigger.",
                    uuid)

            StoragePoolService._update("record", 90.0, "Recording pool configuration")
            record = {
                "enabled": True,
                "name": name,
                "mountpoint": mountpoint,
                "profile": profile,
                "members": members,
                "fs-uuid": uuid,
                "md-uuid": md_uuid,
                "md-device": md_kname,
                "encrypted": encrypted,
                "luks-mappers": luks_records,
                "mount-options": ["compress=zstd", "noatime"],
                "device-timeout": "15s",
                "created-at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                "member-models": member_models,
                "reformatted-at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            }
            if not StoragePoolService._append_pool(record):
                raise RuntimeError(
                    "Volume formatted but failed to write homefree-config.json.")

            msg = (f"Volume '{name}' reformatted on the existing array. "
                   f"Apply changes to mount it at {mountpoint}.")
            if encrypted and not StoragePoolService._tpm_present():
                msg += (
                    " No TPM2 found — the recovery passphrase will be required "
                    "at every boot to unlock this volume.")
            StoragePoolService._done(msg)
        except Exception as e:  # noqa: BLE001
            logger.exception("storage-pool reformat crashed")
            for mapper in reversed(opened_mappers):
                StoragePoolService._luks_close(mapper)
            for dev in formatted_devs:
                StoragePoolService._luks_erase(dev)
            StoragePoolService._error(str(e) if str(e) else f"Unexpected error: {e}")
        finally:
            StoragePoolService._shred_tempfile(master_pp_file)

    # ----------------------------------------------------------- destroy

    @staticmethod
    def destroy_pool(name: str) -> List[str]:
        """Destroy a managed pool: unmount → close LUKS mappers → tear
        down md → wipe member disks → remove the pool record. The
        destructive complement to `forget` (which is non-destructive —
        record only). Used by the pool card's "Reclaim & erase" button
        so the user doesn't have to do Remove → Apply → wait-for-unmount
        → Reclaim as three separate steps.

        Does the work INLINE using the pool record's own knowledge of
        luks-mappers, md-device, and members — does NOT go through
        StorageReclaimService.validate_request, which would refuse when
        the disks are no longer in a reclaimable state (e.g. they were
        already wiped earlier by a stale tank-candidate Reclaim and the
        user re-Promoted before the UI refreshed → the pool record
        points at empty disks, the validate gate says 'in use', the
        record gets stuck). Every step is best-effort; the final goal
        is the pool record gone — wipe is desirable but not strictly
        required, since a disk with no signature is already wipefs-
        equivalent.

        Returns [] on success or a list of error strings."""
        try:
            cfg = ConfigReader.read_config()
        except Exception:  # noqa: BLE001
            return ["Could not read homefree-config.json."]
        existing = ((cfg.get("storage") or {}).get("pools")) or []
        pool = next((p for p in existing if p.get("name") == name), None)
        if pool is None:
            return [f"No pool named '{name}'."]
        members = pool.get("members") or []
        mountpoint = pool.get("mountpoint") or ""
        md_device = pool.get("md-device") or ""
        luks_mappers = pool.get("luks-mappers") or []

        umount = _resolve_bin("umount")
        sgdisk = _resolve_bin("sgdisk")

        # 1. Unmount the live filesystem (best-effort). Try a normal
        # umount first, fall back to umount -l (lazy) so a stray shell
        # cwd inside the mountpoint doesn't block — the kernel detaches
        # on last close. Non-fatal if the mount unit was never started.
        if mountpoint and os.path.ismount(mountpoint):
            rc, _ = StoragePoolService._cmd([umount, mountpoint])
            if rc != 0:
                StoragePoolService._cmd([umount, "-l", mountpoint])

        # 2. Close any LUKS mappers the pool record knows about (managed
        # encrypted pools). Then sweep /sys/block/<dev>/holders for any
        # other CRYPT- mapper that might be open on the disks (e.g. an
        # unmanaged-X mapper from an earlier unlock that was never
        # adopted). Mapper-close has to happen before mdadm --stop;
        # an open mapper holds its backing device.
        for m in luks_mappers:
            mapper = m.get("mapper") if isinstance(m, dict) else None
            if mapper:
                StoragePoolService._luks_close(mapper)
        # Cover stray mappers on the same physical disks too.
        try:
            from services.storage_reclaim import StorageReclaimService
            knames = [os.path.basename(os.path.realpath(f"/dev/disk/by-id/{m}"))
                      for m in members]
            scan_devs = sorted({k for k in knames if k} | ({md_device} if md_device else set()))
            for mapper in StorageReclaimService._crypt_mappers_on(scan_devs):
                StoragePoolService._luks_close(mapper)
        except (ImportError, OSError) as e:  # noqa: BLE001
            logger.warning("destroy_pool: stray-mapper scan failed: %s", e)

        # 3. Stop the md array if the pool is parity-backed. Best-effort
        # — a missing/already-stopped array is fine.
        if md_device and os.path.exists(f"/dev/{md_device}"):
            StoragePoolService._cmd([_MDADM, "--stop", f"/dev/{md_device}"])

        # 4. Wipe each member disk (wipefs clears fs signatures, sgdisk
        # zaps the partition table). Best-effort per disk so one
        # missing/dead disk can't block the rest.
        for member in members:
            dev = f"/dev/disk/by-id/{member}"
            if not os.path.exists(dev):
                continue
            # Also zero any leftover md superblock so a stale signature
            # doesn't make the disk auto-assemble into a phantom array
            # on the next boot.
            StoragePoolService._cmd([_MDADM, "--zero-superblock", "--force", dev])
            StoragePoolService._cmd([_WIPEFS, "-a", dev])
            StoragePoolService._cmd([sgdisk, "--zap-all", dev])

        StoragePoolService._cmd([_UDEVADM, "settle"])

        # 5. Remove the pool record from homefree-config.json. Spread
        # the existing `storage` object so sibling sub-keys (e.g.
        # `shares`) survive — same pattern as `forget`.
        storage = cfg.get("storage") or {}
        new_pools = [p for p in (storage.get("pools") or []) if p.get("name") != name]
        if not ConfigWriter.write_config({"storage": {**storage, "pools": new_pools}}):
            return ["Wiped the volume but failed to remove the pool record "
                    "from homefree-config.json — re-Remove from the UI."]
        return []

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

        # Detect LUKS layer: when the candidate's btrfs sits on a /dev/mapper/X
        # crypt mapper, record the LUKS info so /etc/crypttab auto-unlocks at
        # boot (master TPM2 if keyfile is empty, or a stored per-volume keyfile
        # — both modes handled by modules/storage-pools.nix's mkCrypttabLine).
        luks_layer = StoragePoolService.resolve_candidate_luks(cand.get("device", ""))
        record = {
            "enabled": True,
            "name": name,
            "mountpoint": mountpoint,
            "profile": cand["profile"],
            "members": cand["members"],
            "fs-uuid": fs_uuid,
            "md-uuid": "",
            "md-device": cand.get("md_device") or "",
            "encrypted": luks_layer is not None,
            "luks-mappers": [luks_layer] if luks_layer else [],
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

        # Same LUKS-layer detection as Promote — see resolve_candidate_luks.
        luks_layer = StoragePoolService.resolve_candidate_luks(cand.get("device", ""))
        pool = {
            "enabled": True,
            "name": name,
            "mountpoint": mountpoint,
            "profile": cand["profile"],
            "members": cand["members"],
            "fs-uuid": fs_uuid,
            "md-uuid": "",
            "md-device": cand.get("md_device") or "",
            "encrypted": luks_layer is not None,
            "luks-mappers": [luks_layer] if luks_layer else [],
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

    # --------------------------------------------- locked-LUKS unlock

    @staticmethod
    def unlock_locked_luks(device: str, use_master_key: bool,
                           passphrase: str,
                           save_key: bool = False,
                           adopt_master: bool = False) -> Dict[str, Any]:
        """Open a locked LUKS container persistently. Mapper name is
        derived from the backing device's kernel name as
        `unmanaged-<kname>` (e.g. `unmanaged-md127`, `unmanaged-vdg`) so
        the same physical thing always opens under the same name.

        `use_master_key=True` reads the master passphrase from
        /etc/nixos/secrets/recovery-passphrase.txt; otherwise the
        user-supplied `passphrase` is used. The key bytes are written to
        a /run tempfile (mode 0600), passed via `--key-file`, and shredded
        after — never lingering in a Python string.

        Two optional post-unlock persistence steps for foreign-keyed
        volumes (use_master_key=False) so a Promote afterwards can
        record an actually auto-unlockable pool:

          save_key=True
            Write the user's passphrase bytes to
            /etc/nixos/secrets/luks-keys/<luks-uuid>.key (mode 0600,
            in a chmod-0700 dir). Promote stores this path in the pool's
            luks-mappers[].keyfile so /etc/crypttab references it for
            auto-unlock on boot. Survives backup/restore (rides /etc/nixos).

          adopt_master=True
            cryptsetup luksAddKey — adds the configured master key as a
            new LUKS slot, authorized by the user's passphrase. Then
            best-effort TPM2 enrolls the master slot (--tpm2-pcrs=7) so
            unattended boot works. After this the master key file alone
            can unlock the volume — the same auto-unlock path
            HomeFree-created encrypted pools use.

        Both can be set: TPM2 wins at boot, keyfile is the fallback if
        the TPM is cleared (best of both — see the crypttab line in
        modules/storage-pools.nix). Neither option is honored when
        use_master_key=True (no foreign key to save; master is already a
        slot).

        Returns `{mapper, device, key_stored, master_adopted, luks_uuid}`
        on success. Raises ValueError for a wrong key (cryptsetup exit 2)
        or bad inputs, RuntimeError for tooling / state issues."""
        if not device or not device.startswith("/dev/"):
            raise ValueError("Device path must be an absolute /dev/ path.")
        if not os.path.exists(device):
            raise RuntimeError(f"Device {device} does not exist.")

        # Verify it's actually a locked LUKS — refuse if no LUKS header,
        # or if a mapper is already open (the caller is confused about state).
        from resolvers.storage import _luks_uuid_of_device, _luks_holder_open
        if not _luks_uuid_of_device(device):
            raise ValueError(
                f"{device} does not carry a LUKS header — nothing to unlock.")
        if _luks_holder_open(device):
            raise ValueError(
                f"{device} already has an open LUKS mapper. Refresh the page; "
                "it should show as a regular candidate now.")

        # Resolve the key bytes.
        if use_master_key:
            from services.encryption_master_key import get_master_pp_bytes
            pp = get_master_pp_bytes()
            if not pp:
                raise RuntimeError(
                    "The master encryption key is not configured on this box.")
        else:
            if not passphrase:
                raise ValueError("Passphrase is required.")
            # rstrip a trailing newline only — every other whitespace stays
            # (cryptsetup is byte-exact about what it binds to a keyslot).
            pp = passphrase.encode("utf-8").rstrip(b"\n")
            if not pp:
                raise ValueError("Passphrase is empty after stripping the trailing newline.")

        kname = os.path.basename(os.path.realpath(device))
        mapper = f"unmanaged-{kname}"

        # Refuse if the mapper name is already in use (some other open mapper
        # — possibly a previous unlock that wasn't closed). Caller can resolve
        # by closing the existing mapper first.
        if os.path.exists(f"/dev/mapper/{mapper}"):
            raise RuntimeError(
                f"Mapper /dev/mapper/{mapper} already exists. Close it "
                "first (cryptsetup close) or refresh the page.")

        fd, path = tempfile.mkstemp(prefix="hf-luks-open-", dir="/run")
        try:
            os.fchmod(fd, 0o600)
            os.write(fd, pp)
        finally:
            os.close(fd)
        try:
            p = subprocess.run(
                [_CRYPTSETUP, "open", "--key-file", path, device, mapper],
                capture_output=True, text=True, timeout=30)
            if p.returncode != 0:
                err = (p.stderr or p.stdout or "").strip()
                # Exit 2 from cryptsetup = "No key available with this
                # passphrase" — the typical wrong-key failure mode.
                if p.returncode == 2 or "No key available" in err:
                    raise ValueError(
                        "That passphrase does not unlock this volume.")
                raise RuntimeError(
                    f"cryptsetup open failed (exit {p.returncode}): {err}")
        except (subprocess.SubprocessError, OSError) as e:
            raise RuntimeError(f"cryptsetup open failed: {e}") from e
        finally:
            StoragePoolService._shred_tempfile(path)

        # Nudge udev so /sys/block/<dm-N> + the by-uuid symlink (if a
        # filesystem on the mapper has one) come up before the next API
        # call probes them. The btrfs scan is part of `btrfs filesystem
        # show` which `list_promotable_btrfs` already runs, so the next
        # poll will see the open mapper and its btrfs without help here.
        try:
            subprocess.run([_UDEVADM, "settle"], check=False, timeout=10)
        except (subprocess.SubprocessError, OSError):
            pass

        # Capture the LUKS UUID for the per-volume keyfile path AND for
        # any subsequent Promote — recorded in the pool's luks-mappers
        # entry as the stable id of this container.
        from resolvers.storage import _luks_uuid_of_device
        luks_uuid = _luks_uuid_of_device(device) or ""

        # Persistence steps (foreign-keyed volumes only — use_master_key
        # means master is already a slot, both options become no-ops).
        key_stored = False
        master_adopted = False
        if not use_master_key and luks_uuid and (save_key or adopt_master):
            # Both steps want the user's passphrase as auth/contents. Write
            # it once to a /run tempfile; reuse for whichever ops are on.
            user_fd, user_path = tempfile.mkstemp(prefix="hf-luks-userpp-", dir="/run")
            try:
                os.fchmod(user_fd, 0o600)
                os.write(user_fd, pp)
            finally:
                os.close(user_fd)
            try:
                if save_key:
                    StoragePoolService._save_luks_keyfile(luks_uuid, pp)
                    key_stored = True
                if adopt_master:
                    master_adopted = StoragePoolService._adopt_master_slot(
                        device, user_path)
            finally:
                StoragePoolService._shred_tempfile(user_path)

        logger.info(
            "Unlocked LUKS on %s → /dev/mapper/%s "
            "(master_key=%s, save_key=%s, master_adopted=%s)",
            device, mapper, use_master_key, key_stored, master_adopted)
        return {
            "mapper": mapper,
            "device": f"/dev/mapper/{mapper}",
            "luks_uuid": luks_uuid,
            "key_stored": key_stored,
            "master_adopted": master_adopted,
        }

    @staticmethod
    def _save_luks_keyfile(luks_uuid: str, key_bytes: bytes) -> None:
        """Persist a LUKS unlock key at
        /etc/nixos/secrets/luks-keys/<luks-uuid>.key (mode 0600, in a
        chmod-0700 dir). Promote later references this path from the
        pool's luks-mappers[].keyfile so /etc/crypttab auto-unlocks the
        volume on boot. Lives under /etc/nixos which IS the backed-up
        location — survives restore.

        Uses plain `os` calls instead of utils/privileged.py because
        admin-api runs as root (services/admin-web/default.nix) and does
        NOT need pkexec; the privileged helpers are designed for the
        installer's non-root user and would try to invoke
        /etc/homefree-installer/pkexec-wrapper.sh which doesn't exist on
        the installed system."""
        keys_dir = "/etc/nixos/secrets/luks-keys"
        # exist_ok=True so re-saves don't bomb. mode arg on os.makedirs
        # is masked by umask, so we explicitly chmod afterwards.
        os.makedirs(keys_dir, exist_ok=True)
        os.chmod(keys_dir, 0o700)
        keyfile = f"{keys_dir}/{luks_uuid}.key"
        # Open with O_WRONLY|O_CREAT|O_TRUNC at 0600 from the start — never
        # widen-then-narrow (which would race with anything scanning the
        # dir). The on-disk bytes MUST match what cryptsetup binds to the
        # slot: `key_bytes` is already newline-stripped by the unlock path;
        # write verbatim, no encoding round-trip.
        fd = os.open(keyfile, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        try:
            os.write(fd, key_bytes)
        finally:
            os.close(fd)
        # Defensive — if the file existed before, the mode is preserved
        # across O_TRUNC, so re-chmod to guarantee 0600 regardless.
        os.chmod(keyfile, 0o600)
        logger.info("Persisted LUKS keyfile at %s (mode 0600, dir 0700)", keyfile)

    @staticmethod
    def _adopt_master_slot(device: str, user_pp_file: str) -> bool:
        """Add the configured master encryption key as a NEW LUKS slot on
        `device`, authorized by `user_pp_file` (the unlock passphrase the
        user just typed). On success, also best-effort TPM2-enrolls the
        master slot so unattended boot via the existing
        tpm2-device=auto,tpm2-pcrs=7 crypttab path works.

        Returns True iff the luksAddKey succeeded (TPM2 enrollment is
        best-effort — non-fatal if it fails, e.g. no TPM). Raises
        RuntimeError if the master key isn't configured."""
        from services.encryption_master_key import get_master_pp_bytes
        master_pp = get_master_pp_bytes()
        if not master_pp:
            raise RuntimeError(
                "Cannot adopt master key: the master encryption key is not "
                "configured on this box.")
        # luksAddKey reads the NEW key from the second positional arg as a
        # keyfile (raw bytes to EOF) — so both files must have NO trailing
        # newline (the user_pp_file already has none; master_pp is read via
        # get_master_pp_bytes which strips it). Same byte-match invariant
        # as the create flow's slot binding.
        master_fd, master_path = tempfile.mkstemp(prefix="hf-luks-master-", dir="/run")
        try:
            os.fchmod(master_fd, 0o600)
            os.write(master_fd, master_pp)
        finally:
            os.close(master_fd)
        try:
            p = subprocess.run(
                [_CRYPTSETUP, "luksAddKey", "-q",
                 "--key-file", user_pp_file, device, master_path],
                capture_output=True, text=True, timeout=30)
            if p.returncode != 0:
                # No raise — adoption is opt-in user request; log + return
                # False so the UI can surface a partial-success message.
                logger.warning(
                    "Adopt-master luksAddKey failed on %s (exit %d): %s",
                    device, p.returncode,
                    (p.stderr or p.stdout or "").strip())
                return False
            # Best-effort TPM2 enroll — same call shape as the create path.
            if StoragePoolService._tpm_present():
                try:
                    StoragePoolService._tpm_enroll_best_effort(device, master_path)
                except Exception as e:  # noqa: BLE001
                    logger.warning(
                        "TPM2 enrollment after adopt-master failed on %s: %s",
                        device, e)
            return True
        finally:
            StoragePoolService._shred_tempfile(master_path)

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

    # ----------------------------------------------------- LUKS helpers
    #
    # All operations are bound to ONE master key: the LUKS recovery
    # passphrase at /etc/nixos/secrets/recovery-passphrase.txt (the same
    # value that unlocks the system disk's recovery slot). The passphrase
    # is materialized to /run/hf-luks-XXXX (mode 600, no trailing newline)
    # for the duration of a create job and shredded in `finally`.
    #
    # Trailing newline gotcha: the installer writes the recovery passphrase
    # with `+ "\n"` (install.py:670), but cryptsetup binds the keyslot to
    # the newline-stripped value (what the user types at the boot prompt).
    # `_materialize_master_passphrase` strips the newline so the tempfile's
    # bytes match the slot's bound bytes for both --key-file (raw bytes)
    # and interactive (passphrase semantics) modes.

    @staticmethod
    def _tpm_present() -> bool:
        return any(os.path.exists(p) for p in _TPM_DEV_PATHS)

    @staticmethod
    def resolve_candidate_luks(candidate_device: str) -> Optional[Dict[str, Any]]:
        """Given a btrfs candidate's device path (the `device` field from
        list_promotable_btrfs / list_importable), return the luks-mappers
        entry to record on Promote/Attach when the path is a `/dev/mapper/X`
        crypt device — None when the candidate is unencrypted.

        Walks ONE slave level: a btrfs sitting on a LUKS mapper sitting on
        either an md device (LUKS-on-md / parity) OR a raw disk (single-
        disk LUKS). Per-disk LUKS in a btrfs-native raid1/raid10 is not
        surfaced by list_promotable_btrfs anyway (the multi-device-native
        rejection branch), so we don't have to handle N-mapper cases here.

        The returned `keyfile` is the path of an existing saved keyfile
        at /etc/nixos/secrets/luks-keys/<luks-uuid>.key (set during a
        prior unlock with `save_key=True`), or empty when the volume is
        master-keyed (crypttab will use TPM2 + passphrase fallback)."""
        if not candidate_device or not candidate_device.startswith("/dev/mapper/"):
            return None
        mapper_name = os.path.basename(candidate_device)
        try:
            real_dm = os.path.basename(os.path.realpath(candidate_device))
        except OSError:
            return None
        try:
            dm_uuid = open(f"/sys/block/{real_dm}/dm/uuid").read().strip()
        except OSError:
            return None
        if not dm_uuid.startswith("CRYPT-"):
            return None

        # Walk one slave level to the LUKS backing device.
        try:
            slaves = sorted(os.listdir(f"/sys/block/{real_dm}/slaves"))
        except OSError:
            return None
        if len(slaves) != 1:
            return None  # a crypt mapper should have exactly one backing dev
        backing_name = slaves[0]
        backing_dev = f"/dev/{backing_name}"

        from resolvers.storage import _luks_uuid_of_device, _by_id_map
        luks_uuid = _luks_uuid_of_device(backing_dev)
        if not luks_uuid:
            return None

        # The `by-id` field is what modules/storage-pools.nix's crypttab line
        # references: /dev/disk/by-id/<by-id>. For LUKS-on-md we use the
        # md-uuid-<X> symlink (mirrors the create + reformat conventions);
        # for LUKS-on-disk we use the disk's own by-id.
        if backing_name.startswith("md"):
            md_uuid = ""
            try:
                p = subprocess.run(
                    [_MDADM, "--detail", "--export", backing_dev],
                    capture_output=True, text=True, timeout=15)
                for line in (p.stdout or "").splitlines():
                    if line.startswith("MD_UUID="):
                        md_uuid = line.split("=", 1)[1].strip()
                        break
            except (subprocess.SubprocessError, OSError):
                pass
            if not md_uuid:
                return None
            by_id = f"md-uuid-{md_uuid}"
        else:
            by_id = _by_id_map().get(backing_name) or ""
            if not by_id:
                return None

        keyfile_path = f"/etc/nixos/secrets/luks-keys/{luks_uuid}.key"
        keyfile = keyfile_path if os.path.isfile(keyfile_path) else ""
        # Probe TPM2 enrollment on the LUKS so the crypttab generator can
        # decide whether to include `tpm2-device=auto`. Including that opt
        # against a LUKS with no TPM2 slot SEGFAULTS systemd-cryptsetup
        # (observed on systemd 260 — boot fails with core-dump). See the
        # `mkCrypttabLine` comment in modules/storage-pools.nix.
        tpm2_enrolled = StoragePoolService._luks_has_tpm2_slot(backing_dev)
        return {
            "mapper": mapper_name,
            "by-id": by_id,
            "luks-uuid": luks_uuid,
            "keyfile": keyfile,
            "tpm2-enrolled": tpm2_enrolled,
        }

    @staticmethod
    def _materialize_master_passphrase() -> str:
        """Write the recovery passphrase (newline-stripped) to a private
        tempfile and return its path. Caller MUST `_shred_tempfile` it."""
        if not os.path.isfile(_RECOVERY_PP_PATH):
            raise RuntimeError(
                "Master encryption key not configured. Set up the master "
                "key on the Storage page before creating an encrypted "
                "volume.")
        try:
            with open(_RECOVERY_PP_PATH, "rb") as f:
                pp = f.read().rstrip(b"\n")
        except OSError as e:
            raise RuntimeError(
                f"Could not read {_RECOVERY_PP_PATH}: {e}") from e
        if not pp:
            raise RuntimeError(
                f"Master encryption key at {_RECOVERY_PP_PATH} is empty.")
        fd, path = tempfile.mkstemp(prefix="hf-luks-", dir="/run")
        try:
            os.fchmod(fd, 0o600)
            os.write(fd, pp)
        finally:
            os.close(fd)
        return path

    @staticmethod
    def _shred_tempfile(path: Optional[str]) -> None:
        if not path:
            return
        try:
            subprocess.run([_SHRED, "-u", path], check=False, timeout=10)
        except (subprocess.SubprocessError, OSError):
            pass
        # shred should have deleted it; clean up the fallback.
        if os.path.exists(path):
            try:
                os.unlink(path)
            except OSError:
                pass

    @staticmethod
    def _luks_format(dev: str, pp_file: str) -> None:
        """cryptsetup luksFormat with the master key (passphrase as keyfile
        bytes — equivalent because we stripped the trailing newline)."""
        p = subprocess.run(
            [_CRYPTSETUP, "luksFormat", "-q", "--type", "luks2",
             "--key-file", pp_file, dev],
            capture_output=True, text=True, timeout=120)
        if p.returncode != 0:
            raise RuntimeError(
                f"cryptsetup luksFormat failed on {dev} "
                f"(exit {p.returncode}): {(p.stderr or p.stdout or '').strip()}")

    @staticmethod
    def _luks_open(dev: str, mapper: str, pp_file: str) -> None:
        p = subprocess.run(
            [_CRYPTSETUP, "open", "--key-file", pp_file, dev, mapper],
            capture_output=True, text=True, timeout=30)
        if p.returncode != 0:
            raise RuntimeError(
                f"cryptsetup open failed on {dev} → {mapper} "
                f"(exit {p.returncode}): {(p.stderr or p.stdout or '').strip()}")

    @staticmethod
    def _luks_close(mapper: str) -> None:
        """Best-effort close (used in rollback paths). Missing/already-closed
        mappers must not raise."""
        try:
            subprocess.run([_CRYPTSETUP, "close", mapper],
                           check=False, capture_output=True, timeout=15)
        except (subprocess.SubprocessError, OSError) as e:
            logger.warning("cryptsetup close %s: %s", mapper, e)

    @staticmethod
    def _luks_uuid(dev: str) -> str:
        p = subprocess.run([_CRYPTSETUP, "luksUUID", dev],
                           capture_output=True, text=True, timeout=10)
        if p.returncode != 0:
            raise RuntimeError(
                f"cryptsetup luksUUID failed on {dev}: "
                f"{(p.stderr or p.stdout or '').strip()}")
        return (p.stdout or "").strip()

    @staticmethod
    def _luks_erase(dev: str) -> None:
        """Wipe the LUKS header so a subsequent format attempt isn't blocked.
        `cryptsetup erase -q` zeros the primary header at offset 0; the
        wipefs follow-up clears the LUKS2 secondary header at disk tail.
        Best-effort — used during rollback after a failed create."""
        try:
            subprocess.run([_CRYPTSETUP, "erase", "-q", dev],
                           check=False, capture_output=True, timeout=30)
            subprocess.run([_WIPEFS, "-a", dev],
                           check=False, capture_output=True, timeout=30)
        except (subprocess.SubprocessError, OSError) as e:
            logger.warning("LUKS rollback wipe failed on %s: %s", dev, e)

    @staticmethod
    def _tpm_enroll_best_effort(dev: str, pp_file: str) -> bool:
        """Enroll a TPM2 keyslot (sealed to PCR 7) so unattended boot can
        unlock without typing the passphrase. NON-FATAL: a TPM in DA-lockout
        or a flaky cheap TPM should not block volume creation — the keyslot-0
        passphrase still works at the boot prompt, just attended.

        Returns True iff enrollment succeeded — the caller records this in
        the pool's luks-mappers[].tpm2-enrolled so the crypttab generator
        knows whether to include `tpm2-device=auto` (which segfaults
        systemd-cryptsetup when the LUKS has no TPM2 slot)."""
        p = subprocess.run(
            [_SYSTEMD_CRYPTENROLL,
             f"--unlock-key-file={pp_file}",
             "--tpm2-device=auto",
             "--tpm2-pcrs=7",
             dev],
            capture_output=True, text=True, timeout=30)
        if p.returncode != 0:
            logger.warning(
                "TPM2 enrollment failed on %s (exit %d): %s — passphrase "
                "fallback still works at the boot prompt.",
                dev, p.returncode, (p.stderr or p.stdout or '').strip())
            return False
        return True

    @staticmethod
    def _luks_has_tpm2_slot(device: str) -> bool:
        """True iff `device` is a LUKS container with at least one TPM2-bound
        keyslot enrolled via systemd-cryptenroll. Used by
        resolve_candidate_luks to set the pool record's
        luks-mappers[].tpm2-enrolled correctly at Promote time.

        `systemd-cryptenroll <device>` with no other args lists existing
        slot-type rows; TPM2 slots show 'tpm2' in their TYPE column. We
        don't need to parse precisely — substring is enough; the
        master-keyed create path uses --tpm2-device=auto so the row reads
        'tpm2' on success."""
        try:
            p = subprocess.run(
                [_SYSTEMD_CRYPTENROLL, device],
                capture_output=True, text=True, timeout=10)
            if p.returncode != 0:
                return False
            for line in (p.stdout or "").splitlines():
                if "tpm2" in line.lower():
                    return True
        except (subprocess.SubprocessError, OSError):
            pass
        return False
