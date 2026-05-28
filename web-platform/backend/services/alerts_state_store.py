"""
SQLite-backed state + history store for the alerts engine.

Two tables, deliberately separate:

- alert_state: ONE row per source_id, holding the *current* status
  (firing or not). Rewritten every tick. This is what hysteresis
  reads from to decide "still firing? new alert? resolved?". Per-tick
  reuse across timer fires is the reason this lives on disk rather
  than in process memory — every alerts-engine tick is a fresh
  oneshot, and we need state to survive between them.

- alert_events: append-only LOG of firings. Each transition open/close
  appends one row (or amends an open row's ended_ts on close). The
  admin UI's Alerts page reads this to render history; the engine
  itself only writes.

Why SQLite (and not a JSON file) for state: a JSON file is easier to
read, but the engine ALSO needs to record event history rows, and
mixing one-record state + appendable history in one JSON file means
re-serialising the whole thing every tick. One sqlite file with two
tables is simpler operationally (one fd, one fsync, one schema) and
the admin-api can SELECT a window of events without parsing the
state. Same split-role pattern the dashboard / drive-temp stores
already use.
"""

import json
import logging
import sqlite3
import time
from pathlib import Path
from typing import Any, Dict, List, Optional

logger = logging.getLogger(__name__)

DEFAULT_DB_PATH = "/var/lib/homefree-alerts/state.db"

# Severity ladder used by the engine. Stored in alert_state.severity
# and alert_events.severity (TEXT columns). The integer ordering is
# also exposed so transition logic can compare severities directly.
SEVERITY_CLEAR = "clear"
SEVERITY_WARN = "warn"
SEVERITY_ERR = "err"
SEVERITY_RANK = {SEVERITY_CLEAR: 0, SEVERITY_WARN: 1, SEVERITY_ERR: 2}


class AlertStateStore:
    """Thin SQLite wrapper. Cheap to construct; opens a fresh
    connection per call so it is safe to use from any thread/process
    (engine writes, admin-api reads)."""

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
                CREATE TABLE IF NOT EXISTS alert_state (
                    source_id    TEXT PRIMARY KEY,
                    firing       INTEGER NOT NULL,
                    started_ts   INTEGER,
                    peak_value   REAL,
                    message      TEXT,
                    updated_ts   INTEGER NOT NULL
                )
                """
            )
            conn.execute(
                """
                CREATE TABLE IF NOT EXISTS alert_events (
                    id           INTEGER PRIMARY KEY AUTOINCREMENT,
                    source_id    TEXT NOT NULL,
                    started_ts   INTEGER NOT NULL,
                    ended_ts     INTEGER,
                    peak_value   REAL,
                    open_message TEXT,
                    close_message TEXT
                )
                """
            )
            # History is read newest-first; this index makes the LIMIT
            # query in get_history a clean reverse scan instead of a
            # full table sort.
            conn.execute(
                "CREATE INDEX IF NOT EXISTS idx_alert_events_started "
                "ON alert_events(started_ts DESC)"
            )
            # ── Additive columns for the severity-tier + per-item-readings
            # extension (rule 11: no destructive migrations). On a fresh
            # DB the CREATE TABLE above won't include them yet; on an
            # existing DB they're added via ALTER TABLE. Both paths
            # converge on the same final shape.
            self._add_column_if_missing(
                conn, "alert_state", "severity",
                "TEXT NOT NULL DEFAULT 'clear'",
            )
            # readings is a JSON-encoded list of per-item dicts the
            # source observed this tick. Schema-less because the
            # shape varies per source (drives carry drive_class,
            # filesystems carry mountpoint, sensors carry kind).
            self._add_column_if_missing(
                conn, "alert_state", "readings", "TEXT",
            )
            self._add_column_if_missing(
                conn, "alert_events", "severity",
                "TEXT NOT NULL DEFAULT 'warn'",
            )

    @staticmethod
    def _add_column_if_missing(
        conn: sqlite3.Connection, table: str, column: str, decl: str,
    ) -> None:
        existing = {
            row[1] for row in conn.execute(
                f"PRAGMA table_info({table})"
            ).fetchall()
        }
        if column not in existing:
            conn.execute(f"ALTER TABLE {table} ADD COLUMN {column} {decl}")

    # --- state side (per-source current status) -------------------------

    def get_state(self, source_id: str) -> Optional[Dict[str, Any]]:
        if not Path(self.db_path).exists():
            return None
        try:
            with self._connect() as conn:
                row = conn.execute(
                    "SELECT firing, started_ts, peak_value, message, "
                    "updated_ts, severity, readings "
                    "FROM alert_state WHERE source_id = ?",
                    (source_id,),
                ).fetchone()
        except sqlite3.Error as e:
            logger.warning("alert_state read failed: %s", e)
            return None
        if not row:
            return None
        return _state_row_to_dict(row)

    def all_states(self) -> Dict[str, Dict[str, Any]]:
        if not Path(self.db_path).exists():
            return {}
        try:
            with self._connect() as conn:
                rows = conn.execute(
                    "SELECT source_id, firing, started_ts, peak_value, "
                    "message, updated_ts, severity, readings "
                    "FROM alert_state"
                ).fetchall()
        except sqlite3.Error as e:
            logger.warning("alert_state all_states read failed: %s", e)
            return {}
        out: Dict[str, Dict[str, Any]] = {}
        for row in rows:
            source_id = row[0]
            out[source_id] = _state_row_to_dict(row[1:])
        return out

    def set_state(
        self,
        source_id: str,
        firing: bool,
        started_ts: Optional[int],
        peak_value: Optional[float],
        message: str,
        severity: str = SEVERITY_CLEAR,
        readings: Optional[List[Dict[str, Any]]] = None,
    ) -> None:
        """Write the per-source state row. `severity` and `readings`
        are the new (post-tier-split) shape; `firing` is mirrored from
        severity for compatibility but should be considered derived."""
        now = int(time.time())
        readings_json = json.dumps(readings) if readings is not None else None
        with self._connect() as conn:
            conn.execute(
                "INSERT OR REPLACE INTO alert_state "
                "(source_id, firing, started_ts, peak_value, message, "
                "updated_ts, severity, readings) "
                "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                (
                    source_id, 1 if firing else 0, started_ts, peak_value,
                    message, now, severity, readings_json,
                ),
            )

    # --- event log (open/close, append/amend) ---------------------------

    def open_event(
        self,
        source_id: str,
        started_ts: int,
        value: float,
        message: str,
        severity: str = SEVERITY_WARN,
    ) -> int:
        """Append a new open event; return its id. `severity` captures
        the level at which the alarm OPENED — a later escalation from
        warn → err is reflected by `update_severity` rather than by
        appending a second event row."""
        with self._connect() as conn:
            cur = conn.execute(
                "INSERT INTO alert_events "
                "(source_id, started_ts, ended_ts, peak_value, open_message, severity) "
                "VALUES (?, ?, NULL, ?, ?, ?)",
                (source_id, started_ts, value, message, severity),
            )
            return int(cur.lastrowid)

    def update_severity(self, source_id: str, severity: str) -> None:
        """Bump the open event's severity column. Used on warn → err
        escalation so the history row's worst-observed severity stays
        in sync with the engine's high-water mark."""
        with self._connect() as conn:
            conn.execute(
                "UPDATE alert_events SET severity = ? "
                "WHERE source_id = ? AND ended_ts IS NULL "
                "  AND CASE severity "
                "        WHEN 'err' THEN 2 WHEN 'warn' THEN 1 ELSE 0 END "
                "    < CASE ? "
                "        WHEN 'err' THEN 2 WHEN 'warn' THEN 1 ELSE 0 END",
                (severity, source_id, severity),
            )

    def update_peak(self, source_id: str, value: float) -> None:
        """Bump the peak_value on the open (ended_ts IS NULL) event for
        this source_id, but only if `value` is higher than what's stored.
        Idempotent: a non-peak reading is a no-op."""
        with self._connect() as conn:
            conn.execute(
                "UPDATE alert_events SET peak_value = ? "
                "WHERE source_id = ? AND ended_ts IS NULL "
                "  AND (peak_value IS NULL OR peak_value < ?)",
                (value, source_id, value),
            )

    def close_event(
        self, source_id: str, ended_ts: int, close_message: str
    ) -> None:
        """Close the most recent open event for this source_id. The
        peak_value was set incrementally via update_peak — we don't
        rewrite it here."""
        with self._connect() as conn:
            conn.execute(
                "UPDATE alert_events SET ended_ts = ?, close_message = ? "
                "WHERE id = (SELECT id FROM alert_events "
                "            WHERE source_id = ? AND ended_ts IS NULL "
                "            ORDER BY started_ts DESC LIMIT 1)",
                (ended_ts, close_message, source_id),
            )

    def get_history(
        self, limit: int = 100, offset: int = 0
    ) -> List[Dict[str, Any]]:
        """Newest-first event history (open or closed). Empty list when
        the DB does not exist yet (engine hasn't run)."""
        if not Path(self.db_path).exists():
            return []
        try:
            with self._connect() as conn:
                rows = conn.execute(
                    "SELECT id, source_id, started_ts, ended_ts, peak_value, "
                    "open_message, close_message, severity FROM alert_events "
                    "ORDER BY started_ts DESC LIMIT ? OFFSET ?",
                    (limit, offset),
                ).fetchall()
        except sqlite3.Error as e:
            logger.warning("alert_events read failed: %s", e)
            return []
        out: List[Dict[str, Any]] = []
        for row in rows:
            out.append({
                "id": row[0],
                "source_id": row[1],
                "started_ts": row[2],
                "ended_ts": row[3],
                "peak_value": row[4],
                "open_message": row[5],
                "close_message": row[6],
                "severity": row[7] or "warn",
            })
        return out


def _state_row_to_dict(row: tuple) -> Dict[str, Any]:
    """Convert a (firing, started_ts, peak_value, message, updated_ts,
    severity, readings) row tuple to the API-shaped dict. Centralises
    the readings JSON-decode + severity defaulting for both
    `get_state` and `all_states`."""
    firing, started_ts, peak_value, message, updated_ts, severity, readings_json = row
    try:
        readings = json.loads(readings_json) if readings_json else None
    except Exception:
        readings = None
    return {
        "firing": bool(firing),
        "started_ts": started_ts,
        "peak_value": peak_value,
        "message": message,
        "updated_ts": updated_ts,
        "severity": severity or SEVERITY_CLEAR,
        "readings": readings,
    }
