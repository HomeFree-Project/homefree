"""
Installer-ISO builder — Source Code page surface.

Drives `scripts/build-public-image.sh` from the admin UI: builds the
HomeFree installer ISO and publishes it into /var/lib/homefree/downloads
where the landing-page Caddy block serves it at /downloads/. Two source
modes:

  * `alt`  — build from the alternate-base local checkout. The default
             whenever an alternate base is configured. The resulting ISO
             installs the operator's fork.
  * `main` — clone the official upstream URL to a tempdir and build from
             there. The resulting ISO installs the public release.

State is a single in-process BuildState (one build at a time). The
subprocess streams stdout+stderr to LOG_PATH; the frontend polls
GET /api/source/iso/status for state + log tail.

If the admin-api restarts mid-build the child process is orphaned and
state is lost; on next status read the state shows `idle`. The log
file is preserved so the operator can still inspect what got far enough
to write.
"""

import asyncio
import logging
import os
import shutil
import tempfile
import time
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any, Dict, Optional


# Subprocess environment for the build scripts. The admin-api unit uses
# a deliberately narrow PATH (see services/admin-web/default.nix), but
# scripts/build-public-image.sh and scripts/build-image.sh shell out to
# the full userland (rsync, awk, install, sha256sum, etc.). Augmenting
# with the system profile here keeps the security posture of admin-api
# itself unchanged while giving the build subprocess a normal user PATH.
def _build_env() -> Dict[str, str]:
    env = os.environ.copy()
    env["PATH"] = env.get("PATH", "") + ":/run/current-system/sw/bin"
    return env

from fastapi import APIRouter, HTTPException

from services.developers import DevelopersService, OFFICIAL_HOMEFREE_URL

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api/source", tags=["source-iso"])


# Where the script publishes the artifact.
DOWNLOADS_DIR = Path("/var/lib/homefree/downloads")
LATEST_SYMLINK = DOWNLOADS_DIR / "homefree-latest.iso"

# Build log path. Lives under the admin StateDirectory so it's owned by
# admin-api and survives admin-api restarts (useful for post-mortem on
# a failed build after the in-memory state is gone).
LOG_PATH = Path("/var/lib/homefree-admin/build-iso.log")

# How many bytes of the log we ship back to the UI per status poll.
# Sized to fit a few hundred lines of nix-build output — enough to
# be useful, small enough that polling stays cheap.
LOG_TAIL_BYTES = 16384


@dataclass
class BuildState:
    state: str = "idle"            # idle | running | done | error
    source: Optional[str] = None   # alt | main
    flake_path: Optional[str] = None
    started_at: Optional[float] = None
    finished_at: Optional[float] = None
    exit_code: Optional[int] = None
    error: Optional[str] = None
    # Tracked for cleanup; never round-tripped to the UI.
    _temp_clone_path: Optional[str] = None


_state = BuildState()
_state_lock = asyncio.Lock()


def _read_latest_info() -> Dict[str, Any]:
    """Return info about the currently published ISO (target of the
    homefree-latest.iso symlink) — name, size, mtime, sha256 from the
    sidecar. {} when no ISO is published yet."""
    if not LATEST_SYMLINK.exists():
        return {}
    try:
        target = LATEST_SYMLINK.resolve()
        if not target.is_file():
            return {}
        st = target.stat()
        sha: Optional[str] = None
        # The script writes `<hash>  <basename>` next to the file.
        sha_path = target.parent / (target.name + ".sha256")
        if sha_path.is_file():
            line = sha_path.read_text().strip()
            sha = line.split(None, 1)[0] if line else None
        return {
            "name": target.name,
            "size": st.st_size,
            "modified": st.st_mtime,
            "sha256": sha,
        }
    except OSError as e:
        logger.warning("Reading latest ISO failed: %s", e)
        return {}


def _read_log_tail() -> str:
    if not LOG_PATH.exists():
        return ""
    try:
        size = LOG_PATH.stat().st_size
        with LOG_PATH.open("rb") as f:
            if size > LOG_TAIL_BYTES:
                f.seek(size - LOG_TAIL_BYTES)
            return f.read().decode("utf-8", errors="replace")
    except OSError:
        return ""


def _serialize_state() -> Dict[str, Any]:
    d = asdict(_state)
    d.pop("_temp_clone_path", None)
    return d


@router.get("/iso/status")
async def get_iso_status() -> Dict[str, Any]:
    return {
        "build": _serialize_state(),
        "latest": _read_latest_info(),
        "alt_base": DevelopersService.get_base_override(),
        # Only ship the log tail while a build is live or has just
        # finished — at idle the log is the stale tail of a previous run
        # and is more confusing than useful.
        "log_tail": _read_log_tail() if _state.state != "idle" else "",
    }


@router.post("/iso/build")
async def post_iso_build(payload: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
    source = ((payload or {}).get("source") or "alt").lower()
    if source not in ("alt", "main"):
        raise HTTPException(400, "source must be 'alt' or 'main'")

    async with _state_lock:
        if _state.state == "running":
            raise HTTPException(409, "A build is already in progress.")

        flake_path: Optional[Path] = None
        if source == "alt":
            base = DevelopersService.get_base_override()
            if not base.get("enabled") or (base.get("type") or "") != "local":
                raise HTTPException(
                    400,
                    "source=alt requires an enabled local alternate base.",
                )
            local = base.get("localUrl") or ""
            if local.startswith("git+file://"):
                local = local[len("git+file://"):]
            local = local.strip()
            if not local:
                raise HTTPException(400, "Alternate-base local path is empty.")
            flake_path = Path(local)
            if not (flake_path / "flake.nix").is_file():
                raise HTTPException(
                    400,
                    f"No flake.nix at {flake_path}. Is the alternate base a HomeFree checkout?",
                )

        # source == 'main' resolves the flake_path inside the background
        # task (after the clone) so the HTTP request returns quickly.

        _state.state = "running"
        _state.source = source
        _state.flake_path = str(flake_path) if flake_path else None
        _state.started_at = time.time()
        _state.finished_at = None
        _state.exit_code = None
        _state.error = None
        _state._temp_clone_path = None

        asyncio.create_task(_run_build(source, flake_path))

    return {"started": True, "source": source, "build": _serialize_state()}


async def _run_build(source: str, flake_path: Optional[Path]) -> None:
    """Background task: optional clone, then run build-public-image.sh.

    Stdout/stderr stream to LOG_PATH (truncated at the start of each
    build). On exit (success or failure), updates _state and cleans up
    the temp clone if there was one. Never raises — all exceptions land
    in `_state.error`."""
    try:
        LOG_PATH.parent.mkdir(parents=True, exist_ok=True)
        # Truncate the log up front so each run starts fresh.
        LOG_PATH.write_text("")

        if source == "main":
            tmp = tempfile.mkdtemp(prefix="homefree-iso-main-")
            _state._temp_clone_path = tmp
            clone_url = OFFICIAL_HOMEFREE_URL
            if clone_url.startswith("git+"):
                clone_url = clone_url[len("git+"):]
            with LOG_PATH.open("a") as log:
                log.write(f"[INFO]    Cloning {clone_url} -> {tmp}\n")
                log.flush()
                proc = await asyncio.create_subprocess_exec(
                    "git", "clone", "--depth=1", clone_url, tmp,
                    stdout=log, stderr=log,
                    env=_build_env(),
                )
                rc = await proc.wait()
            if rc != 0:
                _state.state = "error"
                _state.error = f"git clone failed (exit {rc})"
                _state.exit_code = rc
                return
            flake_path = Path(tmp)
            _state.flake_path = str(flake_path)

        assert flake_path is not None, "alt mode validates flake_path upfront"
        script = flake_path / "scripts" / "build-public-image.sh"
        if not script.is_file():
            _state.state = "error"
            _state.error = f"build-public-image.sh not found at {script}"
            return

        with LOG_PATH.open("a") as log:
            log.write(f"[INFO]    Building from {flake_path}\n")
            log.write(f"[INFO]    Invoking {script.name} --local\n")
            log.flush()
            proc = await asyncio.create_subprocess_exec(
                str(script), "--local",
                cwd=str(flake_path),
                stdout=log, stderr=log,
                env=_build_env(),
            )
            rc = await proc.wait()

        _state.exit_code = rc
        if rc == 0:
            _state.state = "done"
        else:
            _state.state = "error"
            _state.error = f"build-public-image.sh exited {rc}"

    except Exception as e:  # noqa: BLE001
        logger.exception("ISO build failed")
        _state.state = "error"
        _state.error = str(e)
    finally:
        _state.finished_at = time.time()
        # Clean up temp clone whether the build succeeded or not — the
        # ISO has been copied out into /var/lib/homefree/downloads/.
        if _state._temp_clone_path:
            shutil.rmtree(_state._temp_clone_path, ignore_errors=True)
            _state._temp_clone_path = None
