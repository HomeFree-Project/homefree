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

# Input names already used by the generated flake.nix / its outputs args /
# its let-block. Registering a custom flake under one of these would shadow
# a real input and break the build, so they are rejected at validation.
RESERVED_INPUT_NAMES = {
    "nixpkgs", "homefree-base", "homefree-local", "homefree",
    "lanzaboote", "disko", "self",
}

# Same filesystem whitelist the /api/filesystem/browse endpoint enforces.
ALLOWED_LOCAL_ROOTS = ["/home", "/mnt", "/var/lib", "/media", "/srv", "/opt"]

# Recognised remote flake-ref URL prefixes.
_REMOTE_PREFIXES = (
    "github:", "gitlab:", "sourcehut:", "git+https://", "git+ssh://",
    "git+http://", "https://", "http://", "path:", "flake:", "tarball+https://",
)

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

        if not ConfigWriter.write_config({"developers": {"flakes": flakes}}):
            return False, "Failed to persist the developers section to homefree-config.json."

        # Local flakes are usually owned by the admin's user, not root;
        # allow-list them so the root-run rebuild can open the repo.
        DevelopersService._register_safe_directories(flakes)
        DevelopersService._git_add()
        return True, None

    # ---- high-level operations --------------------------------------

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
        # store it as a git+file:// flake reference.
        if ftype == "local" and url and not url.startswith("git+file://"):
            url = "git+file://" + url

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
            "message": "Flake registered. Click Apply Changes to rebuild.",
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
            "message": "Flake removed. Click Apply Changes to rebuild.",
        }
