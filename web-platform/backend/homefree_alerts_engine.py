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
from services.alerts_state_store import (
    AlertStateStore,
    SEVERITY_CLEAR,
    SEVERITY_ERR,
    SEVERITY_RANK,
    SEVERITY_WARN,
)

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
    prev_severity = (prev or {}).get("severity") or SEVERITY_CLEAR

    try:
        result: SourceResult = source.evaluate(
            source_cfg, was_severity=prev_severity,
        )
    except Exception as e:
        # An evaluator crash MUST NOT crash the engine — other sources
        # are still due to run, and the systemd unit shouldn't be
        # restart-looping on a single broken source.
        logger.exception("source %r evaluation failed: %s", source_id, e)
        return

    channel_names = list(source_cfg.get("channels") or [])
    prev_peak = (prev or {}).get("peak_value")
    prev_started_ts = (prev or {}).get("started_ts")
    new_severity = result.severity
    prev_rank = SEVERITY_RANK.get(prev_severity, 0)
    new_rank = SEVERITY_RANK.get(new_severity, 0)

    # State semantics:
    #   * `severity` mirrors the source's verdict for THIS tick.
    #   * `started_ts` is non-None while severity != clear; set on
    #     clear→firing open, kept across warn↔err escalations,
    #     cleared on close.
    #   * `peak_value` is the worst observation during the current
    #     alarm WHILE firing, and the LAST observation while idle —
    #     so the Status-tab meter has something to render between
    #     alarms instead of showing "no reading yet" forever.
    #   * `message` always carries the source's most recent message,
    #     firing or not, so the Status-tab body has fresh text.
    #   * `readings` is the source's optional per-item detail list.
    #
    # We always write state on every tick (cheap SQLite upsert).
    # Transitions gate dispatch + history mutations.
    if new_rank > 0 and prev_rank > 0:
        # Still firing (warn or err). Peak only goes UP during an
        # alarm so the history row reflects the worst observed
        # value. The current tick's reading might be lower; we keep
        # the high-water mark.
        if (result.value is not None
                and (prev_peak is None or result.value > prev_peak)):
            state_peak = result.value
        else:
            state_peak = prev_peak
        started_ts = prev_started_ts or now
    elif new_rank > 0:
        # Newly firing (clear → warn or clear → err).
        state_peak = result.value if result.value is not None else 0.0
        started_ts = now
    else:
        # Clear this tick: peak is just the current reading for the
        # meter's "last seen" purpose. None when source has no data.
        state_peak = result.value
        started_ts = None

    store.set_state(
        source_id,
        firing=(new_rank > 0),
        started_ts=started_ts,
        peak_value=state_peak,
        message=result.message,
        severity=new_severity,
        readings=result.readings,
    )

    # ── Transitions: dispatch + history mutations.
    if new_rank > 0 and prev_rank == 0:
        # OPEN (clear → warn|err).
        store.open_event(
            source_id, started_ts, state_peak or 0.0, result.message,
            severity=new_severity,
        )
        priority = "max" if new_severity == SEVERITY_ERR else "high"
        title = (
            f"[{source.label}] {'ERR' if new_severity == SEVERITY_ERR else 'WARN'}"
        )
        dispatch(
            channels, channel_names,
            title=title, body=result.message,
            priority=priority,
            tags=["warning" if new_severity == SEVERITY_WARN else "rotating_light"],
        )
        logger.info(
            "alert OPEN (%s): %s — %s",
            new_severity, source_id, result.message,
        )

    elif new_rank > prev_rank > 0:
        # ESCALATE (warn → err). Same open event, bumped severity.
        store.update_severity(source_id, new_severity)
        if state_peak is not None and state_peak != prev_peak:
            store.update_peak(source_id, state_peak)
        dispatch(
            channels, channel_names,
            title=f"[{source.label}] ESCALATED to ERR",
            body=result.message,
            priority="max",
            tags=["rotating_light"],
        )
        logger.info(
            "alert ESCALATE: %s warn→err — %s",
            source_id, result.message,
        )

    elif prev_rank > new_rank > 0:
        # DE-ESCALATE (err → warn). Open event stays at peak severity;
        # we don't downgrade the history row.
        dispatch(
            channels, channel_names,
            title=f"[{source.label}] de-escalated to WARN",
            body=result.message,
            priority="default",
            tags=["arrow_down"],
        )
        logger.info(
            "alert DE-ESCALATE: %s err→warn — %s",
            source_id, result.message,
        )

    elif new_rank > 0 and new_rank == prev_rank:
        # Still firing at the same level: keep history event peak in
        # sync with state's high-water mark. No notification (already
        # got the push when it crossed the threshold).
        if state_peak is not None and state_peak != prev_peak:
            store.update_peak(source_id, state_peak)

    elif new_rank == 0 and prev_rank > 0:
        # RESOLVED (warn|err → clear).
        store.close_event(source_id, now, result.message)
        dispatch(
            channels, channel_names,
            title=f"[{source.label}] resolved",
            body=result.message,
            priority="default",
            tags=["white_check_mark"],
        )
        logger.info("alert CLOSE: %s — %s", source_id, result.message)
    # Idle (clear, was clear): no dispatch, no history,
    # state already refreshed above.


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
