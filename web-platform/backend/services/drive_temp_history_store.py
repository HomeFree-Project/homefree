"""
SQLite-backed store for per-drive temperature history.

Same split-role design as the dashboard history store:

  * The standalone `homefree-drive-temp-sampler` service is the only
    writer. It runs as root because smartctl needs CAP_SYS_RAWIO to
    open block devices, and INSERTs one row per drive per tick.

  * The admin-api (either blue/green colour) is a pure reader and uses
    the same module-level singleton pattern as StatsHistory.

A separate DB from the dashboard sampler is deliberate: the dashboard
sampler is locked down (unprivileged user, restricted syscall filter)
and we don't want a smartctl-shaped privilege escalation creeping into
that unit. Each sampler owns one DB.

Schema is intentionally flat — one row per (device, ts). Per-drive
SELECTs and the multi-line chart in the UI both want oldest-first
ordering across all devices in the window.
"""

import logging
import sqlite3
import time
from pathlib import Path
from typing import Any, Dict, List, Optional

logger = logging.getLogger(__name__)

# Sample every minute. Drive temps change slowly; a tighter cadence
# would only poke USB bridges and sleeping disks more than necessary.
SAMPLE_INTERVAL = 60                 # seconds
HISTORY_SECONDS = 24 * 3600          # keep 24h, matching the dashboard

DEFAULT_DB_PATH = "/var/lib/homefree-drive-temps/history.db"


class DriveTempHistoryStore:
    """Thin SQLite wrapper. Cheap to construct; opens a fresh connection
    per call so it is safe to use from any thread or process."""

    def __init__(self, db_path: str = DEFAULT_DB_PATH) -> None:
        self.db_path = db_path

    def _connect(self) -> sqlite3.Connection:
        conn = sqlite3.connect(self.db_path, timeout=5.0)
        conn.execute("PRAGMA journal_mode=WAL")
        conn.execute("PRAGMA synchronous=NORMAL")
        return conn

    def init_schema(self) -> None:
        Path(self.db_path).parent.mkdir(parents=True, exist_ok=True)
        with self._connect() as conn:
            conn.execute(
                """
                CREATE TABLE IF NOT EXISTS drive_temps (
                    ts          INTEGER NOT NULL,
                    device      TEXT NOT NULL,
                    temp_c      INTEGER,
                    PRIMARY KEY (device, ts)
                )
                """
            )
            # Range scans over the full window across all drives go via
            # ts; the PK above already indexes (device, ts) which gives
            # us per-drive lookups, but a leading-ts index helps the
            # "give me every drive's reading in the last 24h" path.
            conn.execute(
                "CREATE INDEX IF NOT EXISTS idx_drive_temps_ts "
                "ON drive_temps(ts)"
            )

    # --- writer side (sampler only) -------------------------------------

    def insert_samples(self, ts: int, readings: List[Dict[str, Any]]) -> None:
        """One transaction per tick — all drives written atomically."""
        rows = [(ts, r["device"], r.get("temp_c")) for r in readings]
        if not rows:
            return
        with self._connect() as conn:
            conn.executemany(
                "INSERT OR REPLACE INTO drive_temps "
                "(ts, device, temp_c) VALUES (?, ?, ?)",
                rows,
            )

    def prune(self, window_seconds: int = HISTORY_SECONDS) -> None:
        cutoff = int(time.time()) - window_seconds
        with self._connect() as conn:
            conn.execute("DELETE FROM drive_temps WHERE ts < ?", (cutoff,))

    # --- reader side (admin-api) ----------------------------------------

    def get_history(
        self, window_seconds: int = HISTORY_SECONDS
    ) -> Dict[str, List[Dict[str, Any]]]:
        """All retained samples grouped by device, oldest first.

        Returns {} if the DB does not exist yet (sampler hasn't ticked).
        """
        if not Path(self.db_path).exists():
            return {}
        cutoff = int(time.time()) - window_seconds
        try:
            with self._connect() as conn:
                rows = conn.execute(
                    """
                    SELECT device, ts, temp_c
                    FROM drive_temps
                    WHERE ts >= ?
                    ORDER BY device ASC, ts ASC
                    """,
                    (cutoff,),
                ).fetchall()
        except sqlite3.Error as e:
            logger.warning("drive temps: read failed: %s", e)
            return {}
        out: Dict[str, List[Dict[str, Any]]] = {}
        for device, ts, temp_c in rows:
            out.setdefault(device, []).append({"ts": ts, "temp_c": temp_c})
        return out
