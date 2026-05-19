"""
Nix operations service - handles nixos-rebuild and dry-activate
"""

import subprocess
import logging
from typing import Dict, Any, Optional, List
from pathlib import Path
from enum import Enum
import tempfile
import os
import json
from datetime import datetime

logger = logging.getLogger(__name__)


class RebuildAction(Enum):
    """NixOS rebuild actions"""
    DRY_ACTIVATE = "dry-activate"
    SWITCH = "switch"
    BOOT = "boot"
    TEST = "test"
    BUILD = "build"


class NixOperations:
    """Service for NixOS operations"""

    FLAKE_DIR = Path("/etc/nixos")
    LOG_DIR = Path("/var/lib/homefree-admin/rebuild-logs")
    LATEST_STATUS = LOG_DIR / "latest-status.json"
    MAX_LOGS_TO_KEEP = 10

    # Persistent rebuild state (survives service restarts)
    REBUILD_STATE_DIR = Path("/var/lib/homefree-admin")
    REBUILD_LOG_FILE_REF = REBUILD_STATE_DIR / "rebuild.log"
    REBUILD_OFFSET_FILE = REBUILD_STATE_DIR / "rebuild.offset"
    SERVICE_STATE_FILE = REBUILD_STATE_DIR / "service-state.json"
    APPLIED_CONFIG_FILE = REBUILD_STATE_DIR / "applied-config.json"

    # Transient systemd unit name used for the rebuild. Running the rebuild
    # under its own systemd cgroup decouples it from admin-api's lifecycle —
    # admin-api can restart freely without killing an in-flight rebuild.
    REBUILD_UNIT = "homefree-rebuild.service"

    # Written by the admin-api blue/green flip activation script when a
    # flip fails its health check (or Caddy reload). Its presence means
    # the box is still serving the PREVIOUS admin-api version — a flip
    # failure deliberately exits the activation script 0, so the rebuild
    # itself reports success; this marker is how that partial outcome
    # surfaces in the UI. Cleared by the next successful flip.
    FLIP_FAILED_FILE = REBUILD_STATE_DIR / "admin-api-flip-failed.json"

    _current_rebuild_output_file = None
    _current_rebuild_output_offset = 0
    _last_rebuild_error = None
    _last_rebuild_exit_code = None
    _last_rebuild_partial_success = False
    _last_rebuild_output = None

    @staticmethod
    def _detect_partial_success(output: str, exit_code: int) -> bool:
        """
        Detect if rebuild partially succeeded (generation activated but services failed).

        Args:
            output: Full rebuild output
            exit_code: Process exit code

        Returns:
            True if generation was activated but services failed
        """
        # Exit code 0 is ALWAYS complete success - no need to check output
        if exit_code == 0:
            logger.info("Rebuild succeeded with exit code 0")
            return False

        if not output:
            logger.warning(f"No output available for rebuild with exit code {exit_code}")
            return False

        output_lower = output.lower()

        # Look for activation success indicators
        # More comprehensive patterns to catch various NixOS output formats
        activation_success = any([
            'activating the configuration' in output_lower,
            'activation script' in output_lower,
            'setting up /etc' in output_lower,
            'reloading user units' in output_lower,
            'building the system configuration' in output_lower and 'activat' in output_lower
        ])

        # Look for service failure indicators
        service_failure = (
            'failed' in output_lower and
            ('service' in output_lower or 'unit' in output_lower or '.service' in output_lower)
        )

        # Partial success: activation worked but services failed
        result = activation_success and service_failure

        if result:
            logger.warning(f"Detected partial success: exit_code={exit_code}, activation succeeded but services failed")
        else:
            logger.error(f"Rebuild failed with exit code {exit_code}, no partial success detected")

        return result

    @staticmethod
    def dry_activate() -> Dict[str, Any]:
        """
        Run nixos-rebuild dry-activate to preview changes without applying.

        Returns:
            Dictionary with:
                - success: bool
                - output: str (command output)
                - changes: List[str] (detected changes)
                - errors: List[str] (any errors or warnings)
        """
        try:
            result = subprocess.run(
                ["nixos-rebuild", "dry-activate", "--flake", str(NixOperations.FLAKE_DIR)],
                capture_output=True,
                text=True,
                timeout=300  # 5 minute timeout
            )

            output = result.stdout + result.stderr
            changes = NixOperations._parse_changes(output)
            errors = NixOperations._parse_errors(output)

            return {
                'success': result.returncode == 0,
                'output': output,
                'changes': changes,
                'errors': errors,
                'exit_code': result.returncode
            }

        except subprocess.TimeoutExpired:
            logger.error("dry-activate timed out")
            return {
                'success': False,
                'output': '',
                'changes': [],
                'errors': ['Operation timed out after 5 minutes'],
                'exit_code': -1
            }
        except Exception as e:
            logger.error(f"Error running dry-activate: {e}")
            return {
                'success': False,
                'output': str(e),
                'changes': [],
                'errors': [str(e)],
                'exit_code': -1
            }

    @staticmethod
    def rebuild_switch() -> Dict[str, Any]:
        """
        Run nixos-rebuild switch to apply changes.

        Spawns a transient systemd unit (homefree-rebuild.service) via
        `systemd-run`. The rebuild runs in its own cgroup, managed by PID 1,
        so a restart of admin-api will NOT kill it. systemd-run returns as
        soon as the unit is queued; we poll the unit state via systemctl in
        get_rebuild_status().

        Returns:
            Dictionary with operation status
        """
        try:
            # Clear any previous error state
            NixOperations._last_rebuild_error = None
            NixOperations._last_rebuild_exit_code = None
            NixOperations._last_rebuild_partial_success = False
            NixOperations._last_rebuild_output = None

            # Refuse to start if a previous rebuild unit is still around
            if NixOperations._unit_active():
                return {
                    'success': False,
                    'message': 'A rebuild is already running',
                    'pid': None,
                }

            # Reset any failed/exited unit so we can re-create it cleanly
            subprocess.run(
                ["systemctl", "reset-failed", NixOperations.REBUILD_UNIT],
                capture_output=True, timeout=5,
            )

            # Sync homefree-config.json with module.nix schema before rebuild
            sync_result = NixOperations._sync_config()
            if not sync_result['success']:
                logger.warning(
                    f"Config sync failed or had warnings: {sync_result.get('message', 'Unknown error')}"
                )

            # Refresh local working-tree flake inputs so we don't build
            # against a stale lock snapshot of the dev source. Required for
            # both `path:` and `git+file://` inputs — neither auto-detects
            # working-tree edits without an explicit lock update. See
            # _refresh_local_inputs() for the full rationale.
            NixOperations._refresh_local_inputs()

            NixOperations.LOG_DIR.mkdir(parents=True, exist_ok=True)
            NixOperations.REBUILD_STATE_DIR.mkdir(parents=True, exist_ok=True)

            timestamp = datetime.now().strftime("%Y%m%d-%H%M%S")
            log_file = NixOperations.LOG_DIR / f"rebuild-{timestamp}.log"
            output_path = str(log_file)

            with open(output_path, 'w') as f:
                f.write("Starting NixOS rebuild...\n")
                f.write("Evaluating configuration and downloading dependencies...\n")
                f.flush()

            # Build the systemd-run command. Running as a transient .service
            # unit means PID 1 owns the process tree and admin-api restarting
            # does not affect the rebuild's cgroup.
            unit_name = NixOperations.REBUILD_UNIT  # homefree-rebuild.service
            # NOTE: do NOT pass --collect. With --collect systemd cleans up the
            # transient unit immediately on exit, which races our exit-code
            # poll: by the time we read ExecMainStatus the unit is gone and
            # systemctl returns the default 0. Without --collect the failed
            # unit lingers (state=failed) until we explicitly reset-failed it.
            #
            # PATH handling: rather than inheriting whatever os.environ.PATH
            # was set to when admin-api *started* (which can be stale across
            # admin-web.nix edits — admin-api has restartIfChanged=false), we
            # rebuild the PATH from /run/current-system/sw/bin plus a few
            # well-known nix-store paths via `which`. The rebuild needs at
            # minimum: nixos-rebuild, nix, git, systemctl, coreutils, and a
            # shell. /run/current-system/sw/bin has all of them on a working
            # NixOS install — it's the canonical "system PATH".
            rebuild_path = NixOperations._build_rebuild_path()

            # Env vars nixos-rebuild and the tools it shells out to need:
            # - HOME is required by libgit2 (used by Nix to read flake
            #   inputs of type git+file://). Without it libgit2's ownership
            #   check misbehaves on dev trees.
            # - NIX_PATH / XDG_* keep nix's caches/config consistent with
            #   the host.
            # - LOCALE_ARCHIVE / LANG / TZDIR avoid spurious locale/timezone
            #   warnings.
            #
            # CRITICAL: only inherit a var that is actually set AND non-empty.
            # `--setenv=NAME` for a NAME that is unset/empty in the caller's
            # environment propagates an EMPTY value. Nix then derives, e.g.,
            # its git cache as `$XDG_CACHE_HOME/nix/gitv3` — which with an
            # empty XDG_CACHE_HOME becomes the *relative* path "nix/gitv3"
            # and the flake-input fetch dies with
            #   error: not an absolute path: "nix/gitv3"
            # Omitting the flag entirely lets Nix compute its correct
            # default (e.g. $HOME/.cache) — and HOME is always set below.
            inherit_vars = [
                "HOME", "NIX_PATH", "NIX_REMOTE",
                "XDG_CACHE_HOME", "XDG_CONFIG_HOME", "XDG_DATA_HOME",
                "LOCALE_ARCHIVE", "LANG", "TZDIR",
            ]
            setenv_flags = [
                f"--setenv={name}"
                for name in inherit_vars
                if os.environ.get(name)  # set and non-empty
            ]

            cmd = [
                "systemd-run",
                "--unit", unit_name,
                "--property=KillMode=mixed",
                "--property=TimeoutStopSec=600",
                f"--property=StandardOutput=append:{output_path}",
                f"--property=StandardError=append:{output_path}",
                f"--setenv=PATH={rebuild_path}",
                *setenv_flags,
                "nixos-rebuild", "switch", "--flake", str(NixOperations.FLAKE_DIR),
            ]

            result = subprocess.run(cmd, capture_output=True, text=True, timeout=15)
            if result.returncode != 0:
                err = (result.stderr or result.stdout or "unknown error").strip()
                logger.error(f"systemd-run failed to start rebuild: {err}")
                NixOperations._last_rebuild_error = err
                NixOperations._last_rebuild_exit_code = 1
                return {
                    'success': False,
                    'message': f'systemd-run failed: {err}',
                    'pid': None,
                }

            NixOperations._current_rebuild_output_file = output_path
            NixOperations._current_rebuild_output_offset = 0

            # Persist state for service-restart recovery (just the log file +
            # offset; the unit name is constant).
            NixOperations._save_rebuild_state(output_path, 0)

            logger.info(f"Started rebuild as {unit_name}, logging to {output_path}")

            return {
                'success': True,
                'message': 'Rebuild started',
                'unit': unit_name,
            }

        except Exception as e:
            logger.error(f"Error starting rebuild: {e}")
            NixOperations._current_rebuild_output_file = None
            NixOperations._last_rebuild_error = str(e)
            NixOperations._last_rebuild_exit_code = 1
            return {
                'success': False,
                'message': str(e),
                'pid': None,
            }

    @staticmethod
    def _refresh_local_inputs():
        """
        Refresh flake inputs whose source is a live local working tree, so
        the rebuild reads HEAD-of-disk rather than a stale lock snapshot.

        Why this is needed
        ──────────────────
        Nix pins every flake input in flake.lock by (narHash, lastModified,
        revision). For inputs that point at remote URLs (github:, git+https:,
        tarball mirrors, etc.) the lock is fully appropriate: those sources
        don't change underfoot. For inputs that point at LOCAL working trees
        — `path:/some/dir` or `git+file:///some/dir` — the lock can become
        silently stale: the user edits a file, the narHash changes on disk,
        but Nix continues to use the locked snapshot until the lock is
        explicitly updated. That manifests as "I clicked Apply but my edit
        didn't take effect."

        Both `path:` and `git+file://` exhibit this. Locking is by design;
        the explicit refresh is the canonical Nix mechanism. scripts/build.sh
        already does it manually for command-line builds; we do it
        automatically on every UI Apply so the two code paths behave
        identically.

        Identification, not naming
        ──────────────────────────
        We do NOT hardcode input names. Different forks of this project,
        different installer versions, and devs working on multiple repos
        may all have different names for their local input(s). Instead we
        read flake.lock and select inputs whose `locked.type` indicates a
        local working tree (`path` or `git` with a `file://` URL).
        Production installs only use remote inputs, so this is a no-op
        there. Dev installs get every local input refreshed regardless of
        what it's named or how many there are.

        Best-effort: failures are logged but don't block the rebuild —
        a transient `nix flake lock` failure shouldn't prevent the user
        from applying their config.
        """
        try:
            lock_path = NixOperations.FLAKE_DIR / "flake.lock"
            if not lock_path.exists():
                return

            try:
                lock = json.loads(lock_path.read_text())
            except Exception as e:
                logger.warning(f"Could not parse flake.lock: {e}")
                return

            # Walk root.inputs to get the user-facing input names; only
            # those can be passed to `--update-input`. Transitive inputs
            # of inputs are out of scope (we can't address them by name
            # from this flake anyway).
            nodes = lock.get("nodes", {})
            root = nodes.get("root", {})
            root_input_refs = root.get("inputs", {})

            to_refresh = []
            for input_name, target in root_input_refs.items():
                # `target` may be either a string node name or a list path.
                # Normalise to the actual node dict.
                if isinstance(target, list):
                    # Follow the path through nodes (rare for root inputs)
                    node = nodes
                    for step in target:
                        node = nodes.get(step, {})
                else:
                    node = nodes.get(target, {})

                locked = node.get("locked", {})
                if NixOperations._input_is_local_working_tree(locked):
                    to_refresh.append(input_name)

            if not to_refresh:
                return

            logger.info(f"Refreshing local working-tree flake inputs: {to_refresh}")
            for name in to_refresh:
                try:
                    result = subprocess.run(
                        [
                            "nix",
                            "--extra-experimental-features", "nix-command flakes",
                            "flake", "lock",
                            # These flags mirror scripts/build.sh — they're
                            # required when the source is a dirty git tree
                            # or a path: input, both of which are inherently
                            # non-reproducible and trigger Nix's safety check.
                            "--allow-dirty",
                            "--allow-dirty-locks",
                            "--update-input", name,
                            str(NixOperations.FLAKE_DIR),
                        ],
                        capture_output=True, text=True, timeout=60,
                    )
                    if result.returncode != 0:
                        logger.warning(
                            f"flake lock --update-input {name} returned "
                            f"{result.returncode}: {result.stderr.strip()}"
                        )
                    else:
                        logger.info(f"Refreshed input: {name}")
                except subprocess.TimeoutExpired:
                    logger.warning(f"Timed out refreshing input {name}")
                except Exception as e:
                    logger.warning(f"Error refreshing input {name}: {e}")
        except Exception as e:
            logger.warning(f"_refresh_local_inputs failed: {e}")

    @staticmethod
    def _input_is_local_working_tree(locked: dict) -> bool:
        """
        Return True if a flake.lock `locked` entry refers to a local working
        tree whose contents can change without a corresponding lock update.

        Two cases qualify:
        - `path:` inputs — Nix pins a narHash but won't re-import unless the
          lock is updated, even when the directory's contents have changed.
        - `git:` inputs whose URL is `file://...` — same problem; the local
          checkout is mutable but the lock pins a specific commit/hash.

        Remote inputs (github:, git+https:, tarball:, etc.) are not local
        working trees and are correctly handled by their own lock entries.
        """
        if not locked:
            return False
        ltype = locked.get("type", "")
        if ltype == "path":
            return True
        if ltype == "git":
            url = locked.get("url", "")
            return url.startswith("file://") or url.startswith("/")
        return False

    @staticmethod
    def get_full_log() -> str:
        """
        Return the full text of the most relevant rebuild log:
        - if a rebuild is currently running, the live log file
        - otherwise, the log file from the last persisted status
        - empty string if no log is known.

        Used by the page-load handshake so reloading the UI mid-build (or
        after a build finished) doesn't lose history.
        """
        # In-memory: active rebuild
        candidate = NixOperations._current_rebuild_output_file
        # On-disk fallback: most-recently saved status
        if not candidate:
            try:
                if NixOperations.LATEST_STATUS.exists():
                    with open(NixOperations.LATEST_STATUS, "r") as f:
                        saved = json.load(f)
                    candidate = saved.get("log_file")
            except Exception as e:
                logger.warning(f"Could not read latest-status for full log: {e}")
        # Or the persisted in-flight log pointer
        if not candidate:
            try:
                if NixOperations.REBUILD_LOG_FILE_REF.exists():
                    candidate = NixOperations.REBUILD_LOG_FILE_REF.read_text().strip()
            except Exception as e:
                logger.warning(f"Could not read rebuild.log pointer: {e}")
        if not candidate:
            return ""
        try:
            p = Path(candidate)
            if not p.exists():
                return ""
            return p.read_text()
        except Exception as e:
            logger.warning(f"Could not read rebuild log {candidate}: {e}")
            return ""

    @staticmethod
    def _build_rebuild_path() -> str:
        """
        Build a PATH for the spawned rebuild that doesn't depend on
        admin-api's cached process environment.

        We start with /run/current-system/sw/bin (the canonical system PATH
        on a running NixOS host — guaranteed to have nixos-rebuild, nix,
        coreutils, bash, git, systemctl, etc.) and append admin-api's
        current PATH as a fallback. That way even if /run/current-system
        is somehow incomplete, anything we explicitly listed in
        admin-web.nix's Environment= still resolves.
        """
        parts = ["/run/current-system/sw/bin"]
        env_path = os.environ.get("PATH", "")
        if env_path:
            for p in env_path.split(":"):
                if p and p not in parts:
                    parts.append(p)
        return ":".join(parts)

    @staticmethod
    def _unit_active() -> bool:
        """Return True if the rebuild unit is currently active."""
        try:
            result = subprocess.run(
                ["systemctl", "is-active", NixOperations.REBUILD_UNIT],
                capture_output=True, text=True, timeout=5,
            )
            return result.stdout.strip() == "active"
        except Exception as e:
            logger.error(f"Error checking unit active state: {e}")
            return False

    @staticmethod
    def _unit_exit_code() -> Optional[int]:
        """
        Return the exit code of the most recent run of the rebuild unit, or
        None if the unit doesn't exist / has no recorded exit code yet.

        We read several systemd properties together so we don't get fooled by
        a missing-unit lookup (which returns ExecMainStatus=0 by default) or
        a unit that died from a signal.
        """
        try:
            result = subprocess.run(
                ["systemctl", "show", NixOperations.REBUILD_UNIT,
                 "--property=ExecMainStatus",
                 "--property=ExecMainCode",
                 "--property=Result",
                 "--property=ActiveState",
                 "--property=LoadState"],
                capture_output=True, text=True, timeout=5,
            )
            props = {}
            for line in result.stdout.splitlines():
                if "=" in line:
                    k, _, v = line.partition("=")
                    props[k.strip()] = v.strip()

            load_state = props.get("LoadState", "")
            active_state = props.get("ActiveState", "")
            result_val = props.get("Result", "")
            exec_code = props.get("ExecMainCode", "")
            exec_status = props.get("ExecMainStatus", "")

            # Unit was never created or has been forgotten — no exit code.
            if load_state == "not-found":
                return None
            # Unit exists but hasn't run / has no recorded exit yet.
            if not exec_code or exec_code == "0":
                # ExecMainCode==0 means "not yet exited"; ExecMainStatus is
                # only meaningful once the process has actually run.
                if active_state in ("activating", "active", "reloading"):
                    return None
                # Inactive without an ExecMainCode shouldn't happen for a
                # unit we just started, but treat as still-pending.
                return None

            # The unit has exited. ExecMainCode is one of CLD_* values:
            #   1 = CLD_EXITED (normal exit)
            #   2 = CLD_KILLED (signal)
            #   3 = CLD_DUMPED
            #   4 = CLD_TRAPPED
            #   5 = CLD_STOPPED
            #   6 = CLD_CONTINUED
            try:
                exec_code_int = int(exec_code)
                exec_status_int = int(exec_status) if exec_status else 0
            except ValueError:
                logger.warning(
                    f"Unparseable exit-state for {NixOperations.REBUILD_UNIT}: "
                    f"code={exec_code!r} status={exec_status!r}"
                )
                return 1

            if exec_code_int == 1:
                # Normal exit: ExecMainStatus is the actual return code.
                # Result==success means 0; Result!=success means non-zero.
                # If they disagree, trust Result (more reliable).
                if result_val == "success":
                    return exec_status_int  # usually 0
                return exec_status_int if exec_status_int != 0 else 1

            # Killed by signal or other non-normal exit: treat as failure.
            logger.warning(
                f"Rebuild unit exited abnormally: code={exec_code_int} "
                f"status={exec_status_int} result={result_val}"
            )
            return 1
        except Exception as e:
            logger.error(f"Error reading unit exit code: {e}")
            return None

    @staticmethod
    @staticmethod
    def _apply_flip_failure(status: Dict[str, Any]) -> Dict[str, Any]:
        """Fold an admin-api blue/green flip failure into a finished
        rebuild status.

        A flip failure (new admin-api failed its health check, or the
        Caddy reload failed) deliberately does NOT fail the rebuild —
        the activation script exits 0 so the rest of activation
        completes and the box keeps serving the previous, known-good
        admin-api. The failure is recorded in FLIP_FAILED_FILE. Here we
        surface it: mark the rebuild partial_success and append a
        human-readable line to the output the UI already renders.
        """
        try:
            if not NixOperations.FLIP_FAILED_FILE.exists():
                return status
            try:
                marker = json.loads(NixOperations.FLIP_FAILED_FILE.read_text())
            except Exception:
                marker = {}
            reason = marker.get("reason", "unknown error")
            note = (
                "\n[admin-api] hot-swap to the new version failed "
                f"({reason}) — still serving the previous admin-api. "
                "The rest of the rebuild was applied. Re-apply to retry."
            )
            status = dict(status)
            status["partial_success"] = True
            status["output"] = (status.get("output") or "") + note
        except Exception as e:
            logger.error(f"Error folding flip-failure marker into status: {e}")
        return status

    def get_rebuild_status() -> Dict[str, Any]:
        """
        Get status of current rebuild operation.

        Liveness is determined by querying systemctl for the transient
        homefree-rebuild.service unit. The unit lives independently of
        admin-api, so this function works correctly even after admin-api
        has been restarted mid-rebuild.

        Returns:
            Dictionary with:
                - running: bool
                - output: str (new output since last call, or full output if finished)
                - exit_code: Optional[int]
                - partial_success: bool (True if generation activated but services failed)
        """
        # If we lost in-memory state (e.g. admin-api was restarted), try to
        # recover the log file path from disk.
        if NixOperations._current_rebuild_output_file is None:
            saved_state = NixOperations._load_rebuild_state()
            if saved_state:
                log_file, offset = saved_state
                NixOperations._current_rebuild_output_file = log_file
                NixOperations._current_rebuild_output_offset = offset
                logger.info(f"Restored rebuild state: log={log_file}, offset={offset}")

        unit_active = NixOperations._unit_active()
        output_file = NixOperations._current_rebuild_output_file

        # No active rebuild and no tracked log file — fall back to last
        # persisted status / in-memory cache.
        if not unit_active and output_file is None:
            if NixOperations.LATEST_STATUS.exists():
                try:
                    with open(NixOperations.LATEST_STATUS, 'r') as f:
                        saved_status = json.load(f)
                    log_file = Path(saved_status.get('log_file', ''))
                    full_output = ''
                    if log_file.exists():
                        with open(log_file, 'r') as f:
                            full_output = f.read()
                    return NixOperations._apply_flip_failure({
                        'running': False,
                        'output': full_output,
                        'exit_code': saved_status.get('exit_code'),
                        'partial_success': saved_status.get('partial_success', False),
                    })
                except Exception as e:
                    logger.error(f"Error reading saved rebuild status: {e}")

            if NixOperations._last_rebuild_exit_code is not None:
                return {
                    'running': False,
                    'output': NixOperations._last_rebuild_output or '',
                    'exit_code': NixOperations._last_rebuild_exit_code,
                    'partial_success': NixOperations._last_rebuild_partial_success,
                }

            return {
                'running': False,
                'output': '',
                'exit_code': None,
                'partial_success': False,
            }

        # Read incremental output from the log file (works for both
        # running-and-streaming and just-finished cases).
        new_output = ''
        if output_file and os.path.exists(output_file):
            try:
                with open(output_file, 'r') as f:
                    f.seek(NixOperations._current_rebuild_output_offset)
                    new_output = f.read()
                    NixOperations._current_rebuild_output_offset = f.tell()
                    if new_output:
                        NixOperations._save_rebuild_state(
                            output_file,
                            NixOperations._current_rebuild_output_offset,
                        )
            except Exception as e:
                logger.error(f"Error reading rebuild output: {e}")

        if unit_active:
            return {
                'running': True,
                'output': new_output,
                'exit_code': None,
                'partial_success': False,
            }

        # Unit is no longer active — rebuild has finished. Read the full
        # log first, then determine the exit code.
        full_output = ''
        if output_file and os.path.exists(output_file):
            try:
                with open(output_file, 'r') as f:
                    full_output = f.read()
            except Exception as e:
                logger.error(f"Error reading full rebuild output: {e}")

        exit_code = NixOperations._unit_exit_code()

        # Failure markers we look for in the log itself. nixos-rebuild-ng's
        # final summary line on a non-zero exit is the canonical signal.
        FAILURE_MARKERS = (
            "returned non-zero exit status",
            "\nerror:",
            "error: builder for",
            "error: opening Git repository",
        )
        # Success marker — nixos-rebuild prints this near the end of a clean
        # switch. If we see it AND no failure markers, the build was good
        # even when systemd lost track of the unit's exit code.
        SUCCESS_MARKERS = (
            "activating the configuration",
            "reloading user units",
            "setting up /etc",
        )

        def log_implies_failure(text: str) -> bool:
            tail = text[-4000:]
            return any(m in tail for m in FAILURE_MARKERS)

        def log_implies_success(text: str) -> bool:
            return any(m in text for m in SUCCESS_MARKERS)

        if exit_code is None:
            # Unit is gone (e.g. admin-api was restarted between the unit
            # transitioning to inactive and us getting a chance to read its
            # exit status). Reconstruct from the log.
            if full_output and log_implies_failure(full_output):
                logger.warning(
                    "Rebuild unit gone; log contains failure markers — "
                    "treating as failed."
                )
                exit_code = 1
            elif full_output and log_implies_success(full_output):
                logger.info(
                    "Rebuild unit gone; log contains success markers — "
                    "treating as succeeded."
                )
                exit_code = 0
            else:
                # No log signal either way. Conservatively report failure
                # so the user sees an actionable state, NOT a stuck spinner.
                logger.warning(
                    "Rebuild unit gone; log inconclusive — reporting as "
                    "failed so the UI doesn't hang."
                )
                exit_code = 1
        elif exit_code == 0 and full_output and log_implies_failure(full_output):
            # Belt-and-suspenders cross-check: systemd reports 0 but the log
            # clearly shows an error. Trust the log.
            logger.warning(
                "Log indicates failure despite systemd exit_code=0; "
                "treating as failed rebuild."
            )
            exit_code = 1

        logger.info(f"Rebuild unit finished with exit code: {exit_code}")

        partial_success = NixOperations._detect_partial_success(full_output, exit_code)
        if exit_code == 0 and partial_success:
            partial_success = False

        NixOperations._last_rebuild_exit_code = exit_code
        NixOperations._last_rebuild_partial_success = partial_success
        NixOperations._last_rebuild_output = full_output

        try:
            status_data = {
                "exit_code": exit_code,
                "partial_success": partial_success,
                "timestamp": datetime.now().isoformat(),
                "log_file": output_file,
                "output_length": len(full_output),
            }
            with open(NixOperations.LATEST_STATUS, 'w') as f:
                json.dump(status_data, f, indent=2)

            # On full success, mark the on-disk config as "applied" so the
            # /api/config/dirty endpoint can stop reporting unapplied changes.
            if exit_code == 0 and not partial_success:
                NixOperations._mark_config_applied()

            NixOperations._cleanup_old_logs()
            NixOperations._clear_rebuild_state()
            NixOperations._current_rebuild_output_file = None
            NixOperations._current_rebuild_output_offset = 0

            # Reset the failed/inactive transient unit so the next rebuild
            # can re-create it under the same name.
            subprocess.run(
                ["systemctl", "reset-failed", NixOperations.REBUILD_UNIT],
                capture_output=True, timeout=5,
            )

            # NB: we used to call _restart_admin_if_changed here. That logic
            # has moved to a dedicated systemd path-watch unit
            # (homefree-admin-watch.path / .service) defined in admin-web.nix
            # which fires on any /run/current-system swap — UI rebuilds AND
            # shell rebuilds AND CI runs all get the same treatment. The
            # in-process path was redundant and could only handle UI rebuilds.
        except Exception as e:
            logger.error(f"Error finalising rebuild: {e}")

        return NixOperations._apply_flip_failure({
            'running': False,
            'output': new_output,
            'exit_code': exit_code,
            'partial_success': partial_success,
        })

    @staticmethod
    def generate_diff() -> Dict[str, Any]:
        """
        Generate a diff showing config changes.

        Returns:
            Dictionary with diff output
        """
        try:
            config_file = NixOperations.FLAKE_DIR / "homefree-configuration.nix"
            backup_dir = Path("/var/lib/homefree-admin/config-backups")

            if not backup_dir.exists():
                return {
                    'success': False,
                    'diff': '',
                    'message': 'No backup available for comparison'
                }

            # Get most recent backup
            backups = sorted(backup_dir.glob("homefree-configuration.*.nix"))
            if not backups:
                return {
                    'success': False,
                    'diff': '',
                    'message': 'No backup available for comparison'
                }

            latest_backup = backups[-1]

            # Run diff
            result = subprocess.run(
                ["diff", "-u", str(latest_backup), str(config_file)],
                capture_output=True,
                text=True
            )

            # diff returns 1 if files differ, 0 if same
            return {
                'success': True,
                'diff': result.stdout,
                'has_changes': result.returncode == 1
            }

        except Exception as e:
            logger.error(f"Error generating diff: {e}")
            return {
                'success': False,
                'diff': '',
                'message': str(e)
            }

    @staticmethod
    def _parse_changes(output: str) -> List[str]:
        """Parse dry-activate output to extract changes"""
        changes = []

        # Look for typical change indicators in nixos-rebuild output
        lines = output.split('\n')
        for line in lines:
            if any(indicator in line.lower() for indicator in [
                'would restart', 'would reload', 'would stop', 'would start',
                'activation script', 'setting up', 'updating'
            ]):
                changes.append(line.strip())

        return changes

    @staticmethod
    def _parse_errors(output: str) -> List[str]:
        """Parse output to extract errors and warnings"""
        errors = []

        lines = output.split('\n')
        for line in lines:
            if any(indicator in line.lower() for indicator in [
                'error:', 'warning:', 'failed', 'cannot'
            ]):
                errors.append(line.strip())

        return errors

    @staticmethod
    def _cleanup_old_logs():
        """Keep only the last N rebuild logs"""
        try:
            if not NixOperations.LOG_DIR.exists():
                return

            log_files = sorted(NixOperations.LOG_DIR.glob("rebuild-*.log"))
            if len(log_files) > NixOperations.MAX_LOGS_TO_KEEP:
                for old_log in log_files[:-NixOperations.MAX_LOGS_TO_KEEP]:
                    old_log.unlink()
                    logger.info(f"Cleaned up old rebuild log: {old_log}")
        except Exception as e:
            logger.error(f"Error cleaning up old logs: {e}")

    @staticmethod
    def _save_rebuild_state(log_file: str, offset: int):
        """Persist rebuild state to disk (survives service restarts).

        With the systemd-run refactor we no longer track a PID — the unit
        name is constant. We only need the log file path and read offset
        so a restarted admin-api can resume streaming output from where it
        left off.
        """
        try:
            NixOperations.REBUILD_STATE_DIR.mkdir(parents=True, exist_ok=True)
            NixOperations.REBUILD_LOG_FILE_REF.write_text(log_file)
            NixOperations.REBUILD_OFFSET_FILE.write_text(str(offset))
        except Exception as e:
            logger.error(f"Error saving rebuild state: {e}")

    @staticmethod
    def _load_rebuild_state() -> Optional[tuple]:
        """Load (log_file, offset) from disk, or None if not present."""
        try:
            if not all([
                NixOperations.REBUILD_LOG_FILE_REF.exists(),
                NixOperations.REBUILD_OFFSET_FILE.exists(),
            ]):
                return None
            log_file = NixOperations.REBUILD_LOG_FILE_REF.read_text().strip()
            offset = int(NixOperations.REBUILD_OFFSET_FILE.read_text().strip())
            return (log_file, offset)
        except (ValueError, FileNotFoundError) as e:
            logger.warning(f"Error loading rebuild state: {e}")
            NixOperations._clear_rebuild_state()
            return None

    @staticmethod
    def _clear_rebuild_state():
        """Clear rebuild state files"""
        try:
            for f in [
                NixOperations.REBUILD_LOG_FILE_REF,
                NixOperations.REBUILD_OFFSET_FILE,
            ]:
                if f.exists():
                    f.unlink()
        except Exception as e:
            logger.error(f"Error clearing rebuild state: {e}")

    @staticmethod
    def _mark_config_applied():
        """
        Snapshot /etc/nixos/homefree-config.json into
        /var/lib/homefree-admin/applied-config.json so the dirty-state
        endpoint can tell whether subsequent edits have been applied.
        """
        try:
            src = Path("/etc/nixos/homefree-config.json")
            if src.exists():
                NixOperations.APPLIED_CONFIG_FILE.parent.mkdir(parents=True, exist_ok=True)
                NixOperations.APPLIED_CONFIG_FILE.write_text(src.read_text())
                logger.info("Marked config as applied")
        except Exception as e:
            logger.error(f"Error marking config applied: {e}")

        # Also snapshot the homefree-base flake revision the system was just
        # built against, so the System Updates page / dirty-state endpoint can
        # tell whether a pending version update has actually been applied.
        try:
            from services.system_updates import SystemUpdates
            current = SystemUpdates.get_current()
            if current and current.get("rev"):
                SystemUpdates.APPLIED_FLAKE_REV_FILE.parent.mkdir(
                    parents=True, exist_ok=True
                )
                SystemUpdates.APPLIED_FLAKE_REV_FILE.write_text(current["rev"])
                logger.info(f"Marked flake revision {current['rev']} as applied")
        except Exception as e:
            logger.error(f"Error marking flake revision applied: {e}")


    @staticmethod
    def _sync_config() -> Dict[str, Any]:
        """
        Sync homefree-config.json with module.nix schema.
        Removes obsolete options, adds new options with defaults, preserves user values.

        Returns:
            Dictionary with:
                - success: bool
                - message: str
                - changes: List[str] (if any changes were made)
        """
        try:
            sync_script = Path("/home/erahhal/homefree/scripts/sync-config.sh")
            config_file = NixOperations.FLAKE_DIR / "homefree-config.json"

            # Check if files exist
            if not sync_script.exists():
                logger.warning(f"Sync script not found at {sync_script}")
                return {
                    'success': False,
                    'message': f'Sync script not found at {sync_script}'
                }

            if not config_file.exists():
                logger.info(f"Config file {config_file} does not exist, skipping sync")
                return {
                    'success': True,
                    'message': 'Config file does not exist, skipping sync'
                }

            # Run sync script
            logger.info(f"Running config sync: {sync_script}")
            result = subprocess.run(
                [str(sync_script), "-f", str(NixOperations.FLAKE_DIR)],
                capture_output=True,
                text=True,
                timeout=60  # 1 minute timeout
            )

            output = result.stdout + result.stderr

            if result.returncode == 0:
                logger.info("Config sync completed successfully")
                if output:
                    logger.info(f"Sync output:\n{output}")
                return {
                    'success': True,
                    'message': 'Config synced successfully',
                    'output': output
                }
            else:
                logger.error(f"Config sync failed with exit code {result.returncode}")
                logger.error(f"Sync output:\n{output}")
                return {
                    'success': False,
                    'message': f'Sync failed with exit code {result.returncode}',
                    'output': output
                }

        except subprocess.TimeoutExpired:
            logger.error("Config sync timed out")
            return {
                'success': False,
                'message': 'Config sync timed out after 60 seconds'
            }
        except Exception as e:
            logger.error(f"Error running config sync: {e}")
            return {
                'success': False,
                'message': str(e)
            }


