"""Unit tests for the per-app version-tracking strategy framework
(resolvers/app_versions.py).

These pin the behaviour the framework promises:
  * the DEFAULT ("image") strategy is byte-for-byte the pre-existing path,
    so apps that declare no descriptor cannot drift;
  * `channel` correctly distinguishes a pre-release from a flavour stream,
    reshapes a pre-release anchor to its stable line, and can track a
    pre-release LINE (each beta build is its own tag shape);
  * a declared `current-version` is compared shape-agnostically (nixpkgs
    '0.26.1' vs upstream 'v0.26.1');
  * `none` surfaces as a distinct `untracked` status, not `unknown`;
  * the `command` escape hatch refuses anything but a /nix/store path.
"""
import asyncio

import pytest

from resolvers import app_versions as av


def run(coro):
    return asyncio.run(coro)


# ─── Pre-release detection / anchor reshape ───────────────────────────

@pytest.mark.parametrize("tag,expected", [
    ("v0.108.0-b.88", True),
    ("v1.2.3-rc1", True),
    ("1.2.3-beta", True),
    ("2.0.0-alpha2", True),
    ("33.0.5-apache", False),   # flavour, not pre-release
    ("0.10.1-nginx", False),
    ("1.2.3-bookworm", False),
    ("1.2.3-musl", False),
    ("v1.2.3", False),
])
def test_is_prerelease_tag(tag, expected):
    assert av._is_prerelease_tag(tag) is expected


def test_strip_prerelease_suffix():
    assert av._strip_prerelease_suffix("v0.108.0-b.88") == "v0.108.0"
    assert av._strip_prerelease_suffix("v0.108.0") == "v0.108.0"
    # A flavour suffix is NOT a pre-release, so it is left intact.
    assert av._strip_prerelease_suffix("33.0.5-apache") == "33.0.5-apache"


# ─── Picking under descriptor params ──────────────────────────────────

def _parsed(repo="vaultwarden/server", tag="1.36.0", registry="docker.io"):
    return {"registry": registry, "repo": repo, "tag": tag, "digest": ""}


def test_default_strict_pick_unchanged():
    # No params -> strict same-shape pick, exactly as before.
    got = av._pick_with_params(["1.36.0", "1.37.0", "1.35.0"], _parsed(), {})
    assert got == "1.37.0"


def test_stable_channel_drops_betas_and_reshapes_anchor():
    # Anchor is itself a beta ahead of the latest stable -> honest None
    # (no stable >= the beta), never a silent downgrade to the old stable.
    tags = ["v0.108.0-b.88", "v0.108.0-b.90", "v0.107.73", "v0.107.72"]
    p = _parsed(repo="adguard/adguardhome", tag="v0.108.0-b.88")
    assert av._pick_with_params(tags, p, {"channel": "stable"}) is None


def test_prerelease_channel_advances_beta_line():
    tags = ["v0.108.0-b.88", "v0.108.0-b.90", "v0.107.73"]
    p = _parsed(repo="adguard/adguardhome", tag="v0.108.0-b.88")
    assert av._pick_with_params(tags, p, {"channel": "prerelease"}) == "v0.108.0-b.90"


def test_loose_pick_matches_v_prefix_across_shapes():
    # Declared current-version (no 'v') vs upstream 'v…' tags.
    p = _parsed(repo="", tag="", registry="")
    params = {"current-version": "0.26.1"}
    assert av._pick_with_params(["v0.26.1", "v0.25.0", "v0.27.0"], p, params) == "v0.27.0"
    # A declared current-version may sit ABOVE the latest release; surface the
    # real latest release anyway (the row then reads up-to-date, not unknown).
    assert av._pick_with_params(["v0.25.0"], p, params) == "v0.25.0"


def test_tag_shape_v_prefix_normalised():
    # The single most common image-pin vs. GitHub-tag mismatch.
    assert av._tag_shape("0.17.1") == av._tag_shape("v0.17.1")
    # but a distinct prefix stream stays separate.
    assert av._tag_shape("4.6.0") != av._tag_shape("version-v4.6.0")


def test_frigate_v_prefix_fallback_resolves():
    # image pin '0.17.1' (no v) vs GitHub releases 'v0.17.x' now compare.
    p = _parsed(repo="blakeblackshear/frigate", tag="0.17.1", registry="ghcr.io")
    assert av._pick_with_params(["v0.17.1", "v0.17.2", "v0.16.0"], p, {}) == "v0.17.2"


def test_prerelease_anchor_keeps_no_downgrade_guard():
    # Image-tag pre-release anchor (no current-version): a below-anchor max
    # is the registry page-cap, NOT the operator being ahead -> None.
    p = _parsed(repo="adguard/adguardhome", tag="v0.108.0-b.90")
    assert av._pick_with_params(["v0.108.0-b.88", "v0.107.73"], p,
                                {"channel": "prerelease"}) is None


def test_numbered_prerelease_builds_sort_numerically():
    # adguard regression: '-b.9' must sort BELOW '-b.88'/'-b.90' (a string
    # compare picked build NINE as latest, which upgrade-apps then refused
    # as a numeric downgrade -> dead Update button).
    def t(tag):
        st = av._semver_tuple(tag)
        assert st is not None
        return st
    assert t("v0.108.0-b.9") < t("v0.108.0-b.88") < t("v0.108.0-b.90")
    # Plain release still sorts above any pre-release of the same base.
    assert t("v0.108.0") > t("v0.108.0-b.90")
    p = _parsed(repo="adguard/adguardhome", tag="v0.108.0-b.88")
    tags = ["v0.108.0-b.9", "v0.108.0-b.90", "v0.108.0-b.88", "v0.107.73"]
    assert av._pick_with_params(tags, p, {"channel": "prerelease"}) == "v0.108.0-b.90"
    # The real-world state (2026-06): b.88 IS the newest published build,
    # with old single-digit builds (b.8/b.9) still in the registry window.
    # The pick must come back as the pin itself -> the row reads
    # up-to-date, never "update available" to an ancient build.
    real = ["v0.108.0-b.88", "v0.108.0-b.87", "v0.108.0-b.86",
            "v0.108.0-b.9", "v0.108.0-b.8", "v0.107.65"]
    picked = av._pick_with_params(real, p, {"channel": "prerelease"})
    assert picked == "v0.108.0-b.88"
    assert av._same_release("v0.108.0-b.88", picked)


def test_capture_group_pattern_compares_compound_tags():
    # vectorchord: compare on the captured vectorchord version, recommend
    # the FULL pullable tag, stay on the pin's postgres major.
    p = _parsed(repo="immich-app/postgres",
                tag="18-vectorchord0.5.3-pgvector0.8.1", registry="ghcr.io")
    params = {"tag-pattern": r"^18-vectorchord([0-9.]+)-pgvector[0-9.]+$"}
    tags = [
        "18-vectorchord0.5.3-pgvector0.8.1",
        "18-vectorchord0.6.0-pgvector0.8.1",
        "17-vectorchord0.7.0-pgvector0.8.1",   # other pg major: excluded
        "18-vectorchord0.6.0-rc1-pgvector0.8.1",  # prerelease: excluded
    ]
    got = av._pick_with_params(tags, p, params)
    assert got == "18-vectorchord0.6.0-pgvector0.8.1"
    # Up-to-date case: anchor's captured version is the max -> anchor wins.
    got2 = av._pick_with_params(tags[:1], p, params)
    assert got2 == "18-vectorchord0.5.3-pgvector0.8.1"


def test_collapse_instance_rows(monkeypatch):
    # minecraft: two instance containers (one with a per-instance tag
    # override) collapse to ONE row tracking the SOURCE pin; redis-style
    # shared base images (ambiguous repo) stay per-container.
    monkeypatch.setattr(av, "_read_all_app_images", lambda: [
        {"app": "minecraft", "image": "itzg/minecraft-server:2026.5.0"},
        {"app": "nextcloud", "image": "redis:8.8.0"},
        {"app": "immich", "image": "redis:8.8.0"},
    ])
    rows = [
        {"key": "minecraft_minecraft", "name": "minecraft_minecraft",
         "image": "itzg/minecraft-server:2026.5.0", "enabled": True,
         "app": None, "descriptor": {"strategy": "image", "params": {}},
         "external": False},
        {"key": "minecraft_minecraft-cisco", "name": "minecraft_minecraft-cisco",
         "image": "itzg/minecraft-server:2026.5.0-java17", "enabled": True,
         "app": None, "descriptor": {"strategy": "image", "params": {}},
         "external": False},
        {"key": "nextcloud-redis", "name": "nextcloud-redis",
         "image": "redis:8.8.0", "enabled": True, "app": None,
         "descriptor": {"strategy": "image", "params": {}}, "external": False},
        {"key": "immich-redis", "name": "immich-redis",
         "image": "redis:8.8.0", "enabled": True, "app": None,
         "descriptor": {"strategy": "image", "params": {}}, "external": False},
    ]
    out, keys = av._collapse_instance_rows(rows, {})
    names = sorted(r["name"] for r in out)
    assert names == ["immich-redis", "minecraft", "nextcloud-redis"]
    mc = next(r for r in out if r["name"] == "minecraft")
    # The merged row tracks the SOURCE pin, not the instance override.
    assert mc["image"] == "itzg/minecraft-server:2026.5.0"
    assert mc["members"] == ["minecraft_minecraft", "minecraft_minecraft-cisco"]
    assert "minecraft" in keys


def test_collapse_uses_member_alias_descriptor(monkeypatch):
    # oauth2-proxy blue/green: app dir is zitadel (whose own label has a
    # default descriptor) — the member alias's declared descriptor wins,
    # and the merged name falls back to the repo basename because a
    # container named after the app dir already exists outside the group.
    monkeypatch.setattr(av, "_read_all_app_images", lambda: [
        {"app": "zitadel", "image": "oauth2-proxy/oauth2-proxy:v7.12.0"},
        {"app": "zitadel", "image": "ghcr.io/zitadel/zitadel:v4.15.1"},
    ])
    metadata = {
        "zitadel": {"version-tracking": {"strategy": "image"}},
        "oauth2-proxy-blue": {"version-tracking": {
            "strategy": "github-releases", "repo": "oauth2-proxy/oauth2-proxy"}},
    }
    rows = [
        {"key": "zitadel", "name": "zitadel",
         "image": "ghcr.io/zitadel/zitadel:v4.15.1", "enabled": True,
         "app": None, "descriptor": {"strategy": "image", "params": {}},
         "external": False},
        {"key": "oauth2-proxy-blue", "name": "oauth2-proxy-blue",
         "image": "oauth2-proxy/oauth2-proxy:v7.12.0", "enabled": True,
         "app": None, "descriptor": {"strategy": "github-releases", "params": {}},
         "external": False},
        {"key": "oauth2-proxy-green", "name": "oauth2-proxy-green",
         "image": "oauth2-proxy/oauth2-proxy:v7.12.0", "enabled": True,
         "app": None, "descriptor": {"strategy": "github-releases", "params": {}},
         "external": False},
    ]
    out, _ = av._collapse_instance_rows(rows, metadata)
    names = sorted(r["name"] for r in out)
    assert names == ["oauth2-proxy", "zitadel"]
    merged = next(r for r in out if r["name"] == "oauth2-proxy")
    assert merged["descriptor"]["strategy"] == "github-releases"


def test_update_command_makes_row_updatable(monkeypatch):
    # nzbget shape: loose current-version (normally Manual), but a
    # declared update-command makes the row one-click updatable.
    catalog = [
        {"key": "nzbget", "name": "nzbget",
         "image": "lscr.io/linuxserver/nzbget:version-v24.8", "enabled": True,
         "app": None,
         "descriptor": {"strategy": "github-releases",
                        "params": {"repo": "nzbgetcom/nzbget",
                                   "current-version": "24.8",
                                   "update-command": "/nix/store/abc-nzbget-update"}}},
    ]
    cache = {"nzbget": {"latest_tag": "v26.1", "note": None, "last_checked": 1}}
    monkeypatch.setattr(av, "_merged_catalog", lambda: catalog)
    monkeypatch.setattr(av, "_read_cache", lambda: cache)
    monkeypatch.setattr(av, "_read_service_metadata", lambda: {})
    row = av._build_payload()[0]
    assert row["status"] == "outdated"
    assert row["updatable"] is True


def test_run_custom_updater_contract(monkeypatch):
    import subprocess
    # store-path refusal
    import asyncio as aio
    with pytest.raises(Exception):
        aio.run(av._run_custom_updater("/usr/bin/evil", av.Path("/tmp"), "v1", "x"))

    class _Proc:
        returncode = 0
        stdout = "noise\nversion-v26.1\n"
        stderr = ""
    monkeypatch.setattr(subprocess, "run", lambda *a, **k: _Proc())
    res = aio.run(av._run_custom_updater(
        "/nix/store/abc-upd", av.Path("/tmp"), "v26.1", "nzbget", "24.8"))
    assert res["bumped"][0]["new_value"] == "version-v26.1"
    assert res["bumped"][0]["current_value"] == "24.8"
    assert res["exit_code"] == 2


def test_bare_flavour_aliases_are_floating():
    # `redis:alpine` rolls forward like `latest` — floating, not a failed
    # version lookup. Versioned flavours stay version tags.
    assert av._is_floating("alpine") is True
    assert av._is_floating("slim") is True
    assert av._is_floating("8.8.0-alpine") is False
    assert av._is_floating("alpine3.23") is False


def test_stable_anchor_survives_all_prerelease_window():
    # headscale mid-beta-cycle: releases.atom lists ONLY v0.29.0-beta.*
    # (plus junk tags) — the stable filter empties the candidate set. The
    # declared stable current-version is the newest known stable, so it is
    # returned as latest (-> up-to-date), not a perpetual unknown.
    p = _parsed(repo="", tag="", registry="")
    params = {"current-version": "0.28.0", "channel": "stable"}
    tags = ["v0.29.0-beta.2", "v0.29.0-beta.1", "backup-cleanup",
            "sshtests-with-followup-1778680862"]
    assert av._pick_with_params(tags, p, params) == "0.28.0"
    # But when a stable candidate IS in the window, it still wins.
    assert av._pick_with_params(tags + ["v0.28.0"], p, params) == "v0.28.0"
    # The fallback needs a STABLE declared anchor — a pre-release
    # current-version doesn't get promoted to "latest stable".
    pre = {"current-version": "0.29.0-beta.1", "channel": "stable"}
    assert av._pick_with_params(tags, p, pre) is None


def test_tag_pattern_filters_candidates():
    p = _parsed(repo="x/y", tag="2026.5.1")
    tags = ["2026.5.1", "2026.5.2", "nightly-2099.1.1"]
    # Pattern keeps only the dated stable line; the bogus 'nightly-' tag
    # would otherwise not parse but the filter makes intent explicit.
    got = av._pick_with_params(tags, p, {"tag-pattern": r"^\d{4}\.\d+\.\d+$"})
    assert got == "2026.5.2"


# ─── Descriptor resolution from metadata ──────────────────────────────

def test_descriptor_default_is_image():
    assert av._descriptor_for(None, "whatever", {}) == {"strategy": "image", "params": {}}


def test_descriptor_from_label_metadata():
    meta = {"unifi": {"version-tracking": {"strategy": "github-releases",
                                           "repo": "lemker/unifi-os-server"}}}
    # Enabled rows key on the container name; the admin-web alias makes the
    # primary container name resolve to the label's metadata, but here we
    # exercise the label key directly.
    d = av._descriptor_for("unifi", "unifi", meta)
    assert d["strategy"] == "github-releases"
    assert d["params"]["repo"] == "lemker/unifi-os-server"


# ─── Strategy dispatch (network mocked) ───────────────────────────────

def test_image_strategy_delegates_unchanged(monkeypatch):
    async def fake_fetch_latest(registry, repo, tag, digest=""):
        assert (registry, repo, tag) == ("docker.io", "vaultwarden/server", "1.36.0")
        return "1.37.0", None
    monkeypatch.setattr(av, "_fetch_latest", fake_fetch_latest)
    res = run(av._resolve_version({"strategy": "image", "params": {}}, _parsed()))
    assert res.latest == "1.37.0"
    assert res.note is None


def test_github_releases_strategy(monkeypatch):
    async def fake_tags(repo):
        assert repo == "lemker/unifi-os-server"
        return ["v1.2.0", "v1.3.0", "v1.1.0"]
    async def no_ghsa(repo):
        return []
    monkeypatch.setattr(av, "_fetch_github_release_tags", fake_tags)
    monkeypatch.setattr(av, "_fetch_ghsa", no_ghsa)
    desc = {"strategy": "github-releases", "params": {"repo": "lemker/unifi-os-server"}}
    res = run(av._resolve_version(desc, _parsed(repo="lemker/unifi-os-server",
                                               tag="v1.2.0", registry="ghcr.io")))
    assert res.latest == "v1.3.0"
    assert res.source_repo == "lemker/unifi-os-server"


def test_nixpkgs_strategy_anchors_on_current_version(monkeypatch):
    async def fake_tags(repo):
        return ["v0.26.1", "v0.27.0", "v0.25.0"]
    async def no_ghsa(repo):
        return []
    monkeypatch.setattr(av, "_fetch_github_release_tags", fake_tags)
    monkeypatch.setattr(av, "_fetch_ghsa", no_ghsa)
    desc = {"strategy": "nixpkgs",
            "params": {"repo": "juanfont/headscale", "current-version": "0.26.1"}}
    res = run(av._resolve_version(desc, {"registry": "", "repo": "", "tag": "", "digest": ""}))
    assert res.latest == "v0.27.0"


def test_none_strategy(monkeypatch):
    res = run(av._resolve_version({"strategy": "none", "params": {}}, _parsed()))
    assert res.latest is None
    assert "disabled" in (res.note or "")


def test_unknown_strategy_is_safe(monkeypatch):
    res = run(av._resolve_version({"strategy": "bogus", "params": {}}, _parsed()))
    assert res.latest is None
    assert "unknown version-tracking strategy" in (res.note or "")


def test_command_refuses_non_store_path():
    res = run(av._strategy_command(_parsed(), {"command": "/usr/bin/evil"}))
    assert res.latest is None
    assert "store path" in (res.note or "")


def test_command_happy_path(monkeypatch):
    class _Proc:
        returncode = 0
        stdout = "1.2.3\n"
        stderr = ""
    def fake_run(*a, **k):
        return _Proc()
    monkeypatch.setattr(av.asyncio, "to_thread",
                        lambda fn, *a, **k: _async(fn(*a, **k)))
    import subprocess
    monkeypatch.setattr(subprocess, "run", fake_run)
    res = run(av._strategy_command(_parsed(),
                                   {"command": "/nix/store/abc-version-check"}))
    assert res.latest == "1.2.3"


async def _async(v):
    return v


def test_external_rows_skip_pending_overlay_and_carry_flag(monkeypatch):
    # A plugin-provided row shares the repo's redis base image at an older
    # pin; the overlay must NOT flag it pending against this repo's pins,
    # and the payload must carry external=True for the frontend.
    catalog = [
        {"key": "grampsweb-redis", "name": "grampsweb-redis",
         "image": "docker.io/library/redis:8.6.0", "enabled": True,
         "app": None, "external": True,
         "descriptor": {"strategy": "image", "params": {}}},
    ]
    monkeypatch.setattr(av, "_merged_catalog", lambda: catalog)
    monkeypatch.setattr(av, "_read_cache", lambda: {})
    monkeypatch.setattr(av, "_read_service_metadata", lambda: {})
    monkeypatch.setattr(
        av, "_live_source_pins",
        lambda: {"docker.io/library/redis": "8.8.0"})
    rows = av._apply_pending_overlay(av._build_payload())
    row = rows[0]
    assert row["external"] is True
    assert row["pending"] is False
    assert row["current"] == "8.6.0"
    assert row["updatable"] is False


def test_uncached_row_explains_itself(monkeypatch):
    # A row with NO cache entry (renamed/merged key right after a rebuild,
    # before the next refresh) must say so instead of a bare "Unknown".
    catalog = [{"key": "minecraft", "name": "minecraft",
                "image": "itzg/minecraft-server:2026.5.0", "enabled": True,
                "app": "minecraft",
                "descriptor": {"strategy": "image", "params": {}}}]
    monkeypatch.setattr(av, "_merged_catalog", lambda: catalog)
    monkeypatch.setattr(av, "_read_cache", lambda: {})
    monkeypatch.setattr(av, "_read_service_metadata", lambda: {})
    row = av._build_payload()[0]
    assert row["status"] == "unknown"
    assert "not checked yet" in row["note"]


def test_sso_stack_rows_are_guarded(monkeypatch):
    # Every pin in apps/zitadel (zitadel, login UI, oauth2-proxy) is
    # skipped by upgrade-apps.py without --include-zitadel; the payload
    # mirrors that so the UI shows an SSO-guard pill, not a dead button.
    catalog = [
        {"key": "oauth2-proxy-blue", "name": "oauth2-proxy-blue",
         "image": "oauth2-proxy/oauth2-proxy:v7.12.0", "enabled": True,
         "app": None, "descriptor": {"strategy": "image", "params": {}}},
        {"key": "vaultwarden", "name": "vaultwarden",
         "image": "vaultwarden/server:1.36.0", "enabled": True,
         "app": None, "descriptor": {"strategy": "image", "params": {}}},
    ]
    cache = {
        "oauth2-proxy-blue": {"latest_tag": "v7.15.3", "note": None, "last_checked": 1},
        "vaultwarden": {"latest_tag": "1.37.0", "note": None, "last_checked": 1},
    }
    monkeypatch.setattr(av, "_merged_catalog", lambda: catalog)
    monkeypatch.setattr(av, "_read_cache", lambda: cache)
    monkeypatch.setattr(av, "_read_service_metadata", lambda: {})
    monkeypatch.setattr(av, "_read_all_app_images", lambda: [
        {"app": "zitadel", "image": "oauth2-proxy/oauth2-proxy:v7.12.0"},
        {"app": "vaultwarden", "image": "vaultwarden/server:1.36.0"},
    ])
    rows = {r["name"]: r for r in av._build_payload()}
    assert rows["oauth2-proxy-blue"]["guarded"] is True
    assert rows["oauth2-proxy-blue"]["updatable"] is False
    assert rows["vaultwarden"]["guarded"] is False
    assert rows["vaultwarden"]["updatable"] is True


def test_docker_hub_name_filter_resurfaces_buried_line(monkeypatch):
    # Flavour-heavy repo: the recent-100 window has no plain 8.8.x (only
    # backport patches + variants); the name=<major.minor> filter does.
    class _Resp:
        def __init__(self, data):
            self._d = data
        def raise_for_status(self):
            pass
        def json(self):
            return self._d

    class _Client:
        def __init__(self, *a, **k):
            pass
        async def __aenter__(self):
            return self
        async def __aexit__(self, *a):
            return False
        async def get(self, url, **k):
            if "name=8.8" in url:
                return _Resp({"results": [{"name": "8.8.0"}, {"name": "8.8.0-alpine"}]})
            return _Resp({"results": [{"name": "8.6.4"}, {"name": "8.8.0-bookworm"}]})

    monkeypatch.setattr(av.httpx, "AsyncClient", _Client)
    tags = run(av._fetch_docker_hub_tags("library/redis", "docker.io", "8.8.0"))
    assert "8.8.0" in tags
    p = _parsed(repo="library/redis", tag="8.8.0")
    assert av._pick_with_params(tags, p, {}) == "8.8.0"


# ─── _build_payload status ladder (catalog/cache/metadata mocked) ─────

def test_build_payload_statuses(monkeypatch):
    catalog = [
        # Default image app with a newer upstream -> outdated.
        {"key": "vaultwarden", "name": "vaultwarden",
         "image": "vaultwarden/server:1.36.0", "enabled": True, "app": None,
         "descriptor": {"strategy": "image", "params": {}}},
        # Explicit opt-out -> untracked (NOT unknown).
        {"key": "screeenly", "name": "screeenly",
         "image": "hadogenes/screeenly@sha256:" + "a" * 64,
         "enabled": True, "app": None,
         "descriptor": {"strategy": "none", "params": {}}},
        # Host app, declared current-version equal to latest -> up-to-date
        # across the v-prefix (loose compare).
        {"key": "headscale", "name": "headscale", "image": "",
         "enabled": True, "app": "headscale",
         "descriptor": {"strategy": "nixpkgs",
                        "params": {"repo": "juanfont/headscale",
                                   "current-version": "0.26.1"}}},
        # Host app, declared current-version below latest -> outdated.
        {"key": "opensprinkler", "name": "opensprinkler", "image": "",
         "enabled": True, "app": "opensprinkler",
         "descriptor": {"strategy": "github-releases",
                        "params": {"repo": "OpenSprinkler/OpenSprinkler-App",
                                   "current-version": "2.4.1"}}},
    ]
    cache = {
        "vaultwarden": {"latest_tag": "1.37.0", "note": None, "last_checked": 1},
        "screeenly": {"latest_tag": None, "note": "disabled", "last_checked": 1,
                      "strategy": "none"},
        "headscale": {"latest_tag": "v0.26.1", "note": None, "last_checked": 1},
        "opensprinkler": {"latest_tag": "v2.5.0", "note": None, "last_checked": 1},
    }
    metadata = {
        "headscale": {"project-name": "Headscale"},
        "opensprinkler": {"project-name": "OpenSprinkler"},
    }
    monkeypatch.setattr(av, "_merged_catalog", lambda: catalog)
    monkeypatch.setattr(av, "_read_cache", lambda: cache)
    monkeypatch.setattr(av, "_read_service_metadata", lambda: metadata)

    rows = {r["name"]: r for r in av._build_payload()}
    assert rows["vaultwarden"]["status"] == "outdated"
    assert rows["screeenly"]["status"] == "untracked"
    assert rows["headscale"]["status"] == "up-to-date"
    assert rows["headscale"]["current"] == "0.26.1"
    assert rows["opensprinkler"]["status"] == "outdated"
    assert rows["opensprinkler"]["current"] == "2.4.1"
    assert rows["opensprinkler"]["latest"] == "v2.5.0"
    # One-click bumpable only when `current` IS an image pin in this repo:
    # vaultwarden yes; a declared current-version (vendored/nixpkgs) no.
    assert rows["vaultwarden"]["updatable"] is True
    assert rows["opensprinkler"]["updatable"] is False
    assert rows["headscale"]["updatable"] is False


def test_build_payload_current_ahead_of_release_is_up_to_date(monkeypatch):
    # A host app whose nixpkgs build (0.28.0) is AHEAD of the latest upstream
    # RELEASE (v0.26.1) reads up-to-date, not outdated/unknown.
    catalog = [
        {"key": "headscale", "name": "headscale", "image": "",
         "enabled": True, "app": "headscale",
         "descriptor": {"strategy": "nixpkgs",
                        "params": {"repo": "juanfont/headscale",
                                   "current-version": "0.28.0"}}},
    ]
    cache = {"headscale": {"latest_tag": "v0.26.1", "note": None, "last_checked": 1}}
    monkeypatch.setattr(av, "_merged_catalog", lambda: catalog)
    monkeypatch.setattr(av, "_read_cache", lambda: cache)
    monkeypatch.setattr(av, "_read_service_metadata",
                        lambda: {"headscale": {"project-name": "Headscale"}})
    row = {r["name"]: r for r in av._build_payload()}["headscale"]
    assert row["status"] == "up-to-date"
    assert row["current"] == "0.28.0"
    assert row["latest"] == "v0.26.1"
