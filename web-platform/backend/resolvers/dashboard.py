"""
Dashboard resolvers — system overview stats for admin.<domain>.

Two layers:

  * Point-in-time readers (CPU / memory / disk / IPs / gateway / per-NIC
    counters / LAN clients). Cheap, called on demand by the API.

  * Time-series history (throughput + connectivity + CPU + memory). This
    is *no longer* sampled inside admin-api. A standalone systemd
    service — `homefree-dashboard-sampler` (web-platform/backend/
    dashboard_sampler.py) — is the sole sampler and writer; it INSERTs
    one row per tick into a SQLite DB. admin-api is a pure reader here:
    `StatsHistory` below just runs indexed SELECTs against that DB.

    This split is what makes the dashboard charts survive admin-api
    restarts and blue/green colour flips: the sampler's lifetime is
    independent of admin-api, so history is continuous and there is
    exactly one writer (no last-writer-wins between two colours).
"""

import concurrent.futures
import ipaddress
import json
import logging
import os
import shutil
import socket
import subprocess
import time
from pathlib import Path
from typing import Any, Dict, List, Optional, Set

import psutil

# A stuck NFS server can wedge a statvfs() call indefinitely (the
# `hard` mount option means the RPC retries forever; `psutil.disk_usage`
# is a thin wrapper around statvfs and offers no timeout). If that call
# runs on the asyncio event loop it freezes the entire admin-api.
# Every disk_usage() in this module goes through `_disk_usage_safe`,
# which runs it in a worker thread with a hard wall-clock timeout —
# on timeout we return None and the panel shows "stale" instead.
_DISK_USAGE_POOL = concurrent.futures.ThreadPoolExecutor(
    max_workers=2, thread_name_prefix="disk_usage_safe"
)
_DISK_USAGE_TIMEOUT_S = 2.0


def _disk_usage_safe(path: str) -> Optional[Any]:
    """`psutil.disk_usage(path)` with a hard timeout. None on timeout/error."""
    fut = _DISK_USAGE_POOL.submit(psutil.disk_usage, path)
    try:
        return fut.result(timeout=_DISK_USAGE_TIMEOUT_S)
    except concurrent.futures.TimeoutError:
        # The worker thread is still wedged in the kernel — leak it.
        # A new submission will spawn a fresh worker (pool maxes at 2,
        # so the second wedge is still bounded). The pool deliberately
        # has no `cancel_futures=True` semantics here.
        logger.warning(
            "dashboard: disk_usage(%s) timed out after %ss — NFS server stuck?",
            path, _DISK_USAGE_TIMEOUT_S,
        )
        return None
    except (PermissionError, OSError) as e:
        logger.debug(f"dashboard: disk_usage({path}) failed: {e}")
        return None

from services.config_reader import ConfigReader
from services.dashboard_history_store import (
    DashboardHistoryStore,
    DEFAULT_DB_PATH,
    HISTORY_SECONDS,
    SAMPLE_INTERVAL,
)

logger = logging.getLogger(__name__)


def _ip_bin() -> str:
    """Absolute path to the `ip` binary.

    The admin-api systemd unit sets a restricted PATH; iproute2 is on it
    (services/admin-web/default.nix), but resolve absolutely anyway so a
    future PATH regression can't silently blank the gateway fields and
    the LAN-clients neighbour table. Falls back to the bare name.
    """
    found = shutil.which("ip")
    if found:
        return found
    for candidate in ("/run/current-system/sw/bin/ip", "/usr/sbin/ip", "/sbin/ip"):
        if Path(candidate).exists():
            return candidate
    return "ip"


IP_BIN = _ip_bin()

# Time-series tuning (SAMPLE_INTERVAL / HISTORY_SECONDS) lives with the
# sampler in services.dashboard_history_store and is imported above so
# the resolver and the sampler service can never drift apart.

DNSMASQ_LEASES = Path("/var/lib/dnsmasq/dnsmasq.leases")


def _network_config() -> Dict[str, Any]:
    """WAN/LAN interface config from homefree-config.json (best effort).

    The on-disk file keeps `network` at the top level, but tolerate a
    `homefree`-wrapped shape too in case the format ever changes.
    """
    try:
        cfg = ConfigReader.read_config()
        if "network" in cfg:
            return cfg.get("network") or {}
        return cfg.get("homefree", {}).get("network", {}) or {}
    except Exception as e:
        logger.warning(f"dashboard: could not read network config: {e}")
        return {}


# =========================================================================
# Point-in-time readers
# =========================================================================

class DashboardResolver:

    @staticmethod
    def get_overview() -> Dict[str, Any]:
        """Everything the dashboard needs in one round-trip."""
        net_cfg = _network_config()
        return {
            "hostname": socket.gethostname(),
            "uptime_seconds": DashboardResolver._uptime_seconds(),
            "load_average": list(os.getloadavg()),
            "cpu": DashboardResolver._cpu(),
            "memory": DashboardResolver._memory(),
            "disks": DashboardResolver._disks(),
            "network_mounts": DashboardResolver._network_mounts(),
            "interfaces": DashboardResolver._interfaces(net_cfg),
            "addresses": DashboardResolver._addresses(net_cfg),
            "gateway": DashboardResolver._gateway(),
            "connectivity": _history.latest_connectivity(),
            "clients_count": len(DashboardResolver._lan_clients(net_cfg)),
        }

    # --- CPU / memory / disk --------------------------------------------

    @staticmethod
    def _uptime_seconds() -> float:
        try:
            return time.time() - psutil.boot_time()
        except Exception:
            return 0.0

    @staticmethod
    def _cpu() -> Dict[str, Any]:
        # interval=None => non-blocking; returns % since the previous call.
        # The background sampler calls cpu_percent() regularly so this
        # stays meaningful even when the dashboard is the first caller.
        return {
            "percent": psutil.cpu_percent(interval=None),
            "count": psutil.cpu_count(logical=True),
            "per_core": psutil.cpu_percent(interval=None, percpu=True),
        }

    @staticmethod
    def _memory() -> Dict[str, Any]:
        vm = psutil.virtual_memory()
        sw = psutil.swap_memory()
        return {
            "total": vm.total,
            "used": vm.used,
            "available": vm.available,
            "percent": vm.percent,
            "swap_total": sw.total,
            "swap_used": sw.used,
            "swap_percent": sw.percent,
        }

    @staticmethod
    def _disks() -> List[Dict[str, Any]]:
        """Usage per mounted, real, *local* filesystem.

        Network filesystems (NFS/CIFS/sshfs/…) are excluded here on
        purpose: their statvfs can wedge for minutes if the server is
        unreachable, and they have their own panel (`_network_mounts`)
        which calls `_disk_usage_safe` with a hard timeout.
        """
        out: List[Dict[str, Any]] = []
        skip_fstypes = {
            "tmpfs", "devtmpfs", "squashfs", "overlay", "ramfs",
            "proc", "sysfs", "cgroup", "cgroup2", "devpts", "mqueue",
            "autofs", "binfmt_misc", "configfs", "debugfs", "tracefs",
            "pstore", "bpf", "hugetlbfs", "securityfs", "fusectl", "efivarfs",
        }
        for part in psutil.disk_partitions(all=False):
            fstype = part.fstype.lower()
            if fstype in skip_fstypes:
                continue
            if fstype in DashboardResolver._NETWORK_FSTYPES:
                continue
            usage = _disk_usage_safe(part.mountpoint)
            if usage is None:
                continue
            out.append({
                "mountpoint": part.mountpoint,
                "device": part.device,
                "fstype": part.fstype,
                "total": usage.total,
                "used": usage.used,
                "free": usage.free,
                "percent": usage.percent,
            })
        # De-dupe btrfs subvolumes etc. that report the same device+total.
        seen = set()
        deduped = []
        for d in sorted(out, key=lambda d: d["mountpoint"]):
            key = (d["device"], d["total"])
            if key in seen:
                continue
            seen.add(key)
            deduped.append(d)
        return deduped

    # fs-types that denote a network filesystem. The homefree-config
    # `mounts` list also carries local block devices (btrfs/ext4/... on
    # a UUID= device), so the Network Mounts panel must filter by type
    # or it double-counts local disks already shown under Disk Usage.
    _NETWORK_FSTYPES = {
        "nfs", "nfs4", "cifs", "smbfs", "smb3",
        "sshfs", "fuse.sshfs", "glusterfs", "ceph", "9p",
    }

    @staticmethod
    def _network_mounts() -> List[Dict[str, Any]]:
        """Configured network filesystems (NFS/CIFS) and their live state.

        Joins the `mounts` list from homefree-config.json against the
        kernel mount table. The config list mixes network and local
        filesystems, so entries are filtered to network fs-types only —
        local disks belong in Disk Usage, not here. An `automount` entry
        that hasn't been touched is legitimately *not* in the mount
        table — reported as 'idle', not an error. A non-automount entry
        that's missing is a genuine 'not mounted' fault.
        """
        try:
            cfg = ConfigReader.read_config()
            configured = cfg.get("mounts") or []
        except Exception as e:
            logger.warning(f"dashboard: could not read mounts config: {e}")
            configured = []
        # Keep only network filesystems — drop local disks (btrfs/ext4/…).
        configured = [
            m for m in configured
            if (m.get("fs-type") or "nfs").lower() in DashboardResolver._NETWORK_FSTYPES
        ]
        if not configured:
            return []

        # Current mount table, keyed by mount point.
        live: Dict[str, Dict[str, str]] = {}
        try:
            for line in Path("/proc/mounts").read_text().splitlines():
                parts = line.split()
                if len(parts) >= 3:
                    # /proc/mounts escapes spaces as \040 — unescape.
                    mp = parts[1].replace("\\040", " ")
                    live[mp] = {"device": parts[0], "fstype": parts[2]}
        except Exception as e:
            logger.warning(f"dashboard: could not read /proc/mounts: {e}")

        out: List[Dict[str, Any]] = []
        for m in configured:
            mp = m.get("mount-point") or ""
            automount = m.get("automount", True)
            enabled = m.get("enabled", True)
            mounted = mp in live
            # A disabled row is intentionally absent from the kernel mount
            # table; flag it explicitly so the dashboard doesn't report it
            # as "not mounted" (which reads like a fault) — see
            # modules/mounts.nix where the disabled rows are filtered out
            # before fileSystems is built.
            if not enabled:
                status = "disabled"
            elif mounted:
                status = "mounted"
            elif automount:
                status = "idle"
            else:
                status = "not mounted"
            entry: Dict[str, Any] = {
                "mountpoint": mp,
                "device": m.get("device") or "",
                "fstype": m.get("fs-type") or "nfs",
                "automount": automount,
                "enabled": enabled,
                "mounted": mounted,
                "status": status,
                "total": None, "used": None, "free": None, "percent": None,
            }
            # Capacity is only knowable while actually mounted. Skip the
            # statvfs on idle automounts — touching the path would force
            # a mount, which is a surprising side effect for a dashboard.
            # `_disk_usage_safe` runs the statvfs in a worker thread with
            # a hard timeout: a stuck NFS server (the kernel's `hard`
            # mount default) returns None here instead of wedging the
            # admin-api event loop. The entry is still emitted so the UI
            # can show "mounted but unresponsive" — flagged by `stale`.
            if mounted:
                usage = _disk_usage_safe(mp)
                if usage is not None:
                    entry.update({
                        "total": usage.total,
                        "used": usage.used,
                        "free": usage.free,
                        "percent": usage.percent,
                    })
                else:
                    entry["status"] = "stale"
            out.append(entry)

        out.sort(key=lambda d: d["mountpoint"])
        return out

    # --- network --------------------------------------------------------

    @staticmethod
    def _interfaces(net_cfg: Dict[str, Any]) -> List[Dict[str, Any]]:
        """Per-NIC link state + current throughput (from the sampler)."""
        wan = net_cfg.get("wan-interface") or ""
        lan = net_cfg.get("lan-interface") or ""
        stats = psutil.net_if_stats()
        rates = _history.latest_rates()  # iface -> {rx_bps, tx_bps}

        out: List[Dict[str, Any]] = []
        for name, st in stats.items():
            if name == "lo":
                continue
            role = "wan" if name == wan else "lan" if name == lan else "other"
            rate = rates.get(name, {})
            out.append({
                "name": name,
                "role": role,
                "is_up": st.isup,
                "speed_mbps": st.speed or None,
                "rx_bps": rate.get("rx_bps", 0),
                "tx_bps": rate.get("tx_bps", 0),
            })
        # WAN first, then LAN, then the rest — matches the dashboard layout.
        order = {"wan": 0, "lan": 1, "other": 2}
        out.sort(key=lambda i: (order[i["role"]], i["name"]))
        return out

    @staticmethod
    def _addresses(net_cfg: Dict[str, Any]) -> Dict[str, Any]:
        """Public + LAN IPv4/IPv6 addresses."""
        wan = net_cfg.get("wan-interface") or ""
        lan = net_cfg.get("lan-interface") or ""
        addrs = psutil.net_if_addrs()

        def _pick(iface: str) -> Dict[str, List[str]]:
            v4, v6 = [], []
            for a in addrs.get(iface, []):
                if a.family == socket.AF_INET:
                    v4.append(a.address)
                elif a.family == socket.AF_INET6:
                    # Strip the zone id (%eth0) link-locals carry.
                    v6.append(a.address.split("%")[0])
            return {"ipv4": v4, "ipv6": v6}

        return {
            "wan": {"interface": wan, **_pick(wan)} if wan else None,
            "lan": {
                "interface": lan,
                "configured_address": net_cfg.get("lan-address"),
                "subnet": net_cfg.get("lan-subnet"),
                **_pick(lan),
            } if lan else None,
        }

    @staticmethod
    def _gateway() -> Dict[str, Optional[str]]:
        """Default-route gateway for IPv4 and IPv6."""
        result: Dict[str, Optional[str]] = {
            "ipv4": None, "ipv4_interface": None,
            "ipv6": None, "ipv6_interface": None,
        }
        for fam, key in (("-4", "ipv4"), ("-6", "ipv6")):
            try:
                raw = subprocess.run(
                    [IP_BIN, fam, "-j", "route", "show", "default"],
                    capture_output=True, text=True, timeout=4,
                ).stdout
                routes = json.loads(raw or "[]")
                if routes:
                    result[key] = routes[0].get("gateway")
                    result[f"{key}_interface"] = routes[0].get("dev")
            except Exception as e:
                logger.debug(f"dashboard: gateway {key} lookup failed: {e}")
        return result

    # --- LAN clients ----------------------------------------------------

    @staticmethod
    def get_lan_clients() -> Dict[str, Any]:
        """Public wrapper used by the dedicated LAN-clients endpoint."""
        clients = DashboardResolver._lan_clients(_network_config())
        return {
            "count": len(clients),
            "online": sum(1 for c in clients if c["online"]),
            "clients": clients,
        }

    @staticmethod
    def _lan_clients(net_cfg: Dict[str, Any]) -> List[Dict[str, Any]]:
        """Merge dnsmasq DHCP leases with the kernel neighbour table.

        DHCP leases give us hostname + lease expiry and cover devices
        that aren't talking right now; the neighbour (ARP/NDP) table
        tells us which MACs are actually reachable on the LAN *now* and
        catches static-IP devices dnsmasq never handed a lease to.
        Keyed by MAC so a device shows up once with both sets of facts.
        """
        lan_iface = net_cfg.get("lan-interface") or ""
        guest_networks = net_cfg.get("guest-networks") or []
        # Devices live on the main LAN trunk *or* on a guest/VLAN
        # sub-interface (e.g. `iot`, `guest`). Scan the neighbour table
        # across all of them so VLAN devices aren't reported offline.
        lan_ifaces = {lan_iface} if lan_iface else set()
        lan_ifaces |= {gn["id"] for gn in guest_networks if gn.get("id")}
        # (network-id, ip_network) pairs for labelling each client's network.
        guest_subnets = DashboardResolver._guest_subnets(guest_networks)
        by_mac: Dict[str, Dict[str, Any]] = {}

        # 1. DHCP leases
        for lease in DashboardResolver._read_dhcp_leases():
            mac = lease["mac"].lower()
            by_mac[mac] = {
                "mac": mac,
                "ip": lease["ip"],
                "hostname": lease["hostname"],
                "lease_expiry": lease["expiry"],
                "source": "dhcp",
                "online": False,
                "network": DashboardResolver._network_for_ip(
                    lease["ip"], guest_subnets),
            }

        # 2. Neighbour table — marks who's reachable and adds unknowns
        for nb in DashboardResolver._read_neighbours(lan_ifaces):
            mac = nb["mac"].lower()
            entry = by_mac.get(mac)
            reachable = nb["state"] in ("REACHABLE", "STALE", "DELAY", "PROBE")
            if entry:
                entry["online"] = entry["online"] or reachable
                if not entry.get("ip"):
                    entry["ip"] = nb["ip"]
                    entry["network"] = DashboardResolver._network_for_ip(
                        nb["ip"], guest_subnets)
            else:
                by_mac[mac] = {
                    "mac": mac,
                    "ip": nb["ip"],
                    "hostname": None,
                    "lease_expiry": None,
                    "source": "neighbour",
                    "online": reachable,
                    "network": DashboardResolver._network_for_ip(
                        nb["ip"], guest_subnets),
                }

        clients = list(by_mac.values())
        clients.sort(key=lambda c: (
            not c["online"],
            DashboardResolver._ip_sort_key(c.get("ip")),
        ))
        return clients

    @staticmethod
    def _read_dhcp_leases() -> List[Dict[str, Any]]:
        """Parse /var/lib/dnsmasq/dnsmasq.leases.

        Format per line: <expiry-epoch> <mac> <ip> <hostname> <client-id>
        Hostname is '*' when the client didn't send one.
        """
        leases: List[Dict[str, Any]] = []
        if not DNSMASQ_LEASES.is_file():
            return leases
        try:
            for line in DNSMASQ_LEASES.read_text().splitlines():
                parts = line.split()
                if len(parts) < 4:
                    continue
                expiry, mac, ip, hostname = parts[0], parts[1], parts[2], parts[3]
                try:
                    expiry_epoch: Optional[int] = int(expiry)
                except ValueError:
                    expiry_epoch = None
                leases.append({
                    "mac": mac,
                    "ip": ip,
                    "hostname": None if hostname == "*" else hostname,
                    "expiry": expiry_epoch,
                })
        except Exception as e:
            logger.warning(f"dashboard: failed to read DHCP leases: {e}")
        return leases

    @staticmethod
    def _read_neighbours(ifaces: Optional[Set[str]] = None) -> List[Dict[str, Any]]:
        """Kernel neighbour table via `ip neigh`.

        We can't pass `dev` to `ip neigh` because devices may be on the
        main LAN trunk *or* on any guest/VLAN sub-interface; a single
        `dev` filter would miss the others. Instead we read every
        neighbour and keep only those whose interface is in `ifaces`
        (the LAN trunk + VLAN sub-interfaces). `ifaces` empty/None →
        keep all (e.g. when no LAN interface is configured).
        """
        neighbours: List[Dict[str, Any]] = []
        try:
            raw = subprocess.run(
                [IP_BIN, "-j", "neigh", "show"],
                capture_output=True, text=True, timeout=4,
            ).stdout
            for nb in json.loads(raw or "[]"):
                mac = nb.get("lladdr")
                ip = nb.get("dst")
                dev = nb.get("dev")
                if not mac or not ip:
                    continue
                if ifaces and dev not in ifaces:
                    continue
                neighbours.append({
                    "mac": mac,
                    "ip": ip,
                    "dev": dev,
                    "state": (nb.get("state") or ["UNKNOWN"])[0]
                    if isinstance(nb.get("state"), list)
                    else nb.get("state", "UNKNOWN"),
                })
        except Exception as e:
            logger.warning(f"dashboard: failed to read neighbours: {e}")
        return neighbours

    @staticmethod
    def _guest_subnets(
        guest_networks: List[Dict[str, Any]],
    ) -> List[tuple]:
        """(network-id, ip_network) pairs for labelling client networks."""
        pairs: List[tuple] = []
        for gn in guest_networks:
            gid, subnet = gn.get("id"), gn.get("subnet")
            if not gid or not subnet:
                continue
            try:
                pairs.append((gid, ipaddress.ip_network(subnet, strict=False)))
            except ValueError:
                continue
        return pairs

    @staticmethod
    def _network_for_ip(
        ip: Optional[str], guest_subnets: List[tuple],
    ) -> Optional[str]:
        """Guest-network id whose subnet contains `ip`, else None (main LAN)."""
        if not ip:
            return None
        try:
            addr = ipaddress.ip_address(ip)
        except ValueError:
            return None
        for gid, net in guest_subnets:
            if addr in net:
                return gid
        return None

    @staticmethod
    def _ip_sort_key(ip: Optional[str]):
        """Sort IPv4 numerically; push missing/IPv6 to the end."""
        if not ip or ":" in ip:
            return (1, ())
        try:
            return (0, tuple(int(o) for o in ip.split(".")))
        except ValueError:
            return (1, ())

    # --- history --------------------------------------------------------

    @staticmethod
    def get_history() -> Dict[str, Any]:
        """Time-series samples for the dashboard charts."""
        return _history.snapshot()


# =========================================================================
# Time-series history — SQLite reader
# =========================================================================

class StatsHistory:
    """Read-only view over the dashboard history DB.

    The sampling and writing is done by the standalone
    `homefree-dashboard-sampler` service (dashboard_sampler.py). This
    class only runs SELECTs, so admin-api carries no sampler thread and
    holds no in-process state — every restart and every blue/green flip
    simply reattaches to the same DB with the full history intact.

    All methods are best-effort: if the DB does not exist yet (sampler
    has not had its first tick) or a read fails, they return empty/None
    rather than raising, so the dashboard degrades gracefully.
    """

    def __init__(self, db_path: str = DEFAULT_DB_PATH) -> None:
        self._store = DashboardHistoryStore(
            os.environ.get("HOMEFREE_DASHBOARD_DB", db_path)
        )

    def latest_rates(self) -> Dict[str, Dict[str, float]]:
        """Per-interface throughput from the most recent sample. At most
        SAMPLE_INTERVAL seconds stale — fine for the overview panel."""
        latest = self._store.latest_sample()
        if not latest:
            return {}
        return {
            name: {
                "rx_bps": round(r.get("rx_bps", 0)),
                "tx_bps": round(r.get("tx_bps", 0)),
            }
            for name, r in (latest.get("rates") or {}).items()
        }

    def latest_connectivity(self) -> Dict[str, Any]:
        """Current link state plus an uptime ratio over the retained
        window — a quick 'how stable has my link been' number."""
        samples = self._store.get_samples(HISTORY_SECONDS)
        if not samples:
            return {"connected": None, "latency_ms": None}
        last = samples[-1]
        total = len(samples)
        up = sum(1 for s in samples if s["connected"])
        return {
            "connected": last["connected"],
            "latency_ms": last["latency_ms"],
            "uptime_ratio": round(up / total, 4) if total else None,
            "samples": total,
        }

    def snapshot(self) -> Dict[str, Any]:
        """Full retained window for the time-series charts."""
        return {
            "sample_interval": SAMPLE_INTERVAL,
            "window_seconds": HISTORY_SECONDS,
            "samples": self._store.get_samples(HISTORY_SECONDS),
        }


# Module-level singleton. Cheap to construct — opens no connection until
# a method is called.
_history = StatsHistory()
