"""
Read-side glue for the alerts engine.

Sources of truth for the engine, in order of canonical-ness:

  1. /etc/homefree/alerts-config.json — rendered from
     `config.homefree.alerts` by services/alerts/default.nix on every
     nixos-rebuild. This is the SETTLED config (matches the running
     generation), not the disk JSON that may have un-applied edits.
     Reading this avoids racing in-flight admin-UI edits.

  2. /var/lib/homefree-secrets/ntfy/topic — the ntfy publish topic
     (an unguessable UUID, anchored into sops). Read at engine tick
     time and concatenated with the local ntfy URL to form the
     publish endpoint.

The engine never reads homefree-config.json directly: that file is the
input to the loader, not the resolved view.
"""

import json
import logging
from pathlib import Path
from typing import Any, Dict, Optional

logger = logging.getLogger(__name__)

CONFIG_PATH = "/etc/homefree/alerts-config.json"
NTFY_TOPIC_PATH = "/var/lib/homefree-secrets/ntfy/topic"
NTFY_LOCAL_URL = "http://127.0.0.1:2586"


def load_alerts_config() -> Dict[str, Any]:
    """Read the resolved alerts config rendered by the Nix module.
    Returns an empty dict if absent — equivalent to "feature off",
    which is the right behavior for boxes that haven't rebuilt yet."""
    p = Path(CONFIG_PATH)
    if not p.exists():
        return {}
    try:
        return json.loads(p.read_text())
    except Exception as e:
        logger.warning("alerts config %s unparseable: %s", CONFIG_PATH, e)
        return {}


def get_ntfy_publish_url() -> Optional[str]:
    """Build `http://127.0.0.1:2586/<topic>` from the on-disk topic
    file. Returns None when the secret hasn't been provisioned yet
    (services/ntfy hasn't run its prepare-secrets unit). The engine
    treats None as "ntfy unavailable" and skips that channel for this
    tick — other channels still run."""
    p = Path(NTFY_TOPIC_PATH)
    if not p.exists():
        return None
    try:
        topic = p.read_text().strip()
    except OSError as e:
        logger.warning("ntfy topic %s unreadable: %s", NTFY_TOPIC_PATH, e)
        return None
    if not topic:
        return None
    return f"{NTFY_LOCAL_URL}/{topic}"
