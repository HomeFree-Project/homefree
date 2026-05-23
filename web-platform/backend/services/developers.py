"""
Developers service - register custom Nix flakes that extend the system.

A HomeFree install normally tracks the upstream `homefree-base` flake and
pulls releases via the update mechanism. This service lets an admin ALSO
compose their own flakes' `nixosModules` into the build, so they can run
custom apps/modules without forking and without losing upstream updates.

The mechanism (see web-platform/backend/services/install.py FLAKE_TEMPLATE):

  * /etc/nixos/flake.nix carries a sentinel-delimited "managed inputs"
    region. We rewrite ONLY the text between the markers — one
    `<inputName>.url = "<url>";` line per enabled flake. A flake's inputs
    are fetched before `outputs` is evaluated, so the input URLs MUST be
    literal text in flake.nix; they cannot be JSON-driven.

  * /etc/nixos/custom-flakes.nix is a generated side file that flake.nix
    imports. It receives the whole `inputs` set and returns the list of
    custom nixosModules to append to the build. Because flake.nix's
    `outputs` lambda already captures `}@inputs`, custom inputs never need
    adding to the outputs argument list — only this side file changes.

`ensure_scaffold()` makes both pieces idempotently present on installs
that predate this feature.
"""

import json
import logging
import re
import shutil
import subprocess
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

from services.config_reader import ConfigReader
from services.config_writer import ConfigWriter

logger = logging.getLogger(__name__)


# Sentinel lines bracketing the managed region inside flake.nix `inputs`.
INPUTS_BEGIN = "    # >>> homefree-developers-inputs (managed - do not edit by hand) >>>"
INPUTS_END = "    # <<< homefree-developers-inputs <<<"

# Sentinel lines for the "alternate HomeFree base repo" feature. Two managed
# regions: the input declaration (inside `inputs = { ... }`, 4-space indent)
# and the binding line (inside the `outputs` `let`, 2-space indent) that
# selects which input the build uses for `homefree`.
BASE_OVERRIDE_BEGIN = "    # >>> homefree-base-override (managed - do not edit by hand) >>>"
BASE_OVERRIDE_END = "    # <<< homefree-base-override <<<"
BASE_BINDING_BEGIN = "    # >>> homefree-base-binding (managed - do not edit by hand) >>>"
BASE_BINDING_END = "    # <<< homefree-base-binding <<<"

# The input name a registered alternate HomeFree repo is declared under.
ALT_INPUT_NAME = "homefree-alt"

# The official HomeFree repository — what `homefree-base` always points at,
# and what the build uses when no alternate base is enabled.
OFFICIAL_HOMEFREE_URL = "git+https://git.homefree.host/homefree/homefree.git"

# Input names already used by the generated flake.nix / its outputs args /
# its let-block. Registering a custom flake under one of these would shadow
# a real input and break the build, so they are rejected at validation.
RESERVED_INPUT_NAMES = {
    "nixpkgs", "homefree-base", "homefree-local", "homefree", "homefree-alt",
    "lanzaboote", "disko", "self",
}

# Same filesystem whitelist the /api/filesystem/browse endpoint enforces.
ALLOWED_LOCAL_ROOTS = ["/home", "/mnt", "/var/lib", "/media", "/srv", "/opt"]

# Recognised remote flake-ref URL prefixes.
# Flake-ref prefixes accepted for a remote entry AFTER normalization.
# A bare https:// / http:// is intentionally absent: Nix would treat it
# as a TARBALL fetch, not a git repo, so _normalize_remote_url rewrites
# it (to a github:/gitlab: shorthand or a git+https:// ref) before it is
# ever validated or stored.
_REMOTE_PREFIXES = (
    "github:", "gitlab:", "sourcehut:", "git+https://", "git+ssh://",
    "git+http://", "path:", "flake:", "tarball+https://",
)

# References _normalize_remote_url leaves untouched (already fetchable).
_FLAKE_REF_PREFIXES = _REMOTE_PREFIXES + ("git+file://", "tarball+http://")

# scp-style SSH shorthand: user@host:path  (e.g. git@github.com:o/r.git).
_SCP_SSH_RE = re.compile(r"^(?P<user>[^@/]+)@(?P<host>[^:/]+):(?P<path>.+)$")

_INPUT_NAME_RE = re.compile(r"^[a-zA-Z][a-zA-Z0-9_-]*$")


class DevelopersService:
    """Register/unregister custom flakes and keep /etc/nixos in sync."""

    FLAKE_DIR = Path("/etc/nixos")
    FLAKE_FILE = FLAKE_DIR / "flake.nix"
    CUSTOM_FLAKES_FILE = FLAKE_DIR / "custom-flakes.nix"
    BACKUP_DIR = Path("/var/lib/homefree-admin/config-backups")

    # ---- reading -----------------------------------------------------

    @staticmethod
    def list_flakes() -> List[Dict[str, Any]]:
        """Return the registered custom flakes (empty list if none)."""
        config = ConfigReader.read_config()
        developers = config.get("developers") or {}
        flakes = developers.get("flakes")
        return flakes if isinstance(flakes, list) else []

    @staticmethod
    def get_base_override() -> Dict[str, Any]:
        """
        Return the alternate-HomeFree-base setting, always including the
        official URL for the UI to show when the override is disabled.

        Shape: { enabled, type, localUrl, remoteUrl, officialUrl }. Both
        URLs are returned so the UI can keep each kind independently and
        the active `type` selects which one is applied. Defaults to a
        disabled local override when nothing has been configured.
        """
        config = ConfigReader.read_config()
        developers = config.get("developers") or {}
        override = developers.get("homefree-base")
        if not isinstance(override, dict):
            override = {}
        ftype = override.get("type") or "local"
        local_url = override.get("localUrl")
        remote_url = override.get("remoteUrl")
        # Back-compat: older configs stored a single `url` for the active
        # type only. Map it onto the matching kind so it isn't lost.
        if local_url is None and remote_url is None and override.get("url"):
            if ftype == "remote":
                remote_url = override.get("url")
            else:
                local_url = override.get("url")
        return {
            "enabled": bool(override.get("enabled", False)),
            "type": ftype,
            "localUrl": local_url or "",
            "remoteUrl": remote_url or "",
            "officialUrl": OFFICIAL_HOMEFREE_URL,
        }

    # ---- validation --------------------------------------------------

    @staticmethod
    def _slugify_input_name(name: str) -> str:
        """Derive a default Nix input identifier from a human name."""
        slug = re.sub(r"[^a-zA-Z0-9]+", "-", name.strip().lower()).strip("-")
        slug = slug or "flake"
        return f"custom-{slug}"

    @staticmethod
    def validate_flake(
        entry: Dict[str, Any], existing: List[Dict[str, Any]]
    ) -> Tuple[bool, List[str]]:
        """
        Tier-1 (cheap, synchronous) validation. Returns (ok, errors).
        Tier-2 (network probe) lives in probe_flake().
        """
        errors: List[str] = []

        name = (entry.get("name") or "").strip()
        if not name:
            errors.append("Name is required.")

        ftype = entry.get("type")
        if ftype not in ("local", "remote"):
            errors.append('Type must be "local" or "remote".')

        input_name = (entry.get("inputName") or "").strip()
        if not input_name:
            errors.append("Input name is required.")
        elif not _INPUT_NAME_RE.match(input_name):
            errors.append(
                "Input name must start with a letter and contain only "
                "letters, digits, '-' and '_'."
            )
        elif input_name in RESERVED_INPUT_NAMES:
            errors.append(
                f'Input name "{input_name}" is reserved and would collide '
                "with a built-in flake input."
            )
        else:
            # Uniqueness against OTHER entries (skip the one being updated).
            for other in existing:
                if other.get("id") == entry.get("id"):
                    continue
                if other.get("inputName") == input_name:
                    errors.append(
                        f'Input name "{input_name}" is already used by '
                        f'another registered flake ("{other.get("name")}").'
                    )
                    break

        url = (entry.get("url") or "").strip()
        if not url:
            errors.append("A flake path or URL is required.")
        elif ftype == "local":
            errors.extend(DevelopersService._validate_local_url(url))
        elif ftype == "remote":
            if not url.startswith(_REMOTE_PREFIXES):
                errors.append(
                    "Remote flake URL must be a flake reference "
                    "(e.g. github:owner/repo, git+https://..., gitlab:...)."
                )

        return (len(errors) == 0, errors)

    @staticmethod
    def _validate_local_url(url: str) -> List[str]:
        """Validate a `git+file://` local flake URL. Returns error list."""
        errors: List[str] = []
        prefix = "git+file://"
        if not url.startswith(prefix):
            return [
                "Local flake URL must be a git+file:// path "
                "(choose the repo with the file browser)."
            ]
        path = url[len(prefix):]
        if ".." in Path(path).parts:
            return ["Local flake path must not contain '..'."]
        if not any(
            path == root or path.startswith(root + "/")
            for root in ALLOWED_LOCAL_ROOTS
        ):
            return [
                "Local flake path must be under one of: "
                + ", ".join(ALLOWED_LOCAL_ROOTS)
                + "."
            ]
        p = Path(path)
        if not p.is_dir():
            errors.append(f"Local path does not exist or is not a directory: {path}")
            return errors
        if not (p / "flake.nix").is_file():
            errors.append(f"No flake.nix found in {path}.")
        if not (p / ".git").exists():
            errors.append(
                f"{path} is not a git repository — a git+file:// flake "
                "requires the directory to be a git repo."
            )
        return errors

    @staticmethod
    def _normalize_remote_url(url: str) -> str:
        """
        Rewrite a remote flake reference into a form Nix accepts, so the
        admin can paste what a forge's "Clone" button gives them.

        - Already-fetchable refs (github:, git+ssh://, …) are left as-is.
        - github.com / gitlab.com HTTPS URLs become the idiomatic shorthand
          (github:owner/repo) — public-repo friendly and what most mean.
        - Any other http(s) URL gets a `git+` prefix; a bare https:// is a
          TARBALL fetch in Nix, not a git repo.
        - ssh:// and scp-style `git@host:path` become git+ssh://, preserving
          the user's SSH-key transport (don't shorten SSH to github:, which
          would switch a private repo to token auth).
        Anything unrecognised is returned unchanged for validation to flag.
        """
        u = (url or "").strip()
        if not u or u.startswith(_FLAKE_REF_PREFIXES):
            return u

        # github.com / gitlab.com HTTPS web/clone URL -> shorthand.
        m = re.match(
            r"^https?://(?:www\.)?(?P<forge>github|gitlab)\.com/"
            r"(?P<owner>[^/]+)/(?P<repo>[^/#?]+)",
            u,
        )
        if m:
            repo = m.group("repo")
            if repo.endswith(".git"):
                repo = repo[:-4]
            return f"{m.group('forge')}:{m.group('owner')}/{repo}"

        # ssh:// or any other http(s) git URL -> add the git+ fetcher prefix.
        if u.startswith(("https://", "http://", "ssh://")):
            return "git+" + u

        # scp-style SSH: git@host:owner/repo.git -> git+ssh://git@host/owner/repo.git
        scp = _SCP_SSH_RE.match(u)
        if scp:
            return (
                f"git+ssh://{scp.group('user')}@{scp.group('host')}"
                f"/{scp.group('path')}"
            )

        return u

    @staticmethod
    def probe_flake(url: str, module_attr: str = "default") -> Dict[str, Any]:
        """
        Tier-2 deep probe: confirm the flake is reachable and exposes the
        requested `nixosModules.<module_attr>`. Best-effort — a network
        failure yields warnings, not hard errors.
        """
        result: Dict[str, Any] = {
            "valid": True,
            "checks": {"reachable": False, "hasNixosModules": False},
            "errors": [],
            "warnings": [],
        }

        try:
            meta = subprocess.run(
                ["nix", "--extra-experimental-features", "nix-command flakes",
                 "flake", "metadata", url, "--json", "--no-write-lock-file"],
                capture_output=True, text=True, timeout=90,
            )
        except subprocess.TimeoutExpired:
            result["warnings"].append("Timed out reaching the flake — could not verify it.")
            return result
        except Exception as e:
            result["warnings"].append(f"Could not run flake probe: {e}")
            return result

        if meta.returncode != 0:
            err = (meta.stderr or meta.stdout or "unknown error").strip()
            result["valid"] = False
            result["errors"].append(
                f"Flake is unreachable or not a valid flake: {err.splitlines()[-1] if err else 'unknown error'}"
            )
            return result

        result["checks"]["reachable"] = True

        try:
            show = subprocess.run(
                ["nix", "--extra-experimental-features", "nix-command flakes",
                 "flake", "show", url, "--json", "--no-write-lock-file"],
                capture_output=True, text=True, timeout=120,
            )
            if show.returncode == 0:
                data = json.loads(show.stdout or "{}")
                modules = data.get("nixosModules", {})
                if module_attr in modules:
                    result["checks"]["hasNixosModules"] = True
                else:
                    result["warnings"].append(
                        f'Flake exposes no nixosModules.{module_attr}; '
                        "registering it will break the next rebuild."
                    )
            else:
                result["warnings"].append(
                    "Could not enumerate the flake's outputs to verify "
                    f"nixosModules.{module_attr}."
                )
        except Exception as e:
            result["warnings"].append(f"Could not verify flake outputs: {e}")

        return result

    # ---- alternate HomeFree base — validation -----------------------

    @staticmethod
    def validate_base_override(entry: Dict[str, Any]) -> Tuple[bool, List[str]]:
        """
        Tier-1 (cheap, synchronous) validation of an alternate-base entry.
        A disabled override is always valid — its URL is not used. When
        enabled, the URL is checked the same way a custom flake's is.
        """
        errors: List[str] = []

        ftype = entry.get("type")
        if ftype not in ("local", "remote"):
            errors.append('Type must be "local" or "remote".')

        if not entry.get("enabled"):
            # Disabled: the build uses the official homefree-base; the URL
            # is irrelevant and need not be valid.
            return (len(errors) == 0, errors)

        url = (entry.get("url") or "").strip()
        if not url:
            errors.append("A repository path or URL is required when enabled.")
        elif ftype == "local":
            errors.extend(DevelopersService._validate_local_url(url))
        elif ftype == "remote":
            if not url.startswith(_REMOTE_PREFIXES):
                errors.append(
                    "Remote repository URL must be a flake reference "
                    "(e.g. github:owner/repo, git+https://..., gitlab:...)."
                )

        return (len(errors) == 0, errors)

    @staticmethod
    def probe_base_override(url: str) -> Dict[str, Any]:
        """
        Tier-2 deep probe of an alternate HomeFree base repo: confirm it is
        reachable and exposes `nixosModules.homefree` (the attribute the
        build composes). Best-effort — network failure yields warnings.
        """
        return DevelopersService.probe_flake(url, module_attr="homefree")

    # ---- text generators (pure) -------------------------------------

    @staticmethod
    def _enabled(flakes: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
        return [f for f in flakes if f.get("enabled", True)]

    @staticmethod
    def _render_inputs_region(flakes: List[Dict[str, Any]]) -> str:
        """The text between (and including) the two sentinel lines."""
        lines = [INPUTS_BEGIN]
        for f in DevelopersService._enabled(flakes):
            lines.append(f'    {f["inputName"]}.url = "{f["url"]}";')
        lines.append(INPUTS_END)
        return "\n".join(lines)

    @staticmethod
    def _render_custom_flakes_nix(flakes: List[Dict[str, Any]]) -> str:
        """Full content of /etc/nixos/custom-flakes.nix."""
        body = []
        for f in DevelopersService._enabled(flakes):
            attr = f.get("moduleAttr") or "default"
            body.append(f'  (inputs.{f["inputName"]}.nixosModules.{attr})')
        return (
            "# GENERATED by HomeFree admin panel - do not edit by hand.\n"
            "# Regenerated from homefree-config.json `developers.flakes`.\n"
            "{ inputs }:\n"
            "[\n"
            + ("\n".join(body) + "\n" if body else "")
            + "]\n"
        )

    @staticmethod
    def _render_base_override_region(entry: Dict[str, Any]) -> str:
        """
        The text between (and including) the homefree-base-override
        sentinels. When the override is enabled this declares the
        `homefree-alt` input; when disabled it is just the two markers
        (no extra input is fetched).
        """
        lines = [BASE_OVERRIDE_BEGIN]
        if entry.get("enabled") and (entry.get("url") or "").strip():
            lines.append(f'    {ALT_INPUT_NAME}.url = "{entry["url"].strip()}";')
        lines.append(BASE_OVERRIDE_END)
        return "\n".join(lines)

    @staticmethod
    def _render_base_binding(entry: Dict[str, Any]) -> str:
        """
        The text between (and including) the homefree-base-binding
        sentinels: the single `homefree = inputs.<name>;` line in the
        `outputs` let-block that selects which input the build uses.
        """
        target = ALT_INPUT_NAME if entry.get("enabled") else "homefree-base"
        return "\n".join([
            BASE_BINDING_BEGIN,
            f"    homefree = inputs.{target};",
            BASE_BINDING_END,
        ])

    # ---- flake.nix scaffolding --------------------------------------

    @staticmethod
    def _find_block_end(text: str, open_idx: int) -> int:
        """
        Given the index of an opening '{' or '[', return the index of its
        matching close brace/bracket. Raises ValueError if unbalanced.
        """
        opener = text[open_idx]
        closer = {"{": "}", "[": "]"}[opener]
        depth = 0
        for i in range(open_idx, len(text)):
            c = text[i]
            if c == opener:
                depth += 1
            elif c == closer:
                depth -= 1
                if depth == 0:
                    return i
        raise ValueError(f"Unbalanced '{opener}' starting at index {open_idx}")

    @staticmethod
    def _scaffold_text(original: str) -> str:
        """
        Return `original` flake.nix text with the developers scaffolding
        ensured (inputs sentinel region + customFlakeModules delegation).
        Idempotent: already-scaffolded text is returned unchanged.
        Raises ValueError if the flake.nix is too unusual to edit safely.
        """
        text = original

        # --- 1. inputs sentinel region ---
        if INPUTS_BEGIN not in text:
            m = re.search(r"\binputs\s*=\s*\{", text)
            if not m:
                raise ValueError("Could not locate the `inputs = { ... }` block.")
            open_idx = text.index("{", m.start())
            close_idx = DevelopersService._find_block_end(text, open_idx)
            # Insert the region as whole lines, just before the line that
            # carries the inputs block's closing brace, so the sentinels
            # keep their own (4-space) indentation and the `};` stays put.
            line_start = text.rfind("\n", 0, close_idx) + 1
            region = f"{INPUTS_BEGIN}\n{INPUTS_END}\n"
            text = text[:line_start] + region + text[line_start:]

        # --- 2. customFlakeModules delegation ---
        if "customFlakeModules" not in text:
            # Ensure the outputs lambda captures the full input set as `inputs`.
            om = re.search(r"\boutputs\s*=\s*\{[^}]*\}", text)
            if not om:
                raise ValueError("Could not locate the `outputs = { ... }:` lambda.")
            lambda_close = text.index("}", om.start())
            if not text[lambda_close:lambda_close + 8].startswith("}@inputs"):
                text = text[:lambda_close + 1] + "@inputs" + text[lambda_close + 1:]

            # Inject the customFlakeModules binding right after `let`.
            lm = re.search(r"\blet\b", text)
            if not lm:
                raise ValueError("Could not locate the `let` block in `outputs`.")
            binding = (
                "\n    # Custom developer flakes registered via the admin panel.\n"
                "    customFlakeModules =\n"
                "      if builtins.pathExists ./custom-flakes.nix\n"
                "      then import ./custom-flakes.nix { inherit inputs; }\n"
                "      else [];"
            )
            text = text[:lm.end()] + binding + text[lm.end():]

            # Append `++ customFlakeModules` to the modules list.
            mm = re.search(r"\bmodules\s*=\s*\[", text)
            if not mm:
                raise ValueError("Could not locate the `modules = [ ... ]` list.")
            list_open = text.index("[", mm.start())
            list_close = DevelopersService._find_block_end(text, list_open)
            # Skip past the closing ']' and any trailing ';'.
            insert_at = list_close + 1
            text = text[:insert_at] + " ++ customFlakeModules" + text[insert_at:]

        # --- 3. homefree-base-override input region ---
        # An empty (markers-only) region inside `inputs = { ... }`; the
        # alternate-base feature splices an `homefree-alt.url = ...;` line
        # in when an override is enabled.
        if BASE_OVERRIDE_BEGIN not in text:
            m = re.search(r"\binputs\s*=\s*\{", text)
            if not m:
                raise ValueError("Could not locate the `inputs = { ... }` block.")
            open_idx = text.index("{", m.start())
            close_idx = DevelopersService._find_block_end(text, open_idx)
            line_start = text.rfind("\n", 0, close_idx) + 1
            region = f"{BASE_OVERRIDE_BEGIN}\n{BASE_OVERRIDE_END}\n"
            text = text[:line_start] + region + text[line_start:]

        # --- 4. homefree-base-binding region (`homefree = inputs.<x>;`) ---
        # This single line in the `outputs` let-block selects which input
        # the build uses. Older / hand-edited flakes carry a bare
        # `homefree = homefree-base;` (or `homefree-local`) line, possibly
        # with a commented alternative; replace any such line(s) with the
        # managed region. A fresh installer flake has no `homefree =` line
        # and uses `homefree-base.*` directly — handled below.
        if BASE_BINDING_BEGIN not in text:
            lm = re.search(r"\blet\b", text)
            if not lm:
                raise ValueError("Could not locate the `let` block in `outputs`.")
            # Find the matching `in` for this `let` so we only touch
            # binding lines inside the let-block.
            in_m = re.search(r"\bin\b", text[lm.end():])
            if not in_m:
                raise ValueError("Could not locate the `in` of the `outputs` let-block.")
            let_start, let_end = lm.end(), lm.end() + in_m.start()
            let_body = text[let_start:let_end]

            # `let_body` runs right up to `in`, so it ends with the
            # whitespace that indents `in` (e.g. "\n  "). Split that off
            # so it survives — re-prepended before `in` after the rewrite.
            stripped = let_body.rstrip(" \t")
            in_indent = let_body[len(stripped):]

            # Strip any existing `homefree = ...;` assignment and an
            # immediately adjacent commented `# homefree = ...;` line.
            binding_re = re.compile(
                r"[ \t]*#?[ \t]*homefree\s*=\s*[^;\n]+;[ \t]*\n", re.M
            )
            cleaned_body = binding_re.sub("", stripped)

            # Scaffold inserts the binding pointing at the official
            # `homefree-base`; write_base_override later splices the real
            # selection in. Built via the shared renderer (which carries
            # its own 4-space indentation) so it stays consistent.
            region = DevelopersService._render_base_binding(
                {"enabled": False}
            )
            # Insert the region at the end of the let-block, just before
            # `in`, restoring `in`'s original indentation.
            cleaned_body = cleaned_body.rstrip("\n") + "\n" + region + "\n" + in_indent
            text = text[:let_start] + cleaned_body + text[let_end:]

            # A fresh installer flake references `homefree-base.nixosModules`
            # and `homefree-base.inputs` directly. Now that the let defines
            # `homefree`, point those at the bare binding so the override
            # actually takes effect.
            text = text.replace(
                "homefree-base.nixosModules.homefree",
                "homefree.nixosModules.homefree",
            )
            text = text.replace("homefree-base.inputs", "homefree.inputs")

        return text

    @staticmethod
    def _backup_flake() -> None:
        """Timestamped backup of flake.nix before the first mutation."""
        try:
            DevelopersService.BACKUP_DIR.mkdir(parents=True, exist_ok=True)
            ts = datetime.now().strftime("%Y%m%d_%H%M%S")
            shutil.copy2(
                DevelopersService.FLAKE_FILE,
                DevelopersService.BACKUP_DIR / f"flake.nix.{ts}",
            )
        except Exception as e:
            logger.warning(f"Could not back up flake.nix: {e}")

    @staticmethod
    def ensure_scaffold() -> Tuple[bool, Optional[str]]:
        """
        Idempotently ensure flake.nix has the developers scaffolding and
        that custom-flakes.nix exists. Safe to call before every write.
        Returns (ok, error_message).
        """
        if not DevelopersService.FLAKE_FILE.exists():
            return False, "/etc/nixos/flake.nix not found."

        try:
            original = DevelopersService.FLAKE_FILE.read_text()
            scaffolded = DevelopersService._scaffold_text(original)
            if scaffolded != original:
                DevelopersService._backup_flake()
                DevelopersService.FLAKE_FILE.write_text(scaffolded)
                logger.info("Added developers scaffolding to /etc/nixos/flake.nix")
        except ValueError as e:
            return False, (
                f"This system's flake.nix is not in a supported shape "
                f"({e}). It must be migrated manually before custom flakes "
                "can be registered."
            )
        except Exception as e:
            return False, f"Failed to scaffold flake.nix: {e}"

        if not DevelopersService.CUSTOM_FLAKES_FILE.exists():
            try:
                DevelopersService.CUSTOM_FLAKES_FILE.write_text(
                    DevelopersService._render_custom_flakes_nix([])
                )
            except Exception as e:
                return False, f"Failed to create custom-flakes.nix: {e}"

        return True, None

    # ---- write path --------------------------------------------------

    @staticmethod
    def _splice_inputs_region(flakes: List[Dict[str, Any]]) -> None:
        """Rewrite the managed region in flake.nix from `flakes`."""
        text = DevelopersService.FLAKE_FILE.read_text()
        begin = text.index(INPUTS_BEGIN)
        end = text.index(INPUTS_END) + len(INPUTS_END)
        region = DevelopersService._render_inputs_region(flakes)
        DevelopersService.FLAKE_FILE.write_text(text[:begin] + region + text[end:])

    @staticmethod
    def _splice_base_override(entry: Dict[str, Any]) -> None:
        """
        Rewrite both managed regions for the alternate-base feature: the
        `homefree-base-override` input region and the `homefree-base-binding`
        line, from a single `{enabled, type, url}` entry.
        """
        text = DevelopersService.FLAKE_FILE.read_text()

        begin = text.index(BASE_OVERRIDE_BEGIN)
        end = text.index(BASE_OVERRIDE_END) + len(BASE_OVERRIDE_END)
        text = (
            text[:begin]
            + DevelopersService._render_base_override_region(entry)
            + text[end:]
        )

        begin = text.index(BASE_BINDING_BEGIN)
        end = text.index(BASE_BINDING_END) + len(BASE_BINDING_END)
        text = (
            text[:begin]
            + DevelopersService._render_base_binding(entry)
            + text[end:]
        )

        DevelopersService.FLAKE_FILE.write_text(text)

    @staticmethod
    def _git_add() -> None:
        """Best-effort `git add` so a committed flake build sees the files."""
        try:
            subprocess.run(
                ["git", "-C", str(DevelopersService.FLAKE_DIR), "add",
                 "flake.nix", "custom-flakes.nix"],
                capture_output=True, text=True, timeout=30,
            )
        except Exception as e:
            logger.warning(f"git add of flake files failed (non-fatal): {e}")

    @staticmethod
    def _register_safe_directories(flakes: List[Dict[str, Any]]) -> None:
        """
        Register each enabled LOCAL flake's path as a git `safe.directory`.

        The rebuild runs as root, but a local flake repo is typically owned
        by the admin's user account. libgit2 (and git) refuse to open a repo
        not owned by the current user unless its path is allow-listed via
        `safe.directory` — otherwise the build fails with
        "repository path '...' is not owned by current user".

        This mirrors what the installer does for the dev-mode `homefree-local`
        input (see install.py: `git config --global --add safe.directory`).
        admin-api runs as root, so this writes root's global git config.
        Idempotent — git's `--add` de-duplicates identical values.
        """
        for f in DevelopersService._enabled(flakes):
            if f.get("type") != "local":
                continue
            url = f.get("url", "")
            prefix = "git+file://"
            if not url.startswith(prefix):
                continue
            path = url[len(prefix):]
            try:
                subprocess.run(
                    ["git", "config", "--global", "--add",
                     "safe.directory", path],
                    capture_output=True, text=True, timeout=15, check=True,
                )
                logger.info(f"Registered git safe.directory for {path}")
            except Exception as e:
                logger.warning(
                    f"Could not register safe.directory for {path} "
                    f"(rebuild may fail with an ownership error): {e}"
                )

    @staticmethod
    def _persist_developers(updates: Dict[str, Any]) -> Tuple[bool, Optional[str]]:
        """
        Merge `updates` into the `developers` section of homefree-config.json.

        `updates` carries only the keys to change (e.g. {"flakes": [...]} or
        {"homefree-base": {...}}); other keys of the `developers` section are
        preserved. This matters because `flakes` and `homefree-base` are
        written by separate code paths and must not clobber each other.

        DevelopersService owns the `developers` section outright — it does
        NOT route through ConfigWriter.write_config, because that path is
        also fed the frontend's whole-config blob by /api/config/apply and
        would clobber this section with a stale snapshot. We read the file
        fresh, merge only the given keys, and write it back, so a concurrent
        edit to any other section is preserved.
        """
        try:
            ConfigWriter._backup_config()
            current = json.loads(ConfigWriter.CONFIG_FILE.read_text())
            developers = current.get("developers")
            if not isinstance(developers, dict):
                developers = {}
            developers.update(updates)
            current["developers"] = developers
            ConfigWriter.CONFIG_FILE.write_text(
                json.dumps(current, indent=2, sort_keys=False) + "\n"
            )
            return True, None
        except Exception as e:
            logger.error(f"Failed to persist developers section: {e}")
            return False, f"Failed to persist the developers section: {e}"

    @staticmethod
    def write_flakes(flakes: List[Dict[str, Any]]) -> Tuple[bool, Optional[str]]:
        """
        Persist `flakes`: scaffold, rewrite flake.nix inputs region and
        custom-flakes.nix, store the list in homefree-config.json.
        """
        ok, err = DevelopersService.ensure_scaffold()
        if not ok:
            return False, err

        try:
            DevelopersService._splice_inputs_region(flakes)
            DevelopersService.CUSTOM_FLAKES_FILE.write_text(
                DevelopersService._render_custom_flakes_nix(flakes)
            )
        except Exception as e:
            logger.error(f"Failed to write flake files: {e}")
            return False, f"Failed to write flake files: {e}"

        ok, err = DevelopersService._persist_developers({"flakes": flakes})
        if not ok:
            return False, err

        # Local flakes are usually owned by the admin's user, not root;
        # allow-list them so the root-run rebuild can open the repo.
        DevelopersService._register_safe_directories(flakes)
        DevelopersService._git_add()
        return True, None

    @staticmethod
    def write_base_override(
        stored: Dict[str, Any], effective: Dict[str, Any]
    ) -> Tuple[bool, Optional[str]]:
        """
        Persist the alternate-HomeFree-base setting.

        `stored`   — the {enabled, type, url} dict saved to
                     homefree-config.json (what the admin entered, kept
                     verbatim so the UI shows it back).
        `effective` — the {enabled, type, url} dict spliced into
                     flake.nix. When the stored URL is invalid this is
                     forced to `enabled: false`, so a bad URL is never
                     written into the build — the system keeps building
                     from the official homefree-base until the URL is
                     corrected.

        Scaffolds flake.nix, rewrites its two managed regions from
        `effective`, stores `stored` in homefree-config.json, and
        allow-lists a local repo for the root-run rebuild.
        """
        ok, err = DevelopersService.ensure_scaffold()
        if not ok:
            return False, err

        try:
            DevelopersService._splice_base_override(effective)
        except Exception as e:
            logger.error(f"Failed to write the alternate-base flake regions: {e}")
            return False, f"Failed to write flake.nix: {e}"

        ok, err = DevelopersService._persist_developers({"homefree-base": stored})
        if not ok:
            return False, err

        # An enabled local override repo is usually owned by the admin's
        # user, not root; allow-list it so the root-run rebuild can open it.
        # Only the effective (actually-applied) override needs this.
        # _register_safe_directories reads only type/url/enabled.
        DevelopersService._register_safe_directories([effective])
        DevelopersService._git_add()
        return True, None

    # ---- high-level operations --------------------------------------

    @staticmethod
    def set_base_override(entry: Dict[str, Any]) -> Dict[str, Any]:
        """
        Persist the alternate-HomeFree-base setting.

        The setting is ALWAYS saved to homefree-config.json (so the UI
        keeps the admin's input). An invalid path/URL does NOT block the
        save and does NOT break the build: it is reported as a warning
        and the build keeps using the official homefree-base until the
        URL is corrected. A genuine write failure (e.g. an unparseable
        flake.nix) is still a hard error.

        Returns { success, message, override?, warnings?, errors? }.
        """
        ftype = entry.get("type") or "local"

        # Both kinds are stored so toggling the type never discards the
        # other's value. Back-compat: an old client may still send a
        # single `url` for the active type.
        local_url = entry.get("localUrl")
        remote_url = entry.get("remoteUrl")
        if local_url is None and remote_url is None and entry.get("url") is not None:
            if ftype == "remote":
                remote_url = entry.get("url")
            else:
                local_url = entry.get("url")
        local_url = (local_url or "").strip()
        remote_url = (remote_url or "").strip()
        # For a local override the frontend sends a bare filesystem path;
        # store it as a git+file:// flake reference, mirroring custom flakes.
        # A remote ref is normalized into a form Nix accepts.
        if local_url and not local_url.startswith("git+file://"):
            local_url = "git+file://" + local_url
        if remote_url:
            remote_url = DevelopersService._normalize_remote_url(remote_url)

        # The active type selects which URL is validated and applied.
        active_url = remote_url if ftype == "remote" else local_url

        # `stored` is kept verbatim in homefree-config.json so the UI
        # always shows the admin exactly what they entered — both kinds.
        stored = {
            "enabled": bool(entry.get("enabled", False)),
            "type": ftype,
            "localUrl": local_url,
            "remoteUrl": remote_url,
        }

        # Validate the active URL. Failures become warnings, not blockers.
        ok, problems = DevelopersService.validate_base_override(
            {"enabled": stored["enabled"], "type": ftype, "url": active_url}
        )

        # `effective` is what actually gets written into flake.nix (it uses
        # a single `url`). If the override is enabled but its active URL did
        # not validate, fall back to disabled so a broken URL never reaches
        # the build.
        if stored["enabled"] and not ok:
            effective = {"enabled": False, "type": ftype, "url": active_url}
        else:
            effective = {"enabled": stored["enabled"], "type": ftype, "url": active_url}

        write_ok, err = DevelopersService.write_base_override(stored, effective)
        if not write_ok:
            return {"success": False, "message": err, "errors": [err]}

        warnings: List[str] = []
        if stored["enabled"] and not ok:
            warnings = problems + [
                "The repository was saved but NOT applied — the system is "
                "still building from the official HomeFree repository. Fix "
                "the path/URL above to apply it."
            ]
            msg = "Alternate HomeFree repository saved, but not applied (see warnings)."
        elif stored["enabled"]:
            msg = ("Alternate HomeFree repository saved. Click Apply "
                   "to rebuild from it.")
        else:
            msg = ("Reverted to the official HomeFree repository. Click Apply "
                   "Changes to rebuild.")

        result = {"success": True, "message": msg, "override": stored}
        if warnings:
            result["warnings"] = warnings
        return result

    @staticmethod
    def register_or_update(entry: Dict[str, Any]) -> Dict[str, Any]:
        """
        Create (no `id`) or update (with `id`) a custom-flake registration.
        Returns { success, message, flake?, errors? }.
        """
        flakes = DevelopersService.list_flakes()

        name = (entry.get("name") or "").strip()
        ftype = entry.get("type")
        url = (entry.get("url") or "").strip()
        # For local flakes the frontend sends a bare filesystem path; we
        # store it as a git+file:// flake reference. For remote refs we
        # normalize what the user pasted into a form Nix accepts.
        if ftype == "local" and url and not url.startswith("git+file://"):
            url = "git+file://" + url
        elif ftype == "remote" and url:
            url = DevelopersService._normalize_remote_url(url)

        input_name = (entry.get("inputName") or "").strip()
        if not input_name and name:
            input_name = DevelopersService._slugify_input_name(name)

        normalized = {
            "id": entry.get("id") or uuid.uuid4().hex[:8],
            "name": name,
            "type": ftype,
            "url": url,
            "inputName": input_name,
            "moduleAttr": (entry.get("moduleAttr") or "default").strip() or "default",
            "enabled": bool(entry.get("enabled", True)),
        }

        ok, errors = DevelopersService.validate_flake(normalized, flakes)
        if not ok:
            return {"success": False, "message": "Validation failed.", "errors": errors}

        existing_idx = next(
            (i for i, f in enumerate(flakes) if f.get("id") == normalized["id"]),
            -1,
        )
        if existing_idx >= 0:
            normalized["addedAt"] = flakes[existing_idx].get(
                "addedAt", datetime.now(timezone.utc).isoformat()
            )
            flakes[existing_idx] = normalized
        else:
            normalized["addedAt"] = datetime.now(timezone.utc).isoformat()
            flakes.append(normalized)

        ok, err = DevelopersService.write_flakes(flakes)
        if not ok:
            return {"success": False, "message": err, "errors": [err]}

        return {
            "success": True,
            "message": "Flake registered. Click Apply to rebuild.",
            "flake": normalized,
        }

    @staticmethod
    def delete_flake(flake_id: str) -> Dict[str, Any]:
        """Remove a registered flake by id."""
        flakes = DevelopersService.list_flakes()
        remaining = [f for f in flakes if f.get("id") != flake_id]
        if len(remaining) == len(flakes):
            return {"success": False, "message": f"No flake with id {flake_id}."}

        ok, err = DevelopersService.write_flakes(remaining)
        if not ok:
            return {"success": False, "message": err}
        return {
            "success": True,
            "message": "Flake removed. Click Apply to rebuild.",
        }
