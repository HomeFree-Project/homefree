"""
Alert channels — pluggable notification dispatchers.

Each channel implements `send(title, body, priority, tags)`. The engine
dispatches an event to every channel listed under the source's
`channels` config, skipping channels not enabled at the homefree.alerts
level (a source can name a channel that is currently off; the alert is
still recorded in history, just not pushed).

v1 ships ntfy. The class shape is deliberately wide enough for the
common alternatives (email body+subject, webhook JSON, HA notify
service) so adding one later does not change the engine.
"""

import logging
from typing import List, Optional

import httpx

logger = logging.getLogger(__name__)


# ---------------------------------------------------------------------
# ntfy
# ---------------------------------------------------------------------

class NtfyChannel:
    """POSTs to a self-hosted ntfy server. Topic-as-bearer security
    model: the URL itself contains the unguessable topic UUID, so no
    Authorization header is set."""

    id = "ntfy"

    def __init__(self, url: str) -> None:
        # Full publish URL, e.g. http://127.0.0.1:2586/<topic-uuid>.
        # The engine builds this; the channel does not know how to
        # locate the secret.
        self.url = url

    def send(
        self,
        title: str,
        body: str,
        priority: str = "default",
        tags: Optional[List[str]] = None,
    ) -> None:
        headers = {
            # ntfy supports both `Title` and `X-Title`; the canonical
            # bare form is more readable in tcpdump/curl logs.
            "Title": title,
            # priority values: min, low, default, high, max (or 1-5).
            # Engine maps open events → high, close events → default.
            "Priority": priority,
        }
        if tags:
            headers["Tags"] = ",".join(tags)
        try:
            resp = httpx.post(
                self.url,
                content=body.encode("utf-8"),
                headers=headers,
                # Localhost POST — anything more than a couple of
                # seconds means the ntfy process is wedged. The engine
                # catches the exception and moves on.
                timeout=10.0,
            )
            resp.raise_for_status()
        except Exception as e:
            # Don't propagate — a broken channel must not abort the
            # whole alerts tick (other channels / sources still need
            # to run). The exception is logged for journald.
            logger.warning("ntfy send to %s failed: %s", self.url, e)
