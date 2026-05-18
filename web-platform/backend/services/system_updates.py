"""
System updates service.

Checks whether a newer commit exists for the `homefree-base` flake input
declared in /etc/nixos/flake.nix (pinned in /etc/nixos/flake.lock), and lets
the admin bump the lock to the latest commit on the tracked branch.

Bumping the lock only rewrites flake.lock — the actual switch to the new
version happens via the existing Apply -> `nixos-rebuild switch` path.
"""

import json
import logging
import subprocess
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, Optional

logger = logging.getLogger(__name__)


class SystemUpdates:
    """Check for and pull in newer commits of the homefree-base flake input."""

    FLAKE_DIR = Path("/etc/nixos")
    LOCK_FILE = FLAKE_DIR / "flake.lock"
    APPLIED_FLAKE_REV_FILE = Path("/var/lib/homefree-admin/applied-flake-rev")

    # The installer's flake template always names the HomeFree input
    # `homefree-base` on production installs (see install.py FLAKE_TEMPLATE).
    # Dev-mode installs use a local input instead, so remote update checking
    # is "not applicable" there.
    INPUT_NAME = "homefree-base"

    @staticmethod
    def base_override_active() -> bool:
        """
        True when an alternate HomeFree base repo is enabled (Developers →
        Custom Flakes). While active, the build runs from that repo, not
        from `homefree-base` — so update checks against `homefree-base` are
        informational only, and the updates page shows a warning.
        """
        try:
            from services.config_reader import ConfigReader
            config = ConfigReader.read_config()
            developers = config.get("developers") or {}
            override = developers.get("homefree-base") or {}
            return bool(override.get("enabled", False))
        except Exception as e:
            logger.warning(f"Could not read alternate-base setting: {e}")
            return False

    @staticmethod
    def _load_lock() -> Optional[dict]:
        """Parse /etc/nixos/flake.lock, or return None if unreadable."""
        try:
            if not SystemUpdates.LOCK_FILE.exists():
                return None
            return json.loads(SystemUpdates.LOCK_FILE.read_text())
        except Exception as e:
            logger.warning(f"Could not parse flake.lock: {e}")
            return None

    @staticmethod
    def _homefree_node(lock: dict) -> Optional[dict]:
        """
        Return the flake.lock node dict for the homefree-base input, or None
        if this install has no such root input (e.g. a dev-mode install).
        """
        nodes = lock.get("nodes", {})
        root = nodes.get("root", {})
        target = root.get("inputs", {}).get(SystemUpdates.INPUT_NAME)
        if target is None:
            return None
        # `target` is normally the node name (string); tolerate a list path.
        if isinstance(target, list):
            node = nodes
            for step in target:
                node = nodes.get(step, {})
            return node or None
        return nodes.get(target)

    @staticmethod
    def _strip_git_prefix(url: str) -> str:
        """Turn a flake `git+https://…` URL into a plain git-clonable URL."""
        if url.startswith("git+"):
            return url[len("git+"):]
        return url

    @staticmethod
    def get_current() -> Optional[Dict[str, Any]]:
        """
        Return the currently pinned homefree-base input, or None if this
        install has no homefree-base input.

        Returns dict: { rev, ref, url, lastModified }
        """
        lock = SystemUpdates._load_lock()
        if not lock:
            return None
        node = SystemUpdates._homefree_node(lock)
        if not node:
            return None

        locked = node.get("locked", {})
        original = node.get("original", {})

        url = SystemUpdates._strip_git_prefix(
            locked.get("url") or original.get("url") or ""
        )
        # Drop any `?ref=…`/query suffix that may ride along on the URL.
        if "?" in url:
            url = url.split("?", 1)[0]

        return {
            "rev": locked.get("rev", ""),
            "ref": locked.get("ref") or original.get("ref") or "",
            "url": url,
            "lastModified": locked.get("lastModified"),
        }

    @staticmethod
    def _ls_remote(url: str, ref: str) -> Optional[str]:
        """
        Return the latest commit SHA for `ref` on the remote `url`, or None
        on failure. Tries refs/heads/<ref> first (branch), then the bare ref.
        """
        for query in (f"refs/heads/{ref}", ref):
            try:
                result = subprocess.run(
                    ["git", "ls-remote", url, query],
                    capture_output=True, text=True, timeout=30,
                )
            except subprocess.TimeoutExpired:
                logger.warning(f"git ls-remote timed out for {url}")
                return None
            except Exception as e:
                logger.warning(f"git ls-remote failed for {url}: {e}")
                return None
            if result.returncode != 0:
                logger.warning(
                    f"git ls-remote {url} {query} returned "
                    f"{result.returncode}: {result.stderr.strip()}"
                )
                continue
            line = result.stdout.strip().splitlines()
            if line:
                sha = line[0].split()[0].strip()
                if sha:
                    return sha
        return None

    @staticmethod
    def check_for_update() -> Dict[str, Any]:
        """
        Compare the pinned homefree-base commit against the latest commit on
        the tracked branch in the remote repo.
        """
        checked_at = datetime.now(timezone.utc).isoformat()
        base = {
            "available": False,
            "applicable": True,
            "current_rev": "",
            "current_short": "",
            "current_date": "",
            "latest_rev": "",
            "latest_short": "",
            "ref": "",
            "checked_at": checked_at,
            "error": None,
        }

        current = SystemUpdates.get_current()
        if current is None:
            # No homefree-base input — dev-mode install or hand-rolled flake.
            base["applicable"] = False
            return base

        current_rev = current["rev"]
        ref = current["ref"]
        url = current["url"]

        current_date = ""
        if current.get("lastModified"):
            try:
                current_date = datetime.fromtimestamp(
                    int(current["lastModified"]), timezone.utc
                ).isoformat()
            except Exception:
                current_date = ""

        base.update({
            "current_rev": current_rev,
            "current_short": current_rev[:8],
            "current_date": current_date,
            "ref": ref,
        })

        if not url or not ref:
            base["error"] = "Could not determine the homefree-base repo URL or branch."
            return base

        latest_rev = SystemUpdates._ls_remote(url, ref)
        if not latest_rev:
            base["error"] = f"Could not reach the update server ({url})."
            return base

        base["latest_rev"] = latest_rev
        base["latest_short"] = latest_rev[:8]
        base["available"] = bool(current_rev) and latest_rev != current_rev
        return base

    @staticmethod
    def apply_update() -> Dict[str, Any]:
        """
        Bump only the homefree-base input in /etc/nixos/flake.lock to the
        latest commit on its tracked branch. Does NOT rebuild — the user must
        click Apply afterwards.
        """
        if SystemUpdates.get_current() is None:
            return {
                "success": False,
                "message": "This install has no homefree-base input to update.",
                "latest_rev": "",
            }

        try:
            result = subprocess.run(
                [
                    "nix",
                    "--extra-experimental-features", "nix-command flakes",
                    "flake", "lock",
                    # `flake lock --update-input` rewrites the whole lock
                    # file. When an alternate base or a custom flake uses a
                    # local `git+file://`/`path:` input, that input is
                    # inherently unlocked (no Git revision) and Nix refuses
                    # to write the lock — discarding the homefree-base bump
                    # we actually want. These flags (mirroring scripts/
                    # build.sh and NixOperations._refresh_local_inputs) tell
                    # Nix the unlocked local inputs are intentional; only
                    # homefree-base is being updated here regardless.
                    "--allow-dirty",
                    "--allow-dirty-locks",
                    "--update-input", SystemUpdates.INPUT_NAME,
                    str(SystemUpdates.FLAKE_DIR),
                ],
                capture_output=True, text=True, timeout=120,
            )
        except subprocess.TimeoutExpired:
            return {
                "success": False,
                "message": "Updating the system version timed out.",
                "latest_rev": "",
            }
        except Exception as e:
            logger.error(f"Error updating homefree-base input: {e}")
            return {"success": False, "message": str(e), "latest_rev": ""}

        if result.returncode != 0:
            err = (result.stderr or result.stdout or "unknown error").strip()
            logger.error(f"nix flake lock --update-input failed: {err}")
            return {
                "success": False,
                "message": f"Failed to update system version: {err}",
                "latest_rev": "",
            }

        updated = SystemUpdates.get_current()
        latest_rev = updated["rev"] if updated else ""
        logger.info(f"Updated homefree-base input to {latest_rev}")
        return {
            "success": True,
            "message": "System version updated. Click Apply Changes to finish.",
            "latest_rev": latest_rev,
        }
