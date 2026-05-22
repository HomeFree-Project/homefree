"""
Storage resolver — drive eligibility + pool listing for the Storage admin
module (Phase 1 of the Storage & NAS feature).

READ-ONLY. This module enumerates physical drives (reusing
PhysicalDrivesResolver for SMART/model/size), decides which are eligible to be
pooled, reads the recorded pools from homefree-config.json, and reports their
live status. No disk is ever modified here — creation lives in
services/storage_pool.py.

Eligibility is the safety-critical core (AGENTS.md rule 10): a disk is eligible
ONLY if it passes every disqualifying check. The single most important one is
the multi-device-btrfs cross-reference — disko installs the root filesystem as
btrfs raid1 across two disks, but /proc/mounts names only one member. Without
`btrfs filesystem show --mounted` we would mark the second OS mirror "available"
and let the user destroy it. btrfs membership is a *filesystem* relationship,
invisible to lsblk's block-device tree, so it must be resolved explicitly.

Privilege: admin-api runs as root (services/admin-web/default.nix), so the
read-only probes here run directly. A wedged disk / USB bridge can hang lsblk
or btrfs for tens of seconds, so every external command is time-bounded.
"""

import asyncio
import concurrent.futures
import json
import logging
import os
import shutil
import subprocess
from pathlib import Path
from typing import Any, Dict, List, Optional, Set, Tuple

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel

from resolvers.physical_drives import PhysicalDrivesResolver
from services.config_reader import ConfigReader

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api/storage", tags=["storage"])

# Phase-1 btrfs-native profiles and the minimum member count each requires.
PROFILE_MIN_MEMBERS: Dict[str, int] = {
    "single": 1, "raid0": 2, "raid1": 2, "raid10": 4,
}

_CMD_TIMEOUT_S = 5.0
_STAT_TIMEOUT_S = 2.0

# GPT type GUID of an EFI System Partition. A disk carrying one is (or was) a
# boot disk; we refuse it even when the ESP is unmounted — a stale /boot2-style
# mirror or a previous install's boot disk must never be offered for wiping.
_EFI_GUID = "c12a7328-f81f-11d2-ba4b-00a0c93ec93b"

# A dying disk can wedge statvfs in the kernel; bound it (same shape as
# dashboard._disk_usage_safe). Pool maxes at 2 so a storm stays bounded.
_STAT_POOL = concurrent.futures.ThreadPoolExecutor(
    max_workers=2, thread_name_prefix="storage_statvfs",
)


def _resolve_bin(name: str) -> str:
    """Absolute path to a binary. The admin-api unit ships a restricted PATH;
    fall back to /run/current-system/sw/bin (canonical NixOS location). Mirrors
    resolvers/physical_drives._resolve_bin and dashboard._ip_bin."""
    found = shutil.which(name)
    if found:
        return found
    for c in (f"/run/current-system/sw/bin/{name}",
              f"/usr/sbin/{name}", f"/usr/bin/{name}"):
        if Path(c).exists():
            return c
    return name


_LSBLK = _resolve_bin("lsblk")
_FINDMNT = _resolve_bin("findmnt")
_BTRFS = _resolve_bin("btrfs")


def _run(cmd: List[str]) -> str:
    """Run a read-only command, returning stdout or "" on any failure/timeout."""
    try:
        proc = subprocess.run(
            cmd, capture_output=True, text=True, timeout=_CMD_TIMEOUT_S,
        )
        return proc.stdout or ""
    except (subprocess.TimeoutExpired, FileNotFoundError, OSError) as e:
        logger.warning("storage: command failed (%s): %s", cmd[:2], e)
        return ""


def _statvfs_safe(path: str) -> Optional[os.statvfs_result]:
    fut = _STAT_POOL.submit(os.statvfs, path)
    try:
        return fut.result(timeout=_STAT_TIMEOUT_S)
    except (concurrent.futures.TimeoutError, OSError) as e:
        logger.warning("storage: statvfs(%s) failed: %s", path, e)
        return None


# ----------------------------------------------------------- fact gatherers

def _underlying_disks(dev: str) -> Set[str]:
    """Every physical-disk kname that `dev` ultimately sits on, resolved
    through partitions, LUKS/dm, LVM and md via lsblk's inverse (slave) tree.

    NOTE: this does NOT see sibling btrfs members — btrfs multi-device
    membership is a filesystem relationship, not a block-device one. Callers
    that care about btrfs arrays expand members via `btrfs filesystem show`
    first and pass each member device here.
    """
    out = _run([_LSBLK, "-s", "-n", "-r", "-o", "NAME,TYPE", dev])
    disks: Set[str] = set()
    for line in out.splitlines():
        parts = line.split()
        if len(parts) >= 2 and parts[1] == "disk":
            disks.add(parts[0])
    return disks


def _mounted_btrfs_disks() -> Set[str]:
    """Physical disks backing any *mounted* btrfs filesystem (the root mirror
    and any existing pool). This is the check that protects a multi-device OS
    root that /proc/mounts only names one member of."""
    out = _run([_BTRFS, "filesystem", "show", "--mounted"])
    disks: Set[str] = set()
    for line in out.splitlines():
        line = line.strip()
        # "devid    1 size 3.64TiB used .. path /dev/mapper/cryptd1"
        if line.startswith("devid") and " path " in line:
            dev = line.split(" path ", 1)[1].strip()
            if dev:
                disks |= _underlying_disks(dev)
    return disks


def _os_disks() -> Set[str]:
    """Disks backing /, /boot, /boot2 (boot-critical). Belt-and-suspenders on
    top of the mounted-btrfs set (which already covers a btrfs root)."""
    disks: Set[str] = set()
    for target in ("/", "/boot", "/boot2"):
        out = _run([_FINDMNT, "-n", "-o", "SOURCE", "--target", target])
        for s in out.splitlines():
            s = s.strip()
            # btrfs SOURCE looks like "/dev/sda2[/@]" — strip the subvol suffix.
            if "[" in s:
                s = s.split("[", 1)[0]
            if s.startswith("/dev/"):
                disks |= _underlying_disks(s)
    return disks


def _swap_disks() -> Set[str]:
    disks: Set[str] = set()
    try:
        lines = Path("/proc/swaps").read_text().splitlines()[1:]
    except OSError:
        return disks
    for line in lines:
        parts = line.split()
        if parts and parts[0].startswith("/dev/"):
            disks |= _underlying_disks(parts[0])
    return disks


def _proc_mount_points() -> Set[str]:
    pts: Set[str] = set()
    try:
        for line in Path("/proc/mounts").read_text().splitlines():
            parts = line.split()
            if len(parts) >= 2:
                # /proc/mounts escapes spaces as \040 — unescape.
                pts.add(parts[1].replace("\\040", " "))
    except OSError as e:
        logger.warning("storage: could not read /proc/mounts: %s", e)
    return pts


def _lsblk_disk_nodes() -> Dict[str, Dict[str, Any]]:
    """Top-level disk nodes (with children) keyed by kname."""
    out = _run([_LSBLK, "-J", "-b", "-o",
                "NAME,KNAME,TYPE,SIZE,MOUNTPOINT,FSTYPE,LABEL,PARTTYPE"])
    try:
        blocks = json.loads(out or "{}").get("blockdevices", [])
    except json.JSONDecodeError:
        return {}
    return {(n.get("kname") or n.get("name")): n
            for n in blocks if n.get("type") == "disk"}


def _scan_node(node: Dict[str, Any]) -> Tuple[bool, bool, bool, bool, bool, Optional[str], Optional[str]]:
    """Walk a disk node + descendants. Returns
    (mounted, md_member, lvm_member, esp, has_data, existing_fstype, existing_label)."""
    state = {"mounted": False, "md": False, "lvm": False, "esp": False,
             "data": False, "fstype": None, "label": None}

    def walk(n: Dict[str, Any]) -> None:
        if n.get("mountpoint"):
            state["mounted"] = True
        if (n.get("parttype") or "").lower() == _EFI_GUID:
            state["esp"] = True
        fs = n.get("fstype") or ""
        if fs == "linux_raid_member":
            state["md"] = True
        elif fs == "LVM2_member":
            state["lvm"] = True
        elif fs:
            state["data"] = True
            if state["fstype"] is None:
                state["fstype"] = fs
                state["label"] = n.get("label")
        for c in n.get("children") or []:
            walk(c)

    walk(node)
    return (state["mounted"], state["md"], state["lvm"], state["esp"],
            state["data"], state["fstype"], state["label"])


def _has_holders(kname: str) -> bool:
    """A non-empty holders dir means some dm/md/bcache consumer sits on this
    disk even if no mountpoint or member fstype shows."""
    try:
        return any(Path(f"/sys/block/{kname}/holders").iterdir())
    except OSError:
        return False


def _by_id_map() -> Dict[str, str]:
    """kname -> preferred bare /dev/disk/by-id name. Prefer human-readable
    model_serial forms (ata-/nvme-/scsi- with a serial) over wwn-/eui. links."""
    candidates: Dict[str, List[str]] = {}
    try:
        for link in Path("/dev/disk/by-id").iterdir():
            try:
                target = os.path.realpath(link)
            except OSError:
                continue
            candidates.setdefault(os.path.basename(target), []).append(link.name)
    except OSError:
        return {}

    def rank(name: str) -> tuple:
        good = name.startswith(("ata-", "nvme-", "scsi-"))
        is_wwn = name.startswith("wwn-")
        is_eui = "eui." in name
        has_serial = "_" in name
        return (0 if good and not is_eui else (2 if is_wwn else 1),
                0 if has_serial else 1,
                -len(name))

    return {k: sorted(v, key=rank)[0] for k, v in candidates.items() if v}


# ----------------------------------------------------------- usable capacity

def _usable_bytes(profile: str, sizes: List[int]) -> int:
    if not sizes:
        return 0
    total = sum(sizes)
    if profile in ("single", "raid0"):
        return total
    if profile in ("raid1", "raid10"):
        # btrfs raid1/raid10 keep two copies. With unequal disks the usable
        # capacity is min(total/2, total - largest_disk).
        return min(total // 2, total - max(sizes))
    return total


# ----------------------------------------------------------------- resolver

class StorageResolver:

    @staticmethod
    def list_drives() -> List[Dict[str, Any]]:
        """Every non-removable drive with an eligibility verdict. Reuses
        PhysicalDrivesResolver for the SMART/model/size fields and layers the
        deny-by-default eligibility filter on top."""
        drives = PhysicalDrivesResolver.get_all()
        by_id = _by_id_map()
        nodes = _lsblk_disk_nodes()
        os_disks = _os_disks()
        btrfs_disks = _mounted_btrfs_disks()
        swap_disks = _swap_disks()

        out: List[Dict[str, Any]] = []
        for d in drives:
            name = os.path.basename(d.get("device", ""))
            node = nodes.get(name)
            mounted, md, lvm, esp, has_data, fstype, label = (
                _scan_node(node) if node else (False, False, False, False, False, None, None))

            # `overridable` marks a SOFT block: the disk isn't load-bearing for
            # the running system, but looks risky, so it's hidden by default and
            # the owner can opt in with explicit confirmation. Hard blocks (OS
            # disk, mounted, active RAID/swap/btrfs) are never overridable.
            eligible, reason, overridable = True, None, False
            if name in os_disks:
                eligible, reason = False, "OS / boot disk"
            elif name in btrfs_disks:
                eligible, reason = False, "in use by an existing btrfs filesystem"
            elif mounted:
                eligible, reason = False, "mounted (in use)"
            elif name in swap_disks:
                eligible, reason = False, "backs swap"
            elif esp:
                # Inactive ESP — a degraded-mirror boot disk or a previous
                # install. The ACTIVE boot disk is already caught above as
                # "OS / boot disk", so anything reaching here is not in the
                # running boot path. Soft block: overridable with confirmation.
                eligible, reason, overridable = (
                    False, "holds an EFI System Partition (may be a boot disk)", True)
            elif md:
                eligible, reason = False, "member of an mdadm RAID array"
            elif lvm:
                eligible, reason = False, "LVM physical volume"
            elif _has_holders(name):
                eligible, reason = False, "in use by another device"

            row = dict(d)
            row["name"] = name
            row["by_id"] = by_id.get(name)
            # A disk we can't address by a stable by-id link can't be safely
            # recorded as a member, so it is neither eligible nor overridable.
            if not row["by_id"]:
                if eligible:
                    eligible, reason = False, "no stable /dev/disk/by-id link"
                overridable = False
            row["eligible"] = eligible
            row["ineligible_reason"] = reason
            row["overridable"] = overridable
            row["has_existing_data"] = bool(has_data)
            row["existing_fstype"] = fstype
            row["existing_label"] = label
            out.append(row)
        return out

    @staticmethod
    def list_pools() -> List[Dict[str, Any]]:
        """Recorded pools (homefree-config.json) plus live runtime status."""
        try:
            cfg = ConfigReader.read_config()
        except Exception as e:  # noqa: BLE001
            logger.warning("storage: could not read config: %s", e)
            cfg = {}
        pools = ((cfg.get("storage") or {}).get("pools")) or []
        mount_points = _proc_mount_points()

        out: List[Dict[str, Any]] = []
        for p in pools:
            mp = p.get("mountpoint")
            uuid = p.get("fs-uuid")
            mounted = bool(mp) and mp in mount_points
            present = bool(uuid) and Path(f"/dev/disk/by-uuid/{uuid}").exists()
            used = total = None
            if mounted and mp:
                st = _statvfs_safe(mp)
                if st:
                    total = st.f_blocks * st.f_frsize
                    used = (st.f_blocks - st.f_bfree) * st.f_frsize
            row = dict(p)
            row["runtime"] = {
                "mounted": mounted, "present": present,
                "used_bytes": used, "total_bytes": total,
            }
            out.append(row)
        return out

    @staticmethod
    def preview_pool(members: List[str], profile: str) -> Dict[str, Any]:
        """Usable-size estimate + warnings for a proposed pool. Sizes come from
        the live eligible-drive list keyed by by-id."""
        if profile not in PROFILE_MIN_MEMBERS:
            raise HTTPException(status_code=400, detail=f"Unsupported profile: {profile}")

        drives = {d.get("by_id"): d for d in StorageResolver.list_drives() if d.get("by_id")}
        sizes: List[int] = []
        warnings: List[str] = []
        for m in members:
            d = drives.get(m)
            if not d:
                warnings.append(f"Unknown drive: {m}")
                continue
            sizes.append(int(d.get("size_bytes") or 0))
            if (d.get("transport") or "") == "usb":
                warnings.append(f"{m} is USB-attached — not recommended for a RAID volume.")
            if d.get("has_existing_data"):
                warnings.append(
                    f"{m} contains existing data "
                    f"({d.get('existing_fstype') or 'unknown'}) — it will be erased.")

        need = PROFILE_MIN_MEMBERS[profile]
        if len(sizes) < need:
            warnings.append(f"{profile} needs at least {need} drives; {len(sizes)} selected.")
        if profile == "raid10" and len(sizes) % 2:
            warnings.append("raid10 needs an even number of drives.")
        if profile in ("raid0", "raid1", "raid10") and len(set(sizes)) > 1:
            warnings.append(
                "Mixed drive sizes — usable capacity is limited by the layout; "
                "some space on the larger drive(s) may be unused.")

        return {
            "profile": profile,
            "member_count": len(sizes),
            "raw_bytes": sum(sizes),
            "usable_bytes": _usable_bytes(profile, sizes),
            "warnings": warnings,
        }


# ------------------------------------------------------------------- routes
# All /api/storage/* routes fall through to the admin-role gate in
# TrustedHeaderAuthMiddleware (not in PUBLIC_PATHS / self-service), so these
# are admin-only — important, since the create endpoints (added in the
# pool-create service step) wipe disks.

class PreviewRequest(BaseModel):
    members: List[str]
    profile: str


@router.get("/drives")
async def get_drives() -> Dict[str, Any]:
    return {"drives": await asyncio.to_thread(StorageResolver.list_drives)}


@router.get("/pools")
async def get_pools() -> Dict[str, Any]:
    return {"pools": await asyncio.to_thread(StorageResolver.list_pools)}


@router.post("/preview")
async def post_preview(req: PreviewRequest) -> Dict[str, Any]:
    return await asyncio.to_thread(StorageResolver.preview_pool, req.members, req.profile)


# --- create / forget (delegated to services.storage_pool) -----------------
# These imports are done lazily inside the handlers to avoid a circular import:
# services.storage_pool imports StorageResolver + helpers from this module, and
# this module is fully loaded before any route runs.

class CreateRequest(BaseModel):
    name: str
    mountpoint: str
    profile: str
    members: List[str]
    encrypted: bool = False
    # Opt-in to use soft-blocked drives (e.g. an inactive EFI partition). Hard
    # blocks (OS disk, mounted, active RAID/swap) are rejected regardless.
    force: bool = False


class ForgetRequest(BaseModel):
    name: str


@router.post("/pools/create")
async def post_create(req: CreateRequest) -> Dict[str, Any]:
    from services.storage_pool import StoragePoolService, StoragePoolBusy
    payload = {
        "name": req.name, "mountpoint": req.mountpoint, "profile": req.profile,
        "members": req.members, "encrypted": req.encrypted, "force": req.force,
    }
    # Shape validation up front so the client gets a 400 before any disk work.
    errs = await asyncio.to_thread(StoragePoolService.validate_request, payload)
    if errs:
        raise HTTPException(status_code=400, detail="; ".join(errs))
    try:
        started = StoragePoolService.start(payload)
    except StoragePoolBusy as e:
        raise HTTPException(status_code=409, detail=str(e))
    if not started:
        raise HTTPException(status_code=409, detail="A volume operation is already running.")
    return {"started": True}


@router.get("/pools/create-status")
async def get_create_status() -> Dict[str, Any]:
    from services.storage_pool import StoragePoolService
    return StoragePoolService.get_status()


@router.post("/pools/forget")
async def post_forget(req: ForgetRequest) -> Dict[str, Any]:
    from services.storage_pool import StoragePoolService
    ok = await asyncio.to_thread(StoragePoolService.forget, req.name)
    if not ok:
        raise HTTPException(status_code=500, detail="Failed to update configuration.")
    return {"ok": True}
