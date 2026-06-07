"""
Plugin Directory service — read the curated catalog from
git.homefree.host/homefree-plugins.

Each repo in the `homefree-plugins` Forgejo org is a self-contained
HomeFree-extending Nix flake (typically an app, in the same vein as
`apps/` in this repo) exposing `nixosModules.default`. Listing the org's
repos via the Forgejo API is the catalog — no separate manifest format.

The admin frontend renders the result; installing a directory plugin
is just a `PluginsService.register_or_update` call with the cloneUrl
prefilled, so the flake then goes through the same code path as a
manually-registered remote flake.

Caching: the directory endpoint is hit on every page load of the
Plugins page. The Forgejo response is small and changes rarely, so we
cache the result in-process for 1 hour with a `force_refresh` bypass.
A cache miss with a network failure surfaces the previous result with
`cacheStale: True`; if there is no cache, the endpoint returns an
empty list with an `error` so the page degrades gracefully (the manual
add-flake form below the directory still works).
"""

import asyncio
import logging
import time
from typing import Any, Dict, List, Optional

import httpx

logger = logging.getLogger(__name__)


# Org listing endpoint. Forgejo exposes a Gitea v1-compatible API.
DIRECTORY_SOURCE_URL = (
    "https://git.homefree.host/api/v1/orgs/homefree-plugins/repos"
)
# Forgejo paginates; 50 covers anything plausible for one HomeFree
# directory. If the catalog ever grows past this, follow Link headers.
_PAGE_LIMIT = 50

# In-process cache. Module-global because the admin-api is single-
# process; lock is held while we either return the cached value or
# do the upstream fetch + populate.
_CACHE_TTL_S = 3600.0
_CACHE_LOCK = asyncio.Lock()
_cache: Optional[Dict[str, Any]] = None  # {"fetched_at": float, "result": dict}


def _format_display_name(slug: str) -> str:
    """`homefree-rtl-sdr` -> `RTL SDR`; `homefree-ai` -> `AI`.

    Strips the `homefree-` prefix so the catalog reads as a list of what
    each plugin DOES rather than a column of identical prefixes. Each
    word is title-cased except for short acronyms which stay upper.
    """
    raw = slug
    if raw.startswith("homefree-"):
        raw = raw[len("homefree-"):]
    if not raw:
        return slug
    parts = raw.replace("_", "-").split("-")
    out = []
    for p in parts:
        if not p:
            continue
        if len(p) <= 3 and p.isalpha():
            out.append(p.upper())
        else:
            out.append(p[:1].upper() + p[1:])
    return " ".join(out) if out else slug


def _flake_url_for(clone_url: str) -> str:
    """Turn an https://… clone URL into a Nix git+https:// flake-ref."""
    u = (clone_url or "").strip()
    if not u:
        return u
    if u.startswith(("https://", "http://")):
        return "git+" + u
    return u


def _shape_repo(repo: Dict[str, Any]) -> Dict[str, Any]:
    """Forgejo repo dict -> catalog entry dict."""
    slug = repo.get("name") or ""
    clone_url = repo.get("clone_url") or ""
    return {
        "slug": slug,
        "displayName": _format_display_name(slug),
        "description": (repo.get("description") or "").strip(),
        "htmlUrl": repo.get("html_url") or "",
        "cloneUrl": clone_url,
        "defaultBranch": repo.get("default_branch") or "main",
        "flakeUrl": _flake_url_for(clone_url),
    }


def _annotate_installed(entries: List[Dict[str, Any]]) -> None:
    """Mark each entry as installed if the registered flakes list has a
    matching URL. Done inside the request so each call reflects the
    current installed set (the catalog itself is cached, the
    installed-state is recomputed on every request).
    """
    # Local import: services.plugins depends on config_reader which
    # touches the filesystem at import time on some boxes. Keep the
    # plugin_directory module importable in unit-test/scaffold contexts
    # where that filesystem isn't present.
    try:
        from services.plugins import PluginsService
        flakes = PluginsService.list_flakes()
    except Exception as e:  # pragma: no cover — defensive
        logger.warning("Could not load registered flakes for installed-state: %s", e)
        flakes = []
    by_url = {(f.get("url") or "").strip(): f for f in flakes if isinstance(f, dict)}
    for e in entries:
        match = by_url.get(e["flakeUrl"]) or by_url.get(e["cloneUrl"])
        if match:
            e["installed"] = True
            e["installedFlakeId"] = match.get("id")
        else:
            e["installed"] = False
            e["installedFlakeId"] = None


async def _fetch_upstream() -> List[Dict[str, Any]]:
    """Single call to Forgejo. Caller handles caching + error fallback."""
    params = {"limit": _PAGE_LIMIT}
    async with httpx.AsyncClient(timeout=15.0) as cx:
        r = await cx.get(DIRECTORY_SOURCE_URL, params=params)
        r.raise_for_status()
        data = r.json()
    if not isinstance(data, list):
        raise ValueError(f"Unexpected response shape from {DIRECTORY_SOURCE_URL}")
    out: List[Dict[str, Any]] = []
    for repo in data:
        if not isinstance(repo, dict):
            continue
        if repo.get("archived"):
            continue
        if not repo.get("name") or not repo.get("clone_url"):
            continue
        out.append(_shape_repo(repo))
    # Stable order: alpha by slug, so the UI doesn't shuffle between
    # Forgejo's `created_at` ordering changes.
    out.sort(key=lambda e: e["slug"])
    return out


async def fetch_directory(force_refresh: bool = False) -> Dict[str, Any]:
    """
    Return the directory listing for the admin UI.

    Shape: {
      "plugins":     list of entries (see _shape_repo),
      "fetchedAt":   ISO timestamp of the upstream fetch backing the result,
      "sourceUrl":   the upstream URL (so the UI can link to it),
      "cacheStale":  True if upstream failed but we returned a cached value,
      "error":       Set only when there's no cache AND upstream failed.
    }

    `force_refresh=True` bypasses the cache. Always returns a dict;
    never raises (so the admin UI degrades gracefully).
    """
    global _cache
    now = time.time()

    async with _CACHE_LOCK:
        cached = _cache
        if (
            not force_refresh
            and cached
            and (now - cached["fetched_at"]) < _CACHE_TTL_S
        ):
            entries = [dict(e) for e in cached["result"]]
            _annotate_installed(entries)
            return {
                "plugins": entries,
                "fetchedAt": _iso(cached["fetched_at"]),
                "sourceUrl": DIRECTORY_SOURCE_URL,
                "cacheStale": False,
            }

        try:
            result = await _fetch_upstream()
            _cache = {"fetched_at": now, "result": result}
            entries = [dict(e) for e in result]
            _annotate_installed(entries)
            return {
                "plugins": entries,
                "fetchedAt": _iso(now),
                "sourceUrl": DIRECTORY_SOURCE_URL,
                "cacheStale": False,
            }
        except Exception as e:
            logger.warning("Plugin directory fetch failed: %s", e)
            if cached:
                entries = [dict(en) for en in cached["result"]]
                _annotate_installed(entries)
                return {
                    "plugins": entries,
                    "fetchedAt": _iso(cached["fetched_at"]),
                    "sourceUrl": DIRECTORY_SOURCE_URL,
                    "cacheStale": True,
                    "error": str(e),
                }
            return {
                "plugins": [],
                "fetchedAt": None,
                "sourceUrl": DIRECTORY_SOURCE_URL,
                "cacheStale": False,
                "error": str(e),
            }


def _iso(epoch: float) -> str:
    from datetime import datetime, timezone
    return datetime.fromtimestamp(epoch, tz=timezone.utc).isoformat()
