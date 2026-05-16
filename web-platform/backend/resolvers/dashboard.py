"""
Dashboard resolvers — system overview stats for admin.<domain>.

Two layers:

  * Point-in-time readers (CPU / memory / disk / IPs / gateway / per-NIC
    counters / LAN clients). Cheap, called on demand by the API.

  * A background sampler thread (StatsHistory) that wakes every
    SAMPLE_INTERVAL seconds, takes a snapshot of throughput +
    connectivity, and pushes it into a fixed-size in-memory ring buffer.
    This is what backs the time-series charts. History is intentionally
    *not* persisted — it resets on admin-api restart (including every
    nixos-rebuild). That keeps the resolver dependency-free and avoids
    disk writes; a few hours of in-RAM history is enough for an at-a-
    glance dashboard.
"""

import json
import logging
import os
import shutil
import socket
import subprocess
import threading
import time
from collections import deque
from pathlib import Path
from typing import Any, Dict, List, Optional

import psutil

from services.config_reader import ConfigReader

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

# --- sampler tuning -------------------------------------------------------
SAMPLE_INTERVAL = 10           # seconds between background samples
HISTORY_SECONDS = 3 * 3600     # keep ~3 hours of history
HISTORY_MAXLEN = HISTORY_SECONDS // SAMPLE_INTERVAL

# Host to probe for connectivity. A TCP connect to a well-known anycast
# resolver on :53 — succeeds fast when WAN is up, fails fast when not.
# We deliberately avoid ICMP (needs raw sockets) and DNS resolution
# (would also exercise the local resolver, muddying the signal).
CONNECTIVITY_HOST = "1.1.1.1"
CONNECTIVITY_PORT = 53
CONNECTIVITY_TIMEOUT = 2.0

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
        """Usage per mounted, real (non-virtual) filesystem."""
        out: List[Dict[str, Any]] = []
        skip_fstypes = {
            "tmpfs", "devtmpfs", "squashfs", "overlay", "ramfs",
            "proc", "sysfs", "cgroup", "cgroup2", "devpts", "mqueue",
            "autofs", "binfmt_misc", "configfs", "debugfs", "tracefs",
            "pstore", "bpf", "hugetlbfs", "securityfs", "fusectl", "efivarfs",
        }
        for part in psutil.disk_partitions(all=False):
            if part.fstype.lower() in skip_fstypes:
                continue
            try:
                usage = psutil.disk_usage(part.mountpoint)
            except (PermissionError, OSError):
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
            mounted = mp in live
            entry: Dict[str, Any] = {
                "mountpoint": mp,
                "device": m.get("device") or "",
                "fstype": m.get("fs-type") or "nfs",
                "automount": automount,
                "mounted": mounted,
                "status": "mounted" if mounted
                          else "idle" if automount
                          else "not mounted",
                "total": None, "used": None, "free": None, "percent": None,
            }
            # Capacity is only knowable while actually mounted. Skip the
            # statvfs on idle automounts — touching the path would force
            # a mount, which is a surprising side effect for a dashboard.
            if mounted:
                try:
                    usage = psutil.disk_usage(mp)
                    entry.update({
                        "total": usage.total,
                        "used": usage.used,
                        "free": usage.free,
                        "percent": usage.percent,
                    })
                except (PermissionError, OSError) as e:
                    logger.debug(f"dashboard: disk_usage({mp}) failed: {e}")
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
            }

        # 2. Neighbour table — marks who's reachable and adds unknowns
        for nb in DashboardResolver._read_neighbours(lan_iface):
            mac = nb["mac"].lower()
            entry = by_mac.get(mac)
            reachable = nb["state"] in ("REACHABLE", "STALE", "DELAY", "PROBE")
            if entry:
                entry["online"] = entry["online"] or reachable
                if not entry.get("ip"):
                    entry["ip"] = nb["ip"]
            else:
                by_mac[mac] = {
                    "mac": mac,
                    "ip": nb["ip"],
                    "hostname": None,
                    "lease_expiry": None,
                    "source": "neighbour",
                    "online": reachable,
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
    def _read_neighbours(lan_iface: str) -> List[Dict[str, Any]]:
        """Kernel neighbour table via `ip neigh`, optionally LAN-scoped."""
        neighbours: List[Dict[str, Any]] = []
        cmd = [IP_BIN, "-j", "neigh", "show"]
        if lan_iface:
            cmd += ["dev", lan_iface]
        try:
            raw = subprocess.run(
                cmd, capture_output=True, text=True, timeout=4,
            ).stdout
            for nb in json.loads(raw or "[]"):
                mac = nb.get("lladdr")
                ip = nb.get("dst")
                if not mac or not ip:
                    continue
                neighbours.append({
                    "mac": mac,
                    "ip": ip,
                    "state": (nb.get("state") or ["UNKNOWN"])[0]
                    if isinstance(nb.get("state"), list)
                    else nb.get("state", "UNKNOWN"),
                })
        except Exception as e:
            logger.warning(f"dashboard: failed to read neighbours: {e}")
        return neighbours

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
# Background sampler — fixed-size in-memory ring buffer
# =========================================================================

class StatsHistory:
    """Periodically samples throughput + connectivity into a ring buffer.

    Thread-safe: the sampler thread writes under `_lock`, API handlers
    read under the same lock. Each sample is a small dict, and the deque
    is bounded, so worst-case memory is a few hundred KB.
    """

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._samples: deque = deque(maxlen=HISTORY_MAXLEN)
        # Per-interface running rates, updated each tick from counter deltas.
        self._rates: Dict[str, Dict[str, float]] = {}
        self._last_counters: Optional[Dict[str, Any]] = None
        self._last_ts: Optional[float] = None
        self._thread: Optional[threading.Thread] = None
        self._stop = threading.Event()

    def start(self) -> None:
        if self._thread and self._thread.is_alive():
            return
        # Prime cpu_percent so the first real reading isn't a bogus 0.
        try:
            psutil.cpu_percent(interval=None)
        except Exception:
            pass
        self._thread = threading.Thread(
            target=self._run, name="dashboard-sampler", daemon=True,
        )
        self._thread.start()
        logger.info("dashboard: stats sampler started")

    def stop(self) -> None:
        self._stop.set()

    def _run(self) -> None:
        while not self._stop.wait(SAMPLE_INTERVAL):
            try:
                self._sample()
            except Exception as e:
                logger.error(f"dashboard: sampler tick failed: {e}")

    def _sample(self) -> None:
        now = time.time()
        counters = psutil.net_io_counters(pernic=True)

        # Throughput = counter delta / elapsed. First tick has no delta.
        rates: Dict[str, Dict[str, float]] = {}
        if self._last_counters and self._last_ts:
            elapsed = max(now - self._last_ts, 1e-3)
            for name, cur in counters.items():
                if name == "lo":
                    continue
                prev = self._last_counters.get(name)
                if not prev:
                    continue
                rx = max(cur.bytes_recv - prev.bytes_recv, 0) * 8 / elapsed
                tx = max(cur.bytes_sent - prev.bytes_sent, 0) * 8 / elapsed
                rates[name] = {"rx_bps": rx, "tx_bps": tx}
        self._last_counters = counters
        self._last_ts = now

        connected, latency_ms = self._probe_connectivity()

        try:
            vm = psutil.virtual_memory()
            cpu = psutil.cpu_percent(interval=None)
        except Exception:
            vm, cpu = None, 0.0

        sample = {
            "ts": int(now),
            "connected": connected,
            "latency_ms": latency_ms,
            "cpu_percent": cpu,
            "memory_percent": vm.percent if vm else 0.0,
            # Per-interface bits/sec, rounded to keep the payload small.
            "rates": {
                name: {
                    "rx_bps": round(r["rx_bps"]),
                    "tx_bps": round(r["tx_bps"]),
                }
                for name, r in rates.items()
            },
        }

        with self._lock:
            self._samples.append(sample)
            self._rates = rates

    @staticmethod
    def _probe_connectivity() -> tuple:
        """TCP connect to a public anycast resolver. Returns (up, ms)."""
        start = time.time()
        try:
            with socket.create_connection(
                (CONNECTIVITY_HOST, CONNECTIVITY_PORT),
                timeout=CONNECTIVITY_TIMEOUT,
            ):
                return True, round((time.time() - start) * 1000, 1)
        except Exception:
            return False, None

    # --- readers --------------------------------------------------------

    def latest_rates(self) -> Dict[str, Dict[str, float]]:
        with self._lock:
            return {
                name: {
                    "rx_bps": round(r["rx_bps"]),
                    "tx_bps": round(r["tx_bps"]),
                }
                for name, r in self._rates.items()
            }

    def latest_connectivity(self) -> Dict[str, Any]:
        with self._lock:
            if not self._samples:
                return {"connected": None, "latency_ms": None}
            last = self._samples[-1]
            # Uptime ratio over the retained window — a quick "how stable
            # has my link been" number for the dashboard header.
            total = len(self._samples)
            up = sum(1 for s in self._samples if s["connected"])
            return {
                "connected": last["connected"],
                "latency_ms": last["latency_ms"],
                "uptime_ratio": round(up / total, 4) if total else None,
                "samples": total,
            }

    def snapshot(self) -> Dict[str, Any]:
        with self._lock:
            samples = list(self._samples)
        return {
            "sample_interval": SAMPLE_INTERVAL,
            "window_seconds": HISTORY_SECONDS,
            "samples": samples,
        }


# Module-level singleton. simple_main.py calls _history.start() on
# application startup.
_history = StatsHistory()


def start_sampler() -> None:
    _history.start()
