#!/usr/bin/env python3
"""
HomeFree dashboard sampler — standalone metrics collector.

Runs as its own systemd service (`homefree-dashboard-sampler`), entirely
independent of the admin-api. Every SAMPLE_INTERVAL seconds it takes a
snapshot of WAN connectivity, latency, CPU, memory, and per-interface
throughput, and INSERTs one row into a SQLite database.

Why a separate process rather than a thread inside admin-api:

  * admin-api is deployed blue/green on two ports and is rebuilt often.
    A sampler thread living inside it loses (or gaps) history on every
    restart and every colour flip. This service is never bounced by a
    flip, so history is continuous.

  * There is exactly one sampler process, so there is exactly one writer
    to the DB — no last-writer-wins races between two admin-api colours.

The admin-api reads the same DB read-only to serve /api/dashboard/history.
This process needs no special privileges: psutil counters, net_io_counters
and a TCP connect all work as an unprivileged user.
"""

import logging
import os
import signal
import socket
import sys
import time
from typing import Any, Dict, Optional

import psutil

from services import hwmon
from services.dashboard_history_store import (
    DashboardHistoryStore,
    DEFAULT_DB_PATH,
    HISTORY_SECONDS,
    SAMPLE_INTERVAL,
)

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
)
logger = logging.getLogger("dashboard-sampler")

# Host to probe for connectivity. A TCP connect to a well-known anycast
# resolver on :53 — succeeds fast when WAN is up, fails fast when not.
# We deliberately avoid ICMP (needs raw sockets) and DNS resolution
# (would also exercise the local resolver, muddying the signal).
CONNECTIVITY_HOST = "1.1.1.1"
CONNECTIVITY_PORT = 53
CONNECTIVITY_TIMEOUT = 2.0

# Prune the retention window every this many ticks (~10 min at 10s).
PRUNE_EVERY_TICKS = 60


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


class Sampler:
    """One tick = one DB row. Holds the previous NIC counters so each
    tick can derive throughput from the delta."""

    def __init__(self, store: DashboardHistoryStore) -> None:
        self._store = store
        self._last_counters: Optional[Dict[str, Any]] = None
        self._last_ts: Optional[float] = None
        self._stop = False

    def request_stop(self, *_args: Any) -> None:
        self._stop = True

    def run(self) -> None:
        self._store.init_schema()
        # Prime cpu_percent so the first real reading isn't a bogus 0.
        try:
            psutil.cpu_percent(interval=None)
        except Exception:
            pass
        logger.info(
            "dashboard sampler started: interval=%ss window=%sh db=%s",
            SAMPLE_INTERVAL, HISTORY_SECONDS // 3600, self._store.db_path,
        )

        ticks = 0
        while not self._stop:
            # Sleep first so cpu/throughput have a delta to measure.
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
        logger.info("dashboard sampler stopping")

    def _tick(self) -> None:
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

        connected, latency_ms = _probe_connectivity()

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
            # Per-interface bits/sec, rounded to keep rows small.
            "rates": {
                name: {
                    "rx_bps": round(r["rx_bps"]),
                    "tx_bps": round(r["tx_bps"]),
                }
                for name, r in rates.items()
            },
        }
        self._store.insert_sample(sample)

        # Motherboard sensor temps — pure sysfs reads, no privileges
        # needed. Written into the same DB on the same cadence so the
        # Hardware page's sensor charts share the dashboard window.
        try:
            sensors = hwmon.scan()
            readings = [
                {
                    "sensor": s["key"],
                    "kind": s["kind"],
                    "temp_c": s["temp_c"],
                }
                for s in sensors
            ]
            self._store.insert_sensor_temps(int(now), readings)
        except Exception as e:
            logger.error("sensor temp write failed: %s", e)


def main() -> int:
    db_path = os.environ.get("HOMEFREE_DASHBOARD_DB", DEFAULT_DB_PATH)
    sampler = Sampler(DashboardHistoryStore(db_path))
    # Clean shutdown on systemd stop so WAL is checkpointed promptly.
    signal.signal(signal.SIGTERM, sampler.request_stop)
    signal.signal(signal.SIGINT, sampler.request_stop)
    sampler.run()
    return 0


if __name__ == "__main__":
    sys.exit(main())
