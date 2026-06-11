"""Unit tests for the pure bump-decision logic in scripts/upgrade-apps.py.

Loaded by path because the script name is hyphenated (not importable as a
module). Pins the safety guard that decides whether an automatic image bump
is allowed to be written — the rest of upgrade-apps.py is I/O (reading the
App Versions cache, rewriting Nix files) and not unit-tested here.

The Nix source-pin parsing (regexes, resolve_template, SourceEntry,
parse_source_file) deliberately lives in
web-platform/backend/resolvers/app_source_index.py so the bumper and the
App Versions page share one implementation; it is covered by the
web-platform python-unit gate, not here.
"""
import importlib.util
import sys
from pathlib import Path

import pytest

_SCRIPT = Path(__file__).resolve().parent.parent / "upgrade-apps.py"
_spec = importlib.util.spec_from_file_location("ua", _SCRIPT)
ua = importlib.util.module_from_spec(_spec)
# Register before exec_module so @dataclass (PlannedBump) can resolve
# cls.__module__ via sys.modules (otherwise dataclass processing hits
# None.__dict__).
sys.modules[_spec.name] = ua
_spec.loader.exec_module(ua)


# ─── is_unsafe_bump — THE guard against bad auto-bumps ────────────────
# Returns a reason string when a bump should be refused, else None.

@pytest.mark.parametrize("current,new", [
    ("1.2.3", "1.2.4"),          # patch up
    ("1.2.3", "1.3.0"),          # minor up
    ("1.2.3", "2.0.0"),          # major up, same scheme
    ("v1.2.3", "v1.2.4"),        # v-prefixed, same scheme
    ("version-v1.2", "version-v1.3"),  # prefixed stream, same scheme
    ("1.2.3", "1.2.3"),          # no change is not "unsafe"
])
def test_is_unsafe_bump_allows_safe(current, new):
    assert ua.is_unsafe_bump(current, new) is None


@pytest.mark.parametrize("current,new,needle", [
    ("1.2.4", "1.2.3", "downgrade"),       # numeric downgrade
    ("2.0.0", "1.9.9", "downgrade"),
    ("v1.2.3", "1.2.4", "prefix"),         # v-scheme -> bare (forgejo rootless trap)
    ("1.2.3", "v1.2.4", "prefix"),         # bare -> v-scheme
    ("version-v1.2", "1.3", "prefix"),     # grocy prefixed stream -> bare
])
def test_is_unsafe_bump_rejects(current, new, needle):
    reason = ua.is_unsafe_bump(current, new)
    assert reason is not None
    assert needle in reason


# ─── derive_new_value — reverse the <prefix><value><suffix> transform ──

@pytest.mark.parametrize("latest_tag,prefix,suffix,expected", [
    ("v1.2.3", "v", "", "1.2.3"),
    ("1.2.3-alpine", "", "-alpine", "1.2.3"),
    ("version-v1.2.3", "version-v", "", "1.2.3"),
    ("v1.2.3-rc1", "v", "-rc1", "1.2.3"),
    ("1.2.3", "", "", "1.2.3"),
    ("1.2.3", "v", "", "1.2.3"),   # prefix absent in tag -> left untouched
])
def test_derive_new_value(latest_tag, prefix, suffix, expected):
    assert ua.derive_new_value(latest_tag, prefix, suffix) == expected


# ─── numeric/prefix helpers that is_unsafe_bump is built on ───────────

@pytest.mark.parametrize("s,expected", [
    ("1.2.3", (1, 2, 3)),
    ("1.2", (1, 2)),
    ("20240131", (20240131,)),
    ("abc", ()),
    ("", ()),
])
def test_numeric_tuple(s, expected):
    assert ua._numeric_tuple(s) == expected


@pytest.mark.parametrize("s,expected", [
    ("v1.2.3", "v"),
    ("1.2.3", ""),
    ("version-v1.2", "version-v"),
    ("-rc1", "-rc"),
    ("", ""),
])
def test_leading_non_digit(s, expected):
    assert ua._leading_non_digit(s) == expected


# ─── --app / --skip filter matching (exact, case/space-insensitive) ───

@pytest.mark.parametrize("needles,candidates,expected", [
    ([], ("immich",), True),                       # empty filter matches all
    (["jellyfin"], ("jellyfin",), True),
    (["jellyfin"], ("immich",), False),
    (["Jellyfin"], ("jellyfin", "Media Server"), True),  # case-insensitive
    (["  immich "], ("immich",), True),            # whitespace-insensitive
    (["jelly"], ("jellyfin",), False),             # exact, not substring
    (["x"], (None, "x"), True),                    # None candidate is skipped
])
def test_matches_filter(needles, candidates, expected):
    assert ua.matches_filter(needles, *candidates) is expected
