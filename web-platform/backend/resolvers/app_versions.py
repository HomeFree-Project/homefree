"""
App-Versions resolver — backs the Advanced -> App Versions page.

Shows every container declared on the box (via
virtualisation.oci-containers.containers) alongside its currently-
deployed image tag and the latest tag available from its upstream
registry. Two artifacts feed the merged view:

  * Container catalog (eval-time, immutable between rebuilds):
      /run/homefree/admin/container-images.json
      Emitted by services/admin-web/default.nix from
      config.virtualisation.oci-containers.containers.

  * Upstream cache (refreshed daily + on demand):
      /var/lib/homefree-admin/app-versions-cache.json
      Written by this resolver (manual refresh path) AND by the
      homefree-app-versions-refresh oneshot (the daily timer). Both
      writers run as root and use an atomic rename so the JSON is
      never observed partially written.

Per rule 8, only the BACKEND ever talks to upstream registries —
the frontend just renders the cached result. Per rule 1, the
resolver is generic across all containers; no per-app special-casing.
"""

import asyncio
import json
import logging
import os
import re
import time
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

import httpx
from fastapi import APIRouter, BackgroundTasks

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api/apps", tags=["app-versions"])

# ─── Paths ────────────────────────────────────────────────────────────

# Eval-time, immutable: list of {name, image} for every oci-container.
CONTAINER_CATALOG = Path("/run/homefree/admin/container-images.json")

# Eval-time, immutable: maps service label -> {name, project-name}.
SERVICE_METADATA = Path("/run/homefree/admin/service-metadata.json")

# Mutable cache of upstream-tag lookups. Keyed by container name.
CACHE_FILE = Path("/var/lib/homefree-admin/app-versions-cache.json")

# Per-registry timeouts. Generous on purpose — the refresher is
# happy to skip and try again tomorrow; we'd rather give a slow
# upstream the chance to reply than mass-mark "unknown".
_HTTP_TIMEOUT_S = 10.0

# ─── Image-string parsing ─────────────────────────────────────────────

# Accept semver-like tags. Tolerates a leading 'v', an optional patch
# and an optional 4th numeric segment (radicale-style 3.6.1.0), plus a
# pre-release / build suffix. Rejects floats like 'latest', 'nightly',
# 'edge', 'master', 'main', 'dev', 'develop'.
_SEMVER_RE = re.compile(
    r"^v?(\d+)\.(\d+)(?:\.(\d+))?(?:\.\d+)?(?:[-+].+)?$"
)

# Some upstreams prefix their tags with a common literal (cryptpad
# uses 'version-2026.2.0', some projects use 'release-1.2.3'). We
# strip a known set before semver matching so those rows resolve.
_TAG_PREFIXES = ("version-", "release-", "release/v", "release/")


def _strip_tag_prefix(tag: str) -> str:
    if not tag:
        return tag
    low = tag.lower()
    for p in _TAG_PREFIXES:
        if low.startswith(p):
            return tag[len(p):]
    return tag


def _parse_image(image: str) -> Optional[Dict[str, str]]:
    """Split an OCI image string into {registry, repo, tag, digest}.

    Handles three pinning styles:
      * Tag-only:    'vaultwarden/server:1.36.0'
      * Digest-only: 'hadogenes/screeenly@sha256:142211a...'
      * Tag+digest:  'foo/bar:1.2.3@sha256:142211a...'

    Cope with port-in-registry (registry.local:5000/foo:1.2.3) by
    splitting on the LAST ':' only when it sits after the last '/'.
    Unqualified images default to docker.io; single-segment Docker Hub
    images get the implicit 'library/' namespace.
    """
    if not image or not isinstance(image, str):
        return None

    # Digest split first. A digest always begins with '@<algo>:'; what
    # follows is opaque (it contains a colon, which would otherwise
    # confuse the tag splitter). After this, `image` carries only the
    # tag-style suffix, if any.
    digest = ""
    if "@" in image:
        image, digest = image.rsplit("@", 1)

    # Tag split: last colon AFTER the last slash, or no tag at all.
    last_slash = image.rfind("/")
    last_colon = image.rfind(":")
    if last_colon > last_slash:
        rest, tag = image[:last_colon], image[last_colon + 1 :]
    else:
        rest, tag = image, ""

    # Locally-built images (the `:local` convention) have no upstream
    # registry — short-circuit BEFORE the docker.io default would
    # otherwise mis-tag them. Keep the raw image name in `repo` so the
    # UI can still identify which local image this is; leave
    # `registry` empty so the frontend doesn't render a misleading
    # 'docker.io/...' path.
    if _is_local(tag):
        return {"registry": "", "repo": rest, "tag": tag, "digest": digest}

    # Registry split: first slash if the first segment looks like a
    # host (contains a dot or a colon). Otherwise it's a Docker Hub
    # shorthand like 'vaultwarden/server' or just 'redis'.
    first_slash = rest.find("/")
    if first_slash > 0 and ("." in rest[:first_slash] or ":" in rest[:first_slash]):
        registry, repo = rest[:first_slash], rest[first_slash + 1 :]
    else:
        registry, repo = "docker.io", rest

    if registry == "docker.io" and "/" not in repo:
        repo = f"library/{repo}"

    return {"registry": registry, "repo": repo, "tag": tag, "digest": digest}


# Captures (major, minor, patch?, fourth?, suffix?). The fourth
# segment (radicale uses 3.6.1.0) is rare; capture it so we can
# differentiate 3.6.1 from 3.6.1.0. Suffix capture is anchored so it
# covers any pre-release/build metadata that follows.
_SEMVER_PARTS_RE = re.compile(
    r"^v?(\d+)\.(\d+)(?:\.(\d+))?(?:\.(\d+))?([-+].+)?$"
)


def _semver_tuple(tag: str) -> Optional[Tuple[int, int, int, int, str]]:
    """Return (major, minor, patch, fourth, suffix) for a semver-shaped
    tag, or None if the tag isn't semver-like. Plain releases must
    sort ABOVE pre-releases of the same base version, so we map empty
    suffix -> '~' (which sorts after any printable-ASCII pre-release
    marker like '-' or '+')."""
    normalised = _strip_tag_prefix(tag)
    m = _SEMVER_PARTS_RE.match(normalised)
    if not m:
        return None
    major = int(m.group(1))
    minor = int(m.group(2))
    patch = int(m.group(3) or 0)
    fourth = int(m.group(4) or 0)
    suffix_raw = m.group(5) or ""
    suffix_sortable = suffix_raw if suffix_raw else "~"
    return (major, minor, patch, fourth, suffix_sortable)


def _pick_latest(tags: List[str], current_tag: str) -> Optional[str]:
    """Pick the highest semver-shaped tag whose MAJOR matches current's.

    Pinning the major is a safety call: a HomeFree operator can read
    'latest: 11.0.0' and decide to bump; they can't read
    'latest: 11.0.0' and have us pretend a 10.x -> 11.x leap is the
    same kind of small step as a patch bump. If current_tag itself
    isn't parseable, fall back to highest overall."""
    semver_tags: List[Tuple[Tuple[int, int, int, int, str], str]] = []
    for t in tags:
        st = _semver_tuple(t)
        if st is None:
            continue
        semver_tags.append((st, t))
    if not semver_tags:
        return None
    current = _semver_tuple(current_tag)
    if current is not None:
        same_major = [
            (st, t) for (st, t) in semver_tags if st[0] == current[0]
        ]
        if same_major:
            return max(same_major)[1]
    return max(semver_tags)[1]


# ─── Floating-tag handling ────────────────────────────────────────────

# Tags that explicitly opt out of version pinning. An image pinned to
# one of these has no "current version" to compare against — surfacing
# it as Unknown would be misleading, since the lookup isn't failing
# (there is genuinely nothing to compare). The page shows these with
# a distinct "floating tag" badge instead.
_FLOATING_TAGS = frozenset({
    "", "latest", "stable", "edge", "nightly", "main", "master",
    "dev", "develop", "rolling", "current", "beta", "alpha", "head",
})


def _is_floating(tag: str) -> bool:
    return (tag or "").lower() in _FLOATING_TAGS


# Images built on the box itself — no upstream registry to compare
# against. The convention across HomeFree's locally-built apps is to
# pin to `:local` (e.g. blockout-clean:local, homefree/radicle:local,
# tetris:local). Surfacing these as "Unknown" is misleading — they
# have no upstream by design.
def _is_local(tag: str) -> bool:
    return (tag or "").lower() == "local"


# ─── Per-registry tag fetchers ────────────────────────────────────────
#
# Each fetcher returns the raw tag list for the given repo on its
# registry. The dispatch table below picks one by matching the
# registry hostname against a regex; the FIRST match wins, so order
# matters. The final entry's pattern is `.*` and uses the generic
# OCI-v2 fallback, so any new public registry that conforms to the
# OCI Distribution Spec (codeberg.org, quay.io, gcr.io,
# registry.gitlab.com, ...) works without code changes.


async def _fetch_docker_hub_tags(repo: str, _registry: str) -> List[str]:
    """Anonymous Docker Hub Hub API. Returns up to 100 most recent
    tags; that's plenty for picking the highest semver."""
    url = (
        f"https://hub.docker.com/v2/repositories/{repo}/tags"
        "?page_size=100&ordering=last_updated"
    )
    async with httpx.AsyncClient(timeout=_HTTP_TIMEOUT_S) as cx:
        r = await cx.get(url)
        r.raise_for_status()
        data = r.json()
    return [
        t["name"]
        for t in (data.get("results") or [])
        if isinstance(t, dict) and t.get("name")
    ]


async def _fetch_lscr_tags(repo: str, _registry: str) -> List[str]:
    """lscr.io is LinuxServer's Cloudflare-fronted alias for both
    Docker Hub and ghcr.io. Docker Hub's Hub API is anonymous and
    quick, so route lscr.io/linuxserver/<x> through there. For
    non-linuxserver paths, fall back to the generic OCI v2 fetcher."""
    if repo.startswith("linuxserver/"):
        return await _fetch_docker_hub_tags(repo, "docker.io")
    return await _fetch_oci_v2_tags(repo, "lscr.io")


async def _fetch_ghcr_tags(repo: str, _registry: str) -> List[str]:
    """Anonymous GHCR. The v2 registry API requires a bearer token
    even for public images; ghcr.io issues one to anyone who asks for
    the repository:pull scope. Hard-coding the token URL is faster
    than the generic Www-Authenticate probe — ghcr is by far the
    most common non-Docker-Hub registry on a HomeFree box."""
    token_url = (
        f"https://ghcr.io/token?service=ghcr.io&scope=repository:{repo}:pull"
    )
    list_url = f"https://ghcr.io/v2/{repo}/tags/list?n=100"
    async with httpx.AsyncClient(timeout=_HTTP_TIMEOUT_S) as cx:
        tr = await cx.get(token_url)
        tr.raise_for_status()
        token = tr.json().get("token")
        if not token:
            return []
        r = await cx.get(
            list_url, headers={"Authorization": f"Bearer {token}"}
        )
        r.raise_for_status()
        data = r.json()
    tags = data.get("tags") or []
    return [t for t in tags if isinstance(t, str)]


# Parses a Www-Authenticate Bearer challenge into a dict of params.
# The header shape is `Bearer realm="X",service="Y",scope="Z"`; quoted
# values may contain commas, so a naive split breaks. This regex
# pulls out one `key="quoted value"` pair at a time.
_BEARER_PARAM_RE = re.compile(r'(\w+)="([^"]*)"')


async def _fetch_oci_v2_tags(repo: str, registry: str) -> List[str]:
    """Generic fallback for any OCI Distribution Spec-conformant
    registry (codeberg.org, quay.io, gcr.io, registry.gitlab.com,
    self-hosted Forgejo/Gitea, etc.).

    Flow:
      1. Probe `/v2/<repo>/tags/list`.
      2. If the registry replies 401 with a Bearer Www-Authenticate
         challenge, request a token from the realm in the challenge
         using the advertised service + scope. This is the standard
         anonymous-pull dance — registries that allow public reads
         hand out a token to anyone who asks for `repository:<r>:pull`.
      3. Retry the tags request with the token.

    Returns [] when the registry replies with an error we can't
    recover from. The caller distinguishes 'no tags returned' from
    'network error' by the surrounding try/except in _fetch_latest."""
    list_url = f"https://{registry}/v2/{repo}/tags/list?n=100"
    async with httpx.AsyncClient(
        timeout=_HTTP_TIMEOUT_S, follow_redirects=True
    ) as cx:
        r = await cx.get(list_url)
        if r.status_code == 401:
            challenge = r.headers.get("www-authenticate", "")
            if challenge.lower().startswith("bearer "):
                params = dict(
                    _BEARER_PARAM_RE.findall(challenge[len("Bearer "):])
                )
                realm = params.get("realm")
                if realm:
                    qs = {}
                    if params.get("service"):
                        qs["service"] = params["service"]
                    qs["scope"] = (
                        params.get("scope") or f"repository:{repo}:pull"
                    )
                    tr = await cx.get(realm, params=qs)
                    tr.raise_for_status()
                    payload = tr.json()
                    token = payload.get("token") or payload.get("access_token")
                    if token:
                        r = await cx.get(
                            list_url,
                            headers={"Authorization": f"Bearer {token}"},
                        )
        r.raise_for_status()
        data = r.json()
    tags = data.get("tags") or []
    return [t for t in tags if isinstance(t, str)]


# Dispatch table: (registry_hostname_pattern, fetcher_callable). The
# first match wins. Add a new registry here, not in the dispatcher.
_REGISTRY_FETCHERS: List[Tuple[re.Pattern, Any]] = [
    (re.compile(r"^docker\.io$"),  _fetch_docker_hub_tags),
    (re.compile(r"^lscr\.io$"),    _fetch_lscr_tags),
    (re.compile(r"^ghcr\.io$"),    _fetch_ghcr_tags),
    # Generic OCI v2 catch-all. Place LAST. Handles codeberg.org,
    # quay.io, gcr.io, registry.gitlab.com, and any self-hosted
    # Forgejo/Gitea/Harbor registry.
    (re.compile(r".*"),            _fetch_oci_v2_tags),
]


async def _fetch_latest(
    registry: str, repo: str, current_tag: str, digest: str = ""
) -> Tuple[Optional[str], Optional[str]]:
    """Return (latest_tag, note). Latest is None on error or when
    nothing comparable is found; note carries a short explanation
    either way. `digest` is the @sha256:... pin if the image is
    digest-only (no version tag) — we still look up the underlying
    repo's tags so the operator can see what's out there."""
    # Locally-built images have no upstream by design — skip the
    # registry round-trip.
    if _is_local(current_tag):
        return None, "local image — built on-box, no upstream"

    # Floating-tag images aren't a lookup failure — they're an
    # operator choice. An empty tag PLUS no digest is the
    # 'unspecified, defaults to :latest' case and falls in here too.
    # Empty tag + digest is a digest-only pin, handled below.
    if _is_floating(current_tag) and not digest:
        return None, "floating tag — image not version-pinned"

    fetcher = None
    for pattern, fn in _REGISTRY_FETCHERS:
        if pattern.match(registry):
            fetcher = fn
            break
    if fetcher is None:
        # Unreachable — the catch-all pattern matches anything — but
        # belt-and-braces for static analysis.
        return None, f"registry unsupported: {registry}"

    try:
        tags = await fetcher(repo, registry)
    except httpx.HTTPStatusError as e:
        return None, f"registry returned HTTP {e.response.status_code}"
    except httpx.HTTPError as e:
        return None, f"network error: {type(e).__name__}"
    except Exception as e:  # noqa: BLE001
        return None, f"lookup failed: {type(e).__name__}"

    if not tags:
        return None, "no tags returned"

    latest = _pick_latest(tags, current_tag)
    if latest is None:
        # All the tags the registry handed back are floating
        # (latest/main/git-XXXX/etc.) — the upstream doesn't publish
        # release tags at all (open-webui is the canonical example).
        # That's qualitatively different from "we didn't find a
        # comparable version"; surface it as a rolling release.
        if all(_is_floating(t) or t.startswith(("git-", "sha-")) for t in tags):
            return None, "rolling release — upstream publishes no version tags"
        return None, "no parseable semver tags"

    # Digest-pinned but with an upstream — the latest IS useful to
    # surface even though we can't directly compare digest -> tag.
    if digest and not current_tag:
        short = digest.split(":", 1)[-1][:7]
        return latest, f"pinned by digest @{short}"

    return latest, None


# ─── Release-notes URLs ───────────────────────────────────────────────
#
# Best-effort mapping from (registry, repo, tag) to a page where the
# operator can read about what changed in the latest version. URLs are
# constructed lazily — if a registry isn't in the table, the row just
# doesn't get a link (we don't synthesize broken URLs).
#
# Conventions per registry:
#   ghcr.io        -> github.com/<owner>/<repo>/releases/tag/<tag>
#   codeberg.org   -> codeberg.org/<owner>/<repo>/releases/tag/<tag>
#   lscr.io/linuxserver/X -> github.com/linuxserver/docker-X/releases
#   docker.io      -> hub.docker.com/r/<repo> (no per-tag changelog)
#   quay.io        -> quay.io/repository/<repo>?tab=history
#   *other OCI*    -> https://<registry>/<repo>/releases  (Forgejo/Gitea)


def _changelog_url(
    registry: str, repo: str, latest_tag: Optional[str]
) -> Optional[str]:
    if not registry or not repo:
        return None
    if registry == "ghcr.io":
        if latest_tag:
            return f"https://github.com/{repo}/releases/tag/{latest_tag}"
        return f"https://github.com/{repo}/releases"
    if registry == "codeberg.org":
        if latest_tag:
            return f"https://codeberg.org/{repo}/releases/tag/{latest_tag}"
        return f"https://codeberg.org/{repo}/releases"
    if registry == "lscr.io" and repo.startswith("linuxserver/"):
        # LinuxServer ships each image from a docker-<name> GitHub repo
        # whose Releases page is the canonical changelog.
        name = repo[len("linuxserver/"):]
        return f"https://github.com/linuxserver/docker-{name}/releases"
    if registry == "docker.io":
        # Strip the implicit 'library/' namespace so single-namespace
        # images (redis, postgres) get the clean Hub URL.
        clean = repo[len("library/"):] if repo.startswith("library/") else repo
        return f"https://hub.docker.com/r/{clean}"
    if registry == "quay.io":
        # Quay has no per-tag changelog page; the tags-with-history tab
        # is the next-best thing.
        return f"https://quay.io/repository/{repo}?tab=history"
    # Self-hosted Forgejo/Gitea registries (anything else routed
    # through the generic OCI v2 fetcher) typically expose
    # releases at the same hostname. Synthesizing this URL is a
    # heuristic; the link is best-effort, not guaranteed.
    if latest_tag:
        return f"https://{registry}/{repo}/releases/tag/{latest_tag}"
    return f"https://{registry}/{repo}/releases"


# ─── GitHub Security Advisories ───────────────────────────────────────
#
# For ghcr.io-hosted images we can ALSO fetch any security advisories
# the source repository has published via GitHub Security Advisories.
# These are GHSAs/CVEs that the project itself authored against its
# own code — they don't cover transitive dependency or base-image
# CVEs (that needs a real image scanner like Trivy), but they're
# free, fast, and accurate for what they cover.
#
# Anonymous GitHub API budget: 60 req/hour from a given IP. We make
# at most one call per ghcr.io image per refresh, and a HomeFree box
# has ~13 ghcr.io images, so we're well under. Rate-limit failures
# surface as a generic note and don't blow up the rest of the refresh.

_GHSA_API_HOST = "api.github.com"
_GHSA_MAX_RETURNED = 5


async def _fetch_ghsa(repo: str) -> List[Dict[str, Any]]:
    """Fetch up to _GHSA_MAX_RETURNED most-recent PUBLISHED advisories
    for a github.com/<repo> project. Returns [] on 404 (no advisories)
    or any error — this feature degrades silently rather than blocking
    the version refresh."""
    url = (
        f"https://{_GHSA_API_HOST}/repos/{repo}/security-advisories"
        f"?per_page={_GHSA_MAX_RETURNED}&state=published"
    )
    try:
        async with httpx.AsyncClient(timeout=_HTTP_TIMEOUT_S) as cx:
            r = await cx.get(
                url,
                headers={
                    "Accept": "application/vnd.github+json",
                    "X-GitHub-Api-Version": "2022-11-28",
                },
            )
            if r.status_code in (404, 403):
                return []
            r.raise_for_status()
            data = r.json()
    except httpx.HTTPError:
        return []
    if not isinstance(data, list):
        return []
    out: List[Dict[str, Any]] = []
    for a in data[:_GHSA_MAX_RETURNED]:
        if not isinstance(a, dict):
            continue
        out.append({
            "id": a.get("ghsa_id") or a.get("cve_id") or "",
            "severity": (a.get("severity") or "").lower(),
            "summary": a.get("summary") or "",
            "published_at": a.get("published_at"),
            "html_url": a.get("html_url"),
        })
    return out


_SEVERITY_RANK = {"critical": 4, "high": 3, "medium": 2, "low": 1, "": 0}


def _max_severity(advisories: List[Dict[str, Any]]) -> Optional[str]:
    if not advisories:
        return None
    return max(
        advisories,
        key=lambda a: _SEVERITY_RANK.get(a.get("severity", ""), 0),
    ).get("severity") or None


# ─── Cache I/O ────────────────────────────────────────────────────────


def _read_cache() -> Dict[str, Dict[str, Any]]:
    if not CACHE_FILE.exists():
        return {}
    try:
        data = json.loads(CACHE_FILE.read_text())
        if isinstance(data, dict):
            return data
    except (json.JSONDecodeError, OSError) as e:
        logger.warning("app-versions cache unreadable, ignoring: %s", e)
    return {}


def _write_cache(data: Dict[str, Dict[str, Any]]) -> None:
    CACHE_FILE.parent.mkdir(parents=True, exist_ok=True)
    tmp = CACHE_FILE.with_suffix(".tmp")
    tmp.write_text(json.dumps(data, indent=2, sort_keys=True))
    os.replace(tmp, CACHE_FILE)


def _read_container_catalog() -> List[Dict[str, str]]:
    if not CONTAINER_CATALOG.exists():
        return []
    try:
        data = json.loads(CONTAINER_CATALOG.read_text())
        if isinstance(data, list):
            return [
                e for e in data
                if isinstance(e, dict) and "name" in e and "image" in e
            ]
    except (json.JSONDecodeError, OSError) as e:
        logger.warning("container catalog unreadable: %s", e)
    return []


def _read_service_metadata() -> Dict[str, Dict[str, str]]:
    if not SERVICE_METADATA.exists():
        return {}
    try:
        data = json.loads(SERVICE_METADATA.read_text())
        if isinstance(data, dict):
            return data
    except (json.JSONDecodeError, OSError):
        pass
    return {}


# ─── Refresh ──────────────────────────────────────────────────────────

# Coalesce concurrent refreshes — the daily timer and an admin
# clicking Refresh shouldn't double up. The lock is process-local,
# which is fine: only this process (and the oneshot timer, which
# uses the same module) writes the cache.
_refresh_lock = asyncio.Lock()


async def refresh_all() -> Dict[str, Dict[str, Any]]:
    """Refresh upstream tags for every container in the catalog.
    Returns the freshly-written cache. Drops cache entries for
    containers no longer present (rule 11 — tolerate format drift /
    container removal silently)."""
    async with _refresh_lock:
        catalog = _read_container_catalog()
        cache: Dict[str, Dict[str, Any]] = {}
        now = int(time.time())
        for entry in catalog:
            name = entry["name"]
            parsed = _parse_image(entry["image"])
            if parsed is None:
                cache[name] = {
                    "latest_tag": None,
                    "note": "image string unparseable",
                    "last_checked": now,
                }
                continue
            latest, note = await _fetch_latest(
                parsed["registry"],
                parsed["repo"],
                parsed["tag"],
                parsed.get("digest", ""),
            )
            # GitHub Security Advisories — only for ghcr.io images,
            # since the API is /repos/<org>/<repo>/ and only the
            # ghcr.io repo path maps cleanly onto a github.com one.
            # Skipped silently for everything else.
            advisories: List[Dict[str, Any]] = []
            if parsed["registry"] == "ghcr.io" and parsed["repo"]:
                advisories = await _fetch_ghsa(parsed["repo"])
            cache[name] = {
                "latest_tag": latest,
                "note": note,
                "last_checked": now,
                "advisories": advisories,
            }
        _write_cache(cache)
        return cache


# ─── Endpoint payload ─────────────────────────────────────────────────


def _iso_z(epoch_s: Optional[int]) -> Optional[str]:
    if not epoch_s:
        return None
    from datetime import datetime, timezone
    return (
        datetime.fromtimestamp(epoch_s, tz=timezone.utc)
        .strftime("%Y-%m-%dT%H:%M:%SZ")
    )


def _build_payload() -> List[Dict[str, Any]]:
    catalog = _read_container_catalog()
    cache = _read_cache()
    metadata = _read_service_metadata()

    out: List[Dict[str, Any]] = []
    for entry in catalog:
        name = entry["name"]
        parsed = _parse_image(entry["image"]) or {
            "registry": "", "repo": "", "tag": "",
        }
        meta = metadata.get(name) or {}
        cache_entry = cache.get(name) or {}

        current = parsed.get("tag") or None
        digest = parsed.get("digest") or ""
        latest = cache_entry.get("latest_tag")
        note = cache_entry.get("note")
        last_checked = _iso_z(cache_entry.get("last_checked"))

        # Surface a short digest as the "current" field when the
        # operator pinned by digest with no tag — otherwise the
        # column is blank for digest-only rows.
        if not current and digest:
            short = digest.split(":", 1)[-1][:7]
            current = f"@{short}"

        if _is_local(parsed.get("tag", "")):
            status = "local"
        elif _is_floating(parsed.get("tag", "")) and not digest:
            # Operator opted out of version pinning — nothing to compare.
            status = "floating"
        elif latest is None:
            status = "unknown"
        elif (current and latest
              and current.lstrip("v@") == latest.lstrip("v")):
            status = "up-to-date"
        else:
            # Digest-pinned with a known upstream falls in here. The
            # operator can't be told "up-to-date" without resolving
            # the digest of `latest` and comparing — too much network
            # for a per-row decision — so the honest answer is
            # "Update available, FYI you're on digest X".
            status = "outdated"

        advisories = cache_entry.get("advisories") or []
        if not isinstance(advisories, list):
            advisories = []

        # Release-notes URL — best-effort link to where the operator
        # can see what's in the latest version. Only attached when
        # there IS a latest version to point at; floating/local/
        # up-to-date rows don't need it.
        if status in ("outdated",) and latest:
            changelog_url = _changelog_url(
                parsed.get("registry") or "",
                parsed.get("repo") or "",
                latest,
            )
        else:
            changelog_url = None

        # Security-advisory list URL — for ghcr.io images, the source
        # repo's advisory list on github.com. Surfaced regardless of
        # whether there are any open advisories, so the operator can
        # click through to confirm "still nothing here" if curious.
        advisories_url = None
        if parsed.get("registry") == "ghcr.io" and parsed.get("repo"):
            advisories_url = (
                f"https://github.com/{parsed['repo']}/security/advisories"
                "?state=published"
            )

        out.append({
            "name": name,
            "project_name": meta.get("project-name") or meta.get("name") or name,
            "image": entry["image"],
            "registry": parsed.get("registry") or None,
            "repo": parsed.get("repo") or None,
            "current": current,
            "latest": latest,
            "status": status,
            "note": note,
            "last_checked": last_checked,
            "changelog_url": changelog_url,
            "advisories": advisories,
            "advisory_count": len(advisories),
            "advisory_max_severity": _max_severity(advisories),
            "advisories_url": advisories_url,
        })

    # Stable sort: outdated first (the actionable rows), then unknown
    # (lookup failed — operator may want to investigate), then floating
    # (deliberate choice, informational), then up-to-date. Within each
    # bucket, by project name.
    status_order = {
        "outdated": 0,
        "unknown": 1,
        "floating": 2,
        "local": 3,
        "up-to-date": 4,
    }
    out.sort(key=lambda r: (
        status_order.get(r["status"], 5),
        (r["project_name"] or "").lower(),
    ))
    return out


# ─── HTTP endpoints ───────────────────────────────────────────────────


@router.get("/versions")
async def get_app_versions() -> Dict[str, Any]:
    """Read-only merged view of the eval-time container catalog and
    the cached upstream-tag lookups. Always fast (no network)."""
    return {"apps": _build_payload()}


async def _refresh_in_background() -> None:
    try:
        await refresh_all()
    except Exception as e:  # noqa: BLE001
        logger.error("app-versions refresh failed: %s", e)


@router.post("/versions/refresh")
async def post_app_versions_refresh(
    background_tasks: BackgroundTasks,
) -> Dict[str, Any]:
    """Kick a refresh and return immediately. The UI re-polls
    /api/apps/versions to see updated cache entries. The asyncio.Lock
    inside refresh_all() means a second click during an in-flight
    refresh just waits for the first to finish instead of fanning out."""
    background_tasks.add_task(_refresh_in_background)
    return {"status": "refreshing"}
