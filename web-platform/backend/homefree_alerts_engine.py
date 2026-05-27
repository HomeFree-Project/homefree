#!/usr/bin/env python3
"""
HomeFree alerts engine — single-tick entrypoint.

Invoked by the homefree-alerts.timer systemd unit (services/alerts/
default.nix). Runs ONE tick of source evaluation per invocation: no
in-process loop, no daemon state. All per-source state lives in the
SQLite store (services.alerts_state_store) so two consecutive ticks
can pick up where the previous one left off.

Tick lifecycle:

  1. Read /etc/homefree/alerts-config.json (rendered by the Nix
     module; reflects the deployed config, not the on-disk JSON
     potentially mid-edit). Bail early if alerts.enable=false.
  2. Build the channel objects for every enabled channel.
  3. For each enabled source:
       a. Look up its evaluator in REGISTRY.
       b. Pull previous state from the store; pass `was_firing` to
          the evaluator so it can apply hysteresis.
       c. Compare new firing vs previous firing → open / steady /
          close transition.
       d. On open: insert event, persist state, dispatch to the
          source's configured channels with priority=high.
          On steady (still firing): bump peak_value if higher.
          On close: amend event ended_ts, clear state, dispatch
          with priority=default.

Why one-shot timer instead of a long-running daemon:

  - State is already on disk for the admin UI to read; making the
    engine itself stateless removes a class of "what happened to my
    in-memory peak when the systemd unit restarted" bugs.
  - Each tick is bounded — a hung HTTP POST to ntfy will time out
    within 10s, and the next tick will retry. No engine-wide
    deadlock surface.
  - Systemd `OnUnitInactiveSec` already does what a sleep loop would
    do, with the bonus that it observes `RandomizedDelaySec` and
    rebuild-time activations correctly.
"""

import logging
import os
import sys
import time
from pathlib import Path
from typing import Any, Dict, List

# Backend dir must be on PYTHONPATH for `services.*` / `resolvers.*`
# imports. Mirrors drive_temp_sampler.py.
backend_dir = Path(__file__).parent.absolute()
if str(backend_dir) not in sys.path:
    sys.path.insert(0, str(backend_dir))

from services.alerts_channels import NtfyChannel
from services.alerts_config import get_ntfy_publish_url, load_alerts_config
from services.alerts_sources import REGISTRY, SourceResult
from services.alerts_state_store import AlertStateStore

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
)
logger = logging.getLogger("alerts-engine")


def build_channels(cfg: Dict[str, Any]) -> Dict[str, Any]:
    """Instantiate every channel that is currently enabled. A channel
    that is named by a source but is disabled (or whose backend is
    missing) is silently skipped at dispatch time."""
    channels: Dict[str, Any] = {}

    channels_cfg = cfg.get("channels", {}) or {}
    ntfy_cfg = channels_cfg.get("ntfy", {}) or {}
    if ntfy_cfg.get("enable"):
        url = get_ntfy_publish_url()
        if url is None:
            # ntfy secret not yet provisioned. We log once per tick;
            # this is an EXPECTED state on a fresh box that just
            # enabled alerts and hasn't yet had its ntfy
            # prepare-secrets unit complete.
            logger.info("ntfy channel enabled but topic not yet provisioned; skipping")
        else:
            channels["ntfy"] = NtfyChannel(url=url)

    return channels


def dispatch(
    channels: Dict[str, Any],
    channel_names: List[str],
    title: str,
    body: str,
    priority: str,
    tags: List[str],
) -> None:
    """Send `(title, body)` to every channel name listed that we
    actually have an instantiated backend for. Channels missing from
    `channels` are silently skipped — the alert is still in history,
    just not pushed."""
    for name in channel_names:
        ch = channels.get(name)
        if ch is None:
            continue
        ch.send(title=title, body=body, priority=priority, tags=tags)


def run_source(
    source_id: str,
    source_cfg: Dict[str, Any],
    store: AlertStateStore,
    channels: Dict[str, Any],
    now: int,
) -> None:
    """Evaluate ONE source and act on the transition. Per-source
    exceptions are caught here so one broken source doesn't poison the
    rest of the tick."""

    SourceClass = REGISTRY.get(source_id)
    if SourceClass is None:
        logger.warning("unknown alert source %r; skipping", source_id)
        return

    source = SourceClass()
    prev = store.get_state(source_id)
    was_firing = bool(prev and prev.get("firing"))

    try:
        result: SourceResult = source.evaluate(source_cfg, was_firing=was_firing)
    except Exception as e:
        # An evaluator crash MUST NOT crash the engine — other sources
        # are still due to run, and the systemd unit shouldn't be
        # restart-looping on a single broken source.
        logger.exception("source %r evaluation failed: %s", source_id, e)
        return

    channel_names = list(source_cfg.get("channels") or [])

    # ── Transition handling. Four cases: open / steady / close / idle.
    if result.firing and not was_firing:
        # Newly firing. Record state and event; dispatch a high-priority
        # notification.
        started_ts = now
        peak = result.value if result.value is not None else 0.0
        store.set_state(source_id, True, started_ts, peak, result.message)
        store.open_event(source_id, started_ts, peak, result.message)
        title = f"[{source.label}] alert"
        dispatch(
            channels,
            channel_names,
            title=title,
            body=result.message,
            priority="high",
            tags=["warning"],
        )
        logger.info("alert OPEN: %s — %s", source_id, result.message)

    elif result.firing and was_firing:
        # Still firing. Bump the peak in both state and the open event
        # if this tick observed a new high.
        prev_peak = (prev or {}).get("peak_value")
        new_peak = result.value
        if new_peak is not None and (prev_peak is None or new_peak > prev_peak):
            store.set_state(
                source_id,
                True,
                (prev or {}).get("started_ts") or now,
                new_peak,
                result.message,
            )
            store.update_peak(source_id, new_peak)

    elif not result.firing and was_firing:
        # Resolved.
        store.set_state(source_id, False, None, None, "")
        store.close_event(source_id, now, result.message)
        title = f"[{source.label}] resolved"
        dispatch(
            channels,
            channel_names,
            title=title,
            body=result.message,
            priority="default",
            tags=["white_check_mark"],
        )
        logger.info("alert CLOSE: %s — %s", source_id, result.message)

    else:
        # Idle (not firing, wasn't firing). Nothing to do.
        pass


def tick() -> int:
    cfg = load_alerts_config()
    if not cfg.get("enable"):
        logger.debug("alerts disabled; nothing to do")
        return 0

    store = AlertStateStore()
    store.init_schema()

    channels = build_channels(cfg)

    now = int(time.time())
    sources_cfg = cfg.get("sources", {}) or {}
    for source_id, source_cfg in sources_cfg.items():
        if not (source_cfg or {}).get("enable"):
            continue
        run_source(source_id, source_cfg or {}, store, channels, now)

    return 0


def main() -> int:
    try:
        return tick()
    except Exception as e:
        # A top-level engine crash is rare but possible (DB locked,
        # disk full). Log it loudly so journald shows the failure; the
        # systemd timer will fire again on schedule.
        logger.exception("alerts engine tick failed: %s", e)
        return 1


if __name__ == "__main__":
    sys.exit(main())
