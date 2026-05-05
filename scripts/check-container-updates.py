#!/usr/bin/env nix-shell
#! nix-shell -i python3 -p python3 skopeo

"""
Check podman/docker container images declared in homefree/services/*.nix
for newer versions on their respective registries.

Usage:
  ./scripts/check-container-updates.py                # report only
  ./scripts/check-container-updates.py --apply        # apply available updates interactively
  ./scripts/check-container-updates.py --diff         # preview rewrites
  ./scripts/check-container-updates.py --service jellyfin-podman
  ./scripts/check-container-updates.py --include-prerelease
  ./scripts/check-container-updates.py --major-only
  ./scripts/check-container-updates.py --no-cache
  ./scripts/check-container-updates.py --json

Per-binding overrides via a comment immediately above the version variable:
  # update-check: skip                 — silently ignore this binding
  # update-check: pin                  — never suggest updates; print warning
  # update-check: pin=<reason>         — same, with a documented reason
  # update-check: pin-major            — only suggest updates within current major
  # update-check: regex=<python regex> — restrict candidate tags to a pattern

Exit codes: 0 = no updates, 2 = updates found, 1 = error.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Optional


SCRIPT_DIR = Path(__file__).resolve().parent
CACHE_DIR = Path(os.environ.get("XDG_CACHE_HOME") or (Path.home() / ".cache")) / "check-container-updates"
CACHE_FILE = CACHE_DIR / "tags.json"
CACHE_TTL_SECONDS = 3600

# Set in main() once the repo root is resolved.
SERVICES_DIR: Path = Path()
REPO_ROOT: Path = Path()


def find_repo_root(cli_arg: Optional[str]) -> Path:
    """
    Resolve the homefree repo root containing `flake.nix` and `services/`.
    Needed because `nix run` puts the script in /nix/store, far from the
    services tree. Order: --repo-root, $HOMEFREE_REPO_ROOT, walk up from CWD,
    walk up from SCRIPT_DIR.
    """
    explicit = cli_arg or os.environ.get("HOMEFREE_REPO_ROOT")
    if explicit:
        p = Path(explicit).resolve()
        if (p / "flake.nix").is_file() and (p / "services").is_dir():
            return p
        raise RuntimeError(
            f"--repo-root / HOMEFREE_REPO_ROOT pointed at {p}, "
            "but no flake.nix + services/ there"
        )

    for start in (Path.cwd(), SCRIPT_DIR):
        cur = start.resolve()
        while True:
            if (cur / "flake.nix").is_file() and (cur / "services").is_dir():
                return cur
            if cur.parent == cur:
                break
            cur = cur.parent

    raise RuntimeError(
        "Could not find a flake.nix + services/ directory by walking up from "
        f"CWD ({Path.cwd()}) or script dir ({SCRIPT_DIR}). "
        "Pass --repo-root or set HOMEFREE_REPO_ROOT."
    )

PRERELEASE_KEYWORDS = (
    "rc", "beta", "alpha", "dev", "nightly", "pre", "snapshot",
    "unstable", "edge", "canary", "next", "preview",
)
FLOATING_TAGS = {"latest", "main", "master", "stable", "develop", "edge", "rolling"}

LET_BIND_RE = re.compile(r'^(\s+)([a-zA-Z][a-zA-Z0-9_-]*)\s*=\s*"([^"]*)"\s*;')
IMAGE_LINE_RE = re.compile(r'^(\s+)image\s*=\s*"([^"]+)"\s*;')
ATTR_OPEN_RE = re.compile(
    r'^(\s+)((?:[a-zA-Z][a-zA-Z0-9_-]*\.)*[a-zA-Z][a-zA-Z0-9_-]*)\s*=\s*'
    r'(?:if\s+.*?\s+then\s+)?\{'
)
INTERP_RE = re.compile(r'\$\{([a-zA-Z][a-zA-Z0-9_-]*)\}')
SHAPE_RE = re.compile(r'^(?P<v>v?)(?P<core>\d+(?:\.\d+){0,2})(?P<suffix>-[A-Za-z0-9._-]+)?$')
OVERRIDE_RE = re.compile(r'#\s*update-check:\s*(\S.*?)\s*$')
HEX_SHA_RE = re.compile(r'^[a-f0-9]{7,40}$')
ISO_DATE_RE = re.compile(r'^\d{8}$')
LET_TOKEN_RE = re.compile(r'\blet\b')
IN_TOKEN_RE = re.compile(r'\bin\b')

# Generic attribute-set keys whose name doesn't identify the actual container
# (e.g. listToAttrs uses `name = "..."; value = { image = ...; };`).
GENERIC_ATTR_KEYS = {"value"}


@dataclass
class Entry:
    file: Path
    container_key: str
    var_name: str
    var_line: int  # 0-indexed
    current_value: str
    registry: str
    repo: str
    current_tag: str
    image_template: str
    tag_prefix: str = ""  # literal text in template before ${var} in tag
    tag_suffix: str = ""  # literal text in template after ${var} in tag
    override: Optional[str] = None
    skip_reason: Optional[str] = None


@dataclass
class Result:
    entry: Entry
    latest_tag: Optional[str] = None
    new_value: Optional[str] = None
    status: str = ""  # "up-to-date", "UPDATE", "skipped", "error"
    detail: str = ""


# ---------------------------------------------------------------------------
# Phase 1: Parse
# ---------------------------------------------------------------------------

def mask_lines(lines: list[str]) -> list[str]:
    """
    Return a copy of `lines` where the contents of multi-line `''...''`
    strings and `/* ... */` block comments are replaced with spaces. Single-line
    `#` comments are kept (we need them to spot `# update-check:` directives).
    Quoted "..." strings are kept verbatim — we want to match them.
    """
    out: list[str] = []
    in_heredoc = False
    in_block = False
    for line in lines:
        buf: list[str] = []
        j = 0
        L = len(line)
        while j < L:
            if in_block:
                end = line.find("*/", j)
                if end < 0:
                    buf.append(" " * (L - j))
                    j = L
                else:
                    buf.append(" " * (end + 2 - j))
                    j = end + 2
                    in_block = False
            elif in_heredoc:
                end = line.find("''", j)
                if end < 0:
                    buf.append(" " * (L - j))
                    j = L
                else:
                    buf.append(" " * (end + 2 - j))
                    j = end + 2
                    in_heredoc = False
            else:
                next_block = line.find("/*", j)
                next_heredoc = line.find("''", j)
                cands = [(p, k) for p, k in ((next_block, "b"), (next_heredoc, "h")) if p >= 0]
                if not cands:
                    buf.append(line[j:])
                    j = L
                else:
                    cands.sort()
                    pos, kind = cands[0]
                    buf.append(line[j:pos])
                    if kind == "b":
                        in_block = True
                        buf.append("  ")
                    else:
                        in_heredoc = True
                        buf.append("  ")
                    j = pos + 2
        out.append("".join(buf))
    return out


def find_let_block(masked: list[str]) -> tuple[Optional[int], Optional[int]]:
    """
    Locate the top-level `let ... in` block by counting nested `let`/`in` tokens.
    Returns (let_line, in_line) or (None, None).
    """
    let_idx: Optional[int] = None
    for i, line in enumerate(masked):
        s = line.strip()
        if s == "let" or s.startswith("let "):
            let_idx = i
            break
    if let_idx is None:
        return None, None
    depth = 1
    for i in range(let_idx + 1, len(masked)):
        line = masked[i]
        # Count `let` and `in` tokens (word-boundary matched). Heredocs and
        # block comments have already been masked, so this won't match string
        # contents. Quoted "..." strings are still present but are unlikely
        # to contain bare "let" / "in" tokens in our codebase.
        depth += len(LET_TOKEN_RE.findall(line))
        ins = IN_TOKEN_RE.findall(line)
        for _ in ins:
            depth -= 1
            if depth == 0:
                return let_idx, i
    return let_idx, None


def resolve_recursive(text: str, bindings: dict[str, str], depth: int = 4) -> Optional[str]:
    """Substitute `${var}` references in `text`. Returns None if a referenced var is unknown."""
    seen = 0
    while seen < depth and "${" in text:
        new_text = text
        for ref in INTERP_RE.findall(text):
            if ref not in bindings:
                return None
            new_text = new_text.replace("${" + ref + "}", bindings[ref])
        if new_text == text:
            break
        text = new_text
        seen += 1
    return text


def parse_image_string(resolved: str) -> tuple[str, str, str]:
    """
    Split a resolved image string `registry/repo:tag` into (registry, repo, tag).
    Defaults to docker.io and the `library/` namespace when absent.
    """
    if "@" in resolved.split("/")[-1]:
        # digest pin like name@sha256:...
        before_at = resolved.split("@", 1)[0]
        # caller will see the @ and skip — here we still split off for context
        image_part, tag = before_at, ""
    elif ":" in resolved.split("/")[-1]:
        image_part, tag = resolved.rsplit(":", 1)
    else:
        image_part, tag = resolved, ""

    if "/" in image_part:
        prefix, _, rest = image_part.partition("/")
        if "." in prefix or ":" in prefix or prefix == "localhost":
            registry = prefix
            repo = rest
        else:
            registry = "docker.io"
            repo = image_part
    else:
        registry = "docker.io"
        repo = image_part

    if registry == "docker.io" and "/" not in repo:
        repo = "library/" + repo
    return registry, repo, tag


def parse_file(path: Path) -> list[Entry]:
    raw = path.read_text()
    lines = raw.split("\n")
    masked = mask_lines(lines)

    let_start, in_idx = find_let_block(masked)
    if let_start is None or in_idx is None:
        return []

    # Collect string let-bindings.
    let_bindings: dict[str, tuple[int, str]] = {}
    for i in range(let_start + 1, in_idx):
        m = LET_BIND_RE.match(masked[i])
        if m:
            _, name, value = m.groups()
            let_bindings[name] = (i, value)

    binding_values = {n: v for n, (_, v) in let_bindings.items()}

    entries: list[Entry] = []

    for i in range(in_idx, len(masked)):
        line = masked[i]
        raw_line = lines[i]

        # Skip lines that the user has clearly commented out.
        if raw_line.lstrip().startswith("#"):
            continue

        m = IMAGE_LINE_RE.match(line)
        if not m:
            continue
        img_indent_str, template = m.groups()
        img_indent = len(img_indent_str)

        # Find the enclosing container key by walking back to the nearest
        # `<path> = {` at a strictly smaller indent. The path may be dotted
        # (e.g. `virtualisation.oci-containers.containers.mongo = {`) — in
        # that case the segment after `containers` is the container key.
        # For listToAttrs-style (`name = ...; value = { image = ...; };`)
        # the enclosing key is `value`, so fall back to the file stem.
        container_key: Optional[str] = None
        for j in range(i - 1, in_idx, -1):
            am = ATTR_OPEN_RE.match(masked[j])
            if am:
                a_indent_str, a_path = am.groups()
                if len(a_indent_str) < img_indent:
                    parts = a_path.split(".")
                    if "containers" in parts:
                        idx = parts.index("containers")
                        if idx + 1 < len(parts):
                            container_key = parts[idx + 1]
                        else:
                            # Bare `... .containers = {` — walk further in to
                            # find the inner key (continue loop).
                            continue
                    else:
                        container_key = parts[-1]
                    break

        if container_key in GENERIC_ATTR_KEYS or container_key is None:
            container_key = f"{path.stem.removesuffix('-podman')} (dynamic)"

        # Resolve `${var}` interpolations.
        resolved = resolve_recursive(template, binding_values)
        if resolved is None:
            entries.append(_skip_entry(
                path, container_key, template,
                "unresolved variable",
            ))
            continue

        if resolved.startswith("???"):
            entries.append(_skip_entry(
                path, container_key, template,
                "placeholder registry",
            ))
            continue

        if "@sha256:" in resolved or "@" in resolved.rsplit("/", 1)[-1].split(":")[0]:
            # Catches name@sha256:... and name@digest forms.
            entries.append(_skip_entry(
                path, container_key, template,
                "digest pin",
            ))
            continue

        registry, repo, tag = parse_image_string(resolved)

        if not tag:
            entries.append(_skip_entry(
                path, container_key, template,
                "no tag",
            ))
            continue

        if tag in FLOATING_TAGS:
            entries.append(_skip_entry(
                path, container_key, template,
                f"floating tag :{tag}",
                registry=registry, repo=repo, current_tag=tag,
            ))
            continue

        # Identify which let-binding produced the tag and what literal text
        # surrounds the interpolation in the tag template.
        tag_template = template.rsplit(":", 1)[1] if ":" in template else ""
        tag_refs = INTERP_RE.findall(tag_template)
        if not tag_refs:
            entries.append(_skip_entry(
                path, container_key, template,
                "hardcoded tag",
                registry=registry, repo=repo, current_tag=tag,
            ))
            continue

        var_name = tag_refs[0]
        if var_name not in let_bindings:
            entries.append(_skip_entry(
                path, container_key, template,
                f"unresolved tag variable: {var_name}",
            ))
            continue
        var_line, var_value = let_bindings[var_name]

        placeholder = "${" + var_name + "}"
        before, _, after = tag_template.partition(placeholder)
        # If the variable's value itself contains other interpolations, the
        # before/after split is still useful but the value comparison is fragile.
        # In practice all our version-* bindings are plain strings.

        override = None
        if var_line > 0:
            prev = lines[var_line - 1]
            om = OVERRIDE_RE.search(prev)
            if om:
                override = om.group(1).strip()

        entry = Entry(
            file=path,
            container_key=container_key,
            var_name=var_name,
            var_line=var_line,
            current_value=var_value,
            registry=registry,
            repo=repo,
            current_tag=tag,
            image_template=template,
            tag_prefix=before,
            tag_suffix=after,
            override=override,
        )

        if override == "skip":
            entry.skip_reason = "user-skip directive"

        entries.append(entry)

    return entries


def parse_override(override: Optional[str]) -> tuple[str, str]:
    """Return (kind, arg) for an override string. kind is '' if no override."""
    if not override:
        return "", ""
    if override == "skip":
        return "skip", ""
    if override == "pin":
        return "pin", ""
    if override.startswith("pin="):
        return "pin", override[len("pin="):].strip()
    if override == "pin-major":
        return "pin-major", ""
    if override.startswith("regex="):
        return "regex", override[len("regex="):]
    return "unknown", override


def _skip_entry(
    path: Path,
    container_key: str,
    template: str,
    reason: str,
    *,
    registry: str = "",
    repo: str = "",
    current_tag: str = "",
) -> Entry:
    return Entry(
        file=path,
        container_key=container_key,
        var_name="",
        var_line=-1,
        current_value="",
        registry=registry,
        repo=repo,
        current_tag=current_tag,
        image_template=template,
        skip_reason=reason,
    )


# ---------------------------------------------------------------------------
# Phase 2: Query
# ---------------------------------------------------------------------------

def load_cache() -> dict:
    if not CACHE_FILE.is_file():
        return {}
    try:
        data = json.loads(CACHE_FILE.read_text())
    except (json.JSONDecodeError, OSError):
        return {}
    return data if isinstance(data, dict) else {}


def save_cache(cache: dict) -> None:
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    fd, tmp_path = tempfile.mkstemp(dir=str(CACHE_DIR), prefix="tags-", suffix=".json")
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(cache, f, indent=2, sort_keys=True)
        os.replace(tmp_path, CACHE_FILE)
    except Exception:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise


def skopeo_list_tags(registry: str, repo: str) -> tuple[list[str], Optional[str]]:
    """Return (tags, error_reason). One of the two is empty."""
    ref = f"docker://{registry}/{repo}"
    try:
        proc = subprocess.run(
            ["skopeo", "list-tags", ref],
            capture_output=True, text=True, timeout=60,
        )
    except FileNotFoundError:
        return [], "skopeo not on PATH"
    except subprocess.TimeoutExpired:
        return [], "skopeo timed out"
    if proc.returncode != 0:
        msg = proc.stderr.strip().splitlines()[-1] if proc.stderr.strip() else f"exit {proc.returncode}"
        return [], msg
    try:
        data = json.loads(proc.stdout)
    except json.JSONDecodeError as e:
        return [], f"bad json: {e}"
    tags = data.get("Tags") or []
    return list(tags), None


def query_all(
    repos: list[tuple[str, str]],
    *,
    use_cache: bool,
    workers: int = 8,
) -> dict[tuple[str, str], tuple[list[str], Optional[str]]]:
    cache = load_cache() if use_cache else {}
    now = time.time()
    results: dict[tuple[str, str], tuple[list[str], Optional[str]]] = {}
    needs_query: list[tuple[str, str]] = []

    for key in repos:
        cache_key = f"{key[0]}/{key[1]}"
        entry = cache.get(cache_key)
        if (
            use_cache and isinstance(entry, dict)
            and "tags" in entry and "ts" in entry
            and (now - entry["ts"]) < CACHE_TTL_SECONDS
        ):
            results[key] = (list(entry["tags"]), None)
        else:
            needs_query.append(key)

    if needs_query:
        with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as pool:
            future_to_key = {pool.submit(skopeo_list_tags, r, p): (r, p) for r, p in needs_query}
            for fut in concurrent.futures.as_completed(future_to_key):
                key = future_to_key[fut]
                tags, err = fut.result()
                results[key] = (tags, err)
                if err is None:
                    cache[f"{key[0]}/{key[1]}"] = {"ts": now, "tags": tags}

        if use_cache:
            try:
                save_cache(cache)
            except OSError:
                pass

    return results


# ---------------------------------------------------------------------------
# Phase 3: Compare
# ---------------------------------------------------------------------------

def parse_tag_shape(tag: str):
    """Return (v_prefix: bool, core_tuple: tuple[int,...], suffix: str) or None."""
    m = SHAPE_RE.match(tag)
    if not m:
        return None
    core = tuple(int(x) for x in m.group("core").split("."))
    suffix = m.group("suffix") or ""
    return (bool(m.group("v")), core, suffix)


def looks_prerelease(tag: str) -> bool:
    if HEX_SHA_RE.match(tag) or ISO_DATE_RE.match(tag):
        return True
    low = tag.lower()
    if "-sha-" in low or "-commit-" in low:
        return True
    # Match keyword as token: preceded by start, dot, dash, plus, underscore.
    for kw in PRERELEASE_KEYWORDS:
        if re.search(rf"(^|[.\-+_]){kw}([.\-+_0-9]|$)", low):
            return True
    return False


def is_prerelease_suffix(suffix: str) -> bool:
    """Does this tag suffix (e.g. '-rc2', '-beta.1') look like a pre-release?"""
    if not suffix or not suffix.startswith("-"):
        return False
    body = suffix[1:].lower()
    for kw in PRERELEASE_KEYWORDS:
        if body == kw or body.startswith(kw + ".") or body.startswith(kw + "-"):
            return True
        if body.startswith(kw) and len(body) > len(kw) and body[len(kw)].isdigit():
            return True
    return False


def pick_latest(
    entry: Entry,
    tags: list[str],
    *,
    include_prerelease: bool,
    major_only: bool,
) -> tuple[Optional[str], str]:
    """
    Return (latest_tag, detail_message). `latest_tag` is the highest candidate
    that's strictly newer than the current pin, or None if up-to-date.
    """
    cur_shape = parse_tag_shape(entry.current_tag)
    if cur_shape is None:
        # Try the override regex as a last resort.
        if entry.override and entry.override.startswith("regex="):
            pat = re.compile(entry.override[len("regex="):])
            candidates_raw = [t for t in tags if pat.fullmatch(t) and t != entry.current_tag]
            if not candidates_raw:
                return None, "no candidates from override regex"
            # No semver to compare — just pick the alphabetically max-after-current
            sorted_c = sorted(candidates_raw)
            highest = sorted_c[-1]
            if highest > entry.current_tag:
                return highest, "matched via override regex"
            return None, "up-to-date (override regex)"
        return None, "unrecognized version shape"

    cur_v, cur_core, cur_suffix = cur_shape
    cur_precision = len(cur_core)
    cur_is_prerelease = is_prerelease_suffix(cur_suffix)

    kind, arg = parse_override(entry.override)
    enforce_major = major_only or kind == "pin-major"

    extra_filter = None
    if kind == "regex":
        try:
            extra_filter = re.compile(arg)
        except re.error as e:
            return None, f"invalid override regex: {e}"

    # (core, stable_rank, suffix, tag) — sort gives stable > pre-release at same core.
    candidates: list[tuple[tuple[int, ...], int, str, str]] = []
    for t in tags:
        if t == entry.current_tag:
            continue
        if extra_filter and not extra_filter.fullmatch(t):
            continue
        shape = parse_tag_shape(t)
        if shape is None:
            continue
        v, core, suffix = shape
        if v != cur_v:
            continue
        if len(core) != cur_precision:
            continue

        if cur_is_prerelease:
            # User is on a pre-release tag — let them upgrade to either a
            # stable release at the same shape, or another pre-release.
            if suffix and not is_prerelease_suffix(suffix):
                continue
        else:
            # User is on a stable variant (or no suffix) — require an exact
            # suffix match, and drop pre-release tags unless asked.
            if suffix != cur_suffix:
                continue
            if not include_prerelease and looks_prerelease(t):
                continue

        if enforce_major and core[0] != cur_core[0]:
            continue
        stable_rank = 0 if is_prerelease_suffix(suffix) else 1
        candidates.append((core, stable_rank, suffix, t))

    if not candidates:
        return None, "no comparable candidates"

    candidates.sort()
    highest = candidates[-1]
    highest_core, _, _, highest_tag = highest
    cur_stable_rank = 0 if cur_is_prerelease else 1
    cur_key = (cur_core, cur_stable_rank, cur_suffix)
    new_key = (highest_core, highest[1], highest[2])
    if new_key > cur_key:
        return highest_tag, ""
    return None, "up-to-date"


# ---------------------------------------------------------------------------
# Phase 4: Report
# ---------------------------------------------------------------------------

def truncate(s: str, n: int) -> str:
    return s if len(s) <= n else s[: n - 1] + "…"


def render_table(results: list[Result]) -> str:
    headers = ["Service", "Container", "Image", "Current", "Latest", "Status"]
    rows: list[list[str]] = []
    for r in results:
        e = r.entry
        service = e.file.stem
        image = f"{e.registry}/{e.repo}" if e.registry and e.repo else "—"
        current = e.current_tag or "—"
        latest = r.latest_tag or "—"
        if r.status == "UPDATE":
            status = "UPDATE"
        elif r.status == "skipped":
            status = f"skipped ({r.detail})" if r.detail else "skipped"
        elif r.status == "error":
            status = f"error ({r.detail})" if r.detail else "error"
        elif r.status == "pinned":
            status = f"pinned ({r.detail})" if r.detail else "pinned"
        else:
            status = "up-to-date"
        rows.append([
            truncate(service, 24),
            truncate(e.container_key or "—", 22),
            truncate(image, 50),
            truncate(current, 22),
            truncate(latest, 22),
            status,
        ])

    widths = [len(h) for h in headers]
    for row in rows:
        for i, cell in enumerate(row):
            if len(cell) > widths[i]:
                widths[i] = len(cell)

    def fmt(row: list[str]) -> str:
        return "  ".join(cell.ljust(widths[i]) for i, cell in enumerate(row))

    lines = [fmt(headers), fmt(["-" * w for w in widths])]
    lines.extend(fmt(row) for row in rows)
    return "\n".join(lines)


def render_json(results: list[Result]) -> str:
    out = []
    for r in results:
        e = r.entry
        out.append({
            "file": str(e.file.relative_to(SERVICES_DIR.parent)),
            "container": e.container_key,
            "image": f"{e.registry}/{e.repo}" if e.registry and e.repo else "",
            "var_name": e.var_name,
            "current_tag": e.current_tag,
            "current_value": e.current_value,
            "latest_tag": r.latest_tag,
            "new_value": r.new_value,
            "status": r.status,
            "detail": r.detail,
        })
    return json.dumps(out, indent=2)


# ---------------------------------------------------------------------------
# Phase 5: Update mode
# ---------------------------------------------------------------------------

def derive_new_value(entry: Entry, latest_tag: str) -> str:
    """Reverse the template transform to get the new variable value."""
    val = latest_tag
    if entry.tag_prefix and val.startswith(entry.tag_prefix):
        val = val[len(entry.tag_prefix):]
    if entry.tag_suffix and val.endswith(entry.tag_suffix):
        val = val[: -len(entry.tag_suffix)]
    return val


def rewrite_file(path: Path, line_idx: int, var_name: str, new_value: str) -> bool:
    """Atomically rewrite line `line_idx` in `path` to set `var_name = "new_value";`."""
    raw = path.read_text()
    # Preserve trailing newline behaviour by splitting on "\n".
    lines = raw.split("\n")
    if line_idx < 0 or line_idx >= len(lines):
        return False
    line = lines[line_idx]
    pat = re.compile(r'^(\s*' + re.escape(var_name) + r'\s*=\s*")[^"]*("\s*;.*)$')
    m = pat.match(line)
    if not m:
        return False
    lines[line_idx] = m.group(1) + new_value + m.group(2)

    fd, tmp_path = tempfile.mkstemp(dir=str(path.parent), prefix=f".{path.name}.", suffix=".tmp")
    try:
        with os.fdopen(fd, "w") as f:
            f.write("\n".join(lines))
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp_path, path)
    except Exception:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise
    return True


def render_diff(results: list[Result]) -> str:
    """Render a unified-diff-style preview of the rewrites."""
    lines: list[str] = []
    for r in results:
        if r.status != "UPDATE" or r.new_value is None:
            continue
        e = r.entry
        rel = e.file.relative_to(SERVICES_DIR.parent)
        old_line = e.file.read_text().split("\n")[e.var_line]
        new_line = re.sub(
            r'(' + re.escape(e.var_name) + r'\s*=\s*")[^"]*(")',
            lambda m: m.group(1) + r.new_value + m.group(2),
            old_line, count=1,
        )
        lines.append(f"--- a/{rel}")
        lines.append(f"+++ b/{rel}")
        lines.append(f"@@ line {e.var_line + 1} ({e.container_key}) @@")
        lines.append(f"-{old_line}")
        lines.append(f"+{new_line}")
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--apply", action="store_true", help="prompt to apply each available update")
    ap.add_argument("--service", action="append", default=[], help="restrict to file stem (repeatable)")
    ap.add_argument("--include-prerelease", action="store_true", help="consider rc/beta/alpha/etc. tags")
    ap.add_argument("--major-only", action="store_true", help="only suggest updates within the same major")
    ap.add_argument("--diff", action="store_true", help="print rewrites without applying them")
    ap.add_argument("--no-cache", action="store_true", help="bypass on-disk tag cache")
    ap.add_argument("--json", action="store_true", help="emit machine-readable output")
    ap.add_argument("--repo-root", help="path to the homefree repo (default: walk up from CWD)")
    args = ap.parse_args()

    if shutil.which("skopeo") is None:
        print(
            "skopeo not found on PATH.\n"
            "Run via the nix-shell shebang: `./scripts/check-container-updates.py`,\n"
            "via `nix run .#update-versions`,\n"
            "or `nix-shell -p skopeo --run 'python3 scripts/check-container-updates.py ...'`.",
            file=sys.stderr,
        )
        return 1

    global REPO_ROOT, SERVICES_DIR
    try:
        REPO_ROOT = find_repo_root(args.repo_root)
    except RuntimeError as e:
        print(str(e), file=sys.stderr)
        return 1
    SERVICES_DIR = REPO_ROOT / "services"

    files = sorted(SERVICES_DIR.glob("*.nix"))
    if args.service:
        wanted = set(args.service)
        files = [f for f in files if f.stem in wanted]
        missing = wanted - {f.stem for f in files}
        if missing:
            print(f"unknown service(s): {', '.join(sorted(missing))}", file=sys.stderr)
            return 1

    entries: list[Entry] = []
    for f in files:
        try:
            entries.extend(parse_file(f))
        except Exception as e:
            print(f"failed to parse {f}: {e}", file=sys.stderr)
            return 1

    # Collect repos that need querying.
    needed_repos = sorted({(e.registry, e.repo) for e in entries if not e.skip_reason and e.registry and e.repo})
    repo_results = query_all(needed_repos, use_cache=not args.no_cache)

    results: list[Result] = []
    for e in entries:
        if e.skip_reason:
            results.append(Result(entry=e, status="skipped", detail=e.skip_reason))
            continue
        kind, arg = parse_override(e.override)
        if kind == "pin":
            results.append(Result(
                entry=e, status="pinned",
                detail=arg or "version is pinned",
            ))
            continue
        tags, err = repo_results.get((e.registry, e.repo), ([], "no result"))
        if err:
            results.append(Result(entry=e, status="error", detail=err))
            continue
        latest, detail = pick_latest(
            e, tags,
            include_prerelease=args.include_prerelease,
            major_only=args.major_only,
        )
        if latest is None:
            results.append(Result(entry=e, status="up-to-date", detail=detail))
        else:
            new_value = derive_new_value(e, latest)
            results.append(Result(
                entry=e, latest_tag=latest, new_value=new_value, status="UPDATE",
            ))

    # Sort: UPDATEs first, then errors, up-to-date, pinned, skipped.
    rank = {"UPDATE": 0, "error": 1, "up-to-date": 2, "pinned": 3, "skipped": 4}
    results.sort(key=lambda r: (rank.get(r.status, 9), r.entry.file.stem, r.entry.container_key))

    if args.json:
        print(render_json(results))
    else:
        print(render_table(results))

    pinned = [r for r in results if r.status == "pinned"]
    if pinned and not args.json:
        print()
        print(f"WARNING: {len(pinned)} binding(s) pinned, no upgrade suggestions:")
        for r in pinned:
            e = r.entry
            note = f" — {r.detail}" if r.detail and r.detail != "version is pinned" else ""
            print(f"  {e.file.stem}/{e.container_key}: {e.var_name} = {e.current_value!r}{note}")

    updates = [r for r in results if r.status == "UPDATE"]

    if args.diff:
        if updates:
            print()
            print(render_diff(updates))
        return 2 if updates else 0

    if args.apply and updates:
        print()
        yes_all = False
        rewritten: list[tuple[Path, str, str, str]] = []
        for r in updates:
            e = r.entry
            prompt = (
                f"Update {e.file.stem}/{e.container_key}: "
                f"{e.var_name} = \"{e.current_value}\" -> \"{r.new_value}\"? [y/N/a/q] "
            )
            if yes_all:
                ans = "y"
                print(prompt + "y (auto)")
            else:
                try:
                    ans = input(prompt).strip().lower()
                except EOFError:
                    ans = "n"
            if ans == "q":
                break
            if ans == "a":
                yes_all = True
                ans = "y"
            if ans != "y":
                continue
            ok = rewrite_file(e.file, e.var_line, e.var_name, r.new_value)
            if ok:
                rewritten.append((e.file, e.var_name, e.current_value, r.new_value))
                print(f"  wrote {e.file.relative_to(SERVICES_DIR.parent)}")
            else:
                print(f"  FAILED to rewrite {e.file} line {e.var_line + 1}", file=sys.stderr)

        if rewritten:
            print()
            print(f"updated {len(rewritten)} binding(s):")
            for path, var, old, new in rewritten:
                print(f"  {path.relative_to(SERVICES_DIR.parent)}: {var} {old} -> {new}")

    return 2 if updates else 0


if __name__ == "__main__":
    sys.exit(main())
