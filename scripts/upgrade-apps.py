#!/usr/bin/env nix-shell
#! nix-shell -i python3 -p "python3.withPackages (ps: [ ps.httpx ps.fastapi ])"

"""
Bump every outdated app's image-version pin to its known-latest tag,
driven by the App Versions resolver's cache. Reads
/var/lib/homefree-admin/app-versions-cache.json (refreshed daily by
homefree-app-versions-refresh.timer, or on demand via --refresh) and
edits the version literal in each apps/<name>/default.nix.

Zitadel is skipped by default to avoid SSO lockout; --include-zitadel
opts in after arranging an out-of-band login.

Usage:
  ./scripts/upgrade-apps.py                  # apply all outdated bumps (except zitadel)
  ./scripts/upgrade-apps.py --dry-run        # unified diff preview, no edits
  ./scripts/upgrade-apps.py --refresh        # force a fresh upstream poll first
  ./scripts/upgrade-apps.py --include-zitadel
  ./scripts/upgrade-apps.py --app jellyfin --app immich
  ./scripts/upgrade-apps.py --skip nextcloud
  ./scripts/upgrade-apps.py --json

Exit codes:
  0 = no outdated apps
  2 = at least one file was edited (or would be under --dry-run)
  1 = error
"""

from __future__ import annotations

import argparse
import asyncio
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from collections import defaultdict
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional, TYPE_CHECKING

if TYPE_CHECKING:
    # Type-only; the real runtime import happens in main() once the repo
    # root (and thus web-platform/backend) is on sys.path.
    from resolvers.app_source_index import SourceEntry


SCRIPT_DIR = Path(__file__).resolve().parent

RED = "\033[0;31m"
GREEN = "\033[0;32m"
YELLOW = "\033[1;33m"
BLUE = "\033[0;34m"
CYAN = "\033[0;36m"
NC = "\033[0m"

USE_COLOR = sys.stdout.isatty()

# When --json is set, stdout must carry ONLY the machine-readable JSON
# summary — the admin-api Update Apps endpoint does json.loads(stdout).
# Human-facing log lines then go to stderr so they can't corrupt it.
# (Without this, a single `[INFO] ...` line ahead of the JSON makes the
# parse fail at char 1 with "Expecting value".)
JSON_MODE = False


def _c(code: str, msg: str) -> str:
    return f"{code}{msg}{NC}" if USE_COLOR else msg


def _log_stream():
    return sys.stderr if JSON_MODE else sys.stdout


def log_info(msg: str) -> None:    print(f"{_c(BLUE,    '[INFO]')}    {msg}", file=_log_stream())
def log_bump(msg: str) -> None:    print(f"{_c(GREEN,   '[BUMP]')}    {msg}", file=_log_stream())
def log_skip(msg: str) -> None:    print(f"{_c(YELLOW,  '[SKIP]')}    {msg}", file=_log_stream())
def log_warn(msg: str) -> None:    print(f"{_c(YELLOW,  '[WARNING]')} {msg}", file=_log_stream())
def log_success(msg: str) -> None: print(f"{_c(GREEN,   '[SUCCESS]')} {msg}", file=_log_stream())
def log_error(msg: str) -> None:   print(f"{_c(RED,     '[ERROR]')}   {msg}", file=sys.stderr)
def log_dry(msg: str) -> None:     print(f"{_c(CYAN,    '[DRY]')}     {msg}", file=_log_stream())


# ─── repo discovery ──────────────────────────────────────────────────

def find_repo_root(cli_arg: Optional[str]) -> Path:
    """
    Resolve the homefree repo root containing flake.nix + apps/. The
    script may be invoked via `nix run` (lands in /nix/store, far from
    the apps tree), so the discovery order is: --repo-root,
    $HOMEFREE_REPO_ROOT, walk up from CWD, walk up from SCRIPT_DIR.
    """
    explicit = cli_arg or os.environ.get("HOMEFREE_REPO_ROOT")
    if explicit:
        p = Path(explicit).resolve()
        if (p / "flake.nix").is_file() and (p / "apps").is_dir():
            return p
        raise RuntimeError(
            f"--repo-root / HOMEFREE_REPO_ROOT pointed at {p}, "
            "but no flake.nix + apps/ there"
        )
    for start in (Path.cwd(), SCRIPT_DIR):
        cur = start.resolve()
        while True:
            if (cur / "flake.nix").is_file() and (cur / "apps").is_dir():
                return cur
            if cur.parent == cur:
                break
            cur = cur.parent
    raise RuntimeError(
        "Could not find a flake.nix + apps/ directory by walking up from "
        f"CWD ({Path.cwd()}) or script dir ({SCRIPT_DIR}). "
        "Pass --repo-root or set HOMEFREE_REPO_ROOT."
    )


# ─── Nix source parsing ──────────────────────────────────────────────
#
# The image-pin parser (regexes, resolve_template, SourceEntry,
# parse_source_file, build_source_index) lives in
# web-platform/backend/resolvers/app_source_index.py so this bumper and
# the App Versions page resolver share ONE implementation and can't
# drift. It's imported in main() once the repo root is known (the script
# may run from /nix/store via `nix run`, so the path isn't importable at
# module load time).


# ─── bump planning ────────────────────────────────────────────────────

def derive_new_value(latest_tag: str, prefix: str, suffix: str) -> str:
    """Reverse the template transform: <prefix><value><suffix> == latest_tag."""
    val = latest_tag
    if prefix and val.startswith(prefix):
        val = val[len(prefix):]
    if suffix and val.endswith(suffix):
        val = val[:-len(suffix)]
    return val


_NUM_RE = re.compile(r'\d+')


def _numeric_tuple(s: str) -> tuple[int, ...]:
    return tuple(int(x) for x in _NUM_RE.findall(s))


def _leading_non_digit(s: str) -> str:
    """Leading text before the first digit. Captures 'v', 'version-', etc."""
    m = re.match(r'^[^\d]*', s or "")
    return m.group(0) if m else ""


def is_unsafe_bump(current: str, new: str) -> Optional[str]:
    """Return a reason string if bumping current -> new looks wrong (a
    downgrade or a tag-scheme switch); None if the bump is safe to write.

    Defends against resolver false positives where _pick_latest picks a
    tag from a different release stream — e.g. forgejo 15.x where the
    registry also has 1.x rootless tags, home-assistant year-based
    versions vs old semver, or grocy's `version-vX` prefixed stream
    coexisting with a plain `X.Y.Z` stream."""
    if _numeric_tuple(new) < _numeric_tuple(current):
        return f"numeric downgrade ({current} -> {new})"
    if _leading_non_digit(current) != _leading_non_digit(new):
        return (
            f"tag-scheme prefix changed "
            f"({_leading_non_digit(current)!r} -> {_leading_non_digit(new)!r})"
        )
    return None


@dataclass
class PlannedBump:
    file: Path
    binding: str
    line_idx: int
    current_value: str
    new_value: str
    app_dir: str
    containers: list[str] = field(default_factory=list)
    latest_tag: str = ""


def normalise_filter(name: str) -> str:
    return name.strip().lower()


def matches_filter(needles: list[str], *candidates: str) -> bool:
    if not needles:
        return True
    cands = {normalise_filter(c) for c in candidates if c}
    return any(normalise_filter(n) in cands for n in needles)


# ─── rewriting ────────────────────────────────────────────────────────

def rewrite_binding(path: Path, line_idx: int, binding: str, new_value: str) -> bool:
    raw = path.read_text()
    lines = raw.split("\n")
    if line_idx < 0 or line_idx >= len(lines):
        return False
    line = lines[line_idx]
    pat = re.compile(r'^(\s*' + re.escape(binding) + r'\s*=\s*")[^"]*("\s*;.*)$')
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


def nix_parses(path: Path) -> bool:
    nix_instantiate = shutil.which("nix-instantiate")
    if nix_instantiate is None:
        return True
    try:
        r = subprocess.run(
            [nix_instantiate, "--parse", str(path)],
            capture_output=True, text=True, timeout=10,
        )
        return r.returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        return True


# ─── rendering ────────────────────────────────────────────────────────

def render_diff(bumps: list[PlannedBump], repo_root: Path) -> str:
    out: list[str] = []
    for b in bumps:
        rel = b.file.relative_to(repo_root)
        try:
            old_line = b.file.read_text().split("\n")[b.line_idx]
        except (OSError, IndexError):
            continue
        new_line = re.sub(
            r'(' + re.escape(b.binding) + r'\s*=\s*")[^"]*(")',
            lambda m: m.group(1) + b.new_value + m.group(2),
            old_line, count=1,
        )
        ctx = ", ".join(b.containers) if b.containers else b.app_dir
        out.append(f"--- a/{rel}")
        out.append(f"+++ b/{rel}")
        out.append(f"@@ line {b.line_idx + 1} ({ctx}) @@")
        out.append(f"-{old_line}")
        out.append(f"+{new_line}")
    return "\n".join(out)


def fmt_bump_line(b: PlannedBump, label_pad: int, binding_pad: int, repo_root: Path, trailer: str = "") -> str:
    rel = b.file.relative_to(repo_root)
    extras = ""
    if len(b.containers) > 1 or (b.containers and b.containers[0] != b.app_dir):
        extras = f"  ({', '.join(b.containers)})"
    return (
        f"{b.app_dir.ljust(label_pad)} "
        f"{b.binding.ljust(binding_pad)} "
        f'"{b.current_value}" -> "{b.new_value}"   {rel}:{b.line_idx + 1}{extras}{trailer}'
    )


# ─── --list ───────────────────────────────────────────────────────────


_STATUS_RANK = {"outdated": 0, "unknown": 1, "floating": 2, "local": 3, "up-to-date": 4}


def _do_list(
    rows: list[dict],
    index: dict[str, SourceEntry],
    repo_root: Path,
    app_filters: list[str],
    skip_filters: list[str],
    as_json: bool,
) -> int:
    """Print every known container in a compact status table. Joins
    the resolver's payload with the source index so the operator can
    see which `--app NAME` value to pass for any row.
    """
    items: list[dict] = []
    for row in rows:
        entry = index.get(row.get("image", ""))
        if entry:
            app_dir = entry.file.parent.name
        else:
            # Image-string lookup missed (literal image with no ${VAR} —
            # local builds, digest pins, etc.). Fall back to matching the
            # container name against an apps/<name> dir.
            container = row.get("name") or ""
            for sub in ("apps", "services"):
                cand = repo_root / sub / container / "default.nix"
                if cand.is_file():
                    app_dir = container
                    break
            else:
                app_dir = ""
        candidates = (app_dir, row.get("name") or "", row.get("project_name") or "")
        if skip_filters and matches_filter(skip_filters, *candidates):
            continue
        if app_filters and not matches_filter(app_filters, *candidates):
            continue
        items.append({
            "app": app_dir or "(custom flake)",
            "container": row.get("name") or "",
            "project": row.get("project_name") or "",
            "current": row.get("current") or "",
            "latest": row.get("latest") or "",
            "status": row.get("status") or "",
            "note": row.get("note") or "",
            "binding": entry.binding if entry else "",
            "file": str(entry.file.relative_to(repo_root)) if entry else "",
        })

    items.sort(key=lambda r: (
        _STATUS_RANK.get(r["status"], 9),
        r["app"].lower(),
        r["container"].lower(),
    ))

    if as_json:
        print(json.dumps(items, indent=2))
        return 0

    if not items:
        log_info("No matching rows.")
        return 0

    headers = ["App", "Container", "Current", "Latest", "Status"]
    table = [headers] + [
        [it["app"], it["container"], it["current"] or "—",
         it["latest"] or "—", it["status"]]
        for it in items
    ]
    widths = [max(len(row[c]) for row in table) for c in range(len(headers))]

    def _fmt(row: list[str]) -> str:
        return "  ".join(cell.ljust(widths[c]) for c, cell in enumerate(row))

    print(_fmt(headers))
    print(_fmt(["-" * w for w in widths]))
    for row in table[1:]:
        print(_fmt(row))

    return 0


# ─── main ─────────────────────────────────────────────────────────────

def main() -> int:
    global USE_COLOR, JSON_MODE

    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    ap.add_argument("--dry-run", action="store_true",
                    help="Print a unified diff of the planned changes; don't edit.")
    ap.add_argument("--refresh", action="store_true",
                    help="Run refresh_all() before reading the cache.")
    ap.add_argument("--include-zitadel", action="store_true",
                    help="Allow bumping Zitadel/oauth2-proxy. Off by default to avoid SSO lockout.")
    ap.add_argument("--app", action="append", default=[],
                    help="Restrict to one project name / apps dir / container name (repeatable).")
    ap.add_argument("--skip", action="append", default=[],
                    help="Exclude a specific app (repeatable).")
    ap.add_argument("-l", "--list", action="store_true",
                    help="List every known container with current pin, latest, and status. No edits.")
    ap.add_argument("--json", action="store_true",
                    help="Machine-readable summary on stdout.")
    ap.add_argument("--no-color", action="store_true",
                    help="Disable ANSI color output.")
    ap.add_argument("--repo-root", help="Override repo root discovery.")
    args = ap.parse_args()

    if args.no_color or args.json:
        USE_COLOR = False
    if args.json:
        JSON_MODE = True

    try:
        repo_root = find_repo_root(args.repo_root)
    except RuntimeError as e:
        log_error(str(e))
        return 1

    # Pull the resolver + shared source parser into scope.
    sys.path.insert(0, str(repo_root / "web-platform" / "backend"))
    try:
        from resolvers import app_versions as av
        from resolvers.app_source_index import build_source_index
    except ImportError as e:
        log_error(f"Failed to import app_versions resolver: {e}")
        return 1

    if args.refresh:
        log_info("Refreshing upstream tags (this may take a minute) ...")
        try:
            asyncio.run(av.refresh_all())
        except Exception as e:
            log_error(f"refresh_all failed: {e}")
            return 1

    if not av.CACHE_FILE.exists():
        log_error(
            f"app-versions cache missing at {av.CACHE_FILE}. "
            "Re-run with --refresh, or wait for the daily timer."
        )
        return 1

    try:
        rows = av._build_payload()
    except Exception as e:
        log_error(f"_build_payload failed: {e}")
        return 1

    app_filters = [normalise_filter(a) for a in args.app] if args.app else []
    skip_filters = [normalise_filter(s) for s in args.skip]

    index = build_source_index(repo_root)

    if args.list:
        return _do_list(rows, index, repo_root, app_filters, skip_filters, args.json)

    actionable = [r for r in rows if r.get("status") == "outdated" and r.get("latest")]

    if not actionable:
        if args.json:
            print(json.dumps({"bumped": [], "skipped_zitadel": [], "warnings": [], "errors": []}))
        else:
            log_info("All up-to-date.")
        return 0

    # Group outdated rows by (file, binding).
    groups: dict[tuple[Path, str], list[dict]] = defaultdict(list)
    unmapped: list[dict] = []

    for row in actionable:
        entry = index.get(row.get("image", ""))
        if entry is None:
            unmapped.append(row)
            continue
        groups[(entry.file, entry.binding)].append({
            "row": row,
            "entry": entry,
        })

    warnings: list[str] = []
    errors: list[str] = []
    zitadel_skipped: list[PlannedBump] = []
    planned: list[PlannedBump] = []

    for (file, binding), items in groups.items():
        # All items share file+binding by construction; the binding is
        # the same across them, so the planned new_value must agree.
        entry = items[0]["entry"]
        containers = [it["row"]["name"] for it in items]
        latest_tags = {it["row"]["latest"] for it in items}
        app_dir = file.parent.name

        cand_strs = (app_dir, *(it["row"].get("project_name") or "" for it in items), *containers)
        if skip_filters and matches_filter(skip_filters, *cand_strs):
            continue
        if app_filters and not matches_filter(app_filters, *cand_strs):
            continue

        if len(latest_tags) > 1:
            warnings.append(
                f"{app_dir}/{binding}: shared binding can't satisfy disagreeing targets "
                f"({', '.join(sorted(latest_tags))}); skipping"
            )
            continue

        latest_tag = next(iter(latest_tags))
        new_value = derive_new_value(latest_tag, entry.tag_prefix, entry.tag_suffix)

        if new_value == entry.current_value:
            # Already at the target value (e.g. file edited between
            # refresh and now). Resolver will catch up at next refresh.
            continue

        unsafe_reason = is_unsafe_bump(entry.current_value, new_value)
        if unsafe_reason:
            warnings.append(
                f"{app_dir}/{binding}: refusing {entry.current_value!r} -> {new_value!r}: "
                f"{unsafe_reason}. Likely a resolver mis-pick on a non-standard tag scheme; "
                "bump by hand if intentional."
            )
            continue

        bump = PlannedBump(
            file=file,
            binding=binding,
            line_idx=entry.line_idx,
            current_value=entry.current_value,
            new_value=new_value,
            app_dir=app_dir,
            containers=sorted(containers),
            latest_tag=latest_tag,
        )

        is_zitadel = app_dir == "zitadel"
        if is_zitadel and not args.include_zitadel:
            zitadel_skipped.append(bump)
            continue

        planned.append(bump)

    # Containers in the catalog but absent from this repo's source tree
    # are surfaced as info, not error — they're likely declared by a
    # custom-flakes.nix input on this box. The operator handles those
    # outside this tool. Apply the same --app/--skip filter so a
    # targeted run isn't drowned in notes about unrelated apps.
    unmapped_notes: list[str] = []
    for row in unmapped:
        cands = (row.get("name") or "", row.get("project_name") or "")
        if skip_filters and matches_filter(skip_filters, *cands):
            continue
        if app_filters and not matches_filter(app_filters, *cands):
            continue
        unmapped_notes.append(
            f"{row['name']} (image {row.get('image')}) not in this repo's source tree — "
            "likely declared by a custom flake; bump it there."
        )

    # Stable sort: zitadel first (it appears under SKIP), then by app name.
    planned.sort(key=lambda b: (b.app_dir, b.binding))
    zitadel_skipped.sort(key=lambda b: b.binding)

    # ─── apply / preview ──────────────────────────────────────────────

    if args.dry_run:
        if args.json:
            print(json.dumps({
                "bumped": [_bump_json(b) for b in planned],
                "skipped_zitadel": [_bump_json(b) for b in zitadel_skipped],
                "warnings": warnings,
                "errors": errors,
                "unmapped": unmapped_notes,
            }, indent=2))
            return 2 if (planned or zitadel_skipped) else 0

        log_info(f"{len(actionable)} outdated container(s); {len(planned)} bump(s) planned")
        if planned:
            print()
            print(render_diff(planned, repo_root))
        if zitadel_skipped:
            print()
            label_pad = _label_pad(planned + zitadel_skipped)
            binding_pad = _binding_pad(planned + zitadel_skipped)
            for b in zitadel_skipped:
                log_skip(fmt_bump_line(b, label_pad, binding_pad, repo_root,
                                       trailer="  (use --include-zitadel)"))
            log_warn(
                f"Zitadel had {len(zitadel_skipped)} update(s) available but was skipped to avoid SSO lockout. "
                "Re-run with --include-zitadel after arranging an out-of-band login."
            )
        for w in warnings:
            log_warn(w)
        for n in unmapped_notes:
            log_info(n)
        for e in errors:
            log_error(e)
        if planned:
            log_info("Dry-run: no files were edited. Re-run without --dry-run to apply.")
        return 2 if (planned or zitadel_skipped) else 0

    # Real apply.
    label_pad = _label_pad(planned + zitadel_skipped)
    binding_pad = _binding_pad(planned + zitadel_skipped)

    log_info(f"{len(actionable)} outdated container(s); {len(planned)} bump(s) planned")

    bumped: list[PlannedBump] = []
    for b in planned:
        # Re-read & rewrite atomically; the anchored regex catches any
        # race against an outside edit.
        try:
            original = b.file.read_text()
            ok = rewrite_binding(b.file, b.line_idx, b.binding, b.new_value)
        except OSError as e:
            errors.append(f"{b.file.relative_to(repo_root)}: write failed: {e}")
            log_error(f"{b.file.relative_to(repo_root)}: write failed: {e}")
            continue
        if not ok:
            errors.append(
                f"{b.file.relative_to(repo_root)}:{b.line_idx + 1}: "
                f"{b.binding} line no longer matches (concurrent edit?)"
            )
            log_error(errors[-1])
            continue

        if not nix_parses(b.file):
            try:
                b.file.write_text(original)
            except OSError as e:
                errors.append(
                    f"{b.file.relative_to(repo_root)}: parse failed AND restore failed: {e}"
                )
                log_error(errors[-1])
                continue
            errors.append(
                f"{b.file.relative_to(repo_root)}: nix-instantiate --parse failed after bump; "
                "rolled back"
            )
            log_error(errors[-1])
            continue

        bumped.append(b)
        log_bump(fmt_bump_line(b, label_pad, binding_pad, repo_root))

    for b in zitadel_skipped:
        log_skip(fmt_bump_line(b, label_pad, binding_pad, repo_root,
                               trailer="  (use --include-zitadel)"))

    if zitadel_skipped and not args.include_zitadel:
        print()
        log_warn(
            f"Zitadel had {len(zitadel_skipped)} update(s) available but was skipped to "
            "avoid SSO lockout."
        )
        log_warn(
            "Re-run with --include-zitadel after arranging an out-of-band login "
            "(local console + system.hashedPassword) in case the bootstrap regresses."
        )

    for w in warnings:
        log_warn(w)
    for n in unmapped_notes:
        log_info(n)

    if args.json:
        print(json.dumps({
            "bumped": [_bump_json(b) for b in bumped],
            "skipped_zitadel": [_bump_json(b) for b in zitadel_skipped],
            "warnings": warnings,
            "errors": errors,
            "unmapped": unmapped_notes,
        }, indent=2))

    if bumped:
        print()
        files_touched = len({b.file for b in bumped})
        log_success(f"{len(bumped)} binding(s) bumped across {files_touched} file(s).")
        log_info("To deploy: sudo scripts/build.sh --switch")
    elif not zitadel_skipped:
        log_info("Nothing to do.")

    if errors:
        return 1
    return 2 if (bumped or zitadel_skipped) else 0


def _bump_json(b: PlannedBump) -> dict:
    return {
        "app": b.app_dir,
        "file": str(b.file),
        "binding": b.binding,
        "line": b.line_idx + 1,
        "current_value": b.current_value,
        "new_value": b.new_value,
        "latest_tag": b.latest_tag,
        "containers": b.containers,
    }


def _label_pad(bumps: list[PlannedBump]) -> int:
    return max((len(b.app_dir) for b in bumps), default=0)


def _binding_pad(bumps: list[PlannedBump]) -> int:
    return max((len(b.binding) for b in bumps), default=0)


if __name__ == "__main__":
    sys.exit(main())
