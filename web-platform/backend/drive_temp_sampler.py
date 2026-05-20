#!/usr/bin/env python3
"""
HomeFree drive-temperature sampler — standalone collector.

Runs as `homefree-drive-temp-sampler`, independent of admin-api (so the
chart history survives admin-api restarts) and independent of the
dashboard sampler (so that one stays unprivileged).

Privilege: this service is intentionally root. smartctl needs
CAP_SYS_RAWIO to open block devices; ATA SMART pass-through doesn't
work as a non-root user. The unit is locked down with NoNewPrivileges,
ProtectSystem=strict, and a syscall filter narrower than the default.

The sampler reuses PhysicalDrivesResolver to enumerate drives and read
SMART once per tick; only the per-drive `device` and `temp_c` end up
in the DB row — the rest (model, wear, etc.) is point-in-time data
the admin-api already serves separately, so storing it again would
just waste rows.
"""

import logging
import os
import signal
import sys
import time
from typing import Any, Dict, List

from resolvers.physical_drives import PhysicalDrivesResolver
from services.drive_temp_history_store import (
    DriveTempHistoryStore,
    DEFAULT_DB_PATH,
    HISTORY_SECONDS,
    SAMPLE_INTERVAL,
)

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
)
logger = logging.getLogger("drive-temp-sampler")

# Prune retention every this many ticks (~ once per hour at 60s).
PRUNE_EVERY_TICKS = 60


class Sampler:

    def __init__(self, store: DriveTempHistoryStore) -> None:
        self._store = store
        self._stop = False

    def request_stop(self, *_args: Any) -> None:
        self._stop = True

    def run(self) -> None:
        self._store.init_schema()
        logger.info(
            "drive-temp sampler started: interval=%ss window=%sh db=%s",
            SAMPLE_INTERVAL, HISTORY_SECONDS // 3600, self._store.db_path,
        )

        ticks = 0
        # Tick immediately on startup so the chart isn't empty for the
        # first SAMPLE_INTERVAL seconds after a reboot.
        try:
            self._tick()
        except Exception as e:
            logger.error("first tick failed: %s", e)

        while not self._stop:
            for _ in range(SAMPLE_INTERVAL):
                if self._stop:
                    break
                time.sleep(1)
            if self._stop:
                break
            try:
                self._tick()
            except Exception as e:
                logger.error("sampler tick failed: %s", e)
            ticks += 1
            if ticks % PRUNE_EVERY_TICKS == 0:
                try:
                    self._store.prune(HISTORY_SECONDS)
                except Exception as e:
                    logger.error("history prune failed: %s", e)
        logger.info("drive-temp sampler stopping")

    def _tick(self) -> None:
        now = int(time.time())
        # PhysicalDrivesResolver caches for 60s. The sampler invalidates
        # before each tick so it always sees fresh SMART data — the
        # cache is for HTTP callers; the sampler IS the authoritative
        # source.
        PhysicalDrivesResolver.invalidate_cache()
        drives = PhysicalDrivesResolver.get_all()
        readings: List[Dict[str, Any]] = []
        for d in drives:
            readings.append({"device": d["device"], "temp_c": d.get("temp_c")})
        self._store.insert_samples(now, readings)


def main() -> int:
    db_path = os.environ.get("HOMEFREE_DRIVE_TEMP_DB", DEFAULT_DB_PATH)
    sampler = Sampler(DriveTempHistoryStore(db_path))
    signal.signal(signal.SIGTERM, sampler.request_stop)
    signal.signal(signal.SIGINT, sampler.request_stop)
    sampler.run()
    return 0


if __name__ == "__main__":
    sys.exit(main())
