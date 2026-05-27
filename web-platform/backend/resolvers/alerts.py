"""
Alerts API endpoints (admin-api).

Read-only for v1: writes go through the existing homefree-config.json
edit path so the undeployed-change indication keeps working
(docs/agent-notes/undeployed-change-indication.md). The page POSTing
straight to /api/alerts would bypass that diff and look like a no-op
to the Apply gate.

Endpoints:

  GET /api/alerts/sources         — list of sources with their current
                                    config (threshold, channels, enable)
                                    merged with the engine's live state
                                    (firing? peak? since when?).

  GET /api/alerts/history         — server-paginated event log, newest
                                    first.

  GET /api/alerts/channels/ntfy   — topic URL + pairing info for the
                                    ntfy channel. The topic is a
                                    bearer-equivalent secret, so this
                                    endpoint inherits the same admin-
                                    role gating as every other /api/
                                    path in admin-api.

All endpoints return empty / placeholder results gracefully when
alerts is disabled or the relevant state isn't provisioned yet — the
UI renders an empty state rather than a 5xx in those cases.
"""

import json
import logging
from pathlib import Path
from typing import Any, Dict, List, Optional

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel

from services.alerts_config import (
    NTFY_TOPIC_PATH,
    get_ntfy_publish_url,
    load_alerts_config,
)
from services.alerts_sources import REGISTRY
from services.alerts_state_store import AlertStateStore

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api/alerts", tags=["alerts"])


# --------------------------------------------------------------- models

class SourceState(BaseModel):
    """Engine-reported runtime state for one source. Every field is
    optional because a fresh box that just enabled alerts has no state
    DB yet — the UI's empty state should be "OK, not firing"."""
    firing: bool = False
    started_ts: Optional[int] = None
    peak_value: Optional[float] = None
    message: Optional[str] = None
    updated_ts: Optional[int] = None


class SourceEntry(BaseModel):
    """One row on the Alerts page. Combines the source's identity
    metadata (label etc. — pulled from REGISTRY), its current config
    (threshold etc. — pulled from alerts-config.json), and its live
    state."""
    id: str
    label: str
    enable: bool
    config: Dict[str, Any]
    channels: List[str]
    # Live engine state. Empty (firing=False, rest None) if the engine
    # has never written a row for this source.
    state: SourceState


class SourcesResponse(BaseModel):
    enabled: bool
    interval: str
    sources: List[SourceEntry]


class HistoryEntry(BaseModel):
    id: int
    source_id: str
    started_ts: int
    ended_ts: Optional[int] = None
    peak_value: Optional[float] = None
    open_message: Optional[str] = None
    close_message: Optional[str] = None


class HistoryResponse(BaseModel):
    events: List[HistoryEntry]


class NtfyChannelInfo(BaseModel):
    """Pairing info for the ntfy channel. The mobile ntfy app asks for
    a SERVER URL (Use another server) and a TOPIC separately — not a
    single combined URL — so we return them split. `publish_url` is
    the same value joined, retained because curl-based debugging /
    docs use the combined form.

    Security note: the topic IS the bearer (see services/ntfy/default.nix
    header). `provisioned` is False before the ntfy prepare-secrets
    unit has run; `enabled` is False when the user has not turned the
    channel on (or when alerts itself is off)."""
    enabled: bool
    public: bool
    provisioned: bool
    base_url: Optional[str] = None
    topic: Optional[str] = None
    publish_url: Optional[str] = None


# ------------------------------------------------------------- endpoints

@router.get("/sources", response_model=SourcesResponse)
def list_sources() -> SourcesResponse:
    cfg = load_alerts_config()
    store = AlertStateStore()
    all_states = store.all_states()

    sources_cfg = cfg.get("sources", {}) or {}
    out: List[SourceEntry] = []

    # Iterate REGISTRY (the engine's known sources), not just whatever
    # is in the config — a source that exists in code but is absent
    # from config should still appear in the UI with its defaults, so
    # the user can opt in.
    for source_id, source_class in REGISTRY.items():
        src_cfg: Dict[str, Any] = sources_cfg.get(source_id) or {}
        state_dict = all_states.get(source_id) or {}
        out.append(SourceEntry(
            id=source_id,
            label=source_class.label,
            enable=bool(src_cfg.get("enable", False)),
            # The full source config (minus enable/channels) is what
            # the UI form will edit. We pass through whatever fields
            # the source defines — the engine ignores unknown keys.
            config={k: v for k, v in src_cfg.items() if k not in {"enable", "channels"}},
            channels=list(src_cfg.get("channels") or []),
            state=SourceState(**state_dict) if state_dict else SourceState(),
        ))

    return SourcesResponse(
        enabled=bool(cfg.get("enable")),
        interval=cfg.get("interval", "1min"),
        sources=out,
    )


@router.get("/history", response_model=HistoryResponse)
def history(limit: int = 100, offset: int = 0) -> HistoryResponse:
    # Reasonable cap so a runaway client can't request a million rows.
    limit = max(1, min(limit, 500))
    offset = max(0, offset)
    store = AlertStateStore()
    rows = store.get_history(limit=limit, offset=offset)
    events = [HistoryEntry(**row) for row in rows]
    return HistoryResponse(events=events)


# Path to the per-instance config blob; reading it directly here is
# fine because admin-api runs as root and the file is world-readable
# (it is the user-facing source of truth for the per-instance config).
_HOMEFREE_CONFIG = Path("/etc/nixos/homefree-config.json")


def _read_homefree_config() -> Dict[str, Any]:
    try:
        return json.loads(_HOMEFREE_CONFIG.read_text())
    except Exception as e:
        logger.warning("homefree-config.json unreadable: %s", e)
        return {}


@router.get("/channels/ntfy", response_model=NtfyChannelInfo)
def ntfy_channel_info() -> NtfyChannelInfo:
    """Pair-with-phone info for the ntfy channel.

    Why a separate endpoint and not in /sources: the topic is treated
    as a bearer-equivalent secret. Keeping it on a dedicated endpoint
    means we don't sprinkle it into every /sources response (which
    powers the always-loading dashboard tile), and a future audit-log
    middleware can flag *this* GET specifically if we ever want to
    track who viewed the pairing URL."""
    alerts_cfg = load_alerts_config()
    channels_cfg = alerts_cfg.get("channels") or {}
    ntfy_cfg = channels_cfg.get("ntfy") or {}

    hf_cfg = _read_homefree_config()
    domain = (hf_cfg.get("system") or {}).get("domain") or "homefree.host"
    # `services.ntfy.public` is set by the alerts module via lib.mkDefault
    # when channels.ntfy.enable is on; the JSON may or may not have an
    # explicit value, so default to False (LAN-only is the safe default
    # for surfaced URLs).
    public = bool(((hf_cfg.get("services") or {}).get("ntfy") or {}).get("public"))

    base_url = f"https://ntfy.{domain}"
    topic: Optional[str] = None
    publish_url: Optional[str] = None
    provisioned = False
    try:
        p = Path(NTFY_TOPIC_PATH)
        if p.exists():
            topic_value = p.read_text().strip()
            if topic_value:
                topic = topic_value
                publish_url = f"{base_url}/{topic}"
                provisioned = True
    except OSError as e:
        # The file exists but we couldn't read it (rare given admin-api
        # runs as root). Treat as not-yet-provisioned rather than 500.
        logger.warning("ntfy topic %s unreadable: %s", NTFY_TOPIC_PATH, e)

    return NtfyChannelInfo(
        enabled=bool(ntfy_cfg.get("enable")),
        public=public,
        provisioned=provisioned,
        base_url=base_url if provisioned else None,
        topic=topic,
        publish_url=publish_url,
    )


class TestPushResponse(BaseModel):
    success: bool
    message: str


@router.post("/channels/ntfy/test", response_model=TestPushResponse)
def ntfy_test_push() -> TestPushResponse:
    """Publish a one-off test push to the ntfy channel so the user can
    confirm their phone is paired correctly. Independent of the engine
    timer (no event is written to history) — this is a connectivity
    check, not an alert.

    Failure paths:
      - ntfy server isn't running (`services.ntfy.enable=false`):
        `get_ntfy_publish_url()` returns None and we 503.
      - ntfy server is up but the POST fails (port closed, http error):
        the channel `send()` logs + swallows, so the call returns
        success=true. We do a small dummy POST here directly via
        httpx to capture the actual HTTP error and surface it,
        because for *this* flow the user explicitly wants to know
        whether the push hit the wire.
    """
    publish_url = get_ntfy_publish_url()
    if publish_url is None:
        # Either the channel isn't enabled, or ntfy hasn't finished
        # provisioning yet. The UI button is hidden in those cases,
        # but defend against the direct API call too.
        raise HTTPException(
            status_code=503,
            detail=(
                "ntfy not provisioned. Enable the engine + the ntfy "
                "channel, Apply, and wait for the rebuild to complete."
            ),
        )

    # Import locally so a stale admin-api that pre-dates httpx in its
    # env (unlikely — the engine env already needs it) at least
    # returns a sane 500 instead of a startup-time ImportError.
    import httpx
    body = (
        "If you see this, your phone is paired with HomeFree Alerts. "
        "This is a manual test from the admin UI."
    )
    try:
        resp = httpx.post(
            publish_url,
            content=body.encode("utf-8"),
            headers={
                "Title": "HomeFree test push",
                "Priority": "default",
                "Tags": "test_tube",
            },
            timeout=10.0,
        )
        resp.raise_for_status()
    except httpx.HTTPError as e:
        logger.warning("ntfy test push failed: %s", e)
        raise HTTPException(
            status_code=502,
            detail=f"ntfy POST failed: {e}",
        )

    # Record the test in history so the user can confirm it landed on
    # the box even if they missed the phone push. We use a synthetic
    # source_id with a leading underscore to mark it as a meta-event
    # distinct from any real source's history — the UI renders it
    # with a friendly label ("Manual test"). open + close in the same
    # call: a test is instantaneous, not a sustained alert. State
    # store init is idempotent (CREATE TABLE IF NOT EXISTS), so this
    # is safe even on a fresh box where the engine has never ticked.
    try:
        import time
        store = AlertStateStore()
        store.init_schema()
        now = int(time.time())
        store.open_event(
            source_id="_test-ntfy",
            started_ts=now,
            value=0.0,
            message=body,
        )
        store.close_event(
            source_id="_test-ntfy",
            ended_ts=now,
            close_message="Sent",
        )
    except Exception as e:
        # History write failure must NOT mask a successful push — the
        # POST already went through. Log + move on.
        logger.warning("test push history write failed: %s", e)

    return TestPushResponse(
        success=True,
        message="Test push sent. Check your phone.",
    )
