# pyright: reportMissingImports=false, reportArgumentType=false, reportOptionalMemberAccess=false
"""Unit tests for the strict-overlay YAML merge in
apps/home-assistant/merge-ha-yaml.py (loaded by path — hyphenated name).

Pins the merge semantics: dict keys overlay recursively, id-keyed lists merge
by id (defaults replace same-id, target-only entries preserved), everything
else is full-replace by defaults.
"""
import importlib.util
import sys
from pathlib import Path

_SCRIPT = Path(__file__).resolve().parent.parent / "merge-ha-yaml.py"
_spec = importlib.util.spec_from_file_location("merge_ha_yaml", _SCRIPT)
mhy = importlib.util.module_from_spec(_spec)
sys.modules[_spec.name] = mhy
_spec.loader.exec_module(mhy)

import pytest


@pytest.mark.parametrize("lst,expected", [
    ([{"id": 1}, {"id": 2}], True),
    ([], False),
    ([{"id": 1}, {"x": 2}], False),   # second entry lacks id
    ([{"id": 1}, "str"], False),      # not all dicts
    ([{"a": 1}], False),
])
def test_has_id_field(lst, expected):
    assert mhy.has_id_field(lst) is expected


def test_merge_none_passthrough():
    assert mhy.merge({"a": 1}, None) == {"a": 1}      # defaults None -> target
    assert mhy.merge(None, {"a": 1}) == {"a": 1}      # target None -> defaults


def test_merge_dict_overlay():
    assert mhy.merge({"a": 1, "b": 2}, {"b": 3, "c": 4}) == {"a": 1, "b": 3, "c": 4}


def test_merge_dict_recursive():
    assert mhy.merge({"x": {"a": 1, "b": 2}}, {"x": {"b": 9}}) == {"x": {"a": 1, "b": 9}}


def test_merge_dict_scalar_replaces_subtree():
    # defaults' scalar at a key replaces target's dict there (no recursion).
    assert mhy.merge({"x": {"a": 1}}, {"x": 5}) == {"x": 5}


def test_merge_id_keyed_lists():
    target = [{"id": "a", "v": 1}, {"id": "b", "v": 2}]
    defaults = [{"id": "b", "v": 9}, {"id": "c", "v": 3}]
    # 'a' (target-only) preserved; 'b' replaced by defaults; 'c' added.
    assert mhy.merge(target, defaults) == [
        {"id": "a", "v": 1},
        {"id": "b", "v": 9},
        {"id": "c", "v": 3},
    ]


def test_merge_plain_lists_full_replace():
    assert mhy.merge([1, 2], [3, 4]) == [3, 4]


def test_merge_scalar_defaults_wins():
    assert mhy.merge(5, 7) == 7


def test_merge_type_mismatch_defaults_wins():
    assert mhy.merge({"a": 1}, [1, 2]) == [1, 2]
