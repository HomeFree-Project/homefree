"""
instance_layout.py — canonical definition of a HomeFree box's /etc/nixos
"managed layout", and detection of operator DRIFT.

A box's /etc/nixos is *instance state*, but its STRUCTURE (which files
HomeFree owns) is shared knowledge. Historically that knowledge was
duplicated across the installer (services/install.py templates), the
admin scaffolder (services/plugins.py) and the build flow
(services/nix_operations.py), so a hand-added `.nix` module could leak
into /etc/nixos and stay invisible — exactly what rule 12 in AGENTS.md
warns against.

This module is the single source of truth for the managed file set and
for `detect_drift()`. It is consumed by:

  - the drift warning on the admin Build & Logs page (via the
    /api/config/dirty aggregator), and
  - the `config-divergence` alert source (services/alerts_sources.py).

Both surfaces call `detect_drift()` so they can never disagree.

Remediation policy: detection here is ADVISORY ONLY. Nothing in this
module ever deletes or rewrites an operator's unmanaged files. The build
re-materializes MANAGED structure elsewhere (AGENTS.md / CLAUDE.md via an
activation script in modules/instance-managed-docs.nix; flake.nix managed
regions via the idempotent scaffolder in services/plugins.py).
"""

import json
import logging
import re
from pathlib import Path
from typing import Any, Dict, List, Set

logger = logging.getLogger(__name__)

DEFAULT_ETC_NIXOS = "/etc/nixos"

# Visible files HomeFree owns in a box's /etc/nixos. Anything here is
# never reported as "unmanaged". Conditional/generated members (flake.lock,
# secureboot.nix, development-overrides.nix) are legitimately absent on some
# boxes — present-or-absent, both fine — so they live here but NOT in
# REQUIRED_NAMES below.
#
# Keep AGENTS.md / CLAUDE.md here so the docs materialised by
# modules/instance-managed-docs.nix are never flagged. They are NOT in
# REQUIRED_NAMES: a box that has not yet rebuilt onto the docs-emitting
# code simply lacks them, and nagging about that on every poll would be
# noise (the next rebuild creates them).
MANAGED_NAMES: Set[str] = {
    "flake.nix",
    "flake.lock",
    "homefree-config.json",
    "configuration.nix",
    "disko.nix",
    "hardware-configuration.nix",
    "custom-flakes.nix",
    "secureboot.nix",
    "development-overrides.nix",
    "AGENTS.md",
    "CLAUDE.md",
    ".gitignore",
}

# Directories HomeFree owns / infra dirs that are never "unmanaged".
MANAGED_DIRS: Set[str] = {
    "secrets",  # gitignored; holds the LUKS recovery passphrase + keyfile
    ".git",     # /etc/nixos is a git repo (installer _init_git)
}

# The subset that MUST exist on every healthy box; absence is genuine
# drift worth surfacing. Deliberately conservative: custom-flakes.nix is
# guarded by `builtins.pathExists` in flake.nix and is legitimately absent
# on older installs, so it is not required.
REQUIRED_NAMES: Set[str] = {
    "flake.nix",
    "homefree-config.json",
    "configuration.nix",
    "disko.nix",
    "hardware-configuration.nix",
}

# Timestamped backups HomeFree (and operators) leave behind during
# mutations — `.bak`, `.backup-...`, `.pre-...`, `-backup-...`, editor
# `~`/`.orig`/`.old`. These are not drift; whitelist generously (an
# under-flagged backup is far better than nagging about dozens of them).
_BACKUP_RE = re.compile(
    r"(\.bak(\b|[.\-])|\.backup(\b|[.\-])|\.pre-|-backup-|\.orig$|\.old$|~$)"
)

# A /etc/nixos/<component>/... reference inside homefree-config.json. The
# loader rebases such paths onto the instance dir (e.g. the mediawiki logo,
# user images). The first path component is a top-level entry we must
# whitelist (e.g. `images`).
_ETC_NIXOS_REF_RE = re.compile(r"/etc/nixos/([A-Za-z0-9_.][A-Za-z0-9_.\-]*)")


def detect_drift(etc_nixos: str = DEFAULT_ETC_NIXOS) -> Dict[str, Any]:
    """Inspect /etc/nixos and report divergence from the managed layout.

    Returns a structured dict (JSON-serialisable):

      {
        "unmanaged_files":   ["ha", "home-assistant.nix", ...],   # sorted
        "unmanaged_imports": ["./home-assistant.nix", ...],       # sorted
        "missing_managed":   [],                                  # sorted
        "ok":                False,
      }

    `ok` is True iff none of the three lists has entries. Never raises;
    an unreadable tree returns an empty, ok=True result (advisory only —
    it must never break a poll or a rebuild).
    """
    result: Dict[str, Any] = {
        "unmanaged_files": [],
        "unmanaged_imports": [],
        "missing_managed": [],
        "ok": True,
    }
    try:
        root = Path(etc_nixos)
        if not root.is_dir():
            return result

        whitelist = _whitelisted_top_level(root)

        unmanaged: List[str] = []
        for entry in root.iterdir():
            name = entry.name
            if name in whitelist:
                continue
            if name.startswith("."):
                # Dotfiles are instance infra (.git, .gitignore, .sops.yaml).
                # A leaked config is a visible .nix module, never a dotfile.
                continue
            if _is_backup(name):
                continue
            unmanaged.append(name)

        missing = [n for n in REQUIRED_NAMES if not (root / n).exists()]
        foreign_imports = _foreign_configuration_imports(root)

        result["unmanaged_files"] = sorted(unmanaged)
        result["unmanaged_imports"] = sorted(foreign_imports)
        result["missing_managed"] = sorted(missing)
        result["ok"] = not (unmanaged or foreign_imports or missing)
    except Exception as e:  # pragma: no cover - defensive
        logger.warning("detect_drift failed (treating as ok): %s", e)
        return {
            "unmanaged_files": [],
            "unmanaged_imports": [],
            "missing_managed": [],
            "ok": True,
        }
    return result


def summarize_drift(drift: Dict[str, Any]) -> str:
    """One-line human summary for the dirty `reason` field and the alert
    message. Returns "" when there is nothing to report."""
    if not drift or drift.get("ok"):
        return ""
    parts: List[str] = []
    files = drift.get("unmanaged_files") or []
    if files:
        shown = ", ".join(files[:6])
        if len(files) > 6:
            shown += f" (+{len(files) - 6} more)"
        parts.append(f"{len(files)} unmanaged file(s) in /etc/nixos: {shown}")
    imports = drift.get("unmanaged_imports") or []
    if imports:
        parts.append(
            "configuration.nix imports non-managed module(s): "
            + ", ".join(imports)
        )
    missing = drift.get("missing_managed") or []
    if missing:
        parts.append("missing managed file(s): " + ", ".join(missing))
    return "; ".join(parts)


# ---------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------


def _whitelisted_top_level(root: Path) -> Set[str]:
    """Top-level /etc/nixos names that are never 'unmanaged': the managed
    file set, the managed dirs, plus any asset directory referenced by
    homefree-config.json (e.g. `images`)."""
    names = set(MANAGED_NAMES) | set(MANAGED_DIRS)
    names |= _referenced_asset_dirs(root)
    return names


def _referenced_asset_dirs(root: Path) -> Set[str]:
    """Collect the first path component of every /etc/nixos/<...> reference
    inside homefree-config.json, so operator assets the config legitimately
    points at (images, logos, ...) are not mistaken for leaked code."""
    cfg = _load_config_json(root)
    found: Set[str] = set()
    _collect_etc_nixos_refs(cfg, found)
    return found


def _collect_etc_nixos_refs(obj: Any, out: Set[str]) -> None:
    if isinstance(obj, dict):
        for v in obj.values():
            _collect_etc_nixos_refs(v, out)
    elif isinstance(obj, (list, tuple)):
        for v in obj:
            _collect_etc_nixos_refs(v, out)
    elif isinstance(obj, str):
        out.update(_ETC_NIXOS_REF_RE.findall(obj))


def _load_config_json(root: Path) -> Dict[str, Any]:
    """Read <root>/homefree-config.json directly (not via ConfigReader,
    which hardcodes /etc/nixos) so detect_drift works against a fixture
    tree in tests. Returns {} on any failure."""
    f = root / "homefree-config.json"
    try:
        return json.loads(f.read_text())
    except FileNotFoundError:
        return {}
    except Exception as e:
        logger.debug("instance_layout: config parse failed: %s", e)
        return {}


def _is_backup(name: str) -> bool:
    return bool(_BACKUP_RE.search(name))


def _foreign_configuration_imports(root: Path) -> List[str]:
    """Parse configuration.nix's `imports = [ ... ];` and return any
    `./X.nix` whose target is not a managed file — the primary way
    instance config leaks in (an `imports` line pulling a hand-added
    module). Catches leaks even when the leaked file was `git add`ed
    (which plain git-tracking would miss)."""
    cfgnix = root / "configuration.nix"
    if not cfgnix.exists():
        return []
    try:
        text = cfgnix.read_text(errors="replace")
    except Exception:
        return []

    m = re.search(r"\bimports\s*=\s*\[", text)
    if not m:
        return []
    open_idx = text.index("[", m.start())
    depth = 0
    close_idx = None
    for i in range(open_idx, len(text)):
        c = text[i]
        if c == "[":
            depth += 1
        elif c == "]":
            depth -= 1
            if depth == 0:
                close_idx = i
                break
    if close_idx is None:
        return []

    block = text[open_idx + 1:close_idx]
    block = re.sub(r"#.*", "", block)  # strip line comments

    foreign: List[str] = []
    known = MANAGED_NAMES
    for target in re.findall(r"\./([A-Za-z0-9_./\-]+)", block):
        if target in known:
            continue
        foreign.append("./" + target)
    return foreign


# ---------------------------------------------------------------------
# Canonical flake.nix shape (shared installer <-> scaffolder source)
# ---------------------------------------------------------------------
# The structure of a box's /etc/nixos/flake.nix is owned in ONE place:
#   - the installer (services/install.py) stamps a fresh tree from the
#     templates below, and
#   - the admin scaffolder (services/plugins.py `_scaffold_text`) migrates
#     an existing flake.nix to this same managed shape on every Apply.
# They are kept from drifting by test_instance_layout's fixed-point test:
#   _scaffold_text(render_flake_nix(...)) == render_flake_nix(...).
# The sentinel constants below are the SINGLE definition the scaffolder
# imports (plugins.py) and that the FLAKE_TEMPLATE embeds.

# Sentinel lines bracketing the managed region inside flake.nix `inputs`
# (registered custom/plugin flakes).
INPUTS_BEGIN = "    # >>> homefree-developers-inputs (managed - do not edit by hand) >>>"
INPUTS_END = "    # <<< homefree-developers-inputs <<<"

# Sentinels for the "alternate HomeFree base repo" feature: the input
# declaration (inside `inputs = { ... }`) and the binding line (inside the
# `outputs` let) that selects which input feeds `homefree`.
BASE_OVERRIDE_BEGIN = "    # >>> homefree-base-override (managed - do not edit by hand) >>>"
BASE_OVERRIDE_END = "    # <<< homefree-base-override <<<"
BASE_BINDING_BEGIN = "    # >>> homefree-base-binding (managed - do not edit by hand) >>>"
BASE_BINDING_END = "    # <<< homefree-base-binding <<<"

# Note: the disko *module* is NOT declared as an input here — the HomeFree
# base flake already imports `disko.nixosModules.disko` (see its default.nix).
# Importing it again would define `_module.args.diskoLib` twice and fail
# evaluation. We only import the generated ./disko.nix config file (via
# configuration.nix), which sets `disko.devices` on the module the base
# already provides.
#
# The `@@…@@` markers are filled in by render_flake_nix (and, equivalently,
# the installer's substitution loop in services/install.py).
FLAKE_TEMPLATE = """{
  description = "HomeFree NixOS Configuration";

  inputs = {
    # The system nixpkgs is NOT pinned per-instance: it follows the
    # HomeFree base flake's nixpkgs-unstable so every box shares the same
    # nixpkgs the homefree repo controls (bumped via the admin UI's
    # "Update flakes" button / a homefree-base revision bump), instead of
    # drifting on a per-instance flake.lock. homefree-base is always
    # declared below, so this follows resolves in both prod and dev mode.
    nixpkgs.follows = "homefree-base/nixpkgs-unstable";
    homefree-base.url = "git+https://git.homefree.host/homefree/homefree.git";@@lanzaboote_input@@
    # >>> homefree-base-override (managed - do not edit by hand) >>>@@base_override_region@@
    # <<< homefree-base-override <<<
    # >>> homefree-developers-inputs (managed - do not edit by hand) >>>
    homefree-navidrome.url = "git+https://git.homefree.host/homefree/homefree-navidrome.git";
    # <<< homefree-developers-inputs <<<
  };

  outputs = { self, nixpkgs, homefree-base@@lanzaboote_output_arg@@, ... }@inputs:
  let
    system = "x86_64-linux";
    # Custom developer flakes registered via the admin panel's
    # Developers section. `custom-flakes.nix` is regenerated by the
    # admin backend from homefree-config.json — never edit it by hand.
    # The pathExists guard keeps the build working when no flakes are
    # registered (the file may be absent on older installs).
    customFlakeModules =
      if builtins.pathExists ./custom-flakes.nix
      then import ./custom-flakes.nix { inherit inputs; }
      else [];
    # `homefree` selects which input the build uses for the HomeFree
    # base: the official `homefree-base`, or an alternate repo enabled
    # via the admin panel's Developers section. The admin backend
    # rewrites the region below — never edit it by hand.
    # >>> homefree-base-binding (managed - do not edit by hand) >>>
    homefree = inputs.@@base_binding_target@@;
    # <<< homefree-base-binding <<<
    # Per-instance config. homefree-config.json is the single source of
    # truth; the admin UI / installer write it. The shared homefree repo
    # module homefree-config-loader maps this parsed data into homefree.*
    # — there is NO generated homefree-configuration.nix anymore (the old
    # model went stale on a bare `nixos-rebuild switch`). We pass the
    # parsed JSON and this directory (for the mediawiki logo-path import,
    # which must resolve user assets under /etc/nixos) into the module
    # system via specialArgs.
    homefreeConfigJson = builtins.fromJSON (builtins.readFile ./homefree-config.json);
  in {
    nixosConfigurations = {
      # Build with the bound base's nixpkgs-unstable (homefree = the
      # selected base input, official or local dev) so the system tracks
      # the shared, centrally-controlled nixpkgs rather than a per-instance
      # pin. This mirrors the homefree repo's own nixosConfigurations.
      @@hostname@@ = homefree.inputs.nixpkgs-unstable.lib.nixosSystem {
        inherit system;
        modules = [
          homefree.nixosModules.homefree@@lanzaboote_module@@
          homefree.nixosModules.homefree-config-loader
          ./configuration.nix
        ] ++ customFlakeModules;
        specialArgs = {
          inherit system;
          homefree-inputs = homefree.inputs;
          inherit homefreeConfigJson;
          homefreeInstanceDir = ./.;
        };
      };
    };
  };
}
"""

# Initial custom-flakes.nix written at install time (regenerated by the
# admin Plugins panel from homefree-config.json `plugins.flakes`).
CUSTOM_FLAKES_TEMPLATE = """# GENERATED by HomeFree admin panel - do not edit by hand.
# Regenerated from homefree-config.json `developers.flakes`.
{ inputs }:
[
  (inputs.homefree-navidrome.nixosModules.default)
]
"""


# Substitution keys the installer fills in (network/encryption/etc. keys in
# the installer's variable dict simply don't appear here and are no-ops).
_FLAKE_SUBST_KEYS = (
    "hostname",
    "base_override_region",
    "base_binding_target",
    "lanzaboote_input",
    "lanzaboote_output_arg",
    "lanzaboote_module",
)


def render_flake_nix(
    hostname="homefree",
    base_override_region="",
    base_binding_target="homefree-base",
    lanzaboote_input="",
    lanzaboote_output_arg="",
    lanzaboote_module="",
):
    """Render the canonical /etc/nixos/flake.nix for the given instance
    params. This is the shape the scaffolder converges to; the installer
    uses the same FLAKE_TEMPLATE + substitution, so the two cannot drift
    (enforced by the fixed-point test in test_instance_layout)."""
    values = {
        "hostname": hostname,
        "base_override_region": base_override_region,
        "base_binding_target": base_binding_target,
        "lanzaboote_input": lanzaboote_input,
        "lanzaboote_output_arg": lanzaboote_output_arg,
        "lanzaboote_module": lanzaboote_module,
    }
    text = FLAKE_TEMPLATE
    for key in _FLAKE_SUBST_KEYS:
        text = text.replace("@@" + key + "@@", str(values[key]))
    return text
