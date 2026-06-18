"""Unit tests for NixOperations.build_input_owners().

Pins the per-source attribution that decides which admin-UI nav item gets the
"undeployed changes" dot when a flake / build input (not homefree-config.json)
diverges from the last applied build:

  * homefree-base — a remote HomeFree re-pin (Updates page "Update to latest")
  * homefree-alt  — the alternate HomeFree repository (Source Code page)
  * plugins       — a registered plugin / custom flake (Plugins page)

The manifest computation (_build_inputs_manifest) and the alt-dir resolution
(_alt_base_dir) are stubbed so these tests exercise only the attribution logic;
the heavier machinery is covered where it lives.
"""
import json

import pytest

from services.nix_operations import NixOperations
from services.system_updates import SystemUpdates

# A baseline applied manifest (no local inputs) the cases tweak from.
_BASE = {"flake.nix": "nix0", "custom-flakes.nix": "cf0", "flake.lock": "lock0"}


@pytest.fixture
def configure(tmp_path, monkeypatch):
    """Stub the applied snapshot + current manifest + flake rev + alt dir.

    Returns a callable: configure(applied=, current=, applied_rev=,
    current_rev=, alt_dir=). Omitting `applied` leaves the snapshot file
    absent (the pre-feature box case).
    """
    applied_file = tmp_path / "applied-build-inputs.json"
    rev_file = tmp_path / "applied-flake-rev"
    monkeypatch.setattr(NixOperations, "APPLIED_BUILD_INPUTS_FILE", applied_file)
    monkeypatch.setattr(SystemUpdates, "APPLIED_FLAKE_REV_FILE", rev_file)

    def _configure(applied=None, current=None, applied_rev="r1",
                   current_rev="r1", alt_dir=None):
        if applied is not None:
            applied_file.write_text(json.dumps(applied))
        if applied_rev is not None:
            rev_file.write_text(applied_rev)
        monkeypatch.setattr(
            NixOperations, "_build_inputs_manifest", lambda: dict(current or {}))
        monkeypatch.setattr(
            SystemUpdates, "get_current",
            lambda: {"rev": current_rev} if current_rev else None)
        monkeypatch.setattr(NixOperations, "_alt_base_dir", lambda: alt_dir)

    return _configure


def test_base_rev_bump_only(configure):
    # Updates page bumped homefree-base: flake.lock moved AND the rev differs.
    configure(
        applied={**_BASE},
        current={**_BASE, "flake.lock": "lock1"},
        applied_rev="r0", current_rev="r1",
    )
    # The lock change is explained by the base re-pin → Updates only, no Plugins.
    assert NixOperations.build_input_owners() == ["homefree-base"]


def test_plugin_remote_update(configure):
    # Plugins page re-locked a remote flake: flake.lock moved, base rev unchanged.
    configure(
        applied={**_BASE},
        current={**_BASE, "flake.lock": "lock1"},
        applied_rev="r1", current_rev="r1",
    )
    assert NixOperations.build_input_owners() == ["plugins"]


def test_register_plugin_touches_custom_flakes(configure):
    # Registering a plugin rewrites flake.nix inputs AND custom-flakes.nix.
    configure(
        applied={**_BASE},
        current={"flake.nix": "nix1", "custom-flakes.nix": "cf1", "flake.lock": "lock0"},
    )
    assert NixOperations.build_input_owners() == ["plugins"]


def test_alt_base_toggle_is_flake_nix_only(configure):
    # Enabling/disabling the alt base rewrites flake.nix's managed regions only.
    configure(
        applied={**_BASE},
        current={**_BASE, "flake.nix": "nix1"},
    )
    assert NixOperations.build_input_owners() == ["homefree-alt"]


def test_alt_local_repo_edit(configure):
    # Editing the enabled local alternate repo moves its working-tree fingerprint.
    configure(
        applied={**_BASE, "local-inputs": {"/alt": "f0", "/plugin": "g0"}},
        current={**_BASE, "local-inputs": {"/alt": "f1", "/plugin": "g0"}},
        alt_dir="/alt",
    )
    assert NixOperations.build_input_owners() == ["homefree-alt"]


def test_local_plugin_edit(configure):
    # Editing a local plugin flake (not the alt repo) → Plugins.
    configure(
        applied={**_BASE, "local-inputs": {"/alt": "f0", "/plugin": "g0"}},
        current={**_BASE, "local-inputs": {"/alt": "f0", "/plugin": "g1"}},
        alt_dir="/alt",
    )
    assert NixOperations.build_input_owners() == ["plugins"]


def test_local_edit_without_alt_base_is_plugins(configure):
    # No alternate base configured → any local-input edit is a plugin flake.
    configure(
        applied={**_BASE, "local-inputs": {"/plugin": "g0"}},
        current={**_BASE, "local-inputs": {"/plugin": "g1"}},
        alt_dir=None,
    )
    assert NixOperations.build_input_owners() == ["plugins"]


def test_clean_state_has_no_owners(configure):
    configure(applied={**_BASE}, current={**_BASE})
    assert NixOperations.build_input_owners() == []


def test_no_applied_snapshot_returns_empty(configure):
    # Box upgraded into the feature before its first rebuild: no snapshot yet.
    configure(applied=None, current={**_BASE, "flake.lock": "lock1"})
    assert NixOperations.build_input_owners() == []


def test_base_bump_and_plugin_register_both_dotted(configure):
    # Distinct signals (rev + custom-flakes.nix) are independently attributed.
    configure(
        applied={**_BASE},
        current={"flake.nix": "nix1", "custom-flakes.nix": "cf1", "flake.lock": "lock1"},
        applied_rev="r0", current_rev="r1",
    )
    owners = NixOperations.build_input_owners()
    assert set(owners) == {"homefree-base", "plugins"}
