"""Unit tests for the container-update semver/tag logic in
scripts/check-container-updates.py.

Loaded by path because the script name is hyphenated (not importable as a
module). Pins the pure decision functions that drive automatic image updates.
"""
import importlib.util
import sys
from pathlib import Path

import pytest

_SCRIPT = Path(__file__).resolve().parent.parent / "check-container-updates.py"
_spec = importlib.util.spec_from_file_location("ccu", _SCRIPT)
ccu = importlib.util.module_from_spec(_spec)
# Register before exec_module so @dataclass can resolve cls.__module__ via
# sys.modules (otherwise dataclass processing hits None.__dict__).
sys.modules[_spec.name] = ccu
_spec.loader.exec_module(ccu)


def _entry(current_tag, override=None):
    return ccu.Entry(
        file=Path("x"), container_key="k", var_name="v", var_line=0,
        current_value="", registry="docker.io", repo="library/x",
        current_tag=current_tag, image_template="", override=override,
    )


@pytest.mark.parametrize("tag,expected", [
    ("v1.2.3", (True, (1, 2, 3), "")),
    ("1.2.3", (False, (1, 2, 3), "")),
    ("1.2", (False, (1, 2), "")),
    ("v2", (True, (2,), "")),
    ("1.2.3-rc1", (False, (1, 2, 3), "-rc1")),
    ("1.2.3-alpine", (False, (1, 2, 3), "-alpine")),
    ("latest", None),
    ("1.2.3.4", None),  # 4 core parts not allowed
])
def test_parse_tag_shape(tag, expected):
    assert ccu.parse_tag_shape(tag) == expected


@pytest.mark.parametrize("tag,expected", [
    ("1.2.3-rc1", True),
    ("v1.2.3-beta.2", True),
    ("abcdef0", True),         # 7-char hex sha
    ("20240131", True),        # ISO yyyymmdd
    ("1.2.3-sha-deadbee", True),
    ("1.2.3", False),
    ("1.2.3-alpine", False),   # alpine is not a pre-release keyword
    ("abcdef", False),         # 6 hex < 7 -> not a sha
])
def test_looks_prerelease(tag, expected):
    assert ccu.looks_prerelease(tag) is expected


@pytest.mark.parametrize("suffix,expected", [
    ("-rc2", True),
    ("-beta.1", True),
    ("-rc", True),
    ("-preview", True),
    ("-alpine", False),
    ("-1", False),
    ("", False),
])
def test_is_prerelease_suffix(suffix, expected):
    assert ccu.is_prerelease_suffix(suffix) is expected


@pytest.mark.parametrize("resolved,expected", [
    ("nginx:1.21", ("docker.io", "library/nginx", "1.21")),
    ("redis", ("docker.io", "library/redis", "")),
    ("myorg/myimage:tag", ("docker.io", "myorg/myimage", "tag")),
    ("ghcr.io/foo/bar:v1.2", ("ghcr.io", "foo/bar", "v1.2")),
    ("lscr.io/linuxserver/jellyfin:latest",
     ("lscr.io", "linuxserver/jellyfin", "latest")),
])
def test_parse_image_string(resolved, expected):
    assert ccu.parse_image_string(resolved) == expected


@pytest.mark.parametrize("text,bindings,expected", [
    ("${a}.${b}", {"a": "1", "b": "2"}, "1.2"),
    ("no-vars", {}, "no-vars"),
    ("${a}", {"b": "x"}, None),                 # unknown var -> None
    ("${a}", {"a": "${b}", "b": "5"}, "5"),     # nested, resolves within depth
])
def test_resolve_recursive(text, bindings, expected):
    assert ccu.resolve_recursive(text, bindings) == expected


@pytest.mark.parametrize("current,tags,major_only,expected", [
    ("1.2.3", ["1.2.4", "1.3.0", "1.2.3", "1.2.2"], False, "1.3.0"),
    ("1.2.3", ["1.2.3"], False, None),                     # up-to-date
    ("1.2.3", ["1.2.4", "2.0.0"], True, "1.2.4"),          # major pinned -> 2.0.0 dropped
    ("1.2.3", ["1.2.4-rc1", "1.2.4"], False, "1.2.4"),     # rc dropped
    ("1.2", ["1.3", "1.2.5"], False, "1.3"),               # precision must match
    ("v1.2.3", ["v1.2.4", "1.2.4"], False, "v1.2.4"),      # v-prefix must match
])
def test_pick_latest(current, tags, major_only, expected):
    latest, _ = ccu.pick_latest(
        _entry(current), tags, include_prerelease=False, major_only=major_only,
    )
    assert latest == expected
