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
from services import hwmon
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
        """Snapshot for the Hardware page: drives + sensors + firmware."""
        return {
            "physical_drives": PhysicalDrivesResolver.get_all(),
            "sensors": hwmon.scan(),
            "firmware": FirmwareResolver.get_status(),
        }

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
