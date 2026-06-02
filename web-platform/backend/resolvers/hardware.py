"""
Hardware resolver — backs the admin "Hardware" page.

Three responsibilities today:

  * `get_overview()`  — point-in-time per-drive SMART + a small set of
    motherboard sensor temps (CPU, memory, NVMe controller), all in
    one round-trip so the page renders without a chart of pending
    requests.

  * `get_drive_temp_history()` — read-only over the drive-temperature
    SQLite written by `homefree-drive-temp-sampler`.

The split mirrors dashboard.py's overview/history split. Room to grow
into more sensor surface (fan RPMs, ACPI thermal zones, per-NVMe
controller throttling state) without changing the route shape.
"""

import logging
import os
from typing import Any, Dict

from resolvers.firmware import FirmwareResolver
from resolvers.physical_drives import PhysicalDrivesResolver
from services import hw_buckets, hwmon
from services.alerts_config import load_alerts_config
from services.dashboard_history_store import (
    DashboardHistoryStore,
    DEFAULT_DB_PATH as DASHBOARD_DB_PATH,
    HISTORY_SECONDS as DASHBOARD_HISTORY_SECONDS,
    SAMPLE_INTERVAL as DASHBOARD_SAMPLE_INTERVAL,
)
from services.drive_temp_history_store import (
    DriveTempHistoryStore,
    DEFAULT_DB_PATH as DRIVE_TEMP_DB_PATH,
    HISTORY_SECONDS as DRIVE_TEMP_HISTORY_SECONDS,
    SAMPLE_INTERVAL as DRIVE_TEMP_SAMPLE_INTERVAL,
)

logger = logging.getLogger(__name__)


class HardwareResolver:

    @staticmethod
    def get_overview() -> Dict[str, Any]:
        """Snapshot for the Hardware page: drives + sensors + firmware.

        Each sensor is augmented with `warn_c` / `err_c` — the resolved
        threshold for THIS sensor on THIS box (driver-reported `_crit`
        first, then a CPUID-family / PCI-vendor bucket, with the user's
        alerts-config override layered on top per-tier). The Hardware
        page reads these directly so its chart lines and severity
        coloring always agree with what fires the sensor-temperature
        alert."""
        return {
            "physical_drives": PhysicalDrivesResolver.get_all(),
            "sensors": HardwareResolver._sensors_with_thresholds(),
            "firmware": FirmwareResolver.get_status(),
        }

    @staticmethod
    def _sensors_with_thresholds() -> list:
        """hwmon.scan() + per-sensor warn_c/err_c via the same cascade
        the alerts engine uses. User overrides come from
        /etc/homefree/alerts-config.json — absence (e.g. alerts feature
        off) means inferred-only, which is fine."""
        # Per-class user overrides — same shape the alert source reads.
        try:
            alerts_cfg = load_alerts_config() or {}
            src_cfg = ((alerts_cfg.get("sources") or {})
                       .get("sensor-temperature") or {})
            thr_cfg = src_cfg.get("thresholds") or {}
        except Exception:
            thr_cfg = {}

        def _ov(key):
            v = thr_cfg.get(key)
            if v is None:
                return None
            try:
                return int(v)
            except (TypeError, ValueError):
                return None

        overrides_by_kind = {
            "cpu":  (_ov("cpu-warn-c"),  _ov("cpu-err-c")),
            "nvme": (_ov("nvme-warn-c"), _ov("nvme-err-c")),
            "gpu":  (_ov("gpu-warn-c"),  _ov("gpu-err-c")),
        }

        sensors = hwmon.scan()
        for s in sensors:
            kind = s.get("kind")
            if kind not in overrides_by_kind:
                # memory / other — no threshold concept here, leave
                # warn_c / err_c absent so the UI knows to skip.
                continue
            user_warn, user_err = overrides_by_kind[kind]
            warn, err = hw_buckets.resolve_thresholds_with_overrides(
                kind, s.get("crit_c"), s.get("max_c"), user_warn, user_err,
            )
            s["warn_c"] = warn
            s["err_c"] = err
        return sensors

    @staticmethod
    def get_drive_temp_history() -> Dict[str, Any]:
        """24h of per-drive temperature samples from the dedicated DB."""
        store = DriveTempHistoryStore(DRIVE_TEMP_DB_PATH)
        return {
            "sample_interval": DRIVE_TEMP_SAMPLE_INTERVAL,
            "window_seconds": DRIVE_TEMP_HISTORY_SECONDS,
            "by_device": store.get_history(DRIVE_TEMP_HISTORY_SECONDS),
        }

    @staticmethod
    def get_sensor_temp_history() -> Dict[str, Any]:
        """24h of per-sensor (hwmon) temperature samples.

        Lives in the dashboard sampler's DB because hwmon reads are
        unprivileged — same sampler unit that already writes CPU /
        memory / throughput. Don't pull in admin-api environment
        overrides; the sampler service sets HOMEFREE_DASHBOARD_DB and
        admin-api reads the same path via the resolved DEFAULT.
        """
        db = os.environ.get("HOMEFREE_DASHBOARD_DB", DASHBOARD_DB_PATH)
        store = DashboardHistoryStore(db)
        data = store.get_sensor_temp_history(DASHBOARD_HISTORY_SECONDS)
        return {
            "sample_interval": DASHBOARD_SAMPLE_INTERVAL,
            "window_seconds": DASHBOARD_HISTORY_SECONDS,
            **data,
        }
