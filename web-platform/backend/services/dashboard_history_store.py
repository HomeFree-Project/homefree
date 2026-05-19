"""
SQLite-backed store for dashboard time-series history.

Shared by two processes with deliberately split roles:

  * The standalone `homefree-dashboard-sampler` service is the *only*
    writer. It samples throughput + connectivity every SAMPLE_INTERVAL
    seconds and INSERTs one row per tick. Because the sampler's lifetime
    is decoupled from admin-api, history survives admin-api rebuilds and
    blue/green flips with no gaps and no double-writes — there is exactly
    one writer, always.

  * The admin-api (either blue or green colour) is a pure *reader*. Its
    `/api/dashboard/history` endpoint runs a single indexed time-range
    SELECT. WAL mode means reads never block the writer and vice versa.

The DB lives in a state directory shared by the sampler user and the
admin-api user (group-readable). One small row per tick keeps a 24-hour
window at well under a couple of MB; the sampler prunes older rows.
"""

import json
import logging
import sqlite3
import time
from pathlib import Path
from typing import Any, Dict, List, Optional

logger = logging.getLogger(__name__)

# --- retention -----------------------------------------------------------
SAMPLE_INTERVAL = 10                 # seconds between sampler ticks
HISTORY_SECONDS = 24 * 3600          # keep ~24 hours of history

# Default DB location. Both the sampler unit and the admin-api units
# point at this path; overridable via the constructor for tests.
DEFAULT_DB_PATH = "/var/lib/homefree-dashboard/history.db"


class DashboardHistoryStore:
    """Thin SQLite wrapper. Cheap to construct; opens a fresh connection
    per call so it is safe to use from any thread or process."""

    def __init__(self, db_path: str = DEFAULT_DB_PATH) -> None:
        self.db_path = db_path

    # --- connection helpers ---------------------------------------------

    def _connect(self) -> sqlite3.Connection:
        conn = sqlite3.connect(self.db_path, timeout=5.0)
        # WAL: concurrent reader (admin-api) + writer (sampler) without
        # blocking each other. NORMAL sync is the standard WAL pairing —
        # durable enough for metrics, and a lost final tick on power-cut
        # is immaterial here.
        conn.execute("PRAGMA journal_mode=WAL")
        conn.execute("PRAGMA synchronous=NORMAL")
        return conn

    def init_schema(self) -> None:
        """Create the table if absent. Called once by the sampler at
        startup (the writer owns schema creation)."""
        Path(self.db_path).parent.mkdir(parents=True, exist_ok=True)
        with self._connect() as conn:
            conn.execute(
                """
                CREATE TABLE IF NOT EXISTS samples (
                    ts              INTEGER PRIMARY KEY,
                    connected       INTEGER NOT NULL,
                    latency_ms      REAL,
                    cpu_percent     REAL NOT NULL,
                    memory_percent  REAL NOT NULL,
                    rates_json      TEXT NOT NULL
                )
                """
            )
            # PRIMARY KEY on ts already gives an index for range scans.

    # --- writer side (sampler only) -------------------------------------

    def insert_sample(self, sample: Dict[str, Any]) -> None:
        """Append one tick. `ts` is the primary key; INSERT OR REPLACE
        keeps a re-sampled second idempotent rather than erroring."""
        with self._connect() as conn:
            conn.execute(
                """
                INSERT OR REPLACE INTO samples
                    (ts, connected, latency_ms, cpu_percent,
                     memory_percent, rates_json)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                (
                    int(sample["ts"]),
                    1 if sample["connected"] else 0,
                    sample["latency_ms"],
                    sample["cpu_percent"],
                    sample["memory_percent"],
                    json.dumps(sample["rates"], separators=(",", ":")),
                ),
            )

    def prune(self, window_seconds: int = HISTORY_SECONDS) -> None:
        """Drop rows older than the retention window. Called by the
        sampler periodically — keeps the DB bounded."""
        cutoff = int(time.time()) - window_seconds
        with self._connect() as conn:
            conn.execute("DELETE FROM samples WHERE ts < ?", (cutoff,))

    # --- reader side (admin-api) ----------------------------------------

    def get_samples(
        self, window_seconds: int = HISTORY_SECONDS
    ) -> List[Dict[str, Any]]:
        """Samples within the window, oldest first. Returns [] if the DB
        does not exist yet (sampler hasn't had its first tick)."""
        if not Path(self.db_path).exists():
            return []
        cutoff = int(time.time()) - window_seconds
        try:
            with self._connect() as conn:
                rows = conn.execute(
                    """
                    SELECT ts, connected, latency_ms, cpu_percent,
                           memory_percent, rates_json
                    FROM samples
                    WHERE ts >= ?
                    ORDER BY ts ASC
                    """,
                    (cutoff,),
                ).fetchall()
        except sqlite3.Error as e:
            logger.warning(f"dashboard history: read failed: {e}")
            return []
        out: List[Dict[str, Any]] = []
        for ts, connected, latency, cpu, mem, rates_json in rows:
            try:
                rates = json.loads(rates_json)
            except (ValueError, TypeError):
                rates = {}
            out.append(
                {
                    "ts": ts,
                    "connected": bool(connected),
                    "latency_ms": latency,
                    "cpu_percent": cpu,
                    "memory_percent": mem,
                    "rates": rates,
                }
            )
        return out

    def latest_sample(self) -> Optional[Dict[str, Any]]:
        """Most recent sample, or None when the DB is empty."""
        samples = self._tail(1)
        return samples[-1] if samples else None

    def _tail(self, n: int) -> List[Dict[str, Any]]:
        if not Path(self.db_path).exists():
            return []
        try:
            with self._connect() as conn:
                rows = conn.execute(
                    """
                    SELECT ts, connected, latency_ms, cpu_percent,
                           memory_percent, rates_json
                    FROM samples ORDER BY ts DESC LIMIT ?
                    """,
                    (n,),
                ).fetchall()
        except sqlite3.Error as e:
            logger.warning(f"dashboard history: tail read failed: {e}")
            return []
        out: List[Dict[str, Any]] = []
        for ts, connected, latency, cpu, mem, rates_json in reversed(rows):
            try:
                rates = json.loads(rates_json)
            except (ValueError, TypeError):
                rates = {}
            out.append(
                {
                    "ts": ts,
                    "connected": bool(connected),
                    "latency_ms": latency,
                    "cpu_percent": cpu,
                    "memory_percent": mem,
                    "rates": rates,
                }
            )
        return out
