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
import pwd
import re
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

# Supported profiles and the minimum member count each requires. single/raid0/
# raid1/raid10 are btrfs-native; raid5/raid6 are btrfs-on-mdadm parity.
PROFILE_MIN_MEMBERS: Dict[str, int] = {
    "single": 1, "raid0": 2, "raid1": 2, "raid10": 4, "raid5": 3, "raid6": 4,
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
_PVS = _resolve_bin("pvs")
_BLKID = _resolve_bin("blkid")

# Same constraint `StoragePoolService._NAME_RE` enforces; duplicated here to
# avoid the resolver depending on the service layer (one-way dep).
_NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_-]{0,31}$")


def _fs_present(fs_uuid: Optional[str]) -> bool:
    """Whether the filesystem with this UUID is actually available — NOT merely
    whether a /dev/disk/by-uuid symlink happens to exist (udev doesn't reliably
    create that for md arrays). Falls back to blkid, which probes by UUID."""
    if not fs_uuid:
        return False
    if Path(f"/dev/disk/by-uuid/{fs_uuid}").exists():
        return True
    return bool(_run([_BLKID, "-U", fs_uuid]).strip())


def _fs_uuid_of(dev: str) -> str:
    """UUID of the filesystem on <dev> via blkid. Empty on failure."""
    if not dev:
        return ""
    return _run([_BLKID, "-o", "value", "-s", "UUID", dev]).strip()


def _resolve_mount_spec(spec: str) -> str:
    """Normalize an fstab-style mount source to a real path. `UUID=…` and
    `LABEL=…` are valid in /etc/fstab and round-trip through `homefree.mounts`
    that way too, so a literal path check (`os.path.exists`) on the raw spec
    rejects them. Returns the resolved /dev path or '' if it can't be resolved."""
    if not spec:
        return ""
    if spec.startswith("UUID="):
        p = f"/dev/disk/by-uuid/{spec[5:]}"
        return p if os.path.exists(p) else ""
    if spec.startswith("LABEL="):
        p = f"/dev/disk/by-label/{spec[6:]}"
        return p if os.path.exists(p) else ""
    if spec.startswith("PARTUUID="):
        p = f"/dev/disk/by-partuuid/{spec[9:]}"
        return p if os.path.exists(p) else ""
    return spec if os.path.exists(spec) else ""


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


# ------------------------------------------------------- reclaim detection
# Generic teardown of in-use storage so a hard-blocked disk can be wiped back to
# eligible. Everything here is class-level block-layer fact (mdstat / pvs /
# lsblk) — no vendor- or instance-specific assumptions (AGENTS.md rule 1).

def _md_member_map() -> Dict[str, Dict[str, Any]]:
    """Parse /proc/mdstat → {md_kname: {"members": [member part knames],
    "level": str}} for every currently-ASSEMBLED array. Best-effort."""
    try:
        lines = Path("/proc/mdstat").read_text().splitlines()
    except OSError:
        return {}
    arrays: Dict[str, Dict[str, Any]] = {}
    for line in lines:
        # "md127 : active (read-only) raid6 sde5[0] sdb5[3] sdc5[2] sdd5[1]"
        if " : " not in line:
            continue
        head, rest = line.split(" : ", 1)
        md = head.strip()
        if not md.startswith("md"):
            continue
        toks = rest.split()
        level = next((t for t in toks
                      if t.startswith("raid") or t in ("linear", "multipath")), "")
        members = [m.group(1) for m in
                   (re.match(r"^([A-Za-z0-9]+)\[\d+\]", t) for t in toks) if m]
        arrays[md] = {"members": members, "level": level}
    return arrays


def _pv_vg_map() -> Dict[str, str]:
    """{pv_path: vg_name} from `pvs`. Empty when LVM tooling is absent or there
    are no PVs (a PV with no VG maps to "")."""
    out = _run([_PVS, "--noheadings", "-o", "pv_name,vg_name"])
    mp: Dict[str, str] = {}
    for line in out.splitlines():
        parts = line.split()
        # Skip any non-device noise (e.g. pvs WARNING lines on an old PV header).
        if parts and parts[0].startswith("/dev/"):
            mp[parts[0]] = parts[1] if len(parts) >= 2 else ""
    return mp


def _reclaim_groups() -> List[Dict[str, Any]]:
    """Teardownable storage groups on this box. Each group is wiped as a unit
    (an array/VG spans several disks): an assembled md array (+ any LVM VGs
    layered on it + its member disks), then any standalone LVM-PV disk. The
    create wizard then treats the freed disks as blank."""
    arrays = _md_member_map()
    pv_vg = _pv_vg_map()
    groups: List[Dict[str, Any]] = []
    claimed: Set[str] = set()

    # md arrays first; fold in VGs whose PV is the array device so they are
    # deactivated before the array is stopped.
    for md, info in arrays.items():
        disks: Set[str] = set()
        for part in info["members"]:
            disks |= _underlying_disks(f"/dev/{part}")
        vgs = sorted({vg for pv, vg in pv_vg.items() if vg
                      and os.path.basename(os.path.realpath(pv)) == md})
        level = (info["level"] or "raid").upper()
        desc = f"{level} array /dev/{md} across {len(disks)} drive(s)"
        if vgs:
            desc += f", with LVM group {', '.join(vgs)}"
        groups.append({
            "id": f"md:{md}", "kind": "mdadm", "arrays": [f"/dev/{md}"],
            "vgs": vgs, "disks": sorted(disks), "description": desc,
        })
        claimed |= disks

    # Standalone LVM PVs sitting directly on a disk/partition (not on md).
    for pv, vg in pv_vg.items():
        if not vg or os.path.basename(os.path.realpath(pv)).startswith("md"):
            continue
        disks = _underlying_disks(pv) - claimed
        if not disks:
            continue
        groups.append({
            "id": f"lvm:{vg}", "kind": "lvm", "arrays": [], "vgs": [vg],
            "disks": sorted(disks),
            "description": f"LVM group {vg} on {len(disks)} drive(s)",
        })
        claimed |= disks

    return groups


def _proc_comm(pid: str) -> str:
    try:
        return Path(f"/proc/{pid}/comm").read_text().strip() or pid
    except OSError:
        return pid


def _proc_user(pid: str) -> str:
    try:
        return pwd.getpwuid(os.stat(f"/proc/{pid}").st_uid).pw_name
    except (OSError, KeyError):
        return ""


def _blockers_for_mountpoints(mountpoints: Set[str], limit_per: int = 12
                              ) -> Dict[str, List[Dict[str, Any]]]:
    """For each mountpoint, the processes keeping it busy — a cwd/root/exe or an
    open fd under it — which is why an unmount (and thus a reclaim) is blocked.
    Pure /proc scan, no lsof dependency; one pass covers all mountpoints. Only
    called when a reclaimable array is still mounted, so the cost is rare.
    Best-effort, never raises."""
    targets = [(os.path.realpath(m), os.path.realpath(m).rstrip("/") + "/", m)
               for m in mountpoints]
    result: Dict[str, List[Dict[str, Any]]] = {m: [] for m in mountpoints}
    if not targets:
        return result
    try:
        pids = [p for p in os.listdir("/proc") if p.isdigit()]
    except OSError:
        return result
    for pid in pids:
        base = f"/proc/{pid}"
        links: List[str] = []
        for ln in ("cwd", "root", "exe"):
            try:
                links.append(os.readlink(f"{base}/{ln}"))
            except OSError:
                pass
        try:
            for fd in os.listdir(f"{base}/fd"):
                try:
                    links.append(os.readlink(f"{base}/fd/{fd}"))
                except OSError:
                    pass
        except OSError:
            pass
        matched = None
        for tgt in links:
            for real, prefix, orig in targets:
                if tgt == real or tgt.startswith(prefix):
                    matched = orig
                    break
            if matched:
                break
        if matched and len(result[matched]) < limit_per:
            result[matched].append(
                {"pid": int(pid), "command": _proc_comm(pid), "user": _proc_user(pid)})
    return result


def _dev_size_bytes(dev: str) -> Optional[int]:
    """Size of a block device in bytes via /sys, or None."""
    try:
        name = os.path.basename(os.path.realpath(dev))
        return int(Path(f"/sys/class/block/{name}/size").read_text().strip()) * 512
    except (OSError, ValueError):
        return None


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
    if profile in ("raid5", "raid6"):
        # md parity: capacity is (N - parity) × the SMALLEST member (md sizes
        # every member to the smallest), so 1 disk (raid5) / 2 disks (raid6)
        # worth of space goes to parity.
        parity = 1 if profile == "raid5" else 2
        if len(sizes) <= parity:
            return 0
        return (len(sizes) - parity) * min(sizes)
    return total


def _md_status(md_kname: Optional[str]) -> Optional[Dict[str, Any]]:
    """Live status of the kernel md device <md_kname> (e.g. "md127") parsed
    from /proc/mdstat. Returns {state, degraded, resync, resync_pct} or None.
    Best-effort, never raises. The caller resolves md_kname from the pool's
    btrfs UUID (stable across reboots), not the flaky /dev/md/<name> symlink."""
    if not md_kname:
        return None
    try:
        lines = Path("/proc/mdstat").read_text().splitlines()
    except OSError:
        return None
    for i, line in enumerate(lines):
        if not (line.startswith(md_kname + " ") or line.startswith(md_kname + ":")):
            continue
        # Header: "md127 : active raid6 sde[0] sdf[1] ...". The detail + any
        # progress line follow on the next 1–3 lines (until a blank line).
        block = "\n".join(lines[i:i + 4])
        active = "active" in line.split()
        mmap = re.search(r"\[([U_]+)\]", block)
        degraded = bool(mmap and "_" in mmap.group(1))
        pm = re.search(r"(resync|recovery|reshape|check)\s*=\s*([\d.]+)%", block)
        resync = pm.group(1) if pm else None
        pct = None
        if pm:
            try:
                pct = float(pm.group(2))
            except ValueError:
                pct = None
        if resync:
            state = "resyncing"
        elif degraded:
            state = "degraded"
        elif active:
            state = "active"
        else:
            state = "inactive"
        return {"state": state, "degraded": degraded,
                "resync": resync, "resync_pct": pct}
    return None


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

        # Teardownable structures, indexed by member disk, so a hard-blocked
        # drive can offer a group-scoped "reclaim".
        disk_to_group: Dict[str, Dict[str, Any]] = {}
        for g in _reclaim_groups():
            for dk in g["disks"]:
                disk_to_group.setdefault(dk, g)

        # Mountpoints backed by each disk. A reclaimable array that is still
        # mounted can't be reclaimed until it's unmounted, so we surface where
        # it's mounted and (only then) which processes hold it busy.
        disk_mounts: Dict[str, List[str]] = {}
        try:
            for line in Path("/proc/mounts").read_text().splitlines():
                parts = line.split()
                if len(parts) >= 2 and parts[0].startswith("/dev/"):
                    mp = parts[1].replace("\\040", " ")
                    for dk in _underlying_disks(parts[0]):
                        disk_mounts.setdefault(dk, [])
                        if mp not in disk_mounts[dk]:
                            disk_mounts[dk].append(mp)
        except OSError:
            pass
        blocked_mps = {mp for dk, mps in disk_mounts.items()
                       if dk in disk_to_group for mp in mps}
        blockers_by_mp = _blockers_for_mountpoints(blocked_mps) if blocked_mps else {}

        # All unmanaged btrfs filesystems on this box (mounted or not, single
        # or multi-drive). Indexed by member kname so each drive row carries a
        # `promotable_btrfs` hint — the UI uses it both to render an inline
        # "Promote to volume…" button on single-drive rows and to group the
        # members of a multi-drive set under one set-box header.
        disk_to_promotable_btrfs: Dict[str, Dict[str, Any]] = {}
        for rec in StorageResolver.list_promotable_btrfs():
            hint = {
                "fs_uuid": rec["fs_uuid"],
                "label": rec.get("label") or "",
                "profile": rec["profile"],
                "member_count": len(rec.get("member_knames") or []),
                "size_bytes": rec.get("size_bytes") or 0,
                "mount_point": rec.get("mount_point") or "",
                "suggested_name": rec["suggested_name"],
                "suggested_mountpoint": rec["suggested_mountpoint"],
            }
            for dk in rec.get("member_knames", []):
                disk_to_promotable_btrfs.setdefault(dk, hint)

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

            # Reclaim: a disk that belongs to a teardownable structure (md/LVM)
            # can be wiped back to Available — but only once nothing is mounted on
            # it. NEVER offered for os/swap disks. When it IS still mounted we
            # withhold Reclaim (can't wipe a live filesystem) and instead set
            # `reclaim_blocked` so the UI can explain why and surface what's
            # holding the mount. A plain mounted btrfs that is NOT on an md/LVM
            # group (e.g. an ordinary data disk) is not in disk_to_group and sets
            # no md/lvm flag, so it stays simply "in use" — never reclaimable.
            reclaim = None
            reclaim_blocked = None
            grp = disk_to_group.get(name)
            if (not eligible and row["by_id"]
                    and name not in os_disks and name not in swap_disks
                    and (grp or md or lvm)):
                g = grp or {
                    "id": f"disk:{name}", "kind": "stale", "arrays": [],
                    "vgs": [], "disks": [name],
                    "description": "leftover RAID/LVM signature",
                }
                if (name in btrfs_disks) or mounted:
                    blk: List[Dict[str, Any]] = []
                    seen_pids = set()
                    for mp in disk_mounts.get(name, []):
                        for b in blockers_by_mp.get(mp, []):
                            if b["pid"] not in seen_pids:
                                seen_pids.add(b["pid"])
                                blk.append(b)
                    reclaim_blocked = {
                        "description": g["description"],
                        "mountpoints": disk_mounts.get(name, []),
                        "blockers": blk,
                    }
                else:
                    reclaim = {
                        "id": g["id"], "kind": g["kind"], "arrays": g["arrays"],
                        "vgs": g["vgs"], "description": g["description"],
                        "member_knames": g["disks"],
                        "member_ids": [by_id[dk] for dk in g["disks"] if by_id.get(dk)],
                    }
            row["reclaimable"] = reclaim is not None
            row["reclaim"] = reclaim
            row["reclaim_blocked"] = reclaim_blocked
            row["promotable_btrfs"] = disk_to_promotable_btrfs.get(name)
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
            # If it's mounted it is obviously present; otherwise probe by UUID
            # (not just the by-uuid symlink, which udev may never create for md).
            present = mounted or _fs_present(uuid)
            used = total = None
            if mounted and mp:
                st = _statvfs_safe(mp)
                if st:
                    total = st.f_blocks * st.f_frsize
                    used = (st.f_blocks - st.f_bfree) * st.f_frsize
            row = dict(p)
            runtime = {
                "mounted": mounted, "present": present,
                "used_bytes": used, "total_bytes": total,
            }
            # Parity volumes carry an md array — surface its assembly / sync /
            # degraded state. Resolve the live kernel md device via the btrfs
            # UUID (stable; the /dev/md/<name> symlink may not exist), then read
            # /proc/mdstat for it.
            if p.get("profile") in ("raid5", "raid6") and uuid:
                real = os.path.realpath(f"/dev/disk/by-uuid/{uuid}")
                base = os.path.basename(real)
                md = _md_status(base if base.startswith("md") else None)
                if md is not None:
                    runtime["md"] = md
            row["runtime"] = runtime
            out.append(row)
        return out

    @staticmethod
    def list_importable() -> List[Dict[str, Any]]:
        """Existing btrfs filesystems that can be re-attached WITHOUT
        reformatting: not recorded in storage.pools, not the OS, not mounted —
        e.g. a Removed/forgotten volume, or drives moved from another box.
        Limited to md-backed (raid level known from /proc/mdstat) and
        single-device btrfs; a native multi-device layout can't be determined
        offline, so it's skipped (recreate or mount it manually instead)."""
        try:
            cfg = ConfigReader.read_config()
        except Exception:  # noqa: BLE001
            cfg = {}
        recorded = {p.get("fs-uuid")
                    for p in ((cfg.get("storage") or {}).get("pools") or [])}
        by_id = _by_id_map()
        arrays = _md_member_map()

        # Disks we must never offer to import onto: OS/boot, anything backing a
        # mounted btrfs (root mirror, other data fs), swap, or a disk holding an
        # EFI System Partition (a boot-mirror disk whose ESP/root isn't currently
        # mounted — `os_disks` alone misses it). Mirrors the create-flow blocks.
        nodes = _lsblk_disk_nodes()
        esp_disks = {k for k, n in nodes.items() if _scan_node(n)[3]}
        protected = (_os_disks() | _mounted_btrfs_disks() | _swap_disks() | esp_disks)

        mounted_real: Set[str] = set()
        try:
            for line in Path("/proc/mounts").read_text().splitlines():
                parts = line.split()
                if parts and parts[0].startswith("/dev/"):
                    mounted_real.add(os.path.realpath(parts[0]))
        except OSError:
            pass

        # Parse `btrfs filesystem show` into {label, uuid, devices[]}.
        blocks: List[Dict[str, Any]] = []
        cur: Optional[Dict[str, Any]] = None
        for line in _run([_BTRFS, "filesystem", "show"]).splitlines():
            s = line.strip()
            if s.startswith("Label:"):
                m = re.search(r"Label:\s+(?:'([^']*)'|none)\s+uuid:\s+(\S+)", s)
                if m:
                    cur = {"label": m.group(1) or "", "uuid": m.group(2), "devices": []}
                    blocks.append(cur)
            elif cur is not None and s.startswith("devid") and " path " in s:
                cur["devices"].append(s.split(" path ", 1)[1].strip())

        out: List[Dict[str, Any]] = []
        for b in blocks:
            uuid, devs = b["uuid"], b["devices"]
            if not uuid or not devs or uuid in recorded:
                continue
            if any(os.path.realpath(d) in mounted_real for d in devs):
                continue
            md_dev = next((os.path.basename(d) for d in devs
                           if os.path.basename(d).startswith("md")), None)
            if md_dev:
                info = arrays.get(md_dev) or {}
                members: Set[str] = set()
                for part in info.get("members", []):
                    members |= _underlying_disks(f"/dev/{part}")
                level = (info.get("level") or "").lower()
                profile = level if level in (
                    "raid0", "raid1", "raid10", "raid5", "raid6") else "raid6"
                md_device = md_dev
            else:
                members = set()
                for d in devs:
                    members |= _underlying_disks(d)
                if len(members) != 1:
                    continue  # native multi-device: layout unknown offline
                profile, md_device = "single", ""
            if members & protected:
                continue
            member_ids = [by_id[k] for k in sorted(members) if by_id.get(k)]
            if not member_ids or len(member_ids) != len(members):
                continue  # need a stable by-id for every member
            out.append({
                "fs_uuid": uuid,
                "label": b["label"],
                "profile": profile,
                "members": member_ids,
                "md_device": md_device,
                "device": devs[0],          # backing device, for the udev re-probe
                "size_bytes": _dev_size_bytes(devs[0]),
            })
        return out

    @staticmethod
    def list_promotable_btrfs() -> List[Dict[str, Any]]:
        """All btrfs filesystems on this box that could be moved into
        `homefree.storage.pools` as managed volumes — mounted (via
        `homefree.mounts`) or not, single-device or md-backed.

        Skipped cases:
        - filesystems already recorded in `storage.pools` (would duplicate);
        - filesystems whose members touch OS / swap / ESP / a *different*
          mounted btrfs (same protections `list_importable` enforces);
        - filesystems that ARE mounted but **not** via `homefree.mounts`
          (a hand-rolled fstab or sysadmin mount — out of scope; the
          promotion would have to evict whatever owns it);
        - native multi-device btrfs (profile unknowable offline — same
          restriction as `list_importable`); md-backed is fine because the
          raid level is in `/proc/mdstat`."""
        try:
            cfg = ConfigReader.read_config()
        except Exception:  # noqa: BLE001
            cfg = {}
        recorded_uuids = {p.get("fs-uuid")
                          for p in ((cfg.get("storage") or {}).get("pools") or [])}
        hf_mounts = cfg.get("mounts") or []

        # Index `homefree.mounts` by the fs-uuid each row resolves to, so we
        # can identify "mounted via HomeFree" in O(1) per candidate. Resolve
        # `UUID=…`/`LABEL=…`/path uniformly via the shared helper, then read
        # the fs-uuid from the spec or via blkid as a fallback.
        hf_mp_by_uuid: Dict[str, str] = {}
        for m in hf_mounts:
            if (m.get("fs-type") or "").lower() != "btrfs":
                continue
            mp = m.get("mount-point") or ""
            dev = m.get("device") or ""
            if not mp:
                continue
            u = ""
            if dev.startswith("UUID="):
                u = dev[5:]
            elif dev.startswith("/dev/disk/by-uuid/"):
                u = dev.rsplit("/", 1)[-1]
            if not u:
                resolved = _resolve_mount_spec(dev)
                if resolved:
                    u = _fs_uuid_of(os.path.realpath(resolved))
            if u:
                hf_mp_by_uuid.setdefault(u, mp)

        by_id = _by_id_map()
        arrays = _md_member_map()

        # Same protected-disks set `list_importable` uses: OS/boot, swap,
        # any drive backing an ESP, and (importantly) the running root
        # mirror's members are caught by `_mounted_btrfs_disks()` once we
        # exclude the candidate's own devices from it below.
        nodes = _lsblk_disk_nodes()
        esp_disks = {k for k, n in nodes.items() if _scan_node(n)[3]}
        all_mounted_btrfs_disks = _mounted_btrfs_disks()

        # Every /dev path currently in /proc/mounts → real path, plus a
        # mount-point lookup by realpath. Lets us both detect "this fs is
        # mounted somehow" AND recover the actual mount-point for an fs
        # that's mounted outside `homefree.mounts` (e.g. leftover fstab
        # entry or a previous-deployment systemd mount unit that survived
        # a Forget without an Apply). Those are now promote-eligible too.
        mounted_real: Set[str] = set()
        proc_mp_by_real: Dict[str, str] = {}
        try:
            for line in Path("/proc/mounts").read_text().splitlines():
                parts = line.split()
                if not parts or not parts[0].startswith("/dev/"):
                    continue
                real = os.path.realpath(parts[0])
                mounted_real.add(real)
                mp = parts[1].replace("\\040", " ") if len(parts) >= 2 else ""
                if mp and real not in proc_mp_by_real:
                    proc_mp_by_real[real] = mp
        except OSError:
            pass

        # Parse `btrfs filesystem show` → [{label, uuid, devices[]}] (same
        # parse as `list_importable`).
        blocks: List[Dict[str, Any]] = []
        cur: Optional[Dict[str, Any]] = None
        for line in _run([_BTRFS, "filesystem", "show"]).splitlines():
            s = line.strip()
            if s.startswith("Label:"):
                m_re = re.search(r"Label:\s+(?:'([^']*)'|none)\s+uuid:\s+(\S+)", s)
                if m_re:
                    cur = {"label": m_re.group(1) or "", "uuid": m_re.group(2), "devices": []}
                    blocks.append(cur)
            elif cur is not None and s.startswith("devid") and " path " in s:
                cur["devices"].append(s.split(" path ", 1)[1].strip())

        out: List[Dict[str, Any]] = []
        for b in blocks:
            fs_uuid, devs = b["uuid"], b["devices"]
            if not fs_uuid or not devs or fs_uuid in recorded_uuids:
                continue

            # Member resolution + profile (mirrors `list_importable`).
            md_dev = next((os.path.basename(d) for d in devs
                           if os.path.basename(d).startswith("md")), None)
            if md_dev:
                info = arrays.get(md_dev) or {}
                member_knames: Set[str] = set()
                for part in info.get("members", []):
                    member_knames |= _underlying_disks(f"/dev/{part}")
                level = (info.get("level") or "").lower()
                profile = level if level in (
                    "raid0", "raid1", "raid10", "raid5", "raid6") else "raid6"
                md_device = md_dev
            else:
                member_knames = set()
                for d in devs:
                    member_knames |= _underlying_disks(d)
                if len(member_knames) != 1:
                    continue   # multi-device native: layout unknown offline
                profile, md_device = "single", ""

            # Exclude this candidate's own members from the mounted-btrfs set
            # before treating it as a "protected disk" — otherwise a mounted
            # candidate would always reject itself.
            protected = (_os_disks() | _swap_disks() | esp_disks
                         | (all_mounted_btrfs_disks - member_knames))
            if member_knames & protected:
                continue
            member_ids = [by_id[k] for k in sorted(member_knames) if by_id.get(k)]
            if not member_ids or len(member_ids) != len(member_knames):
                continue

            # Mount state has three flavors:
            #   1. not mounted          → `mount_point` empty; user picks one
            #      in the Promote modal.
            #   2. mounted via HomeFree → `mount_point` from hf_mp_by_uuid;
            #      modal shows the path read-only.
            #   3. mounted outside HomeFree (leftover fstab/systemd mount, a
            #      previous-deployment unit still alive after a Forget) →
            #      `mount_point` recovered from /proc/mounts so the user can
            #      re-adopt it. Treated like (2) for the Promote flow: the
            #      pool record is added with the same mount-point and the
            #      filesystem stays mounted.
            is_mounted = any(os.path.realpath(d) in mounted_real for d in devs)
            mount_point = hf_mp_by_uuid.get(fs_uuid, "")
            if is_mounted and not mount_point:
                for d in devs:
                    real = os.path.realpath(d)
                    mp = proc_mp_by_real.get(real)
                    if mp:
                        mount_point = mp
                        break

            label = (b.get("label") or "").strip()
            if mount_point:
                suggested_name = mount_point.rstrip("/").rsplit("/", 1)[-1] or "volume"
            elif _NAME_RE.match(label):
                suggested_name = label
            else:
                suggested_name = f"btrfs-{fs_uuid[:8]}"
            suggested_mountpoint = mount_point or f"/mnt/{suggested_name}"

            out.append({
                "fs_uuid": fs_uuid,
                "label": label,
                "profile": profile,
                "members": member_ids,
                "member_knames": sorted(member_knames),
                "md_device": md_device,
                "device": devs[0],                        # backing device for udev re-probe
                "size_bytes": _dev_size_bytes(devs[0]),
                "mount_point": mount_point,               # "" if unmounted
                "suggested_name": suggested_name,
                "suggested_mountpoint": suggested_mountpoint,
            })
        return out

    @staticmethod
    def list_mounts() -> List[Dict[str, Any]]:
        """Every `homefree.mounts` row paired with live runtime — same idea as
        `list_pools`, so the Disk Mounts UI can render each entry as a
        Volume-style card (badge + usage bar) instead of a flat table.

        Each row gets:
        - `device_real`:  the realpath the spec resolves to (e.g. `/dev/sda1`
          for `UUID=…`); empty when the device isn't currently visible.
        - `disk_by_ids`:  the *whole-disk* by-id link(s) underlying the device
          (e.g. `ata-…`) for a stable, human-readable footer line.
        - `runtime`:      `{ mounted, used_bytes, total_bytes }` — `mounted`
          comes from `/proc/mounts`, `used/total` from statvfs (mounted only).
        Network mounts (nfs/cifs/…) get `runtime.mounted` but no size — a
        statvfs on a remote share would hang if the server's gone."""
        try:
            cfg = ConfigReader.read_config()
        except Exception:  # noqa: BLE001
            cfg = {}
        mounts = cfg.get("mounts") or []
        # Filesystems already represented as managed pools — skip the
        # `homefree.mounts` row in that case so the unified Volumes UI doesn't
        # render the same filesystem twice. Defensive: a well-behaved config
        # never has both, but a hand-edited file can.
        pool_uuids = {p.get("fs-uuid")
                      for p in ((cfg.get("storage") or {}).get("pools") or [])
                      if p.get("fs-uuid")}
        proc_mp = _proc_mount_points()
        by_id = _by_id_map()

        out: List[Dict[str, Any]] = []
        for m in mounts:
            mp = (m.get("mount-point") or "").strip()
            spec = (m.get("device") or "").strip()
            fstype = (m.get("fs-type") or "").lower()

            real = ""
            disk_by_ids: List[str] = []
            resolved = _resolve_mount_spec(spec)
            if resolved:
                try:
                    real = os.path.realpath(resolved)
                except OSError:
                    real = ""
            if real and real.startswith("/dev/"):
                disk_knames = _underlying_disks(real)
                disk_by_ids = [by_id[k] for k in sorted(disk_knames) if by_id.get(k)]

            # fs-uuid resolution: spec wins (UUID= / by-uuid path) → blkid on
            # the resolved real device → empty. Exposed on the row so the UI
            # doesn't have to redo this work for the Promote affordance.
            fs_uuid = ""
            if spec.startswith("UUID="):
                fs_uuid = spec[5:]
            elif spec.startswith("/dev/disk/by-uuid/"):
                fs_uuid = spec.rsplit("/", 1)[-1]
            elif real:
                fs_uuid = _fs_uuid_of(real)

            # Dedup against managed pools.
            if fs_uuid and fs_uuid in pool_uuids:
                continue

            mounted = bool(mp) and mp in proc_mp
            # Don't statvfs network mounts — a hung NFS server would block.
            local = fstype not in ("nfs", "nfs4", "cifs", "smb", "smbfs", "sshfs")
            used = total = None
            if mounted and mp and local:
                st = _statvfs_safe(mp)
                if st:
                    total = st.f_blocks * st.f_frsize
                    used = (st.f_blocks - st.f_bfree) * st.f_frsize

            row = dict(m)
            row["device_real"] = real
            row["disk_by_ids"] = disk_by_ids
            row["fs_uuid"] = fs_uuid
            row["runtime"] = {
                "mounted": mounted,
                "used_bytes": used,
                "total_bytes": total,
            }
            out.append(row)
        return out

    @staticmethod
    def list_system_volumes() -> List[Dict[str, Any]]:
        """Read-only `/` mount info for the unified Volumes UI's "System"
        card. Returns a list (length 0 or 1) so the frontend's items-array
        rendering stays uniform with pools and mounts. Only `/` is
        surfaced: same-fs subvolume mounts (e.g. `/nix/store` on the same
        btrfs filesystem under `@nix`) would double-count usage, and
        `/boot` is too small to merit its own card. Future work can
        broaden if needed."""
        by_id = _by_id_map()
        try:
            for line in Path("/proc/mounts").read_text().splitlines():
                parts = line.split()
                if len(parts) < 3:
                    continue
                dev_spec = parts[0]
                mp = parts[1].replace("\\040", " ")
                fstype = parts[2]
                if mp != "/" or not dev_spec.startswith("/dev/"):
                    continue
                try:
                    real = os.path.realpath(dev_spec)
                except OSError:
                    real = ""
                disks = _underlying_disks(real) if real else set()
                disk_by_ids = [by_id[k] for k in sorted(disks) if by_id.get(k)]
                st = _statvfs_safe(mp)
                used = total = None
                if st:
                    total = st.f_blocks * st.f_frsize
                    used = (st.f_blocks - st.f_bfree) * st.f_frsize
                return [{
                    "mount-point": mp,
                    "device": dev_spec,
                    "fs-type": fstype,
                    "device_real": real,
                    "disk_by_ids": disk_by_ids,
                    "runtime": {
                        "mounted": True,
                        "used_bytes": used,
                        "total_bytes": total,
                    },
                }]
        except OSError:
            pass
        return []

    @staticmethod
    def list_mountable_devices() -> List[Dict[str, Any]]:
        """Disks and partitions that the maintainer could add to
        `homefree.mounts`: anything with a filesystem (so a one-shot mkfs isn't
        part of the flow), not already in `storage.pools`, not already in
        `homefree.mounts`, not OS / swap / ESP / md-member / lvm-member, not
        currently mounted elsewhere.

        Used to populate the radio-card source picker on the Add Disk Mount
        modal. The user can still fall back to a free-form `device` path if a
        candidate is missing (e.g. unusual layouts the scan doesn't surface)."""
        try:
            cfg = ConfigReader.read_config()
        except Exception:  # noqa: BLE001
            cfg = {}
        recorded_uuids = {p.get("fs-uuid")
                          for p in ((cfg.get("storage") or {}).get("pools") or [])}

        # All fs-uuids already claimed by an existing homefree.mounts row, so
        # we don't offer the same disk twice.
        hf_uuids: Set[str] = set()
        for m in (cfg.get("mounts") or []):
            d = (m.get("device") or "").strip()
            if d.startswith("UUID="):
                hf_uuids.add(d[5:])
            elif d.startswith("/dev/disk/by-uuid/"):
                hf_uuids.add(d.rsplit("/", 1)[-1])
            else:
                resolved = _resolve_mount_spec(d)
                if resolved:
                    u = _fs_uuid_of(os.path.realpath(resolved))
                    if u:
                        hf_uuids.add(u)

        os_disks = _os_disks()
        swap_disks = _swap_disks()
        by_id = _by_id_map()

        # lsblk JSON walk: at every level (disk-as-fs OR partition) emit a
        # row when the node looks like a usable, unclaimed filesystem.
        out_raw = _run([_LSBLK, "-J", "-b", "-o",
                        "NAME,KNAME,TYPE,SIZE,FSTYPE,LABEL,UUID,MOUNTPOINT,PARTTYPE,PATH,MODEL"])
        try:
            blocks = json.loads(out_raw or "{}").get("blockdevices", [])
        except json.JSONDecodeError:
            blocks = []

        candidates: List[Dict[str, Any]] = []
        skip_fs = {"swap", "linux_raid_member", "lvm2_member", "crypto_luks", ""}

        for disk in blocks:
            if disk.get("type") != "disk":
                continue
            disk_kname = disk.get("kname") or disk.get("name") or ""
            if disk_kname in os_disks or disk_kname in swap_disks:
                continue
            disk_by_id = by_id.get(disk_kname, "")
            disk_model = (disk.get("model") or "").strip()

            def walk(n: Dict[str, Any], part_idx: int = 0) -> None:
                fstype = (n.get("fstype") or "").lower()
                fs_uuid = (n.get("uuid") or "").strip()
                parttype = (n.get("parttype") or "").lower()
                mountpoint = (n.get("mountpoint") or "").strip()
                kname = n.get("kname") or n.get("name") or ""

                # Recurse first so children are considered regardless of this
                # node's own status (a partition table has fstype "").
                children = n.get("children") or []
                for i, c in enumerate(children, start=1):
                    walk(c, i)

                # Filter: only nodes with a usable, unclaimed filesystem and
                # not currently mounted (anywhere).
                if fstype in skip_fs:
                    return
                if parttype == _EFI_GUID:
                    return
                if not fs_uuid:
                    return
                if fs_uuid in recorded_uuids or fs_uuid in hf_uuids:
                    return
                if mountpoint:
                    return

                path = n.get("path") or f"/dev/{kname}"
                size = int(n.get("size") or 0)
                label = (n.get("label") or "").strip()
                # The card-picker description: model is "ata-…" by-id when we
                # don't have a real model string, then partition number when
                # this is a child node.
                tag = disk_model or disk_by_id or disk_kname or "Unknown"
                if part_idx > 0:
                    tag = f"{tag} (part {part_idx})"
                candidates.append({
                    "device": f"UUID={fs_uuid}",   # what we'll write to config — stable
                    "device_path": path,             # for display: /dev/sdb1
                    "fs_uuid": fs_uuid,
                    "fs_type": fstype,
                    "label": label,
                    "size_bytes": size,
                    "kname": kname,
                    "disk_kname": disk_kname,
                    "disk_by_id": disk_by_id,
                    "disk_model": disk_model,
                    "display_name": tag,
                })

            walk(disk)
        return candidates

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
        if profile in ("raid0", "raid1", "raid10", "raid5", "raid6") and len(set(sizes)) > 1:
            warnings.append(
                "Mixed drive sizes — usable capacity is limited by the layout; "
                "some space on the larger drive(s) may be unused.")
        if profile in ("raid5", "raid6"):
            warnings.append(
                "Parity volumes build on Linux md: the array is usable right "
                "away, but a full parity sync runs in the background for "
                "several hours after creation.")

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


# --- reclaim (delegated to services.storage_reclaim) -----------------------
# Tears down an in-use storage group (mdadm/LVM) and wipes its member disks
# back to eligible. Destructive; admin-only via the header gate above.

class ReclaimRequest(BaseModel):
    members: List[str]            # by-id names of the disks to reclaim (a group)
    force: bool = False


@router.post("/reclaim")
async def post_reclaim(req: ReclaimRequest) -> Dict[str, Any]:
    from services.storage_reclaim import StorageReclaimService, StorageReclaimBusy
    errs = await asyncio.to_thread(StorageReclaimService.validate_request, req.members)
    if errs:
        raise HTTPException(status_code=400, detail="; ".join(errs))
    try:
        started = StorageReclaimService.start(req.members)
    except StorageReclaimBusy as e:
        raise HTTPException(status_code=409, detail=str(e))
    if not started:
        raise HTTPException(status_code=409, detail="A storage operation is already running.")
    return {"started": True}


@router.get("/reclaim-status")
async def get_reclaim_status() -> Dict[str, Any]:
    from services.storage_reclaim import StorageReclaimService
    return StorageReclaimService.get_status()


# --- import (re-attach an existing on-disk volume; non-destructive) --------

@router.get("/importable")
async def get_importable() -> Dict[str, Any]:
    return {"importable": await asyncio.to_thread(StorageResolver.list_importable)}


class ImportRequest(BaseModel):
    fs_uuid: str
    name: str
    mountpoint: str


@router.post("/pools/import")
async def post_import(req: ImportRequest) -> Dict[str, Any]:
    from services.storage_pool import StoragePoolService
    errs = await asyncio.to_thread(
        StoragePoolService.import_pool, req.fs_uuid, req.name, req.mountpoint)
    if errs:
        raise HTTPException(status_code=400, detail="; ".join(errs))
    return {"ok": True}


# --- promote (any unmanaged btrfs → storage.pools, optionally evicting the
#     matching homefree.mounts row in the same atomic write) -----------------

@router.get("/promotable-btrfs")
async def get_promotable_btrfs() -> Dict[str, Any]:
    return {"promotable": await asyncio.to_thread(StorageResolver.list_promotable_btrfs)}


class PromoteRequest(BaseModel):
    fs_uuid: str
    name: str
    mountpoint: str


@router.post("/pools/promote")
async def post_promote(req: PromoteRequest) -> Dict[str, Any]:
    from services.storage_pool import StoragePoolService
    errs = await asyncio.to_thread(
        StoragePoolService.promote_volume,
        req.fs_uuid, req.name, req.mountpoint)
    if errs:
        raise HTTPException(status_code=400, detail="; ".join(errs))
    return {"ok": True}


# --- mounts: live view of homefree.mounts + sources for Add Disk Mount -------

@router.get("/mounts")
async def get_mounts() -> Dict[str, Any]:
    return {"mounts": await asyncio.to_thread(StorageResolver.list_mounts)}


@router.get("/mountable-devices")
async def get_mountable_devices() -> Dict[str, Any]:
    return {"devices": await asyncio.to_thread(StorageResolver.list_mountable_devices)}


@router.get("/system-volumes")
async def get_system_volumes() -> Dict[str, Any]:
    return {"system_volumes": await asyncio.to_thread(StorageResolver.list_system_volumes)}
