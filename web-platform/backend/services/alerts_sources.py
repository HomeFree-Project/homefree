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
import re
import subprocess
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

import httpx

from resolvers.physical_drives import PhysicalDrivesResolver
from services import hwmon
from services.alerts_config import load_alerts_config

logger = logging.getLogger(__name__)


class SourceResult:
    """Per-tick evaluation result.

    Constructor accepts BOTH the legacy `firing=bool` form (existing
    binary sources) and the new `severity='clear'|'warn'|'err'` form
    (sources that distinguish tiers). When both are given, severity
    wins; when only firing is given, severity is derived as 'warn'
    when firing else 'clear'.

    Fields:
      severity   — clear / warn / err for this tick
      value      — peak observation across all items (the engine's
                   high-water-mark for the peak_value column and for
                   the meter's "now" label between alarms)
      message    — human-readable summary for push + history
      readings   — optional per-item detail list, one dict per
                   measurable item the source observed. Shape per
                   entry:
                     name      : "/dev/sda" or "/mnt/tank"
                     value     : float|None
                     class     : "hdd"|"ssd"|"nvme"|"cpu"|... (optional)
                     warn,err  : per-item thresholds (optional)
                     severity  : per-item severity verdict
                   The UI Status-tab card renders one bar per entry.
                   Sources without per-item structure (smart,
                   services-down, etc.) leave it None.

      firing     — read-only property; True iff severity != 'clear'.
                   Retained so old callers and the engine's legacy
                   branch labels keep working.
    """

    def __init__(
        self,
        firing: Optional[bool] = None,
        value: Optional[float] = None,
        message: str = "",
        severity: Optional[str] = None,
        readings: Optional[List[Dict[str, Any]]] = None,
    ) -> None:
        if severity is not None:
            self.severity = severity
        elif firing is not None:
            self.severity = "warn" if firing else "clear"
        else:
            self.severity = "clear"
        self.value = value
        self.message = message
        self.readings = readings

    @property
    def firing(self) -> bool:
        return self.severity != "clear"


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

    Two-tier severity (warn / err) per the Hardware page's colour
    scheme. Source severity = max of per-drive severities. Hysteresis
    applies at the source level: stuck at the current severity until
    every drive is below the lower-tier threshold minus hysteresis.

    `readings` carries one entry per drive so the Status-tab UI can
    render a bar per drive with its own warn/err markers.
    """

    id = "disk-temperature"
    label = "Disk temperature"

    def evaluate(
        self,
        config: Dict[str, Any],
        was_severity: str,
    ) -> SourceResult:
        thresholds_cfg = config.get("thresholds") or {}
        per_class = {
            "hdd": (
                int(thresholds_cfg.get("hdd-warn-c", 45)),
                int(thresholds_cfg.get("hdd-err-c", 50)),
            ),
            "ssd": (
                int(thresholds_cfg.get("ssd-warn-c", 60)),
                int(thresholds_cfg.get("ssd-err-c", 70)),
            ),
            "nvme": (
                int(thresholds_cfg.get("nvme-warn-c", 70)),
                int(thresholds_cfg.get("nvme-err-c", 80)),
            ),
        }
        hysteresis = int(config.get("hysteresis-c", 4))

        try:
            drives = PhysicalDrivesResolver.get_all()
        except Exception:
            return SourceResult(
                severity="clear", value=None,
                message="Drive enumeration failed; skipping tick",
            )

        readings: List[Dict[str, Any]] = []
        peak_t: Optional[float] = None
        for d in drives:
            t = d.get("temp_c")
            if t is None:
                continue
            cls = d.get("drive_class") or "hdd"
            warn, err = per_class.get(cls, per_class["hdd"])
            t_f = float(t)
            if peak_t is None or t_f > peak_t:
                peak_t = t_f
            # Per-drive severity (no hysteresis at the per-item level;
            # source-level hysteresis is applied below to the OVERALL
            # severity).
            if t_f >= err:
                drive_sev = "err"
            elif t_f >= warn:
                drive_sev = "warn"
            else:
                drive_sev = "clear"
            readings.append({
                "name": d.get("device") or d.get("name") or "<unknown>",
                "value": t_f,
                "class": cls,
                "warn": warn,
                "err": err,
                "severity": drive_sev,
            })

        if not readings:
            return SourceResult(
                severity="clear", value=None,
                message="No drive temperature data yet",
            )

        # Tentative source severity = worst per-drive severity.
        tentative = _max_sev(r["severity"] for r in readings)
        # Apply source-level hysteresis: don't downgrade unless ALL
        # drives have cleared the relevant lower-band edge.
        severity = _apply_hysteresis(
            was_severity, tentative, readings, hysteresis,
        )

        message = _format_drive_temp_message(readings, severity, peak_t)
        return SourceResult(
            severity=severity, value=peak_t,
            message=message, readings=readings,
        )


def _max_sev(severities) -> str:
    order = {"clear": 0, "warn": 1, "err": 2}
    rev = {v: k for k, v in order.items()}
    best = 0
    for s in severities:
        best = max(best, order.get(s, 0))
    return rev[best]


def _apply_hysteresis(
    was_severity: str,
    tentative: str,
    readings: List[Dict[str, Any]],
    hysteresis: float,
) -> str:
    """Source-level Schmitt-trigger.

    - Escalations are immediate (tentative wins if it's worse).
    - De-escalations are sticky: to drop from err, EVERY reading
      must be below (err - hysteresis). To drop from warn, EVERY
      reading must be below (warn - hysteresis).

    This avoids flap when one drive sits exactly at the threshold.
    """
    order = {"clear": 0, "warn": 1, "err": 2}
    prev_rank = order.get(was_severity, 0)
    tent_rank = order.get(tentative, 0)

    if tent_rank >= prev_rank:
        # Escalation OR same level — accept immediately.
        return tentative

    # Trying to downgrade. Check that every reading is below the
    # appropriate hysteresis-adjusted lower band.
    if was_severity == "err":
        # Must clear err - hysteresis (per-drive err threshold)
        all_below = all(
            (r.get("value") is None) or (r["value"] < r["err"] - hysteresis)
            for r in readings
        )
        if not all_below:
            return "err"
        # Cleared err; tentative could be warn or clear. Apply same
        # logic recursively.
        return _apply_hysteresis(
            "warn", tentative, readings, hysteresis,
        )
    if was_severity == "warn":
        all_below = all(
            (r.get("value") is None) or (r["value"] < r["warn"] - hysteresis)
            for r in readings
        )
        if not all_below:
            return "warn"
        return "clear"
    return tentative


_DRIVE_TEMP_CLS_LABEL = {"hdd": "HDD", "ssd": "SSD", "nvme": "NVMe"}


def _format_drive_temp_message(
    readings: List[Dict[str, Any]],
    severity: str,
    peak_t: Optional[float],
) -> str:
    """Same shape as before — readable single-line summary suitable for
    push body. Names the offending drive(s) with class + threshold;
    for non-firing, gives the peak observation for the Status-tab
    badge suffix."""
    hot = [r for r in readings if r.get("severity") != "clear"]
    if severity == "clear":
        if peak_t is None:
            return "No drive temperature data yet"
        # Find the drive with the peak temp for the message.
        peak = max(readings, key=lambda r: r.get("value") or 0.0)
        cls = _DRIVE_TEMP_CLS_LABEL.get(peak.get("class"), peak.get("class"))
        return (
            f"All drives below their class thresholds "
            f"(peak {peak.get('name')} [{cls}] @ {int(peak_t)}°C)"
        )
    # Firing — sort hottest first.
    hot.sort(key=lambda r: r.get("value") or 0.0, reverse=True)
    top = hot[0]
    top_cls = _DRIVE_TEMP_CLS_LABEL.get(top.get("class"), top.get("class"))
    threshold = top["err"] if top.get("severity") == "err" else top["warn"]
    head = (
        f"{top.get('name')} [{top_cls}] at "
        f"{int(top.get('value'))}°C "
        f"({top.get('severity').upper()}; threshold {threshold}°C)"
    )
    if len(hot) == 1:
        return head
    others = ", ".join(
        f"{r.get('name')} [{_DRIVE_TEMP_CLS_LABEL.get(r.get('class'), r.get('class'))}]"
        f"@{int(r.get('value'))}°C/{r.get('severity').upper()}"
        for r in hot[1:]
    )
    return head + "; also " + others


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
        was_severity: str,
    ) -> SourceResult:
        warn = int(config.get("threshold-warn-percent", 90))
        err = int(config.get("threshold-err-percent", 95))
        hysteresis = int(config.get("hysteresis-percent", 3))
        fs_types = set(config.get("fs-types") or _DISK_SPACE_DEFAULT_FS_TYPES)
        skip_prefixes = tuple(
            config.get("skip-mount-prefixes") or _DISK_SPACE_DEFAULT_SKIP_PREFIXES
        )

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
                    if mp in seen_mp:
                        continue
                    if "ro" in opts.split(","):
                        continue
                    seen_mp.add(mp)
                    mountpoints.append(mp)
        except OSError as e:
            logger.warning("disk-space: /proc/mounts read failed: %s", e)
            return SourceResult(
                severity="clear", value=None,
                message="Could not enumerate filesystems",
            )

        readings: List[Dict[str, Any]] = []
        peak_pct: Optional[float] = None
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
            if peak_pct is None or pct > peak_pct:
                peak_pct = pct
            if pct >= err:
                sev = "err"
            elif pct >= warn:
                sev = "warn"
            else:
                sev = "clear"
            readings.append({
                "name": mp,
                "value": pct,
                "warn": warn,
                "err": err,
                "severity": sev,
                "total_gb": total_gb,
            })

        if not readings:
            return SourceResult(
                severity="clear", value=None,
                message="No monitored filesystems found",
            )

        tentative = _max_sev(r["severity"] for r in readings)
        severity = _apply_hysteresis(
            was_severity, tentative, readings, hysteresis,
        )

        if severity == "clear":
            top = max(readings, key=lambda r: r.get("value") or 0.0)
            msg = (
                f"All filesystems below {warn}% used "
                f"(peak {top['name']} @ {top['value']}%)"
            )
        else:
            hot = sorted(
                (r for r in readings if r.get("severity") != "clear"),
                key=lambda r: r.get("value") or 0.0, reverse=True,
            )
            top = hot[0]
            threshold = top["err"] if top.get("severity") == "err" else top["warn"]
            head = (
                f"{top['name']} at {top['value']}% used "
                f"({top['severity'].upper()}; threshold {threshold}%, "
                f"{top['total_gb']} GiB total)"
            )
            if len(hot) == 1:
                msg = head
            else:
                others = ", ".join(
                    f"{r['name']}@{r['value']}%/{r['severity'].upper()}"
                    for r in hot[1:]
                )
                msg = head + "; also " + others

        return SourceResult(
            severity=severity, value=peak_pct,
            message=msg, readings=readings,
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
        was_severity: str,
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
_SENSOR_KIND_TO_THRESHOLD_KEYS = {
    "cpu":  ("cpu-warn-c",  "cpu-err-c"),
    "nvme": ("nvme-warn-c", "nvme-err-c"),
    "gpu":  ("gpu-warn-c",  "gpu-err-c"),
}

_SENSOR_KIND_DEFAULTS = {
    "cpu":  (75, 85),
    "nvme": (70, 80),
    "gpu":  (80, 90),
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
        was_severity: str,
    ) -> SourceResult:
        thresholds_cfg = config.get("thresholds") or {}
        per_class: Dict[str, Tuple[int, int]] = {}
        for kind, (warn_key, err_key) in _SENSOR_KIND_TO_THRESHOLD_KEYS.items():
            warn_d, err_d = _SENSOR_KIND_DEFAULTS[kind]
            per_class[kind] = (
                int(thresholds_cfg.get(warn_key, warn_d)),
                int(thresholds_cfg.get(err_key, err_d)),
            )
        hysteresis = int(config.get("hysteresis-c", 4))

        try:
            sensors = hwmon.scan()
        except Exception as e:
            logger.warning("sensor-temperature: hwmon scan failed: %s", e)
            return SourceResult(
                severity="clear", value=None,
                message="Sensor scan failed; skipping tick",
            )

        readings: List[Dict[str, Any]] = []
        peak_t: Optional[float] = None
        for s in sensors:
            kind = s.get("kind") or "other"
            thresholds = per_class.get(kind)
            if thresholds is None:
                # No threshold for this kind (memory / other); skip.
                continue
            warn, err = thresholds
            t = s.get("temp_c")
            if t is None:
                continue
            t_f = float(t)
            display_name = s.get("name") or "?"
            sublabel = s.get("label")
            if sublabel:
                display_name = f"{display_name} ({sublabel})"
            if peak_t is None or t_f > peak_t:
                peak_t = t_f
            if t_f >= err:
                sev = "err"
            elif t_f >= warn:
                sev = "warn"
            else:
                sev = "clear"
            readings.append({
                "name": display_name,
                "value": t_f,
                "class": kind,
                "warn": warn,
                "err": err,
                "severity": sev,
            })

        if not readings:
            return SourceResult(
                severity="clear", value=None,
                message="No monitored sensors present",
            )

        tentative = _max_sev(r["severity"] for r in readings)
        severity = _apply_hysteresis(
            was_severity, tentative, readings, hysteresis,
        )

        if severity == "clear":
            top = max(readings, key=lambda r: r.get("value") or 0.0)
            cls = _SENSOR_KIND_LABEL.get(top.get("class"), top.get("class"))
            msg = (
                f"All sensors below their class thresholds "
                f"(peak {top['name']} [{cls}] @ {int(top['value'])}°C)"
            )
        else:
            hot = sorted(
                (r for r in readings if r.get("severity") != "clear"),
                key=lambda r: r.get("value") or 0.0, reverse=True,
            )
            top = hot[0]
            cls = _SENSOR_KIND_LABEL.get(top.get("class"), top.get("class"))
            threshold = top["err"] if top.get("severity") == "err" else top["warn"]
            head = (
                f"{top['name']} [{cls}] at {int(top['value'])}°C "
                f"({top['severity'].upper()}; threshold {threshold}°C)"
            )
            if len(hot) == 1:
                msg = head
            else:
                others = ", ".join(
                    f"{r['name']} [{_SENSOR_KIND_LABEL.get(r.get('class'), r.get('class'))}]"
                    f"@{int(r.get('value'))}°C/{r.get('severity').upper()}"
                    for r in hot[1:]
                )
                msg = head + "; also " + others

        return SourceResult(
            severity=severity, value=peak_t,
            message=msg, readings=readings,
        )


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
        was_severity: str,
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
# backup-failures
# ---------------------------------------------------------------------

class BackupFailuresSource:
    """Fires when:
      - any scheduled backup unit's last run failed (local or backblaze),
      - OR the backup canary's last self-test failed.

    Pulls the same `BackupOperations.get_backup_health()` /
    `get_canary_status()` data the Backups page health card shows, so
    the Alerts notification and the Backups page agree by construction
    instead of via parallel computation.

    Backup outcomes are binary, so there's no threshold — a single
    failure is worth a push."""

    id = "backup-failures"
    label = "Backup failures"

    def evaluate(
        self,
        config: Dict[str, Any],
        was_severity: str,
    ) -> SourceResult:
        # Lazy-import so the alerts engine startup isn't blocked by a
        # transient issue inside backup_operations' module-level code.
        # Same defensive pattern services_down uses with subprocess.
        try:
            from services.backup_operations import BackupOperations
        except Exception as e:
            logger.warning("backup-failures: import failed: %s", e)
            return SourceResult(
                firing=False, value=None,
                message="BackupOperations module unavailable",
            )

        try:
            health = BackupOperations.get_backup_health()
        except Exception as e:
            logger.warning("backup-failures: get_backup_health raised: %s", e)
            return SourceResult(
                firing=False, value=None,
                message=f"Health query crashed: {e}",
            )

        if not health.get("success"):
            err = health.get("error") or "unknown"
            return SourceResult(
                firing=False, value=None,
                message=f"Health query reported error: {err}",
            )

        failures: List[str] = []

        local = health.get("local") or {}
        local_failed = int(local.get("failed") or 0)
        if local_failed > 0:
            services = local.get("failed_services") or []
            svc_str = ", ".join(services) if services else "?"
            failures.append(f"local: {local_failed} failed ({svc_str})")

        backblaze = health.get("backblaze")
        if backblaze:
            bb_failed = int(backblaze.get("failed") or 0)
            if bb_failed > 0:
                services = backblaze.get("failed_services") or []
                svc_str = ", ".join(services) if services else "?"
                failures.append(f"backblaze: {bb_failed} failed ({svc_str})")

        # Canary check — independent of backup unit success since a
        # backup can exit 0 and still be unrestorable.
        try:
            canary = BackupOperations.get_canary_status()
            if canary.get("success") and canary.get("enabled"):
                result = canary.get("result") or {}
                if result.get("result") == "fail":
                    detail = result.get("detail") or "fail"
                    failures.append(f"canary: {detail}")
        except Exception as e:
            # Canary-specific errors are not alertable on their own —
            # the backup unit failures above are enough signal.
            logger.debug("backup-failures: canary check skipped: %s", e)

        if not failures:
            return SourceResult(
                firing=False, value=0.0,
                message="All backups healthy",
            )

        return SourceResult(
            firing=True, value=float(len(failures)),
            message="; ".join(failures),
        )


# ---------------------------------------------------------------------
# attacks
# ---------------------------------------------------------------------

class AttacksSource:
    """Fires when fail2ban's currently-banned IP total across all jails
    crosses `threshold-bans`. Uses the same `fail2ban-client status`
    pipeline the Abuse Blocking page already runs — single source of
    truth.

    "Currently banned" is the running count fail2ban tracks against
    each jail's actions; an unban (timer expiry or admin unban) drops
    the count immediately. We don't track deltas across ticks because
    that requires per-source persistent state for a property the OS
    already maintains."""

    id = "attacks"
    label = "Attacks"

    # `fail2ban-client status` emits:
    #   Status
    #   |- Number of jail:      3
    #   `- Jail list:   caddy-404-storm, caddy-oauth-hammer, sshd
    _JAIL_LIST_RE = re.compile(r"Jail list:\s*(.+)$", re.MULTILINE)
    # `fail2ban-client status <jail>` emits a "Currently banned: N" line
    # inside the Actions section.
    _BANNED_RE = re.compile(r"Currently banned:\s*(\d+)")

    def evaluate(
        self,
        config: Dict[str, Any],
        was_severity: str,
    ) -> SourceResult:
        threshold = int(config.get("threshold-bans", 5))
        hysteresis = int(config.get("hysteresis-bans", 2))
        # Single-tier source; we still need the prior-firing bool for
        # hysteresis. Derive it from the new severity-aware signature.
        was_firing = was_severity != "clear"
        active_threshold = (threshold - hysteresis) if was_firing else threshold

        # List jails.
        try:
            r = subprocess.run(
                ["fail2ban-client", "status"],
                capture_output=True, text=True, timeout=10,
            )
        except FileNotFoundError:
            # fail2ban-client absent — fail2ban not enabled on this
            # box. Not an attack condition, just no signal.
            return SourceResult(
                firing=False, value=None,
                message="fail2ban not installed",
            )
        except subprocess.TimeoutExpired:
            return SourceResult(
                firing=False, value=None,
                message="fail2ban-client timed out",
            )
        except Exception as e:
            logger.warning("attacks: fail2ban-client status raised: %s", e)
            return SourceResult(
                firing=False, value=None,
                message=f"fail2ban query failed: {e}",
            )

        if r.returncode != 0:
            return SourceResult(
                firing=False, value=None,
                message="fail2ban-client status returned non-zero",
            )

        m = self._JAIL_LIST_RE.search(r.stdout)
        if not m:
            return SourceResult(
                firing=False, value=0.0,
                message="No fail2ban jails configured",
            )

        jails = [j.strip() for j in m.group(1).split(",") if j.strip()]
        per_jail: List[Tuple[str, int]] = []
        total = 0
        for jail in jails:
            try:
                rj = subprocess.run(
                    ["fail2ban-client", "status", jail],
                    capture_output=True, text=True, timeout=10,
                )
                mb = self._BANNED_RE.search(rj.stdout)
                if mb:
                    n = int(mb.group(1))
                    per_jail.append((jail, n))
                    total += n
            except Exception as e:
                logger.debug("attacks: jail %s read failed: %s", jail, e)
                continue

        if total < active_threshold:
            return SourceResult(
                firing=False, value=float(total),
                message=(
                    f"{total} IP(s) currently banned "
                    f"(under threshold {threshold})"
                ),
            )

        # Firing — show top jails by ban count for context.
        nonzero = sorted(
            (p for p in per_jail if p[1] > 0),
            key=lambda x: x[1], reverse=True,
        )
        top = ", ".join(f"{j}={n}" for j, n in nonzero[:3])
        if len(nonzero) > 3:
            top += f" (+{len(nonzero) - 3} more)"
        return SourceResult(
            firing=True, value=float(total),
            message=(
                f"{total} IP(s) currently banned (threshold {threshold}): {top}"
            ),
        )


# ---------------------------------------------------------------------
# tls-cert
# ---------------------------------------------------------------------

class TlsCertSource:
    """Fires when any cert under Caddy's storage is expiring within
    `warn-days`, or already expired. Walks the standard Caddy storage
    layout
    /var/lib/caddy/.local/share/caddy/certificates/<ca>/<host>/<host>.crt
    and reads NotAfter via openssl.

    Catches the failure mode where ACME silently stops renewing
    (DNS-01 token revoked, rate-limit hit, CA terms changed). Caddy
    keeps retrying in the background but doesn't surface the failure
    anywhere user-visible; the first user-visible signal is a browser
    cert error at expiry. Watching the file mtime / NotAfter from
    outside Caddy is the simplest unambiguous check that doesn't
    require Caddy admin API access."""

    id = "tls-cert"
    label = "TLS certificates"

    CERT_ROOT = Path("/var/lib/caddy/.local/share/caddy/certificates")

    def evaluate(
        self,
        config: Dict[str, Any],
        was_severity: str,
    ) -> SourceResult:
        warn_days = int(config.get("warn-days", 14))

        if not self.CERT_ROOT.exists():
            return SourceResult(
                firing=False, value=None,
                message="Caddy cert dir not present",
            )

        certs = list(self.CERT_ROOT.rglob("*.crt"))
        if not certs:
            return SourceResult(
                firing=False, value=0.0,
                message="No certificates found",
            )

        now = datetime.now(timezone.utc)
        expiring: List[Tuple[str, int]] = []  # (host, days_remaining)
        expired:  List[Tuple[str, int]] = []  # (host, days_overdue)
        min_days: Optional[float] = None
        min_host: Optional[str] = None
        parsed_count = 0

        for crt in certs:
            not_after = self._read_not_after(crt)
            if not_after is None:
                continue
            parsed_count += 1
            host = crt.stem  # filename minus .crt = canonical host
            delta_days = (not_after - now).total_seconds() / 86400.0
            if min_days is None or delta_days < min_days:
                min_days = delta_days
                min_host = host
            if delta_days < 0:
                expired.append((host, int(-delta_days)))
            elif delta_days < warn_days:
                expiring.append((host, int(delta_days)))

        if parsed_count == 0:
            return SourceResult(
                firing=False, value=None,
                message="Could not parse any certificates",
            )

        if not expired and not expiring:
            return SourceResult(
                firing=False, value=float(min_days or 0),
                message=(
                    f"All {parsed_count} cert(s) OK "
                    f"(earliest: {min_host} in {int(min_days or 0)}d)"
                ),
            )

        msgs: List[str] = []
        for host, d in expired:
            msgs.append(f"{host} EXPIRED ({d}d ago)")
        for host, d in expiring:
            msgs.append(f"{host} expires in {d}d")
        head = "; ".join(msgs[:3])
        if len(msgs) > 3:
            head += f" (+{len(msgs) - 3} more)"
        return SourceResult(
            firing=True,
            value=float(min(min_days or 0, 0)) if expired else float(min_days or 0),
            message=head,
        )

    @staticmethod
    def _read_not_after(crt: Path) -> Optional[datetime]:
        """Run `openssl x509 -in <crt> -noout -enddate` and parse.
        Output format: `notAfter=Aug 25 20:12:00 2026 GMT`.
        Returns a UTC-aware datetime, or None on parse failure."""
        try:
            r = subprocess.run(
                ["openssl", "x509", "-in", str(crt), "-noout", "-enddate"],
                capture_output=True, text=True, timeout=5,
            )
            if r.returncode != 0:
                return None
            line = (r.stdout or "").strip()
            if not line.startswith("notAfter="):
                return None
            date_str = line.split("=", 1)[1]
            # openssl always emits GMT here; strip and treat as UTC.
            # Avoids %Z locale ambiguity (it's not portable for "GMT").
            date_str = date_str.removesuffix(" GMT")
            naive = datetime.strptime(date_str, "%b %d %H:%M:%S %Y")
            return naive.replace(tzinfo=timezone.utc)
        except Exception as e:
            logger.debug("tls-cert: parse failed for %s: %s", crt, e)
            return None


# ---------------------------------------------------------------------
# Shared helper: read service-config catalog
# ---------------------------------------------------------------------

_SERVICE_CONFIG_PATH = Path("/etc/homefree/service-config.json")


def _load_catalog() -> List[Dict[str, Any]]:
    """Read /etc/homefree/service-config.json. Returns [] on any
    failure — sources that depend on the catalog handle empty
    gracefully (typically by skipping evaluation)."""
    try:
        return json.loads(_SERVICE_CONFIG_PATH.read_text())
    except FileNotFoundError:
        return []
    except Exception as e:
        logger.warning("catalog parse failed: %s", e)
        return []


def _catalog_entry(catalog: List[Dict[str, Any]], label: str) -> Optional[Dict[str, Any]]:
    for entry in catalog:
        if entry.get("label") == label:
            return entry
    return None


def _any_wan_public(catalog: List[Dict[str, Any]]) -> bool:
    """True iff some catalog entry is enabled AND its reverse-proxy
    block is public. The signal `wan-accessibility` uses to decide
    whether to probe at all."""
    for entry in catalog:
        if not entry.get("enable"):
            continue
        rp = entry.get("reverse-proxy") or {}
        if rp.get("enable") and rp.get("public"):
            return True
    return False


# ---------------------------------------------------------------------
# wan-accessibility
# ---------------------------------------------------------------------

class WanAccessibilitySource:
    """Verifies that the box's public-DNS A record actually matches its
    egress public IP. Catches the DDNS-misroute scenario deterministically
    without depending on a (flaky in practice) third-party reverse-ping
    service. Limitations documented in module.nix.

    Does TWO outbound HTTPS calls per tick:
      1. ipinfo.io/ip — the box's egress IP, what NAT shows the world.
      2. cloudflare-dns.com/dns-query — public DNS A records for
         `system.domain`, bypassing local unbound.

    Then: fire if the IPs don't intersect, or if the DoH returns no
    A record at all. Either condition means the public path to this
    box is currently broken from the outside.

    Each call has its own try/except: a transient failure of EITHER
    endpoint maps to a benign non-firing 'skip this tick' state
    rather than a false positive. The trichotomy from the original
    helper isn't needed here because the failure modes are explicit
    (HTTP error / parse error / IP mismatch) instead of inferred."""

    id = "wan-accessibility"
    label = "WAN accessibility"

    _DEFAULT_PUBLIC_IP_URL = "https://ipinfo.io/ip"
    _DEFAULT_DOH_URL = "https://cloudflare-dns.com/dns-query"

    def evaluate(
        self,
        config: Dict[str, Any],
        was_severity: str,
    ) -> SourceResult:
        catalog = _load_catalog()
        if not _any_wan_public(catalog):
            return SourceResult(
                firing=False, value=None,
                message="Box not WAN-exposed; skipping check",
            )

        cfg_blob = load_alerts_config()
        domain = ((cfg_blob.get("system") or {}).get("domain")) or ""
        if not domain:
            return SourceResult(
                firing=False, value=None,
                message="No system.domain in alerts-config; cannot check",
            )

        public_ip_url = config.get("public-ip-url") or self._DEFAULT_PUBLIC_IP_URL
        doh_url = config.get("doh-url") or self._DEFAULT_DOH_URL

        public_ip = self._fetch_public_ip(public_ip_url)
        if public_ip is None:
            # ipinfo (or whatever) didn't respond cleanly. Without
            # knowing our public IP we can't make a verdict — skip
            # this tick rather than alert.
            return SourceResult(
                firing=False, value=None,
                message="Could not fetch public IP from " + public_ip_url,
            )

        a_records, dns_err = self._resolve_a_records(doh_url, domain)
        if dns_err is not None:
            # DoH failed — same reasoning, skip rather than false-fire.
            return SourceResult(
                firing=False, value=None,
                message=f"Public DNS lookup failed: {dns_err}",
            )

        if not a_records:
            # DoH succeeded but returned no A records. That's an
            # unambiguous "domain doesn't resolve publicly" verdict.
            return SourceResult(
                firing=True, value=1.0,
                message=(
                    f"No public A record for {domain} — DDNS / DNS "
                    f"misconfigured. Public IP is {public_ip}."
                ),
            )

        if public_ip not in a_records:
            # The DDNS-misroute case the user asked about.
            return SourceResult(
                firing=True, value=1.0,
                message=(
                    f"DDNS mismatch: public IP {public_ip} not in "
                    f"DNS A records {a_records} for {domain}"
                ),
            )

        return SourceResult(
            firing=False, value=0.0,
            message=f"DDNS OK: {domain} → {public_ip}",
        )

    @staticmethod
    def _fetch_public_ip(url: str) -> Optional[str]:
        """Return the egress IP as a plain string, or None on failure.
        Body is expected to be a single IP literal — ipinfo.io/ip's
        shape. Strips whitespace and validates that what came back
        actually parses as an IPv4 or IPv6 address."""
        import ipaddress
        try:
            r = httpx.get(url, timeout=10.0, follow_redirects=True)
            r.raise_for_status()
        except Exception as e:
            logger.info("public-ip fetch %s failed: %s", url, e)
            return None
        body = (r.text or "").strip()
        try:
            return str(ipaddress.ip_address(body))
        except ValueError:
            logger.warning("public-ip fetch %s returned non-IP %r", url, body[:80])
            return None

    @staticmethod
    def _resolve_a_records(
        doh_url: str, domain: str,
    ) -> Tuple[List[str], Optional[str]]:
        """Return (a_records, error). On success error is None and
        a_records may be empty (meaning the DoH lookup succeeded and
        the domain has no public A record — itself an alert-worthy
        verdict). On HTTP / parse failure, returns ([], error_string).

        Cloudflare DoH JSON shape:
          {
            "Status": 0,                       // 0 = NOERROR
            "Answer": [
              {"name": "...", "type": 1, "TTL": 300, "data": "1.2.3.4"},
              ...
            ],
            ...
          }
        type 1 = A; we filter for those."""
        try:
            r = httpx.get(
                doh_url,
                params={"name": domain, "type": "A"},
                headers={"Accept": "application/dns-json"},
                timeout=10.0,
                follow_redirects=True,
            )
            r.raise_for_status()
        except Exception as e:
            return ([], f"DoH HTTP error: {e}")
        try:
            data = r.json()
        except Exception as e:
            return ([], f"DoH body not JSON: {e}")

        # Non-zero Status means an upstream DNS error (NXDOMAIN, SERVFAIL,
        # etc.). Treat as "no A records" — the message lookup will
        # interpret that as a misconfigured public DNS.
        dns_status = data.get("Status")
        if isinstance(dns_status, int) and dns_status != 0:
            logger.info("DoH lookup for %s returned Status=%s", domain, dns_status)
            return ([], None)

        answers = data.get("Answer") or []
        a_records = []
        for ans in answers:
            if not isinstance(ans, dict):
                continue
            # type 1 is A (IPv4). We ignore AAAA for this check because
            # ipinfo.io/ip returns IPv4 by default — comparing v4 to v6
            # would always mismatch.
            if ans.get("type") == 1:
                data_field = ans.get("data")
                if isinstance(data_field, str):
                    a_records.append(data_field)
        return (a_records, None)


# ---------------------------------------------------------------------
# headscale-accessibility
# ---------------------------------------------------------------------

class HeadscaleAccessibilitySource:
    """Four-check health of the self-hosted Headscale control plane:
    units active, API responds, recent journal clean, externally
    reachable when WAN-public.

    Auto-skips when Headscale isn't enabled on this box (label
    `headscale` absent from the catalog, or enable=false). Does NOT
    attempt to verify a real Tailscale client — that requires a
    second host; this source covers "everything this box exposes
    for Headscale looks healthy."""

    id = "headscale-accessibility"
    label = "Headscale accessibility"

    HEADSCALE_LABEL = "headscale"
    HEADSCALE_UNIT = "headscale.service"
    HEADPLANE_UNIT = "headplane.service"

    def evaluate(
        self,
        config: Dict[str, Any],
        was_severity: str,
    ) -> SourceResult:
        catalog = _load_catalog()
        entry = _catalog_entry(catalog, self.HEADSCALE_LABEL)
        if entry is None or not entry.get("enable"):
            return SourceResult(
                firing=False, value=None,
                message="Headscale not enabled; skipping checks",
            )

        failures: List[str] = []

        # 1. Units active (or at least not `failed`).
        for unit in (self.HEADSCALE_UNIT, self.HEADPLANE_UNIT):
            state = self._unit_state(unit)
            if state == "failed":
                failures.append(f"{unit} is {state}")
            elif state == "missing":
                # Unit doesn't exist (e.g. headplane disabled on
                # this box). Not a failure.
                continue

        # 2. Headscale API responds to a read-only CLI call.
        api_err = self._headscale_users_list_err()
        if api_err:
            failures.append(f"headscale API: {api_err}")

        # 3. Recent error-level journal lines.
        window = config.get("journal-window") or "5 min ago"
        journal_err = self._recent_journal_errors(self.HEADSCALE_UNIT, window)
        if journal_err:
            failures.append(f"journal err: {journal_err}")

        # NOTE: external WAN-reachability check for headscale.<domain>
        # used to live here. It was removed when the reverse-ping
        # design pivoted to DNS-consistency (free reverse-ping
        # services were too flaky for an alert source — see
        # services/alerts_external_probe.py header). The
        # `wan-accessibility` source's DNS-consistency check covers
        # the base domain; a headscale-specific DNS check would
        # duplicate it. If `wan-accessibility` fires, headscale's
        # external path is broken too. We rely on the three local
        # checks above (units, API, journal) for Headscale-specific
        # signal.

        if not failures:
            return SourceResult(
                firing=False, value=0.0,
                message="Headscale healthy",
            )

        return SourceResult(
            firing=True, value=float(len(failures)),
            message="; ".join(failures),
        )

    @staticmethod
    def _unit_state(unit: str) -> str:
        """Same convention as ServicesDownSource — returns the bare
        is-active state string. Adds a `missing` return for the case
        where the unit file doesn't exist (Headplane absent), so the
        caller can distinguish it from `failed`."""
        try:
            r = subprocess.run(
                ["systemctl", "is-active", unit],
                capture_output=True, text=True, timeout=5,
            )
            state = (r.stdout or "").strip() or "unknown"
            # `inactive` from is-active for a non-existent unit is
            # indistinguishable from a stopped unit. Disambiguate via
            # is-enabled which returns `static`/`enabled`/... for
            # existing units and exits non-zero with empty output for
            # missing ones.
            if state == "inactive":
                r2 = subprocess.run(
                    ["systemctl", "is-enabled", unit],
                    capture_output=True, text=True, timeout=5,
                )
                if (r2.returncode != 0
                        and not (r2.stdout or "").strip()):
                    return "missing"
            return state
        except subprocess.TimeoutExpired:
            return "timeout"
        except FileNotFoundError:
            return "error"
        except Exception:
            return "error"

    @staticmethod
    def _headscale_users_list_err() -> Optional[str]:
        """The established readiness pattern from apps/headscale: the
        CLI's `users list -o json` succeeds iff the API is up. We
        only care about the exit status, not the result rows.

        Returns None on success, or a short error string on failure.
        FileNotFoundError (headscale not on PATH) is reported as
        "binary not on PATH" rather than swallowed — if Headscale is
        supposed to be running per the catalog, missing binary IS a
        problem worth surfacing."""
        try:
            r = subprocess.run(
                ["headscale", "users", "list", "-o", "json"],
                capture_output=True, text=True, timeout=10,
            )
        except subprocess.TimeoutExpired:
            return "users-list timed out"
        except FileNotFoundError:
            return "headscale binary not on PATH"
        except Exception as e:
            return f"users-list raised: {e}"
        if r.returncode == 0:
            return None
        # First line of stderr is the most informative bit.
        err = (r.stderr or "").strip().splitlines()
        return err[0] if err else f"exit {r.returncode}"

    @staticmethod
    def _recent_journal_errors(unit: str, since: str) -> Optional[str]:
        """Run `journalctl -u <unit> -p err --since <since>` and
        return a short summary if non-empty, else None. We don't
        report the full lines (could be many) — just the count and
        the first line for triage."""
        try:
            r = subprocess.run(
                [
                    "journalctl",
                    "-u", unit,
                    "-p", "err",
                    "--since", since,
                    "--no-pager",
                    "--output=cat",
                ],
                capture_output=True, text=True, timeout=10,
            )
        except subprocess.TimeoutExpired:
            return None  # Not the alert this source fires on.
        except FileNotFoundError:
            return None
        except Exception as e:
            logger.debug("journalctl on %s raised: %s", unit, e)
            return None
        out = (r.stdout or "").strip()
        if not out:
            return None
        lines = out.splitlines()
        head = lines[0]
        # Trim very long log lines so the alert message doesn't
        # balloon — push notifications truncate poorly.
        if len(head) > 160:
            head = head[:157] + "…"
        if len(lines) == 1:
            return head
        return f"{len(lines)} entries; first: {head}"


# ---------------------------------------------------------------------
# Registry
# ---------------------------------------------------------------------
# Mapping from source id → class. The engine instantiates and dispatches
# off this; a config key pointing at an id not in this map is logged
# and skipped (rather than crashing the whole tick).

REGISTRY: Dict[str, type] = {
    DiskTemperatureSource.id:           DiskTemperatureSource,
    DiskSpaceSource.id:                 DiskSpaceSource,
    SmartSource.id:                     SmartSource,
    SensorTemperatureSource.id:         SensorTemperatureSource,
    ServicesDownSource.id:              ServicesDownSource,
    BackupFailuresSource.id:            BackupFailuresSource,
    AttacksSource.id:                   AttacksSource,
    TlsCertSource.id:                   TlsCertSource,
    WanAccessibilitySource.id:          WanAccessibilitySource,
    HeadscaleAccessibilitySource.id:    HeadscaleAccessibilitySource,
}
