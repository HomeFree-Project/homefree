"""
App-Versions resolver — backs the Advanced -> App Versions page.

Shows every app/service declared in the source tree — NOT just the
ones currently enabled — alongside its currently-pinned image tag and
the latest tag available from its upstream registry. A disabled app
never declares a virtualisation.oci-containers.containers entry, so it
would otherwise be invisible here; we fill it in from a source scan.
Three artifacts feed the merged view:

  * Container catalog (eval-time, immutable between rebuilds):
      /run/homefree/admin/container-images.json
      Emitted by services/admin-web/default.nix from
      config.virtualisation.oci-containers.containers. Authoritative
      for the ENABLED containers (exact names + the actually-deployed
      image, which honours any alternate-base override).

  * All-app-images catalog (eval-time, immutable between rebuilds):
      /run/homefree/admin/all-app-images.json
      Emitted by services/admin-web/default.nix, which runs
      resolvers/app_source_index.py over apps/ + services/ at build
      time. Lists EVERY image pin in the source, so apps that aren't
      currently enabled still get a row.

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
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple
from urllib.parse import quote, unquote

import httpx
from fastapi import APIRouter, BackgroundTasks, Body

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api/apps", tags=["app-versions"])

# ─── Paths ────────────────────────────────────────────────────────────

# Eval-time, immutable: list of {name, image} for every oci-container.
CONTAINER_CATALOG = Path("/run/homefree/admin/container-images.json")

# Eval-time, immutable: [{app, image}] for EVERY app/service image pin
# in the source tree — including apps that are currently disabled and so
# never appear in CONTAINER_CATALOG. Emitted by
# services/admin-web/default.nix (which runs resolvers/app_source_index.py
# over apps/ + services/ at build time).
ALL_APP_IMAGES = Path("/run/homefree/admin/all-app-images.json")

# Eval-time, immutable: maps service label -> {name, project-name,
# version-tracking}. The version-tracking descriptor (declared per app in
# its homefree.service-config entry) is how an app overrides the default
# image-derived version-detection strategy.
SERVICE_METADATA = Path("/run/homefree/admin/service-metadata.json")

# Eval-time, immutable: [{label, name, project-name, current-version,
# version-tracking}] for NON-container host apps (headscale, opensprinkler,
# ...) that declare a version-tracking strategy but ship no OCI image, so
# they never appear in the two image catalogs above. Emitted by
# services/admin-web/default.nix.
HOST_APPS = Path("/run/homefree/admin/host-apps.json")

# Mutable cache of upstream-tag lookups. Keyed by catalog entry key
# (container name for enabled apps; a derived stable id for disabled).
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


def _suffix_key(suffix: str) -> Tuple:
    """Sortable key for a tag's pre-release/build suffix.

    A plain string compare mis-orders numbered builds — '-b.9' sorts
    ABOVE '-b.90' lexicographically (adguard's beta line picked build
    NINE as 'latest', which upgrade-apps then refused as a numeric
    downgrade). Split the suffix into digit / non-digit runs and compare
    digit runs numerically: ('-b.', 9) < ('-b.', 88) < ('-b.', 90).

    Each run is encoded as (type-rank, value) so int/str never compare
    directly; the empty suffix maps to rank 9 so a PLAIN release still
    sorts above any pre-release of the same base version."""
    if not suffix:
        return ((9, ""),)
    return tuple(
        (0, int(run)) if run.isdigit() else (1, run)
        for run in re.findall(r"\d+|\D+", suffix)
    )


def _semver_tuple(tag: str) -> Optional[Tuple[int, int, int, int, Tuple]]:
    """Return (major, minor, patch, fourth, suffix_key) for a
    semver-shaped tag, or None if the tag isn't semver-like. The suffix
    key (see _suffix_key) sorts plain releases above pre-releases of the
    same base version, and numbered pre-release builds numerically."""
    normalised = _strip_tag_prefix(tag)
    m = _SEMVER_PARTS_RE.match(normalised)
    if not m:
        return None
    major = int(m.group(1))
    minor = int(m.group(2))
    patch = int(m.group(3) or 0)
    fourth = int(m.group(4) or 0)
    return (major, minor, patch, fourth, _suffix_key(m.group(5) or ""))


# Captures (leading_text_before_digits, trailing_text_after_semver_core).
# Used to distinguish parallel release streams that share a semver core
# (nextcloud `33.0.5-apache` vs `33.0.5`; baikal `0.10.1-nginx` vs
# `0.10.1`; grocy `4.6.0` vs `version-v4.6.0`). The picker requires an
# exact shape match against the current tag so it never recommends a
# cross-flavour or cross-prefix-stream tag as "newer".
_SHAPE_RE = re.compile(r"^([^\d]*)(\d+(?:\.\d+)*)(.*)$")


def _tag_shape(tag: str) -> Optional[Tuple[str, str]]:
    """Return (leading_prefix, trailing_suffix) for a semver-shaped tag.

    Leading prefix is everything before the first digit ('', 'v',
    'version-v', 'release-'). Trailing suffix is everything after the
    last digit-or-dot of the semver core ('', '-apache', '-rc1',
    '-b.88'). None if the tag has no semver core.

    A leading 'v' version marker is normalised away ('v1.2.3' and '1.2.3'
    are the same stream — the single most common image-pin vs. GitHub-tag
    mismatch, e.g. frigate's image `0.17.1` vs its release `v0.17.1`).
    Other prefixes ('version-', 'release-') stay distinct, so grocy's
    `4.6.0` and `version-v4.6.0` are still kept in separate lanes."""
    if not tag:
        return None
    m = _SHAPE_RE.match(tag)
    if not m:
        return None
    prefix = re.sub(r"(^|[-_/])v$", r"\1", m.group(1))
    return (prefix, m.group(3))


def _raw_tag_lead(tag: str) -> str:
    """The LITERAL leading non-digit run of a tag ('' or 'v' for the two
    variants that collapse to the same _tag_shape). _tag_shape normalises a
    leading 'v' away, so a plain `0.73.0` and a `v0.73.0` — which many
    upstreams (netbird, ...) publish for the SAME release — share a shape and
    an identical semver tuple. When both appear in a listing, the tie-break in
    _pick_latest must prefer the one whose literal marker matches the current
    pin; otherwise it reports e.g. `v0.73.0` for a `0.72.4` pin, and the
    one-click bumper then refuses `0.72.4 -> v0.73.0` as a tag-scheme change."""
    m = re.match(r"[^\d]*", tag or "")
    return m.group(0) if m else ""


def _same_release(current: str, latest: str) -> bool:
    """Two tags refer to the same upstream release iff they share both
    a semver core (parsed via _semver_tuple) AND a shape (parsed via
    _tag_shape). Falls back to string equality when either tag isn't
    semver-shaped."""
    cs = _tag_shape(current)
    ls = _tag_shape(latest)
    if cs is None or ls is None or cs != ls:
        return False
    ct = _semver_tuple(current)
    lt = _semver_tuple(latest)
    if ct is None or lt is None:
        return current == latest
    return ct == lt


def _pick_latest(tags: List[str], current_tag: str) -> Optional[str]:
    """Pick the highest semver-shaped tag in the SAME release stream as
    current's, AND only if it's >= current. 'Same release stream' =
    same _tag_shape (matching leading prefix AND trailing suffix) AND
    same major.

    Failure modes this guards against:
      * Flavor switch — current `33.0.5-apache` won't pick plain `33.0.5`
        (different stream); current `0.10.1-nginx` won't pick plain
        `0.10.1`.
      * Pre-release leakage — current `v0.107.73` won't auto-pick a
        `v0.108.0-b.88` beta (different suffix); the operator bumps
        across streams by hand.
      * Cross-prefix confusion — current `4.6.0` won't pick
        `version-v4.6.0` from the same registry.
      * Cross-major recommendation — current `15.0.1` (forgejo) won't
        pick `1.21.x` from an old release line; current `2026.4`
        (home-assistant) won't pick `2021.7.1`.
      * Paginated-listing downgrade — registries cap tag listings at
        100 entries, often dominated by `sha256-...` cosign artifacts
        and floats. When the current pin isn't in the window, the next
        candidate is almost always older — never recommend a tag whose
        semver tuple is below current's. The row falls back to
        status=unknown, which is honest about the listing limit.

    If current_tag isn't semver-shaped, refuse — nothing to anchor."""
    semver_tags: List[Tuple[Tuple[int, int, int, int, Tuple], str]] = []
    for t in tags:
        st = _semver_tuple(t)
        if st is None:
            continue
        semver_tags.append((st, t))
    if not semver_tags:
        return None

    current_shape = _tag_shape(current_tag)
    current = _semver_tuple(current_tag)

    if current_shape is None:
        # Nothing to anchor a stream to; refuse to guess.
        return None

    same_shape = [
        (st, t) for (st, t) in semver_tags if _tag_shape(t) == current_shape
    ]
    if not same_shape:
        return None

    if current is None:
        # Shape matched but current's semver didn't parse — trust the
        # highest in-shape candidate (rare; e.g. weird 5-segment tags).
        return max(same_shape)[1]

    same_shape_same_major = [
        (st, t) for (st, t) in same_shape if st[0] == current[0]
    ]
    if not same_shape_same_major:
        # No tags share current's major in current's stream. Could be a
        # paginated listing that doesn't reach current, or a renamed
        # release line. Cross-major would be a downgrade or surprise
        # leap — refuse.
        return None

    # Highest semver wins; ties (a plain `X.Y.Z` and a `vX.Y.Z` for the same
    # release — same shape, same tuple) break toward the tag whose literal
    # marker matches the current pin, so the picked tag stays in the current
    # scheme and a downstream one-click bump isn't refused as a scheme change.
    cur_lead = _raw_tag_lead(current_tag)
    candidate_st, candidate_t = max(
        same_shape_same_major,
        key=lambda it: (it[0], _raw_tag_lead(it[1]) == cur_lead),
    )
    if candidate_st < current:
        # Best in-stream same-major candidate is OLDER than current.
        # The registry's recent tags don't include anything at or above
        # the current pin — almost certainly the page-size cap hiding
        # newer tags. Refusing here keeps the row honest (status=unknown)
        # instead of silently flagging it as outdated to an older tag.
        return None
    return candidate_t


# ─── Floating-tag handling ────────────────────────────────────────────

# Tags that explicitly opt out of version pinning. An image pinned to
# one of these has no "current version" to compare against — surfacing
# it as Unknown would be misleading, since the lookup isn't failing
# (there is genuinely nothing to compare). The page shows these with
# a distinct "floating tag" badge instead.
_FLOATING_TAGS = frozenset({
    "", "latest", "stable", "edge", "nightly", "main", "master",
    "dev", "develop", "rolling", "current", "beta", "alpha", "head",
    # Bare flavour aliases roll forward just like `latest` — `redis:alpine`
    # is "newest release, alpine build", not a version pin. Versioned
    # flavour tags (8.8.0-alpine, alpine3.23) still parse as versions.
    "alpine", "slim", "bookworm", "bullseye", "trixie",
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


# Cosign-style signature / attestation artifacts. Modern ghcr.io (and
# increasingly other registries) publish one or two of these per real
# release, so a `?n=100` tag listing can be entirely consumed by them
# before any actual semver tag appears. We drop them before semver
# matching so the page-size budget goes to real tags.
_COSIGN_TAG_RE = re.compile(r"^sha256-[a-f0-9]{64}(\.(sig|att|sbom))?$")


def _is_cosign_artifact(tag: str) -> bool:
    return bool(_COSIGN_TAG_RE.match(tag or ""))


# ─── Per-registry tag fetchers ────────────────────────────────────────
#
# Each fetcher returns the raw tag list for the given repo on its
# registry. The dispatch table below picks one by matching the
# registry hostname against a regex; the FIRST match wins, so order
# matters. The final entry's pattern is `.*` and uses the generic
# OCI-v2 fallback, so any new public registry that conforms to the
# OCI Distribution Spec (codeberg.org, quay.io, gcr.io,
# registry.gitlab.com, ...) works without code changes.


def _hub_results(data: Any) -> List[str]:
    return [
        t["name"]
        for t in (data.get("results") or [])
        if isinstance(t, dict) and t.get("name")
    ]


async def _fetch_docker_hub_tags(
    repo: str, _registry: str, current_tag: str = ""
) -> List[str]:
    """Anonymous Docker Hub Hub API. Returns up to 100 most-recent tags.

    Flavour-heavy official repos (redis, postgres) publish many variant
    tags (`-alpine`, `-bookworm`, ...) per release, so the plain `X.Y.Z`
    tag of the CURRENT line is routinely pushed off the recent-100 window
    by later backport variants. When we know the current tag, a second
    request filtered by its `<major>.<minor>` (Hub's `name=` substring
    filter) resurfaces that line; the two result sets are merged. The
    primary request's errors propagate (a real failure); the filtered
    one is best-effort."""
    base = (
        f"https://hub.docker.com/v2/repositories/{repo}/tags"
        "?page_size=100&ordering=last_updated"
    )
    async with httpx.AsyncClient(timeout=_HTTP_TIMEOUT_S) as cx:
        r = await cx.get(base)
        r.raise_for_status()
        names = _hub_results(r.json())
        mm = re.match(r"v?(\d+)\.(\d+)", current_tag or "")
        if mm:
            try:
                r2 = await cx.get(f"{base}&name={mm.group(1)}.{mm.group(2)}")
                r2.raise_for_status()
                seen = set(names)
                names += [n for n in _hub_results(r2.json()) if n not in seen]
            except httpx.HTTPError:
                pass
    return names


async def _fetch_lscr_tags(
    repo: str, _registry: str, current_tag: str = ""
) -> List[str]:
    """lscr.io is LinuxServer's Cloudflare-fronted alias for both
    Docker Hub and ghcr.io. Docker Hub's Hub API is anonymous and
    quick, so route lscr.io/linuxserver/<x> through there. For
    non-linuxserver paths, fall back to the generic OCI v2 fetcher."""
    if repo.startswith("linuxserver/"):
        return await _fetch_docker_hub_tags(repo, "docker.io", current_tag)
    return await _fetch_oci_v2_tags(repo, "lscr.io", current_tag)


async def _fetch_ghcr_tags(
    repo: str, _registry: str, current_tag: str = ""
) -> List[str]:
    """Anonymous GHCR. The v2 registry API requires a bearer token
    even for public images; ghcr.io issues one to anyone who asks for
    the repository:pull scope. Hard-coding the token URL is faster
    than the generic Www-Authenticate probe — ghcr is by far the
    most common non-Docker-Hub registry on a HomeFree box.

    Uses n=1000 because GHCR tag listings are dominated by cosign
    `sha256-*` artifacts (one or two per release) plus a `-arm`,
    `-rootless`, `-hardened` etc. flavor expansion. The default n=100
    is routinely consumed before any real semver appears."""
    token_url = (
        f"https://ghcr.io/token?service=ghcr.io&scope=repository:{repo}:pull"
    )
    list_url = f"https://ghcr.io/v2/{repo}/tags/list?n=1000"
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
    return [t for t in tags if isinstance(t, str) and not _is_cosign_artifact(t)]


# Parses a Www-Authenticate Bearer challenge into a dict of params.
# The header shape is `Bearer realm="X",service="Y",scope="Z"`; quoted
# values may contain commas, so a naive split breaks. This regex
# pulls out one `key="quoted value"` pair at a time.
_BEARER_PARAM_RE = re.compile(r'(\w+)="([^"]*)"')


async def _fetch_oci_v2_tags(
    repo: str, registry: str, current_tag: str = ""
) -> List[str]:
    """Generic fallback for any OCI Distribution Spec-conformant
    registry (codeberg.org, quay.io, gcr.io, registry.gitlab.com,
    self-hosted Forgejo/Gitea, etc.). `current_tag` is accepted for a
    uniform fetcher signature but unused (the v2 tags/list has no
    server-side name filter).

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
    list_url = f"https://{registry}/v2/{repo}/tags/list?n=1000"
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
    return [t for t in tags if isinstance(t, str) and not _is_cosign_artifact(t)]


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
        tags = await fetcher(repo, registry, current_tag)
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
        #
        # For ghcr.io this is ALSO where the page-cap case lands (zitadel,
        # home-assistant and other repos with more tags than the n=1000
        # window returns). refresh_all retries those against the source
        # repo's GitHub Releases — see _ghcr_github_release_fallback.
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


# Pulls the tag out of each <link .../releases/tag/TAG"/> in a releases
# atom feed. The char class stops at the closing quote / angle bracket.
_GITHUB_RELEASE_TAG_RE = re.compile(r"/releases/tag/([^\"'<>]+)")


async def _fetch_github_release_tags(repo: str) -> List[str]:
    """Recent GitHub Release tags for github.com/<repo>, newest first,
    via the releases.atom feed. Returns [] on 404 / error.

    Deliberately uses the github.com WEB feed, NOT api.github.com: the
    anonymous REST API is only 60 requests/hour per IP, which a full
    refresh (advisories for every ghcr image + this version fallback)
    blows through in a couple of runs — after which every github-derived
    version reverts to Unknown. The atom feed is served like an ordinary
    page under a far more generous limit. It lists releases newest-first
    INCLUDING pre-releases; we return them all and let _pick_latest's
    shape guard drop betas (a `2026.6.0b4`-shaped tag won't match a
    `2026.4` pin)."""
    url = f"https://github.com/{repo}/releases.atom"
    try:
        async with httpx.AsyncClient(
            timeout=_HTTP_TIMEOUT_S, follow_redirects=True
        ) as cx:
            r = await cx.get(url)
            if r.status_code == 404:
                return []
            r.raise_for_status()
            body = r.text
    except httpx.HTTPError:
        return []
    seen: set = set()
    tags: List[str] = []
    for raw in _GITHUB_RELEASE_TAG_RE.findall(body):
        tag = unquote(raw)
        if tag and tag not in seen:
            seen.add(tag)
            tags.append(tag)
    return tags


def _github_repo_from_url(url: str) -> Optional[str]:
    """Extract 'owner/name' from a github.com URL, else None. Tolerates a
    trailing '.git', '/', or deeper path."""
    if not url:
        return None
    m = re.match(r"https?://github\.com/([^/\s]+)/([^/\s#?]+)", url.strip())
    if not m:
        return None
    owner, name = m.group(1), m.group(2)
    if name.endswith(".git"):
        name = name[:-4]
    return f"{owner}/{name}" if owner and name else None


# Accept header advertising every manifest media type ghcr serves, so a
# single GET resolves whether the ref is a single-arch image or a
# multi-arch index.
_OCI_MANIFEST_ACCEPT = ",".join([
    "application/vnd.oci.image.index.v1+json",
    "application/vnd.docker.distribution.manifest.list.v2+json",
    "application/vnd.oci.image.manifest.v1+json",
    "application/vnd.docker.distribution.manifest.v2+json",
])


async def _ghcr_source_repo(repo: str, ref: str) -> Optional[str]:
    """Best-effort: resolve a ghcr.io image to its GitHub source repo
    ('owner/name') via the org.opencontainers.image.source label on the
    image config. A ghcr image name frequently differs from its source
    repo — ghcr.io/home-assistant/home-assistant is built from
    github.com/home-assistant/core; immich-server from immich-app/immich
    — so the bare ghcr path can't be assumed to be the GitHub repo.

    Returns None on any failure; the caller falls back to the ghcr path."""
    try:
        async with httpx.AsyncClient(
            timeout=_HTTP_TIMEOUT_S, follow_redirects=True
        ) as cx:
            tr = await cx.get(
                f"https://ghcr.io/token?service=ghcr.io&scope=repository:{repo}:pull"
            )
            tr.raise_for_status()
            token = tr.json().get("token")
            if not token:
                return None
            headers = {
                "Authorization": f"Bearer {token}",
                "Accept": _OCI_MANIFEST_ACCEPT,
            }
            r = await cx.get(
                f"https://ghcr.io/v2/{repo}/manifests/{ref}", headers=headers
            )
            r.raise_for_status()
            man = r.json()
            # Multi-arch index -> drill into a concrete linux image manifest
            # (prefer amd64; skip attestation entries whose architecture is
            # 'unknown') to reach an actual config blob.
            sub = man.get("manifests")
            if isinstance(sub, list):
                digest = None
                for entry in sub:
                    plat = entry.get("platform") or {}
                    arch = plat.get("architecture")
                    if arch in (None, "unknown"):
                        continue
                    if plat.get("os") == "linux" and arch == "amd64":
                        digest = entry.get("digest")
                        break
                    if digest is None:
                        digest = entry.get("digest")
                if not digest:
                    return None
                r = await cx.get(
                    f"https://ghcr.io/v2/{repo}/manifests/{digest}",
                    headers=headers,
                )
                r.raise_for_status()
                man = r.json()
            cfg_digest = (man.get("config") or {}).get("digest")
            if not cfg_digest:
                return None
            b = await cx.get(
                f"https://ghcr.io/v2/{repo}/blobs/{cfg_digest}",
                headers={"Authorization": f"Bearer {token}"},
            )
            b.raise_for_status()
            labels = ((b.json().get("config") or {}).get("Labels")) or {}
    except (httpx.HTTPError, ValueError, KeyError, TypeError):
        return None
    return _github_repo_from_url(labels.get("org.opencontainers.image.source") or "")


async def _ghcr_github_release_fallback(
    repo: str, current_tag: str
) -> Tuple[Optional[str], Optional[str]]:
    """For a ghcr.io image whose registry tag listing couldn't yield a
    comparable version, try the GitHub Releases of its source repo.
    Returns (latest_tag, github_source_repo), or (None, None).

    Tries the org.opencontainers.image.source-derived repo first (so
    ghcr.io/home-assistant/home-assistant -> home-assistant/core resolves),
    then the ghcr repo path itself (covers zitadel/zitadel, where the names
    match and the label lookup is unnecessary). The candidate GH release
    tag is run through _pick_latest so the same shape/major/no-downgrade
    guards apply — e.g. frigate's `v0.17.1` release won't be recommended
    over a `0.17.1` pin (different prefix stream)."""
    candidates: List[str] = []
    src = await _ghcr_source_repo(repo, current_tag)
    if src:
        candidates.append(src)
    if repo not in candidates:
        candidates.append(repo)
    for gh_repo in candidates:
        gh_tags = await _fetch_github_release_tags(gh_repo)
        if not gh_tags:
            continue
        picked = _pick_latest(gh_tags, current_tag)
        if picked:
            return picked, gh_repo
    return None, None


_SEVERITY_RANK = {"critical": 4, "high": 3, "medium": 2, "low": 1, "": 0}


def _max_severity(advisories: List[Dict[str, Any]]) -> Optional[str]:
    if not advisories:
        return None
    return max(
        advisories,
        key=lambda a: _SEVERITY_RANK.get(a.get("severity", ""), 0),
    ).get("severity") or None


# ─── Version-tracking strategies ──────────────────────────────────────
#
# The default ("image") strategy infers the lookup entirely from the
# parsed OCI image — the registry host picks the tag fetcher, and a
# ghcr.io image that the registry can't resolve falls back to its source
# repo's GitHub Releases. That covers the large majority of apps with no
# per-app configuration, and is the EXACT behaviour the page had before
# this layer existed.
#
# An app that the default can't resolve (a community fork, a beta channel,
# an odd tag shape, a digest-only pin, or — for a non-container host app —
# no image at all) declares a `version-tracking` descriptor in its
# homefree.service-config entry: `{strategy, repo, registry, tag-prefix,
# tag-pattern, channel, current-version, url, regex, command}`. Core owns
# the strategy catalog; each app (and each out-of-tree plugin, in its own
# repo) only selects + parameterises one — nothing app-specific lives here
# (rule 1). Per rule 8 only this backend ever talks to upstream.


@dataclass
class StrategyResult:
    """Uniform return shape for every strategy. `latest` is None on any
    failure or when nothing comparable was found; `note` always carries a
    short human reason. `source_repo` (github 'owner/name') drives the
    changelog + advisory links when the version came from GitHub rather
    than the image's own registry."""
    latest: Optional[str] = None
    note: Optional[str] = None
    source_repo: Optional[str] = None
    advisories: List[Dict[str, Any]] = field(default_factory=list)


# Pre-release markers in a tag's trailing suffix. Distinguishes a real
# pre-release (-rc1, -beta, -b.88, -alpha2) — which `channel = "stable"`
# drops — from a parallel FLAVOUR stream (-apache, -nginx, -bookworm)
# which _tag_shape already keeps in its own lane. Conservative on
# purpose: a false "this is a pre-release" would hide a real stable
# update, so the marker set is short and the bare 'b' form requires a
# following digit (so '-bookworm' / '-musl' don't match).
_PRERELEASE_MARKERS = (
    "rc", "alpha", "beta", "pre", "preview", "dev", "snapshot", "nightly",
)


def _is_prerelease_tag(tag: str) -> bool:
    shape = _tag_shape(tag)
    if shape is None:
        return False
    suffix = (shape[1] or "").lstrip("-.").lower()
    if not suffix:
        return False
    if re.match(r"^b[-.]?\d", suffix):  # adguard-style '-b.88' / '-b88'
        return True
    return any(suffix.startswith(m) for m in _PRERELEASE_MARKERS)


def _strip_prerelease_suffix(tag: str) -> str:
    """Drop a trailing pre-release marker so a pin that is ITSELF a
    pre-release can anchor to its stable stream (adguard's
    'v0.108.0-b.88' -> 'v0.108.0'). No-op for non-pre-release tags."""
    shape = _tag_shape(tag)
    if shape is None or not _is_prerelease_tag(tag):
        return tag
    suffix = shape[1] or ""
    if suffix and tag.endswith(suffix):
        return tag[: len(tag) - len(suffix)]
    return tag


def _anchor(parsed: Dict[str, str], params: Dict[str, Any]) -> str:
    """The version to compare candidates against: an explicit
    `current-version` (host apps / digest pins) wins over the image tag."""
    return (params.get("current-version") or "").strip() or parsed.get("tag", "") or ""


def _pick_latest_loose(
    tags: List[str], anchor: str, allow_behind: bool = False
) -> Optional[str]:
    """Shape-agnostic picker: highest semver tuple. Used when the anchor is
    a DECLARED `current-version` whose shape is decoupled from the upstream
    tag shape (headscale's nixpkgs '0.28.0' vs the GitHub 'v0.28.0'
    release) — the strict same-shape guard in _pick_latest would wrongly
    reject every candidate there.

    `allow_behind` distinguishes the two anchor kinds: a declared
    current-version legitimately sits ABOVE the latest upstream RELEASE (a
    box can run a nixpkgs build ahead of the last stable tag) — surface the
    real latest anyway so the row reads up-to-date rather than unknown. An
    image-tag anchor (the pre-release channel) keeps the no-downgrade guard,
    since a below-anchor max there is the registry page-cap hiding newer
    tags, not the operator being ahead."""
    cand: List[Tuple[Tuple[int, int, int, int, Tuple], str]] = []
    for t in tags:
        st = _semver_tuple(t)
        if st is not None:
            cand.append((st, t))
    if not cand:
        return None
    best_st, best_t = max(cand)
    at = _semver_tuple(anchor) if anchor else None
    if not allow_behind and at is not None and best_st < at:
        return None
    return best_t


def _pick_with_params(
    tags: List[str], parsed: Dict[str, str], params: Dict[str, Any]
) -> Optional[str]:
    """Apply the descriptor's `tag-pattern` + `channel` filters, then pick
    the latest. Uses the strict, same-shape _pick_latest when anchoring on
    an image tag (flavours/prefix streams matter), or the loose,
    tuple-based picker when an explicit `current-version` is the anchor."""
    anchor = _anchor(parsed, params)
    channel = (params.get("channel") or "stable").lower()
    pattern = params.get("tag-pattern") or ""
    # Loose (shape-agnostic, tuple-only) picking when the anchor is a
    # declared current-version (host apps), OR when tracking a pre-release
    # line — each beta BUILD is its own _tag_shape (suffix carries the
    # build number), so the strict picker can never advance b.88 -> b.90.
    loose = bool((params.get("current-version") or "").strip()) or channel == "prerelease"

    if pattern:
        try:
            rx = re.compile(pattern)
        except re.error:
            rx = None
        if rx is not None and rx.groups:
            # CAPTURE-GROUP mode: the pattern's first group extracts the
            # comparable version out of a compound tag that isn't itself
            # semver — immich's postgres image tags
            # ('18-vectorchord0.5.3-pgvector0.8.1') compare on the captured
            # vectorchord version, while the FULL tag (a real, pullable
            # image tag) is what gets returned/recommended.
            pairs = [
                (m.group(1), t)
                for t in tags
                for m in [rx.search(t)]
                if m and m.group(1)
            ]
            am = rx.search(anchor or "")
            anchor_v = am.group(1) if (am and am.group(1)) else anchor
            if channel == "stable":
                pairs = [(v, t) for (v, t) in pairs if not _is_prerelease_tag(v)]
            versions = [v for (v, _) in pairs]
            picked_v = (
                _pick_latest_loose(versions, anchor_v, allow_behind=True)
                if loose else _pick_latest(versions, anchor_v)
            )
            if picked_v is None:
                return None
            return max(t for (v, t) in pairs if v == picked_v)
        if rx is not None:
            tags = [t for t in tags if rx.search(t)]

    if channel == "stable":
        tags = [t for t in tags if not _is_prerelease_tag(t)]
        if not loose:
            anchor = _strip_prerelease_suffix(anchor)
    # channel "prerelease"/"any": keep all tags, anchor unchanged.

    if loose:
        # A declared current-version may legitimately be ahead of the latest
        # release; an image-tag pre-release anchor keeps the no-downgrade guard.
        allow_behind = bool((params.get("current-version") or "").strip())
        picked = _pick_latest_loose(tags, anchor, allow_behind=allow_behind)
        if (
            picked is None
            and allow_behind
            and channel == "stable"
            and anchor
            and not _is_prerelease_tag(anchor)
            and _semver_tuple(anchor) is not None
        ):
            # The upstream's recent release window can be ENTIRELY
            # pre-releases (headscale's releases.atom mid-beta-cycle lists
            # only v0.XX.0-beta.* entries), so the stable filter leaves no
            # comparable candidate at all. The declared, stable
            # current-version is then the newest stable we know of —
            # surface it as latest (the row reads up-to-date) rather than
            # a perpetual unknown.
            return anchor
        return picked
    return _pick_latest(tags, anchor)


# ─── Extra tag fetchers (selected only by an explicit strategy) ───────


async def _fetch_github_tags(repo: str) -> List[str]:
    """Git tags for github.com/<repo> via the tags.atom web feed — for
    projects that tag releases but don't publish GitHub Releases. Same
    anti-rate-limit rationale as _fetch_github_release_tags (the atom feed
    is served as an ordinary page, not the 60/hr REST API)."""
    url = f"https://github.com/{repo}/tags.atom"
    try:
        async with httpx.AsyncClient(
            timeout=_HTTP_TIMEOUT_S, follow_redirects=True
        ) as cx:
            r = await cx.get(url)
            if r.status_code == 404:
                return []
            r.raise_for_status()
            body = r.text
    except httpx.HTTPError:
        return []
    seen: set = set()
    tags: List[str] = []
    # tags.atom links each entry to /releases/tag/<tag>, same as the
    # releases feed, so the existing extractor works unchanged.
    for raw in _GITHUB_RELEASE_TAG_RE.findall(body):
        tag = unquote(raw)
        if tag and tag not in seen:
            seen.add(tag)
            tags.append(tag)
    return tags


async def _fetch_gitlab_releases(project: str, host: str = "gitlab.com") -> List[str]:
    """Release tag_names for a GitLab project (path or numeric id), via the
    anonymous Releases API. The project path is URL-encoded whole (nested
    groups become %2F)."""
    pid = quote(project, safe="")
    url = f"https://{host}/api/v4/projects/{pid}/releases?per_page=50"
    async with httpx.AsyncClient(
        timeout=_HTTP_TIMEOUT_S, follow_redirects=True
    ) as cx:
        r = await cx.get(url)
        r.raise_for_status()
        data = r.json()
    if not isinstance(data, list):
        return []
    return [d["tag_name"] for d in data if isinstance(d, dict) and d.get("tag_name")]


async def _fetch_forgejo_releases(host: str, repo: str) -> List[str]:
    """Release tag_names for a Forgejo/Gitea repo (owner/name) via the
    anonymous /api/v1 Releases endpoint (codeberg.org, self-hosted)."""
    url = f"https://{host}/api/v1/repos/{repo}/releases?limit=50"
    async with httpx.AsyncClient(
        timeout=_HTTP_TIMEOUT_S, follow_redirects=True
    ) as cx:
        r = await cx.get(url)
        r.raise_for_status()
        data = r.json()
    if not isinstance(data, list):
        return []
    return [d["tag_name"] for d in data if isinstance(d, dict) and d.get("tag_name")]


# ─── Strategy implementations ─────────────────────────────────────────


async def _tags_to_result(
    fetch_coro,
    parsed: Dict[str, str],
    params: Dict[str, Any],
    *,
    source_repo: Optional[str] = None,
    fetch_advisories: bool = False,
) -> StrategyResult:
    """Shared body for every tag-list strategy: await the fetch (mapping
    httpx errors to a note exactly like _fetch_latest does), pick the
    latest under the descriptor's filters, and optionally pull GitHub
    advisories for the resolved source repo."""
    try:
        tags = await fetch_coro
    except httpx.HTTPStatusError as e:
        return StrategyResult(note=f"registry returned HTTP {e.response.status_code}",
                              source_repo=source_repo)
    except httpx.HTTPError as e:
        return StrategyResult(note=f"network error: {type(e).__name__}",
                              source_repo=source_repo)
    except Exception as e:  # noqa: BLE001
        return StrategyResult(note=f"lookup failed: {type(e).__name__}",
                              source_repo=source_repo)
    if not tags:
        return StrategyResult(note="no tags returned", source_repo=source_repo)
    latest = _pick_with_params(tags, parsed, params)
    note = None if latest is not None else "no comparable version tags"
    advisories: List[Dict[str, Any]] = []
    if fetch_advisories and source_repo and latest is not None:
        advisories = await _fetch_ghsa(source_repo)
    return StrategyResult(latest=latest, note=note,
                          source_repo=source_repo, advisories=advisories)


async def _strategy_image(parsed: Dict[str, str], params: Dict[str, Any]) -> StrategyResult:
    """The default. Byte-for-byte the pre-existing resolution path: host-
    dispatch tag lookup, ghcr->GitHub-Releases fallback, GitHub advisories
    for ghcr images. Apps with no descriptor land here and cannot drift."""
    registry, repo = parsed["registry"], parsed["repo"]
    current_tag, digest = parsed["tag"], parsed.get("digest", "")
    latest, note = await _fetch_latest(registry, repo, current_tag, digest)
    source_repo: Optional[str] = None
    if (
        latest is None
        and registry == "ghcr.io"
        and current_tag
        and not _is_floating(current_tag)
    ):
        fb_latest, fb_repo = await _ghcr_github_release_fallback(repo, current_tag)
        if fb_latest:
            latest, note, source_repo = fb_latest, None, fb_repo
    advisories: List[Dict[str, Any]] = []
    adv_repo = source_repo or repo
    if registry == "ghcr.io" and adv_repo:
        advisories = await _fetch_ghsa(adv_repo)
    return StrategyResult(latest=latest, note=note,
                          source_repo=source_repo, advisories=advisories)


def _strategy_repo(parsed: Dict[str, str], params: Dict[str, Any]) -> str:
    """Repo/project for a strategy: the explicit `repo` param, else the
    parsed image repo (so e.g. `strategy=docker-hub` with no repo just
    re-resolves the image's own Hub repo)."""
    return (params.get("repo") or "").strip() or parsed.get("repo", "") or ""


async def _strategy_github_releases(parsed, params) -> StrategyResult:
    repo = (params.get("repo") or "").strip()
    if not repo:
        return StrategyResult(note="github-releases strategy needs `repo`")
    return await _tags_to_result(_fetch_github_release_tags(repo), parsed, params,
                                 source_repo=repo, fetch_advisories=True)


async def _strategy_github_tags(parsed, params) -> StrategyResult:
    repo = (params.get("repo") or "").strip()
    if not repo:
        return StrategyResult(note="github-tags strategy needs `repo`")
    return await _tags_to_result(_fetch_github_tags(repo), parsed, params,
                                 source_repo=repo, fetch_advisories=True)


async def _strategy_docker_hub(parsed, params) -> StrategyResult:
    repo = _strategy_repo(parsed, params)
    if not repo:
        return StrategyResult(note="docker-hub strategy needs `repo`")
    if "/" not in repo:
        repo = f"library/{repo}"
    return await _tags_to_result(
        _fetch_docker_hub_tags(repo, "docker.io", _anchor(parsed, params)),
        parsed, params)


async def _strategy_ghcr(parsed, params) -> StrategyResult:
    repo = _strategy_repo(parsed, params)
    if not repo:
        return StrategyResult(note="ghcr strategy needs `repo`")
    return await _tags_to_result(_fetch_ghcr_tags(repo, "ghcr.io"), parsed, params)


async def _strategy_oci_v2(parsed, params) -> StrategyResult:
    registry = (params.get("registry") or parsed.get("registry") or "").strip()
    repo = _strategy_repo(parsed, params)
    if not registry or not repo:
        return StrategyResult(note="oci-v2 strategy needs `registry` + `repo`")
    return await _tags_to_result(_fetch_oci_v2_tags(repo, registry), parsed, params)


async def _strategy_gitlab(parsed, params) -> StrategyResult:
    repo = (params.get("repo") or "").strip()
    host = (params.get("registry") or "gitlab.com").strip()
    if not repo:
        return StrategyResult(note="gitlab strategy needs a project `repo`")
    return await _tags_to_result(_fetch_gitlab_releases(repo, host), parsed, params)


async def _strategy_forgejo(parsed, params) -> StrategyResult:
    repo = (params.get("repo") or "").strip()
    host = (params.get("registry") or parsed.get("registry") or "").strip()
    if not repo or not host:
        return StrategyResult(note="forgejo/gitea strategy needs `registry` host + `repo`")
    return await _tags_to_result(_fetch_forgejo_releases(host, repo), parsed, params)


async def _strategy_nixpkgs(parsed, params) -> StrategyResult:
    """Host apps whose CURRENT version is the nixpkgs/flake build version
    (supplied as `current-version` in the descriptor and surfaced by
    _build_payload). LATEST comes from the declared upstream repo's GitHub
    Releases, then tags as a fallback."""
    repo = (params.get("repo") or "").strip()
    if not repo:
        return StrategyResult(note="tracked via nixpkgs (no upstream `repo` declared)")
    res = await _tags_to_result(_fetch_github_release_tags(repo), parsed, params,
                                source_repo=repo, fetch_advisories=True)
    if res.latest is None and not (res.note or "").startswith(("registry", "network")):
        alt = await _tags_to_result(_fetch_github_tags(repo), parsed, params,
                                    source_repo=repo)
        if alt.latest is not None:
            return alt
    return res


async def _strategy_url_regex(parsed, params) -> StrategyResult:
    """Generic escape hatch: GET an arbitrary page/endpoint and extract the
    version with a regex (first capture group, else whole match)."""
    url = (params.get("url") or "").strip()
    rx_src = (params.get("regex") or "").strip()
    if not url or not rx_src:
        return StrategyResult(note="url-regex strategy needs `url` + `regex`")
    try:
        async with httpx.AsyncClient(
            timeout=_HTTP_TIMEOUT_S, follow_redirects=True
        ) as cx:
            r = await cx.get(url)
            r.raise_for_status()
            body = r.text
    except httpx.HTTPError as e:
        return StrategyResult(note=f"network error: {type(e).__name__}")
    try:
        m = re.search(rx_src, body)
    except re.error:
        return StrategyResult(note="url-regex: invalid regex")
    if not m:
        return StrategyResult(note="url-regex: no match")
    latest = (m.group(1) if m.groups() else m.group(0)).strip()
    return StrategyResult(latest=latest or None,
                          note=None if latest else "url-regex: empty match")


async def _strategy_command(parsed, params) -> StrategyResult:
    """The most general escape hatch: run an app-declared script and take
    its stdout as the latest version. SECURITY: the command must be an
    eval-time /nix/store path declared in the app's own module (reviewed,
    immutable, content-addressed) — never runtime/user input. We refuse
    anything that isn't a store path so an API-supplied descriptor can't
    smuggle in an arbitrary command."""
    cmd = params.get("command") or ""
    if not cmd:
        return StrategyResult(note="command strategy needs a `command`")
    if not (isinstance(cmd, str) and cmd.startswith("/nix/store/")):
        return StrategyResult(note="command must be a /nix/store path")
    import subprocess
    try:
        proc = await asyncio.to_thread(
            subprocess.run, [cmd], capture_output=True, text=True, timeout=15
        )
    except subprocess.TimeoutExpired:
        return StrategyResult(note="version command timed out")
    except Exception as e:  # noqa: BLE001
        return StrategyResult(note=f"version command failed: {type(e).__name__}")
    if proc.returncode != 0:
        return StrategyResult(note=f"version command exited {proc.returncode}")
    out = (proc.stdout or "").strip()
    latest = out.splitlines()[0].strip() if out else ""
    return StrategyResult(latest=latest or None,
                          note=None if latest else "version command produced no output")


async def _strategy_none(parsed, params) -> StrategyResult:
    return StrategyResult(note="version tracking disabled for this app")


# name -> coroutine. An app's descriptor selects one; default is "image".
STRATEGIES: Dict[str, Any] = {
    "image": _strategy_image,
    "github-releases": _strategy_github_releases,
    "github-tags": _strategy_github_tags,
    "docker-hub": _strategy_docker_hub,
    "ghcr": _strategy_ghcr,
    "oci-v2": _strategy_oci_v2,
    "gitlab": _strategy_gitlab,
    "forgejo": _strategy_forgejo,
    "gitea": _strategy_forgejo,
    "nixpkgs": _strategy_nixpkgs,
    "url-regex": _strategy_url_regex,
    "command": _strategy_command,
    "none": _strategy_none,
}


async def _resolve_version(
    descriptor: Optional[Dict[str, Any]], parsed: Dict[str, str]
) -> StrategyResult:
    strategy = (descriptor or {}).get("strategy") or "image"
    params = (descriptor or {}).get("params") or {}
    fn = STRATEGIES.get(strategy)
    if fn is None:
        return StrategyResult(note=f"unknown version-tracking strategy: {strategy}")
    return await fn(parsed, params)


def _descriptor_for(
    app: Optional[str], name: str, metadata: Dict[str, Dict[str, Any]]
) -> Dict[str, Any]:
    """Resolve a catalog row's version-tracking descriptor from the
    label-keyed service metadata, using the same `app or name` key fallback
    _build_payload already uses for project_name (so a single-container
    app, where the container name equals its label, resolves cleanly; a
    multi-container app's non-primary sidecars miss and fall back to the
    default image strategy — see the keying note in the agent docs)."""
    meta = metadata.get(app or "") or metadata.get(name) or {}
    vt = meta.get("version-tracking") or {}
    return {"strategy": (vt.get("strategy") or "image"), "params": vt}


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


def _read_all_app_images() -> List[Dict[str, str]]:
    """Read the source-scanned [{app, image}] catalog. Returns [] when
    the artifact is missing (older deploy that predates this feature) —
    the resolver then falls back to the enabled-only container catalog,
    so the page never regresses to empty."""
    if not ALL_APP_IMAGES.exists():
        return []
    try:
        data = json.loads(ALL_APP_IMAGES.read_text())
        if isinstance(data, list):
            return [
                e for e in data
                if isinstance(e, dict) and e.get("app") and e.get("image")
            ]
    except (json.JSONDecodeError, OSError) as e:
        logger.warning("all-app-images catalog unreadable: %s", e)
    return []


def _read_host_apps() -> List[Dict[str, Any]]:
    """Read the non-container host-app catalog. Returns [] when the
    artifact is missing (older deploy) so the page never regresses."""
    if not HOST_APPS.exists():
        return []
    try:
        data = json.loads(HOST_APPS.read_text())
        if isinstance(data, list):
            return [
                e for e in data
                if isinstance(e, dict) and e.get("label")
            ]
    except (json.JSONDecodeError, OSError) as e:
        logger.warning("host-apps catalog unreadable: %s", e)
    return []


# ─── Merged catalog ───────────────────────────────────────────────────


def _source_index() -> Tuple[Dict[str, set], Dict[Tuple[str, str], str]]:
    """Two views over the source-tree image scan:
      * repo -> {apps/<dir>, ...} that pin it (ambiguous for shared base
        images like library/redis);
      * (app, repo) -> the SOURCE-pinned image string."""
    apps_by_repo: Dict[str, set] = {}
    image_by_app_repo: Dict[Tuple[str, str], str] = {}
    for e in _read_all_app_images():
        p = _parse_image(e["image"])
        if not (p and p.get("repo")):
            continue
        repo_key = f"{p['registry']}/{p['repo']}"
        apps_by_repo.setdefault(repo_key, set()).add(e["app"])
        image_by_app_repo[(e["app"], repo_key)] = e["image"]
    return apps_by_repo, image_by_app_repo


def _collapse_instance_rows(
    rows: List[Dict[str, Any]], metadata: Dict[str, Dict[str, Any]]
) -> Tuple[List[Dict[str, Any]], set]:
    """Collapse multiple enabled containers of ONE source pin into a
    single row. Two shapes produce duplicate rows otherwise:

      * per-instance apps — minecraft runs one container per instance,
        all from the single `version` binding (an instance's image-tag
        override is per-instance CONFIG, owned by the App Configuration
        page, not a second source pin to track);
      * blue/green colour pairs — oauth2-proxy-blue/-green share one
        image.

    Grouping key: the apps/<dir> the row's repo is pinned in — but only
    when that repo maps to exactly ONE source app. A shared base image
    (library/redis pinned by nextcloud AND immich) is ambiguous, so
    those sidecar rows stay per-container. The merged row tracks the
    SOURCE image (the bumpable pin), not any instance override."""
    apps_by_repo, image_by_app_repo = _source_index()

    groups: Dict[Tuple[str, str], List[Dict[str, Any]]] = {}
    for row in rows:
        p = _parse_image(row["image"]) or {}
        repo_key = f"{p.get('registry', '')}/{p.get('repo', '')}" if p.get("repo") else ""
        apps = apps_by_repo.get(repo_key) or set()
        if len(apps) == 1:
            groups.setdefault((next(iter(apps)), repo_key), []).append(row)

    merged_away: set = set()
    merged_rows: List[Dict[str, Any]] = []
    taken_names = {r["name"] for r in rows}
    for (app, repo_key), members in groups.items():
        if len(members) < 2:
            continue
        member_names = sorted(m["name"] for m in members)
        merged_away.update(member_names)
        # Name: the app dir, unless a container OUTSIDE the group already
        # uses it (zitadel's own container vs its oauth2-proxy pair) —
        # then the repo basename.
        name = app
        if name in (taken_names - set(member_names)):
            name = repo_key.rsplit("/", 1)[-1]
        # Descriptor: the first NON-default declared one wins — a member's
        # aliased metadata (oauth2-proxy-blue -> the oauth2proxy entry's
        # github-releases descriptor) over an app label that only carries
        # the default image strategy.
        descriptor = {"strategy": "image", "params": {}}
        for cand in [name, app, *member_names]:
            d = _descriptor_for(None, cand, metadata)
            if d["strategy"] != "image":
                descriptor = d
                break
        merged_rows.append({
            "key": name, "name": name,
            "image": image_by_app_repo.get((app, repo_key)) or members[0]["image"],
            "enabled": True, "app": app,
            "descriptor": descriptor,
            "external": bool(members[0].get("external")),
            "members": member_names,
        })

    kept = [r for r in rows if r["name"] not in merged_away]
    kept.extend(merged_rows)
    return kept, {r["key"] for r in kept}


def _merged_catalog() -> List[Dict[str, Any]]:
    """Unify the two eval-time catalogs into one list of rows to check.

    Each entry: {key, name, image, enabled, app}.
      * key   — stable, unique id used to key the upstream cache.
      * name  — what the UI shows as the container/row name.
      * app   — apps/<app>/ dir name (None for enabled containers,
                whose project metadata is keyed on the container name
                exactly as before).
      * enabled — True for a currently-deployed container, False for an
                  image pin that exists in source but isn't running.

    Enabled containers come from CONTAINER_CATALOG and are authoritative
    (exact names + the actually-deployed image). Every source image that
    isn't already covered by an enabled container — deduped by image
    string, so an app's redis/postgres sidecars shared with an enabled
    app don't double up — is appended as a disabled row. Finally,
    non-container HOST apps that declared a version-tracking strategy are
    appended (they have no image, so they appear nowhere else).

    Each row also carries a `descriptor` ({strategy, params}) resolved from
    the app's version-tracking metadata; rows with no descriptor default to
    the `image` strategy = the pre-existing behaviour."""
    enabled = _read_container_catalog()
    enabled_images = {e["image"] for e in enabled}
    metadata = _read_service_metadata()

    out: List[Dict[str, Any]] = []
    seen_keys: set = set()
    for e in enabled:
        out.append({
            "key": e["name"], "name": e["name"], "image": e["image"],
            "enabled": True, "app": None,
            "descriptor": _descriptor_for(None, e["name"], metadata),
            # Declared by an external module (plugin flake), not this
            # repo's tree — upgrade-apps.py can never bump its pin, so
            # the UI hides Update and the pending overlay skips it.
            "external": bool(e.get("external")),
        })
        seen_keys.add(e["name"])

    out, seen_keys = _collapse_instance_rows(out, metadata)

    for entry in _read_all_app_images():
        image = entry["image"]
        app = entry["app"]
        if image in enabled_images:
            continue
        # Derive a unique, stable key/name. The app dir name is the
        # natural choice; when an app contributes several images (e.g.
        # netbird's management/signal/relay/dashboard) or collides with
        # an enabled container name, disambiguate with the image's repo
        # basename, then a counter.
        key = app
        if key in seen_keys:
            repo_seg = image.rsplit("/", 1)[-1].split("@", 1)[0].split(":", 1)[0]
            # Avoid doubling when the repo basename already carries the
            # app name (nextcloud + nextcloud-appapi-harp ->
            # nextcloud-appapi-harp, not nextcloud-nextcloud-appapi-harp).
            key = repo_seg if repo_seg.startswith(app) else f"{app}-{repo_seg}"
            base_key = key
            n = 2
            while key in seen_keys:
                key = f"{base_key}-{n}"
                n += 1
        seen_keys.add(key)
        out.append({
            "key": key, "name": key, "image": image,
            "enabled": False, "app": app,
            "descriptor": _descriptor_for(app, key, metadata),
        })

    # Host apps (no image): each carries its own descriptor + the
    # eval-time current-version, so the resolver can show a real
    # current/latest for a service that ships no OCI image.
    for h in _read_host_apps():
        label = h["label"]
        if label in seen_keys:
            continue
        seen_keys.add(label)
        vt = h.get("version-tracking") or {}
        out.append({
            "key": label, "name": label, "image": "",
            "enabled": bool(h.get("enabled", True)), "app": label,
            "descriptor": {"strategy": (vt.get("strategy") or "none"), "params": vt},
            "host": True,
        })
    return out


# ─── Refresh ──────────────────────────────────────────────────────────

# Coalesce concurrent refreshes — the daily timer and an admin
# clicking Refresh shouldn't double up. The lock is process-local,
# which is fine: only this process (and the oneshot timer, which
# uses the same module) writes the cache.
_refresh_lock = asyncio.Lock()


async def refresh_all() -> Dict[str, Dict[str, Any]]:
    """Refresh upstream tags for every entry in the merged catalog —
    enabled containers AND disabled-app image pins. Returns the freshly-
    written cache. Drops cache entries for images no longer present
    (rule 11 — tolerate format drift / removal silently)."""
    async with _refresh_lock:
        catalog = _merged_catalog()
        # Previous cache is the last-known-good source: a single transient
        # lookup blip must not blank a value that resolved fine before and
        # freeze it in the once-daily cache (see the preservation block below).
        prev = _read_cache()
        cache: Dict[str, Dict[str, Any]] = {}
        now = int(time.time())
        for entry in catalog:
            key = entry["key"]
            descriptor = entry.get("descriptor") or {"strategy": "image", "params": {}}
            strategy = descriptor.get("strategy") or "image"
            parsed = _parse_image(entry["image"])
            if parsed is None:
                # Only the default image strategy genuinely needs a
                # parseable image; every other strategy resolves from its
                # descriptor (a host app has image="" by design).
                if strategy == "image":
                    cache[key] = {
                        "latest_tag": None,
                        "note": "image string unparseable",
                        "last_checked": now,
                        "strategy": strategy,
                    }
                    continue
                parsed = {"registry": "", "repo": "", "tag": "", "digest": ""}

            # The chosen strategy does the registry/GitHub/command lookup
            # and (for the image + GitHub strategies) the source-repo +
            # advisory resolution that _build_payload reuses for links.
            res = await _resolve_version(descriptor, parsed)
            new_entry: Dict[str, Any] = {
                "latest_tag": res.latest,
                "note": res.note,
                "last_checked": now,
                "advisories": res.advisories,
                "source_repo": res.source_repo,
                "strategy": strategy,
            }
            # Last-known-good preservation. A transient failure (the flaky
            # ghcr label dance in _ghcr_source_repo, a throttled GitHub atom
            # feed, a network blip) returns latest=None; writing that null
            # would erase a value that resolved fine yesterday and leave the
            # row "unknown" until the next daily refresh (often longer, since
            # the same blip recurs). Instead keep the prior good value, mark
            # it stale, and PRESERVE the old last_checked so the displayed
            # timestamp honestly ages until a real lookup succeeds again.
            #
            # Guards:
            #   * only when the prior entry actually had a latest_tag, and
            #   * only when its strategy matches — so we never carry a value
            #     across a strategy change (e.g. an app that just gained a
            #     version-tracking descriptor: image -> github-releases).
            # No time bound is applied: a removed app drops out of `catalog`
            # (so its entry disappears naturally), and for a still-deployed
            # app the aging last_checked + `stale` flag are the honest signal.
            if res.latest is None:
                old = prev.get(key) or {}
                if (
                    old.get("latest_tag") is not None
                    and old.get("strategy") == strategy
                ):
                    new_entry.update(
                        latest_tag=old["latest_tag"],
                        source_repo=old.get("source_repo"),
                        advisories=old.get("advisories") or [],
                        last_checked=old.get("last_checked", now),
                        stale=True,
                        note=(
                            f"last lookup failed ({res.note}); "
                            "showing last known good"
                        ),
                    )
            cache[key] = new_entry
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


# upgrade-apps.py skips every pin in apps/zitadel/default.nix unless
# --include-zitadel: a bad identity-core bump (Zitadel, its login UI, OR
# the oauth2-proxy gate — all pinned in that file) can take down every
# SSO login including the admin UI itself. Mirror that guard here so the
# page never offers a one-click button the script will refuse.
_SSO_GUARDED_APP_DIRS = frozenset({"zitadel"})


def _source_app_by_repo() -> Dict[str, str]:
    """Map 'registry/repo' -> apps/<dir> for every source-tree image pin.
    Lets an ENABLED container row (keyed by container name, no app field)
    be attributed to the app dir its pin lives in. Keyed by repo rather
    than the full image so a staged-but-unbuilt tag bump doesn't break
    the attribution."""
    out: Dict[str, str] = {}
    for e in _read_all_app_images():
        p = _parse_image(e["image"])
        if p and p.get("repo"):
            out[f"{p['registry']}/{p['repo']}"] = e["app"]
    return out


def _build_payload() -> List[Dict[str, Any]]:
    catalog = _merged_catalog()
    cache = _read_cache()
    metadata = _read_service_metadata()
    source_app_by_repo = _source_app_by_repo()

    out: List[Dict[str, Any]] = []
    for entry in catalog:
        key = entry["key"]
        name = entry["name"]
        image = entry["image"]
        enabled = entry.get("enabled", True)
        app = entry.get("app")
        parsed = _parse_image(image) or {
            "registry": "", "repo": "", "tag": "",
        }
        # Service metadata is keyed on the service label, which for a
        # disabled app equals its apps/<app>/ dir name; enabled rows
        # keep the original container-name lookup.
        # Display metadata: merged instance rows look up by their own
        # name then their member containers' aliases (so the collapsed
        # oauth2-proxy pair reads "OAuth2 Proxy", not its app dir's
        # label); plain rows keep the original app-then-name chain.
        members = entry.get("members") or []
        if members:
            meta = {}
            for cand in [name, *members, app or ""]:
                meta = metadata.get(cand or "") or {}
                if meta:
                    break
        else:
            meta = metadata.get(app or "") or metadata.get(name) or {}
        cache_entry = cache.get(key) or {}
        descriptor = entry.get("descriptor") or {"strategy": "image", "params": {}}
        strategy = descriptor.get("strategy") or "image"
        params = descriptor.get("params") or {}

        # Which apps/<dir> the row's pin lives in: disabled rows carry it,
        # enabled rows are attributed via the source-scan repo map.
        source_app = app or source_app_by_repo.get(
            f"{parsed.get('registry', '')}/{parsed.get('repo', '')}"
        )
        guarded = source_app in _SSO_GUARDED_APP_DIRS

        digest = parsed.get("digest") or ""
        latest = cache_entry.get("latest_tag")
        note = cache_entry.get("note")
        # No cache entry at all (a freshly added/renamed row between a
        # rebuild and the next refresh) previously rendered a bare
        # "Unknown" with no explanation — say what's actually going on.
        if not cache_entry:
            note = note or "not checked yet — refresh to fetch"
        last_checked = _iso_z(cache_entry.get("last_checked"))

        # `current` precedence: an explicit declared current-version (host
        # apps, digest pins) wins over the image tag; a short digest is the
        # last-resort label for a digest-only pin.
        current = (params.get("current-version") or "").strip() or parsed.get("tag") or None
        if not current and digest:
            short = digest.split(":", 1)[-1][:7]
            current = f"@{short}"

        # A declared current-version is shape-decoupled from the upstream
        # tags, so compare by semver tuple; otherwise the strict same-shape
        # comparison the image strategy relies on.
        loose = bool((params.get("current-version") or "").strip())
        if loose:
            # current >= latest: equal is up-to-date, and a current-version
            # AHEAD of the newest upstream release (a box on a nixpkgs build
            # past the last stable tag) is up-to-date too — not outdated.
            ct = _semver_tuple(current) if current else None
            lt = _semver_tuple(latest) if latest else None
            up_to_date = ct is not None and lt is not None and ct >= lt
        else:
            up_to_date = bool(current and latest and _same_release(current, latest))

        if strategy == "none":
            # Explicit opt-out — a deliberate "not tracked" choice, not a
            # lookup failure. Distinct from unknown so it doesn't alarm.
            status = "untracked"
        elif _is_local(parsed.get("tag", "")):
            status = "local"
        elif strategy == "image" and _is_floating(parsed.get("tag", "")) and not digest:
            # Operator opted out of version pinning — nothing to compare.
            # (Only meaningful for the image strategy; a host/declared-
            # version row has an empty tag by design, not a floating one.)
            status = "floating"
        elif latest is None:
            status = "unknown"
        elif up_to_date:
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

        # When the version was resolved via a ghcr.io -> GitHub Releases
        # fallback, refresh_all recorded the real source repo (e.g.
        # home-assistant/core for ghcr.io/home-assistant/home-assistant).
        # Prefer it for the changelog + advisory links so they don't 404
        # on the ghcr path; fall back to the parsed repo otherwise.
        source_repo = cache_entry.get("source_repo")
        link_repo = source_repo or parsed.get("repo") or ""

        # Release-notes URL — best-effort link to where the operator
        # can see what's in the latest version. Only attached when
        # there IS a latest version to point at; floating/local/
        # up-to-date rows don't need it. A resolved source_repo means the
        # latest came from GitHub Releases, so point the link at github.com
        # regardless of the (ghcr) registry.
        if status in ("outdated",) and latest:
            changelog_url = _changelog_url(
                "ghcr.io" if source_repo else (parsed.get("registry") or ""),
                link_repo,
                latest,
            )
        else:
            changelog_url = None

        # Security-advisory list URL — for ghcr.io images, the source
        # repo's advisory list on github.com. Surfaced regardless of
        # whether there are any open advisories, so the operator can
        # click through to confirm "still nothing here" if curious.
        advisories_url = None
        if parsed.get("registry") == "ghcr.io" and link_repo:
            advisories_url = (
                f"https://github.com/{link_repo}/security/advisories"
                "?state=published"
            )

        out.append({
            "name": name,
            "project_name": meta.get("project-name") or meta.get("name") or name,
            "image": image,
            "enabled": enabled,
            # Plugin-provided (or otherwise externally declared) app: its
            # version pin lives outside this repo, so the frontend hides
            # the per-row Update button and shows a Plugin pill instead.
            "external": bool(entry.get("external")),
            # One-click bumpable by upgrade-apps.py only when the version
            # IS an image pin in this repo: there must be an image, it
            # must not be external, and `current` must come from the pin
            # itself — a declared current-version means the version lives
            # elsewhere (vendored assets, a nixpkgs build) OR that the
            # tracked "latest" is a source tag that is NOT a valid image
            # tag (nzbget's GitHub v26.1 vs its LSIO version-v24.8 pin).
            # The SSO stack (every pin in apps/zitadel) is additionally
            # guarded against one-click lockouts — see _SSO_GUARDED_APP_DIRS.
            # A declared `update-command` overrides all of that except the
            # guard: the app ships its own updater and takes responsibility
            # (tag-scheme translation, re-vendoring, plugin-local edits).
            "guarded": guarded,
            "updatable": not guarded and (
                bool((params.get("update-command") or "").strip())
                or (bool(image) and not entry.get("external") and not loose)
            ),
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
            # True when refresh_all kept a previous good value because the
            # latest lookup transiently failed (see the last-known-good block
            # in refresh_all). `last_checked` then reflects the last SUCCESS,
            # not now — the frontend can surface this to explain the age.
            "stale": bool(cache_entry.get("stale")),
            # Set by _apply_pending_overlay() when the live source pin
            # differs from the deployed image (a staged-but-unbuilt bump).
            "pending": False,
            "pending_version": None,
            "deployed_version": None,
        })

    # Stable sort: outdated first (the actionable rows), then unknown
    # (lookup failed — operator may want to investigate), then floating /
    # local / untracked (all deliberate, informational), then up-to-date.
    # Within each bucket, enabled apps before disabled (a running app's
    # update is the more urgent), then by project name.
    status_order = {
        "outdated": 0,
        "unknown": 1,
        "floating": 2,
        "local": 3,
        "untracked": 4,
        "up-to-date": 5,
    }
    out.sort(key=lambda r: (
        status_order.get(r["status"], 5),
        0 if r.get("enabled", True) else 1,
        (r["project_name"] or "").lower(),
    ))
    return out


# ─── Pending-rebuild overlay ──────────────────────────────────────────
#
# "Update apps" (and the per-row Update button) rewrite the image-version
# pin in the LIVE checkout's default.nix. The deployed image — and the
# build-time catalogs this resolver reads — don't change until the box is
# rebuilt. So between bump and rebuild there's a staged-but-unbuilt state,
# which we surface the same way the rest of the admin UI flags undeployed
# config: an amber row. The signal is purely disk-derived (live source pin
# vs deployed image), so it survives a page reload and clears on rebuild —
# no ephemeral client state.


def _pins_from_entries(entries: List[Dict[str, str]]) -> Dict[str, str]:
    """'registry/repo' -> staged tag, but ONLY for repos pinned at a SINGLE
    distinct tag across the whole checkout.

    A base image pinned at DIVERGENT tags by different apps (library/redis:
    immich/nextcloud `8.8.0` vs nomad `7-alpine`) has no single staged value,
    and the rows are keyed by container name — so a repo-keyed comparison
    can't attribute one app's pin to a given row. A naive last-wins map would
    pick whichever app sorts last (nomad's `7-alpine`) and then flag EVERY
    sibling redis row (immich-redis, nextcloud-redis) pending-rebuild forever
    (a rebuild can't reconcile divergent pins). Dropping such ambiguous repos
    here makes _apply_pending_overlay skip them (`pins.get()` -> None). Mirrors
    the `len(apps) == 1` guard in _collapse_instance_rows."""
    by_repo: Dict[str, set] = {}
    for entry in entries:
        p = _parse_image(entry.get("image") or "")
        if p and p.get("repo") and p.get("tag"):
            by_repo.setdefault(f"{p['registry']}/{p['repo']}", set()).add(p["tag"])
    return {r: next(iter(t)) for r, t in by_repo.items() if len(t) == 1}


def _live_source_pins() -> Dict[str, str]:
    """Map 'registry/repo' -> the tag pinned in the LIVE local-base
    checkout's source (apps/ + services/). Empty unless an enabled LOCAL
    alternate base is configured — only then is there a writable,
    ahead-of-build source tree to compare against.

    Keyed by repo (not the full image): a freshly-bumped pin has a new
    tag, and we want to detect exactly that the same repo now resolves to
    a different tag than what's deployed. Repos pinned at divergent tags by
    several apps are dropped (see _pins_from_entries) — they can't be
    attributed to a container-keyed row, so a last-wins value there would be
    a permanent false pending."""
    try:
        from services.plugins import PluginsService
        base = PluginsService.get_base_override()
        if not base.get("enabled") or (base.get("type") or "") != "local":
            return {}
        local = base.get("localUrl") or ""
        if local.startswith("git+file://"):
            local = local[len("git+file://"):]
        local = local.strip()
        if not local:
            return {}
        from resolvers.app_source_index import scan_all_app_images
        root = Path(local)
        return _pins_from_entries(
            scan_all_app_images([root / "apps", root / "services"]))
    except Exception as e:  # noqa: BLE001
        logger.warning("live source-pin scan failed: %s", e)
        return {}


def _apply_pending_overlay(rows: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
    """Flag rows whose live source pin differs from the deployed image as
    pending-rebuild: show the staged version as `current`, recompute the
    status against it, and set `pending` so the UI can amber the row."""
    pins = _live_source_pins()
    if not pins:
        return rows
    for row in rows:
        # External (plugin-provided) rows are never bumped by this repo's
        # checkout; matching them by repo against the local pins produces
        # FALSE "pending rebuild" flags whenever a plugin shares a base
        # image (grampsweb-redis vs the repo's own redis pin).
        if row.get("external"):
            continue
        parsed = _parse_image(row.get("image") or "")
        if not parsed or not parsed.get("repo"):
            continue
        deployed_tag = parsed.get("tag")
        if not deployed_tag:
            continue
        staged = pins.get(f"{parsed['registry']}/{parsed['repo']}")
        if not staged or staged == deployed_tag:
            continue
        # Staged-but-unbuilt: the checkout pins a different tag than the
        # running image. Surface the staged version as current + amber.
        row["pending"] = True
        row["pending_version"] = staged
        row["deployed_version"] = deployed_tag
        row["current"] = staged
        latest = row.get("latest")
        if latest and _same_release(staged, latest):
            # Staged up to the latest — once built it'll be current.
            row["status"] = "up-to-date"
    return rows


# ─── Custom per-app updater ───────────────────────────────────────────


async def _run_custom_updater(
    updater: str, repo_root: Path, target: str, app_name: str,
    current: str = "",
) -> Dict[str, Any]:
    """Run an app-declared update-command against the writable checkout.

    Contract: `script <checkout-root> <target-version>`, cwd = checkout
    root, 300s budget (re-vendoring can be slow). The last non-empty
    stdout line is reported as the new value. SECURITY: like the
    `command` strategy, only an eval-time /nix/store path is accepted —
    the descriptor comes from the box's own build, never from the API."""
    import subprocess
    from fastapi import HTTPException

    if not updater.startswith("/nix/store/"):
        raise HTTPException(
            status_code=400,
            detail=f"{app_name}: update-command must be a /nix/store path.",
        )
    try:
        proc = await asyncio.to_thread(
            subprocess.run,
            [updater, str(repo_root), target],
            capture_output=True,
            text=True,
            timeout=300,
            cwd=str(repo_root),
        )
    except subprocess.TimeoutExpired:
        raise HTTPException(
            status_code=504,
            detail=f"{app_name}: update-command exceeded 300s.",
        )
    except Exception as e:  # noqa: BLE001
        raise HTTPException(
            status_code=500,
            detail=f"{app_name}: failed to spawn update-command: {e}",
        )

    stdout = (proc.stdout or "").strip()
    stderr = (proc.stderr or "").strip()
    new_value = stdout.splitlines()[-1].strip() if stdout else (target or "?")
    if proc.returncode != 0:
        return {
            "bumped": [],
            "skipped_zitadel": [],
            "warnings": [],
            "errors": [
                f"{app_name}: update-command exited "
                f"{proc.returncode}: {stderr or stdout or 'no output'}"
            ],
            "unmapped": [],
            "exit_code": proc.returncode,
        }
    return {
        "bumped": [{
            "app": app_name,
            "binding": "update-command",
            "current_value": current,
            "new_value": new_value,
        }],
        "skipped_zitadel": [],
        "warnings": [stderr] if stderr else [],
        "errors": [],
        "unmapped": [],
        # upgrade-apps.py convention: 2 = something was edited.
        "exit_code": 2,
    }


# ─── HTTP endpoints ───────────────────────────────────────────────────


@router.get("/versions")
async def get_app_versions() -> Dict[str, Any]:
    """Read-only merged view of the eval-time container catalog and the
    cached upstream-tag lookups, with a pending-rebuild overlay derived
    from the live checkout source. Always fast (no network)."""
    return {"apps": _apply_pending_overlay(_build_payload())}


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


@router.post("/versions/upgrade")
async def post_app_versions_upgrade(
    payload: Dict[str, Any] = Body(default={}),
) -> Dict[str, Any]:
    """Run scripts/upgrade-apps.py against the alternate-base local
    checkout and return its JSON summary.

    Body may carry `{"app": "<name>"}` to bump just one app (the row's
    container name / apps-dir / project name — the script's --app filter
    matches any of them); omit it to bump everything.

    Requires an alternate-base `local` repository to be configured —
    the upstream `/nix/store` tree the box would otherwise build from
    is read-only, so a bump has nowhere to land. The script's own
    safety guard (is_unsafe_bump) refuses cross-major / cross-flavour /
    downgrade picks; this endpoint is otherwise a thin wrapper.

    Run synchronously with a hard timeout because the script's
    bottleneck is its disk writes, not network — the registry lookups
    are already cached. A typical run on ~35 apps finishes in well
    under a second."""
    import subprocess
    import sys as _sys
    from fastapi import HTTPException

    app_filter = ""
    if isinstance(payload, dict) and isinstance(payload.get("app"), str):
        app_filter = payload["app"].strip()

    # Lazy import — keep the resolver's import chain clean for the
    # daily timer entrypoint that doesn't need developers/.
    from services.plugins import PluginsService

    base = PluginsService.get_base_override()
    if not base.get("enabled"):
        raise HTTPException(
            status_code=400,
            detail="Alternate HomeFree repository is not enabled. "
                   "Configure a local checkout on the Source Code page "
                   "before running Update apps.",
        )
    if (base.get("type") or "") != "local":
        raise HTTPException(
            status_code=400,
            detail="Update apps requires a LOCAL alternate base. "
                   "A remote URL points at a read-only tree.",
        )
    local_url = base.get("localUrl") or ""
    if local_url.startswith("git+file://"):
        local_url = local_url[len("git+file://"):]
    local_url = local_url.strip()
    if not local_url:
        raise HTTPException(
            status_code=400,
            detail="Alternate base is enabled but the local repository "
                   "path is empty.",
        )

    repo_root = Path(local_url)

    # Per-app CUSTOM updater: when the targeted row's version-tracking
    # descriptor declares an `update-command`, the app owns its update
    # (tag-scheme translation, asset re-vendoring, plugin-local edits) —
    # run that against the writable checkout instead of the generic pin
    # rewriter. Only the per-app path honours it; the bulk "Update apps"
    # run stays pins-only on purpose (a custom updater may be slow or
    # have side effects the operator should trigger row-by-row).
    if app_filter:
        row = next(
            (e for e in _merged_catalog() if e.get("name") == app_filter),
            None,
        )
        if row is not None:
            params = (row.get("descriptor") or {}).get("params", {})
            updater = (params.get("update-command") or "").strip()
            if updater:
                target = (
                    (_read_cache().get(row["key"]) or {}).get("latest_tag") or ""
                )
                parsed_row = _parse_image(row.get("image") or "") or {}
                current = (
                    (params.get("current-version") or "").strip()
                    or parsed_row.get("tag") or ""
                )
                return await _run_custom_updater(
                    updater, repo_root, target, app_filter, current
                )

    script = repo_root / "scripts" / "upgrade-apps.py"
    if not script.is_file():
        raise HTTPException(
            status_code=400,
            detail=f"upgrade-apps.py not found at {script}. "
                   "Is the alternate base actually a HomeFree checkout?",
        )

    # Invoke with the SAME interpreter the admin-api is running under so
    # we don't pay a nix-shell spin-up. The interpreter already has
    # httpx + fastapi (it's serving us right now).
    cmd = [_sys.executable, str(script),
           "--json", "--no-color",
           "--repo-root", str(repo_root)]
    if app_filter:
        cmd += ["--app", app_filter]
    try:
        proc = await asyncio.to_thread(
            subprocess.run,
            cmd,
            capture_output=True,
            text=True,
            timeout=120,
        )
    except subprocess.TimeoutExpired:
        raise HTTPException(
            status_code=504,
            detail="upgrade-apps.py exceeded 120s. The script normally "
                   "finishes in under a second — check the admin-api "
                   "journal for what stalled.",
        )
    except Exception as e:  # noqa: BLE001
        raise HTTPException(
            status_code=500,
            detail=f"Failed to spawn upgrade-apps.py: {e}",
        )

    # The script uses exit code 2 when at least one file was edited,
    # 0 when nothing was outdated, 1 when an error occurred. The JSON
    # body is on stdout in every case; treat 1 as a body-bearing error.
    stdout = (proc.stdout or "").strip()
    stderr = (proc.stderr or "").strip()
    if proc.returncode == 1 and not stdout:
        raise HTTPException(
            status_code=500,
            detail=f"upgrade-apps.py failed: {stderr or 'no output'}",
        )
    try:
        data = json.loads(stdout) if stdout else {}
    except json.JSONDecodeError as e:
        raise HTTPException(
            status_code=500,
            detail=f"upgrade-apps.py emitted unparseable JSON: {e}. "
                   f"stderr: {stderr[:500]}",
        )
    if not isinstance(data, dict):
        raise HTTPException(
            status_code=500,
            detail="upgrade-apps.py emitted non-object JSON.",
        )
    data.setdefault("bumped", [])
    data.setdefault("skipped_zitadel", [])
    data.setdefault("warnings", [])
    data.setdefault("errors", [])
    data.setdefault("unmapped", [])
    data["exit_code"] = proc.returncode
    return data
