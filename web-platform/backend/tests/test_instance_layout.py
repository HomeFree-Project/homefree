"""Unit tests for services/instance_layout.detect_drift().

These pin the divergence-detection contract that both the Build & Logs
warning and the `config-divergence` alert source rely on:

  * a clean /etc/nixos (only the managed set) reports ok=True;
  * a tree mirroring a real box's leak (the 10.0.0.1 case:
    home-assistant.nix + ha/ + storage-disk-selftest.nix +
    homefree-encryption.nix, imported from configuration.nix) is flagged;
  * timestamped backups, dotfiles, and assets referenced by
    homefree-config.json (images/) are whitelisted, never flagged;
  * configuration.nix imports of non-managed modules are reported.
"""
import json

from services import instance_layout as il


def _write(p, text=""):
    p.write_text(text)


def _clean_tree(root):
    """Materialise a minimal healthy /etc/nixos under `root`."""
    for name in (
        "flake.nix", "flake.lock", "homefree-config.json",
        "disko.nix", "hardware-configuration.nix", "custom-flakes.nix",
        ".gitignore", "AGENTS.md", "CLAUDE.md",
    ):
        _write(root / name, "# managed\n")
    _write(root / "configuration.nix", _CONFIG_NIX_CLEAN)
    (root / "secrets").mkdir()
    (root / ".git").mkdir()
    _write(root / "homefree-config.json", json.dumps({
        "system": {"domain": "example.test"},
        "apps": {"mediawiki": {"logo-path": "/etc/nixos/images/logo.png"}},
    }))


_CONFIG_NIX_CLEAN = """{ config, pkgs, ... }:
{
  imports = [
    ./hardware-configuration.nix
    ./disko.nix
    ./development-overrides.nix
  ];
  system.stateVersion = "24.05";
}
"""

_CONFIG_NIX_LEAK = """{ config, pkgs, ... }:
{
  imports = [
    ./hardware-configuration.nix
    ./disko.nix
    ./development-overrides.nix
    ./home-assistant.nix
    ./storage-disk-selftest.nix
  ];
  system.stateVersion = "24.05";
}
"""


def test_clean_tree_is_ok(tmp_path):
    _clean_tree(tmp_path)
    # development-overrides.nix is a conditional managed file; present here.
    _write(tmp_path / "development-overrides.nix", "{ ... }: {}\n")
    drift = il.detect_drift(str(tmp_path))
    assert drift["ok"] is True
    assert drift["unmanaged_files"] == []
    assert drift["unmanaged_imports"] == []
    assert drift["missing_managed"] == []


def test_box_leak_is_flagged(tmp_path):
    """Mirror the real 10.0.0.1 leak."""
    _clean_tree(tmp_path)
    _write(tmp_path / "development-overrides.nix", "{ ... }: {}\n")
    _write(tmp_path / "configuration.nix", _CONFIG_NIX_LEAK)
    # The leaked instance modules + their asset dir.
    _write(tmp_path / "home-assistant.nix", "{ ... }: {}\n")
    _write(tmp_path / "storage-disk-selftest.nix", "{ ... }: {}\n")
    _write(tmp_path / "homefree-encryption.nix", "{ ... }: {}\n")
    (tmp_path / "ha").mkdir()
    _write(tmp_path / "ha" / "configuration.extra.yaml", "x: 1\n")

    drift = il.detect_drift(str(tmp_path))
    assert drift["ok"] is False
    assert drift["unmanaged_files"] == [
        "ha", "home-assistant.nix", "homefree-encryption.nix",
        "storage-disk-selftest.nix",
    ]
    assert drift["unmanaged_imports"] == [
        "./home-assistant.nix", "./storage-disk-selftest.nix",
    ]


def test_backups_and_dotfiles_whitelisted(tmp_path):
    _clean_tree(tmp_path)
    # The kinds of backups that actually litter a live box's /etc/nixos.
    for name in (
        "configuration.nix.bak.boot-mirror",
        "custom-flakes.nix.bak",
        "flake.lock.bak-relock-20260609-122659",
        "flake.lock.pre-strip-homefree-alt",
        "flake.nix.pre-local",
        "homefree-config.json.backup-20260526-165013",
        "homefree-config.json.bak.20260603-202047",
        "homefree-config.json.pre-kvm-cat",
    ):
        _write(tmp_path / name, "backup\n")
    (tmp_path / "secrets.pre-restore-merge").mkdir()
    _write(tmp_path / ".sops.yaml", "creation_rules: []\n")
    drift = il.detect_drift(str(tmp_path))
    assert drift["ok"] is True, drift["unmanaged_files"]


def test_referenced_asset_dir_whitelisted(tmp_path):
    _clean_tree(tmp_path)
    # homefree-config.json references /etc/nixos/images/logo.png (see
    # _clean_tree), so the images/ dir must NOT be flagged.
    (tmp_path / "images").mkdir()
    _write(tmp_path / "images" / "logo.png", "PNG")
    drift = il.detect_drift(str(tmp_path))
    assert "images" not in drift["unmanaged_files"]
    assert drift["ok"] is True


def test_missing_required_flagged(tmp_path):
    _clean_tree(tmp_path)
    (tmp_path / "disko.nix").unlink()
    drift = il.detect_drift(str(tmp_path))
    assert drift["ok"] is False
    assert "disko.nix" in drift["missing_managed"]


def test_missing_agents_doc_is_not_drift(tmp_path):
    """A box that hasn't rebuilt onto the docs-emitting code lacks
    AGENTS.md/CLAUDE.md; that alone must not register as drift."""
    _clean_tree(tmp_path)
    (tmp_path / "AGENTS.md").unlink()
    (tmp_path / "CLAUDE.md").unlink()
    drift = il.detect_drift(str(tmp_path))
    assert drift["ok"] is True


def test_nonexistent_tree_is_ok(tmp_path):
    drift = il.detect_drift(str(tmp_path / "does-not-exist"))
    assert drift["ok"] is True


def test_summarize_drift():
    assert il.summarize_drift({"ok": True}) == ""
    s = il.summarize_drift({
        "ok": False,
        "unmanaged_files": ["home-assistant.nix", "ha"],
        "unmanaged_imports": ["./home-assistant.nix"],
        "missing_managed": [],
    })
    assert "2 unmanaged file(s)" in s
    assert "home-assistant.nix" in s
    assert "configuration.nix imports" in s


# ─── Canonical flake.nix shape: installer ↔ scaffolder agreement ──────
#
# These lock the Phase-5 unification: the installer (services/install.py)
# and the admin scaffolder (services/plugins.py `_scaffold_text`) both go
# through this one FLAKE_TEMPLATE / render_flake_nix, so they can't drift.

# The substitution params for prod / dev / Secure-Boot installs.
_FLAKE_CASES = {
    "prod": dict(hostname="homefree"),
    "dev": dict(
        hostname="homefree",
        base_override_region='\n    homefree-alt.url = "git+file:///home/nixos/homefree";',
        base_binding_target="homefree-alt",
    ),
    "lanzaboote": dict(
        hostname="homefree",
        lanzaboote_input=(
            '\n    lanzaboote.url = "github:nix-community/lanzaboote/v0.4.3";'
            '\n    lanzaboote.inputs.nixpkgs.follows = "nixpkgs";'
        ),
        lanzaboote_output_arg=", lanzaboote",
        lanzaboote_module="\n          lanzaboote.nixosModules.lanzaboote",
    ),
}


def test_flake_template_embeds_canonical_sentinels():
    for s in (
        il.INPUTS_BEGIN, il.INPUTS_END,
        il.BASE_OVERRIDE_BEGIN, il.BASE_OVERRIDE_END,
        il.BASE_BINDING_BEGIN, il.BASE_BINDING_END,
    ):
        assert s in il.FLAKE_TEMPLATE, f"sentinel not in FLAKE_TEMPLATE: {s!r}"


def test_render_flake_nix_leaves_no_markers():
    for params in _FLAKE_CASES.values():
        assert "@@" not in il.render_flake_nix(**params)


def test_plugins_imports_canonical_sentinels():
    # plugins.py must use instance_layout's sentinels, not its own copy.
    from services import plugins as pl
    assert pl.INPUTS_BEGIN is il.INPUTS_BEGIN
    assert pl.BASE_BINDING_END is il.BASE_BINDING_END


def test_installer_flake_is_scaffold_fixed_point():
    """The installer's rendered flake.nix is a fixed point of the admin
    scaffolder — i.e. the two produce the SAME managed shape. If someone
    edits FLAKE_TEMPLATE or _scaffold_text without the other, this fails."""
    from services.plugins import PluginsService
    for name, params in _FLAKE_CASES.items():
        rendered = il.render_flake_nix(**params)
        scaffolded = PluginsService._scaffold_text(rendered)
        assert scaffolded == rendered, (
            f"installer/scaffolder drift for '{name}': _scaffold_text changed "
            "render_flake_nix output"
        )
