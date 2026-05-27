"""
Alert sources — pluggable evaluators.

Each source is a class with:

  - id: stable identifier matching its key under
        homefree.alerts.sources in the deployed JSON (this is also
        how the engine looks up its config).

  - label: human-facing name (admin UI, ntfy title).

  - evaluate(config) -> SourceResult: read the current world, decide
        whether the alert condition is met. Sources never decide
        WHETHER to notify — the engine handles transitions / hysteresis
        based on a `firing` boolean and the previous state. A source
        returning firing=True every tick is fine; the engine only
        dispatches on transitions.

v1 ships disk-temperature. Adding a new source is "define one class,
add it to REGISTRY at the bottom." No engine changes.
"""

import json
import logging
import os
import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

from resolvers.physical_drives import PhysicalDrivesResolver
from services import hwmon

logger = logging.getLogger(__name__)


@dataclass
class SourceResult:
    """Per-tick evaluation result. The engine compares `firing` with the
    previous state to decide open / close / steady, and uses `value` to
    track a peak across the lifetime of an open alert.
    """
    firing: bool
    # Numeric metric value (e.g. peak temp °C). Used by the engine to
    # track the worst observed value while an alert is open. None when
    # the source has no data to report (firing must be False).
    value: Optional[float]
    # Human-readable message displayed in the push and history.
    message: str


# ---------------------------------------------------------------------
# disk-temperature
# ---------------------------------------------------------------------

# Class label mapping for messages — matches the Hardware page so a
# user reading both pages sees the same nomenclature.
_CLASS_LABELS = {"hdd": "HDD", "ssd": "SSD", "nvme": "NVMe"}


class DiskTemperatureSource:
    """Reads per-drive temperature + drive class via
    `PhysicalDrivesResolver.get_all()` and compares each drive against
    the threshold for its CLASS (HDD / SSD / NVMe), with hysteresis on
    the per-class threshold so a disk hovering right at its threshold
    doesn't flap open/close every poll.

    Why PhysicalDrivesResolver and not the drive_temp history DB: the
    history sampler only records (device, temp_c) — no drive class — so
    we'd need a second source for the class anyway. The resolver already
    pulls both in a 60s-cached call (shared with the Hardware page),
    making it the single source of truth for "what drives are present
    right now and how hot is each."

    The engine — not the source — owns the previous firing state. The
    source receives `was_firing` so it can apply hysteresis correctly:
    a disk is "still firing" if it stays ABOVE (threshold - hysteresis)
    once an alert is open, even if it has dropped just under threshold.
    """

    id = "disk-temperature"
    label = "Disk temperature"

    def evaluate(
        self,
        config: Dict[str, Any],
        was_firing: bool,
    ) -> SourceResult:
        thresholds_cfg = config.get("thresholds") or {}
        # Per-class thresholds. Defaults match the Hardware page warn
        # colour and the schema defaults in module.nix.
        class_threshold = {
            "hdd":  int(thresholds_cfg.get("hdd-c",  45)),
            "ssd":  int(thresholds_cfg.get("ssd-c",  60)),
            "nvme": int(thresholds_cfg.get("nvme-c", 70)),
        }
        hysteresis = int(config.get("hysteresis-c", 4))

        try:
            drives = PhysicalDrivesResolver.get_all()
        except Exception:
            # Worst case: smartctl wedged or sysfs unreadable. Source
            # cannot know whether to fire; treat as "no data" so the
            # engine takes no action this tick.
            return SourceResult(
                firing=False, value=None,
                message="Drive enumeration failed; skipping tick",
            )

        peak_overall: Optional[Tuple[float, str, str]] = None  # (temp, device, class)
        hot: List[Tuple[float, str, str, int]] = []   # (temp, device, class, threshold)

        for d in drives:
            t = d.get("temp_c")
            if t is None:
                # NVMe drives that don't expose SMART temp, USB enclosures
                # that hide SMART, etc. Not an alert condition.
                continue
            cls = d.get("drive_class") or "hdd"
            # Fall back to HDD threshold for an unrecognised class — the
            # tightest of the three, so we err toward alerting.
            threshold = class_threshold.get(cls, class_threshold["hdd"])
            # Schmitt-trigger: once OPEN, the disk must drop below
            # (threshold - hysteresis) to clear. Applied per-class so
            # a hysteresis band tied to the wrong class can't bleed
            # across (e.g. an NVMe at 67°C should never sit "still open"
            # because the HDD-class hysteresis says so).
            active_threshold = (threshold - hysteresis) if was_firing else threshold

            t_f = float(t)
            device = d.get("device") or d.get("name") or "<unknown>"
            if peak_overall is None or t_f > peak_overall[0]:
                peak_overall = (t_f, device, cls)
            if t_f >= active_threshold:
                hot.append((t_f, device, cls, threshold))

        if not hot:
            if peak_overall is not None:
                peak_t, peak_dev, peak_cls = peak_overall
                msg = (
                    f"All drives below their class thresholds "
                    f"(peak {peak_dev} [{_CLASS_LABELS.get(peak_cls, peak_cls)}] "
                    f"@ {int(peak_t)}°C)"
                )
                return SourceResult(firing=False, value=peak_t, message=msg)
            return SourceResult(
                firing=False, value=None,
                message="No drive temperature data yet",
            )

        # Firing. Sort by temp descending; name every offending disk
        # with its class and the class threshold so the message is
        # self-explanatory in a push.
        hot.sort(key=lambda r: r[0], reverse=True)
        peak_t, peak_dev, peak_cls, peak_threshold = hot[0]
        head = (
            f"{peak_dev} [{_CLASS_LABELS.get(peak_cls, peak_cls)}] "
            f"at {int(peak_t)}°C (threshold {peak_threshold}°C)"
        )
        if len(hot) == 1:
            msg = head
        else:
            others = ", ".join(
                f"{d} [{_CLASS_LABELS.get(c, c)}]@{int(t)}°C/≥{thr}°C"
                for t, d, c, thr in hot[1:]
            )
            msg = head + "; also " + others
        return SourceResult(firing=True, value=peak_t, message=msg)


# ---------------------------------------------------------------------
# disk-space
# ---------------------------------------------------------------------

# Default allowlists / denylists are also defined here as a defensive
# fallback for when the engine config blob is missing the keys (older
# alerts-config.json on a box mid-rebuild). They mirror the module.nix
# option defaults — keep these in sync if the defaults change.
_DISK_SPACE_DEFAULT_FS_TYPES = {
    "ext2", "ext3", "ext4", "xfs", "btrfs", "zfs", "f2fs", "jfs",
    "reiserfs", "ntfs", "ntfs3", "vfat", "exfat",
    "nfs", "nfs4", "cifs",
}
_DISK_SPACE_DEFAULT_SKIP_PREFIXES = (
    "/proc", "/sys", "/dev", "/run",
    "/var/lib/docker", "/var/lib/containers",
    "/boot",
)


class DiskSpaceSource:
    """Walks /proc/mounts every tick, statvfs() each filesystem on the
    allowlist (and not under a skip prefix), fires when any one is at
    or above `threshold-percent` used.

    Per-mount thresholds are NOT supported in v1 — one global percent
    is enough for "I want to know when something's filling up." A
    user with a special case can use `skip-mount-prefixes` to opt that
    mount out of the global threshold; we can add per-mount overrides
    later behind an `overrides = [ { path; percent; } ]` field if
    anyone needs it."""

    id = "disk-space"
    label = "Disk space"

    def evaluate(
        self,
        config: Dict[str, Any],
        was_firing: bool,
    ) -> SourceResult:
        threshold = int(config.get("threshold-percent", 90))
        hysteresis = int(config.get("hysteresis-percent", 3))
        fs_types = set(config.get("fs-types") or _DISK_SPACE_DEFAULT_FS_TYPES)
        skip_prefixes = tuple(
            config.get("skip-mount-prefixes") or _DISK_SPACE_DEFAULT_SKIP_PREFIXES
        )
        active_threshold = (threshold - hysteresis) if was_firing else threshold

        def _is_skipped(mp: str) -> bool:
            for p in skip_prefixes:
                if mp == p or mp.startswith(p + "/"):
                    return True
            return False

        mountpoints: List[str] = []
        try:
            with open("/proc/mounts") as f:
                seen_mp = set()
                for line in f:
                    parts = line.split()
                    if len(parts) < 4:
                        continue
                    mp, fst, opts = parts[1], parts[2], parts[3]
                    if fst not in fs_types:
                        continue
                    if _is_skipped(mp):
                        continue
                    # /proc/mounts may list a path twice (bind mounts).
                    # statvfs returns the same numbers either way, so
                    # dedupe to avoid printing a single full mount twice.
                    if mp in seen_mp:
                        continue
                    # Read-only mounts: a ro filesystem won't fill from
                    # writes the user can affect, so they'd be noise.
                    # Exception: nfs/cifs ro is unusual — included via
                    # the fs-type allowlist already, so skip-on-ro
                    # catches /nix/store-style bind mounts cleanly.
                    if "ro" in opts.split(","):
                        continue
                    seen_mp.add(mp)
                    mountpoints.append(mp)
        except OSError as e:
            logger.warning("disk-space: /proc/mounts read failed: %s", e)
            return SourceResult(
                firing=False, value=None,
                message="Could not enumerate filesystems",
            )

        peak: Optional[Tuple[float, str]] = None        # (pct, mp)
        full: List[Tuple[float, str, int]] = []          # (pct, mp, total_gb)
        for mp in mountpoints:
            try:
                st = os.statvfs(mp)
            except OSError as e:
                logger.debug("disk-space: statvfs(%s) failed: %s", mp, e)
                continue
            total = st.f_blocks * st.f_frsize
            if total == 0:
                continue
            avail = st.f_bavail * st.f_frsize
            used = total - avail
            pct = round(used * 100.0 / total, 1)
            total_gb = max(1, total // (1024 ** 3))
            if peak is None or pct > peak[0]:
                peak = (pct, mp)
            if pct >= active_threshold:
                full.append((pct, mp, total_gb))

        if not full:
            if peak is not None:
                msg = (
                    f"All filesystems below {threshold}% used "
                    f"(peak {peak[1]} @ {peak[0]}%)"
                )
                return SourceResult(firing=False, value=peak[0], message=msg)
            return SourceResult(
                firing=False, value=None,
                message="No monitored filesystems found",
            )

        full.sort(reverse=True)
        peak_pct, peak_mp, peak_gb = full[0]
        head = (
            f"{peak_mp} at {peak_pct}% used "
            f"(threshold {threshold}%, {peak_gb} GiB total)"
        )
        if len(full) == 1:
            return SourceResult(firing=True, value=peak_pct, message=head)
        others = ", ".join(f"{mp}@{p}%" for p, mp, _ in full[1:])
        return SourceResult(
            firing=True, value=peak_pct, message=head + "; also " + others,
        )


# ---------------------------------------------------------------------
# smart
# ---------------------------------------------------------------------

class SmartSource:
    """Fires when any drive reports a SMART overall-health FAIL.

    Strictly `smart_passed is False` — i.e. SMART is available AND the
    drive's self-assessment is negative. Drives that don't expose
    SMART (`smart_available=False`, typical of cheap USB enclosures)
    are NOT a failure, just absence of signal; we don't alert on them
    here because "no data" is not actionable as a push."""

    id = "smart"
    label = "SMART health"

    def evaluate(
        self,
        config: Dict[str, Any],
        was_firing: bool,
    ) -> SourceResult:
        try:
            drives = PhysicalDrivesResolver.get_all()
        except Exception as e:
            logger.warning("smart: drive enumeration failed: %s", e)
            return SourceResult(
                firing=False, value=None,
                message="Drive enumeration failed; skipping tick",
            )

        failed: List[Tuple[str, Optional[str]]] = []   # (device, model)
        checked = 0
        for d in drives:
            if not d.get("smart_available"):
                continue
            checked += 1
            if d.get("smart_passed") is False:
                device = d.get("device") or d.get("name") or "<unknown>"
                failed.append((device, d.get("model")))

        if not failed:
            if checked == 0:
                return SourceResult(
                    firing=False, value=None,
                    message="No drives report SMART; nothing to check",
                )
            return SourceResult(
                firing=False, value=None,
                message=f"All {checked} SMART-capable drive(s) passed",
            )

        if len(failed) == 1:
            dev, model = failed[0]
            tag = f"{dev} ({model})" if model else dev
            return SourceResult(
                firing=True, value=1.0,
                message=f"SMART FAILING: {tag}",
            )
        devs = ", ".join(dev for dev, _ in failed)
        return SourceResult(
            firing=True, value=float(len(failed)),
            message=f"{len(failed)} drives SMART failing: {devs}",
        )


# ---------------------------------------------------------------------
# sensor-temperature  (hwmon: CPU / NVMe controller / GPU)
# ---------------------------------------------------------------------

# Map hwmon's `kind` bucket → config key for the threshold lookup.
# Only kinds with a defined threshold can fire; everything else is
# silently skipped (memory / other are surfaced on the Hardware page
# but rarely worth a push).
_SENSOR_KIND_TO_CFG_KEY = {
    "cpu":  "cpu-c",
    "nvme": "nvme-c",
    "gpu":  "gpu-c",
}

_SENSOR_KIND_LABEL = {
    "cpu":  "CPU",
    "nvme": "NVMe ctlr",
    "gpu":  "GPU",
}


class SensorTemperatureSource:
    """CPU / NVMe controller / GPU temperatures from hwmon — the same
    sensors the Hardware page Sensors panel shows. Per-class thresholds
    because silicon classes have very different safe operating ranges.

    Distinct from `disk-temperature`: that source reads SMART (which
    knows about platter / NAND temperatures, the *media* not the
    controller); this one reads hwmon (kernel sysfs, knows about the
    *silicon controller temperature* exposed by the kernel driver).
    Both can fire for an NVMe drive simultaneously if the media AND
    the controller are hot — they measure different things."""

    id = "sensor-temperature"
    label = "Sensor temperatures"

    def evaluate(
        self,
        config: Dict[str, Any],
        was_firing: bool,
    ) -> SourceResult:
        thresholds_cfg = config.get("thresholds") or {}
        class_threshold: Dict[str, int] = {}
        for kind, cfg_key in _SENSOR_KIND_TO_CFG_KEY.items():
            class_threshold[kind] = int(thresholds_cfg.get(cfg_key, 80))
        hysteresis = int(config.get("hysteresis-c", 4))

        try:
            sensors = hwmon.scan()
        except Exception as e:
            logger.warning("sensor-temperature: hwmon scan failed: %s", e)
            return SourceResult(
                firing=False, value=None,
                message="Sensor scan failed; skipping tick",
            )

        peak: Optional[Tuple[float, str, str]] = None    # (temp, kind, name)
        hot: List[Tuple[float, str, str, int]] = []      # (temp, kind, name, thr)
        for s in sensors:
            kind = s.get("kind") or "other"
            threshold = class_threshold.get(kind)
            if threshold is None:
                # No threshold for this kind (memory / other); ignore.
                continue
            t = s.get("temp_c")
            if t is None:
                continue
            t_f = float(t)
            display_name = s.get("name") or "?"
            sublabel = s.get("label")
            if sublabel:
                display_name = f"{display_name} ({sublabel})"
            active = (threshold - hysteresis) if was_firing else threshold
            if peak is None or t_f > peak[0]:
                peak = (t_f, kind, display_name)
            if t_f >= active:
                hot.append((t_f, kind, display_name, threshold))

        if not hot:
            if peak is not None:
                peak_t, peak_kind, peak_name = peak
                msg = (
                    f"All sensors below their class thresholds "
                    f"(peak {peak_name} "
                    f"[{_SENSOR_KIND_LABEL.get(peak_kind, peak_kind)}] "
                    f"@ {int(peak_t)}°C)"
                )
                return SourceResult(firing=False, value=peak_t, message=msg)
            return SourceResult(
                firing=False, value=None,
                message="No monitored sensors present",
            )

        hot.sort(key=lambda r: r[0], reverse=True)
        peak_t, peak_kind, peak_name, peak_thr = hot[0]
        head = (
            f"{peak_name} "
            f"[{_SENSOR_KIND_LABEL.get(peak_kind, peak_kind)}] "
            f"at {int(peak_t)}°C (threshold {peak_thr}°C)"
        )
        if len(hot) == 1:
            return SourceResult(firing=True, value=peak_t, message=head)
        others = ", ".join(
            f"{n} [{_SENSOR_KIND_LABEL.get(k, k)}]@{int(t)}°C/≥{thr}°C"
            for t, k, n, thr in hot[1:]
        )
        return SourceResult(firing=True, value=peak_t, message=head + "; also " + others)


# ---------------------------------------------------------------------
# services-down
# ---------------------------------------------------------------------

class ServicesDownSource:
    """Fires when any enabled service in homefree.service-config has a
    systemd unit in the `failed` state.

    Reads the rendered service catalog at /etc/homefree/service-config.json
    (services/service-config-json/), iterates each entry with
    `enable=true` and a non-empty `systemd-service-names`, and shells
    out to `systemctl is-active <unit>` for each.

    Conservative trigger: only `failed` is treated as down. `inactive`
    means too many things (a Type=oneshot RemainAfterExit=false that
    finished cleanly is `inactive`; a unit manually stopped via
    `systemctl stop` is also `inactive` — and stopping a service is a
    deliberate admin action that shouldn't push). The price is that
    a SHOULD-be-running service which crashed without auto-restart
    and didn't reach `failed` state will not alert via this source;
    such a unit is misconfigured at the systemd level, separate
    issue."""

    id = "services-down"
    label = "Services down"

    CATALOG_PATH = "/etc/homefree/service-config.json"

    def evaluate(
        self,
        config: Dict[str, Any],
        was_firing: bool,
    ) -> SourceResult:
        try:
            catalog: List[Dict[str, Any]] = json.loads(
                Path(self.CATALOG_PATH).read_text()
            )
        except FileNotFoundError:
            # No catalog yet — fresh box, services/service-config-json
            # may not have rendered. Skip silently.
            return SourceResult(
                firing=False, value=None,
                message="Service catalog not present; skipping tick",
            )
        except Exception as e:
            logger.warning(
                "services-down: catalog parse failed: %s", e,
            )
            return SourceResult(
                firing=False, value=None,
                message="Could not read service catalog",
            )

        down: List[Tuple[str, str, str]] = []   # (label, unit, state)
        checked = 0
        for entry in catalog:
            if not entry.get("enable"):
                continue
            label = entry.get("label") or "?"
            units = entry.get("systemd-service-names") or []
            for unit in units:
                checked += 1
                state = self._unit_state(unit)
                if state == "failed":
                    down.append((label, unit, state))

        if not down:
            return SourceResult(
                firing=False, value=None,
                message=f"All {checked} enabled service unit(s) healthy",
            )

        if len(down) == 1:
            label, unit, state = down[0]
            return SourceResult(
                firing=True, value=1.0,
                message=f"{label} ({unit}) is {state}",
            )
        msg = f"{len(down)} units failed: " + ", ".join(
            f"{u}" for _, u, _ in down
        )
        return SourceResult(
            firing=True, value=float(len(down)), message=msg,
        )

    @staticmethod
    def _unit_state(unit: str) -> str:
        """`systemctl is-active <unit>` → 'active' / 'inactive' /
        'failed' / 'activating' / 'deactivating' / 'unknown'.
        Always returns a string, never raises."""
        try:
            r = subprocess.run(
                ["systemctl", "is-active", unit],
                capture_output=True, text=True, timeout=5,
            )
            # is-active is fluent: stdout has the literal state, even
            # when exit code is non-zero (`failed`, `inactive` both
            # exit with 3). So we always read stdout.
            state = (r.stdout or "").strip()
            return state or "unknown"
        except subprocess.TimeoutExpired:
            return "timeout"
        except FileNotFoundError:
            # systemctl missing from PATH — shouldn't happen on a real
            # NixOS box (the engine wrapper prepends
            # /run/current-system/sw/bin). Surface as "error" so we
            # neither alert nor mask the configuration issue.
            return "error"
        except Exception:
            return "error"


# ---------------------------------------------------------------------
# Registry
# ---------------------------------------------------------------------
# Mapping from source id → class. The engine instantiates and dispatches
# off this; a config key pointing at an id not in this map is logged
# and skipped (rather than crashing the whole tick).

REGISTRY: Dict[str, type] = {
    DiskTemperatureSource.id:    DiskTemperatureSource,
    DiskSpaceSource.id:          DiskSpaceSource,
    SmartSource.id:              SmartSource,
    SensorTemperatureSource.id:  SensorTemperatureSource,
    ServicesDownSource.id:       ServicesDownSource,
}
