"""
Shared Nix-source image-pin parser.

Two consumers read an app/service's container image pin straight from
its `apps/<x>/default.nix` (or `services/<x>/default.nix`) source —
NOT from the evaluated NixOS config — so that DISABLED apps (which
never declare a `virtualisation.oci-containers.containers` entry) are
still visible:

  * scripts/upgrade-apps.py — needs the bumpable `${VAR}`-tagged pins
    so it can rewrite the version literal. Uses build_source_index().

  * resolvers/app_versions.py (the App Versions page) — needs EVERY
    image pin, bumpable or not, so the page can show update status for
    apps that aren't currently enabled. Uses scan_all_app_images(),
    surfaced as a build-time artifact (/run/homefree/admin/
    all-app-images.json, emitted by services/admin-web/default.nix).

Keeping both behind one parser avoids the two drifting — a repeat
gotcha when version-pin logic lived in two places.

The parser is a deliberately pragmatic line scanner, not a full Nix
grammar (see parse_source_file's docstring for why that's safe here).
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Optional


# ─── regexes ──────────────────────────────────────────────────────────

LET_BIND_RE = re.compile(r'^(\s+)([A-Za-z][\w-]*)\s*=\s*"([^"]*)"\s*;')
IMAGE_LINE_RE = re.compile(r'^(\s+)image\s*=\s*"([^"]+)"\s*;')
INTERP_RE = re.compile(r'\$\{([A-Za-z][\w-]*)\}')


def resolve_template(template: str, bindings: dict[str, str], depth: int = 4) -> Optional[str]:
    """Substitute ${var} references. Returns None if any var is unknown."""
    seen = 0
    text = template
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


@dataclass
class SourceEntry:
    file: Path
    binding: str
    line_idx: int
    current_value: str
    tag_prefix: str
    tag_suffix: str


def _collect_lines(path: Path) -> tuple[dict[str, tuple[int, str]], list[tuple[int, str]]]:
    """Scan one `.nix` file's raw lines and return:

      * bindings: {name: (line_idx, value)} for every `name = "value";`
        let-binding, first-wins (a top-level `version = "X"` shadows a
        same-name binding redeclared deeper in the file).
      * image_lines: [(line_idx, template)] for every `image = "...";`.

    Comment lines are skipped. No let-block detection or heredoc
    masking — see parse_source_file for the justification.
    """
    try:
        raw = path.read_text()
    except OSError:
        return {}, []
    lines = raw.split("\n")

    bindings: dict[str, tuple[int, str]] = {}
    image_lines: list[tuple[int, str]] = []
    for i, raw_line in enumerate(lines):
        stripped = raw_line.lstrip()
        if stripped.startswith("#") or stripped.startswith("##"):
            continue
        m = IMAGE_LINE_RE.match(raw_line)
        if m:
            _, template = m.groups()
            image_lines.append((i, template))
        m = LET_BIND_RE.match(raw_line)
        if m:
            _, name, value = m.groups()
            bindings.setdefault(name, (i, value))
    return bindings, image_lines


def parse_source_file(path: Path) -> list[tuple[str, SourceEntry]]:
    """
    Return list of (resolved_image_string, SourceEntry) for every
    BUMPABLE `image = "...${VAR}...";` literal in the file — i.e. only
    the ones whose tag references a let-binding the bumper can rewrite.
    Scans raw lines — no let-block detection, no heredoc masking.
    Justification:

      * `name = "value";` and `image = "...";` with semicolon are Nix
        syntax. Heredocs in HomeFree contain YAML/shell/JSON, none of
        which use `key = "value";` shape — false positives are
        essentially impossible in practice.
      * The full-Nix grammar (heredoc escapes `''${`, `'''`, `''\n`;
        nested `''` blocks) is too tangled for a regex masker to track
        reliably across all apps. The pragmatic scan is simpler and
        more robust.
    """
    bindings, image_lines = _collect_lines(path)
    binding_values = {n: v for n, (_, v) in bindings.items()}

    results: list[tuple[str, SourceEntry]] = []
    for _, template in image_lines:
        if "@sha256:" in template:
            continue
        if ":" not in template:
            continue

        tag_template = template.rsplit(":", 1)[1]
        tag_refs = INTERP_RE.findall(tag_template)
        if not tag_refs:
            continue
        var_name = tag_refs[0]
        if var_name not in bindings:
            continue

        resolved = resolve_template(template, binding_values)
        if resolved is None:
            continue

        placeholder = "${" + var_name + "}"
        before, _, after = tag_template.partition(placeholder)
        if "${" in before or "${" in after:
            continue

        var_line, var_value = bindings[var_name]
        results.append((resolved, SourceEntry(
            file=path,
            binding=var_name,
            line_idx=var_line,
            current_value=var_value,
            tag_prefix=before,
            tag_suffix=after,
        )))
    return results


def build_source_index(repo_root: Path) -> dict[str, SourceEntry]:
    """
    Walk apps/*/default.nix and services/*/default.nix; return a map
    from resolved-image-string to its SourceEntry. The container
    catalog's image string is what the bumper looks up.
    """
    index: dict[str, SourceEntry] = {}
    for sub in ("apps", "services"):
        root = repo_root / sub
        if not root.is_dir():
            continue
        for child in sorted(root.iterdir()):
            f = child / "default.nix"
            if not f.is_file():
                continue
            for image_str, entry in parse_source_file(f):
                index.setdefault(image_str, entry)
    return index


def _has_tag_or_digest(image: str) -> bool:
    """True if an image string carries a real version pin — a tag (a
    `:` AFTER the last `/`, so a registry-port colon doesn't count) or
    a `@sha256:` digest. A bare `repo/name` is an intermediate base-
    image let-binding (matrix's `matrixdotorg/synapse`, freshrss's
    `freshrss/freshrss`), not a deployable pin — the real, tagged pin
    is a separate line in the same file."""
    if "@sha256:" in image:
        return True
    last_slash = image.rfind("/")
    last_colon = image.rfind(":")
    return last_colon > last_slash


def _images_in_file(path: Path) -> list[str]:
    """Return every resolvable, version-pinned image string in one
    default.nix — bumpable OR not (literal tags, digests, `:local`,
    floating tags all included). Dropped:

      * lines whose `${VAR}` can't be resolved from the file's let-
        bindings (we can't honestly report a `???`-shaped image), and
      * tagless/digestless intermediates (see _has_tag_or_digest).
    """
    bindings, image_lines = _collect_lines(path)
    binding_values = {n: v for n, (_, v) in bindings.items()}

    out: list[str] = []
    seen: set[str] = set()
    for _, template in image_lines:
        resolved = resolve_template(template, binding_values)
        if resolved is None or "${" in resolved:
            continue
        if not _has_tag_or_digest(resolved):
            continue
        if resolved not in seen:
            seen.add(resolved)
            out.append(resolved)
    return out


def scan_all_app_images(parent_dirs: list[Path]) -> list[dict]:
    """Scan every `<parent>/<child>/default.nix` under the given parent
    directories (typically the repo's apps/ and services/) and return
    [{"app": <child-dir-name>, "image": <resolved-image-string>}] for
    every image pin found — INCLUDING apps that are currently disabled.

    `_`-prefixed child dirs are skipped: that prefix is HomeFree's
    convention (see configuration.nix auto-discovery) for a module that
    is disabled at the discovery level and never loaded at all.
    """
    out: list[dict] = []
    seen: set[tuple[str, str]] = set()
    for parent in parent_dirs:
        parent = Path(parent)
        if not parent.is_dir():
            continue
        for child in sorted(parent.iterdir()):
            if not child.is_dir() or child.name.startswith("_"):
                continue
            f = child / "default.nix"
            if not f.is_file():
                continue
            for image in _images_in_file(f):
                pair = (child.name, image)
                if pair in seen:
                    continue
                seen.add(pair)
                out.append({"app": child.name, "image": image})
    return out


# ─── CLI ──────────────────────────────────────────────────────────────
#
# Used by services/admin-web/default.nix at build time:
#   python app_source_index.py scan <apps-dir> <services-dir> > out.json
# Emits the all-app-images catalog the App Versions resolver reads.


def main(argv: Optional[list[str]] = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    sub = ap.add_subparsers(dest="cmd", required=True)
    scan = sub.add_parser("scan", help="Emit the all-app-images JSON catalog.")
    scan.add_argument("dirs", nargs="+",
                      help="Parent directories to scan (e.g. apps/ services/).")
    args = ap.parse_args(argv)

    if args.cmd == "scan":
        catalog = scan_all_app_images([Path(d) for d in args.dirs])
        json.dump(catalog, sys.stdout, indent=2)
        sys.stdout.write("\n")
        return 0
    return 1


if __name__ == "__main__":
    sys.exit(main())
