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
    REBUILD_PID_FILE = REBUILD_STATE_DIR / "rebuild.pid"
    REBUILD_LOG_FILE_REF = REBUILD_STATE_DIR / "rebuild.log"
    REBUILD_OFFSET_FILE = REBUILD_STATE_DIR / "rebuild.offset"

    _current_rebuild_process = None
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

        Returns:
            Dictionary with operation status and output
        """
        try:
            # Clear any previous error state
            NixOperations._last_rebuild_error = None
            NixOperations._last_rebuild_exit_code = None
            NixOperations._last_rebuild_partial_success = False
            NixOperations._last_rebuild_output = None

            # Ensure log directory exists
            NixOperations.LOG_DIR.mkdir(parents=True, exist_ok=True)

            # Create timestamped log file in persistent location
            timestamp = datetime.now().strftime("%Y%m%d-%H%M%S")
            log_file = NixOperations.LOG_DIR / f"rebuild-{timestamp}.log"
            output_path = str(log_file)

            # Write initial status message to ensure output exists immediately
            with open(output_path, 'w') as f:
                f.write("Starting NixOS rebuild...\n")
                f.write("Evaluating configuration and downloading dependencies...\n")
                f.flush()

            # Run rebuild in background, return immediately
            # Redirect output to file for streaming (append mode)
            with open(output_path, 'a') as f:
                process = subprocess.Popen(
                    ["nixos-rebuild", "switch", "--flake", str(NixOperations.FLAKE_DIR)],
                    stdout=f,
                    stderr=subprocess.STDOUT,
                    text=True
                )

            # Store process and output file for later progress monitoring
            NixOperations._current_rebuild_process = process
            NixOperations._current_rebuild_output_file = output_path
            NixOperations._current_rebuild_output_offset = 0

            # Persist state to disk (survives service restarts)
            NixOperations._save_rebuild_state(process.pid, output_path, 0)

            logger.info(f"Started rebuild process {process.pid}, logging to {output_path}")

            return {
                'success': True,
                'message': 'Rebuild started',
                'pid': process.pid
            }

        except Exception as e:
            logger.error(f"Error starting rebuild: {e}")
            # Set process to None and ensure we can report the error
            NixOperations._current_rebuild_process = None
            NixOperations._current_rebuild_output_file = None
            NixOperations._last_rebuild_error = str(e)
            NixOperations._last_rebuild_exit_code = 1  # Indicate failure
            return {
                'success': False,
                'message': str(e),
                'pid': None
            }

    @staticmethod
    def get_rebuild_status() -> Dict[str, Any]:
        """
        Get status of current rebuild operation.

        Returns:
            Dictionary with:
                - running: bool
                - output: str (new output since last call, or full output if finished)
                - exit_code: Optional[int]
                - partial_success: bool (True if generation activated but services failed)
        """
        process = NixOperations._current_rebuild_process
        output_file = NixOperations._current_rebuild_output_file

        # Try to restore from persistent state if process is None (service restart)
        if process is None:
            saved_state = NixOperations._load_rebuild_state()
            if saved_state:
                pid, log_file, offset = saved_state
                # Restore process reference (re-attach to running process)
                try:
                    # Create a pseudo-process object that we can poll
                    # We can't recreate the Popen object, but we can track the PID
                    NixOperations._current_rebuild_process = type('Process', (), {
                        'pid': pid,
                        'poll': lambda: None  # Always return None (still running)
                    })()
                    NixOperations._current_rebuild_output_file = log_file
                    NixOperations._current_rebuild_output_offset = offset
                    process = NixOperations._current_rebuild_process
                    output_file = log_file
                    logger.info(f"Restored rebuild process {pid} from persistent state")
                except Exception as e:
                    logger.error(f"Error restoring rebuild process: {e}")
                    NixOperations._clear_rebuild_state()

        if process is None:
            # No active rebuild process
            # CHECK PERSISTENT STORAGE FIRST (survives service restarts)
            if NixOperations.LATEST_STATUS.exists():
                try:
                    with open(NixOperations.LATEST_STATUS, 'r') as f:
                        saved_status = json.load(f)

                    # Read full output from log file
                    log_file = Path(saved_status.get('log_file', ''))
                    full_output = ''
                    if log_file.exists():
                        with open(log_file, 'r') as f:
                            full_output = f.read()
                        logger.debug(f"Loaded rebuild logs from persistent storage: {log_file} ({len(full_output)} chars)")
                    else:
                        logger.warning(f"Log file not found: {log_file}")

                    return {
                        'running': False,
                        'output': full_output,
                        'exit_code': saved_status.get('exit_code'),
                        'partial_success': saved_status.get('partial_success', False)
                    }
                except Exception as e:
                    logger.error(f"Error reading saved rebuild status from {NixOperations.LATEST_STATUS}: {e}")

            # Fallback to in-memory state (for backwards compatibility during process lifetime)
            if NixOperations._last_rebuild_exit_code is not None:
                logger.debug(f"Returning in-memory rebuild state: exit_code={NixOperations._last_rebuild_exit_code}, partial_success={NixOperations._last_rebuild_partial_success}")
                return {
                    'running': False,
                    'output': NixOperations._last_rebuild_output or '',
                    'exit_code': NixOperations._last_rebuild_exit_code,
                    'partial_success': NixOperations._last_rebuild_partial_success
                }

            # No rebuild has been run yet
            logger.debug("No rebuild has been run yet, returning initial state")
            return {
                'running': False,
                'output': '',
                'exit_code': None,
                'partial_success': False
            }

        # Check if process is still running
        exit_code = process.poll()

        # Read new output from file
        new_output = ''
        if output_file and os.path.exists(output_file):
            try:
                with open(output_file, 'r') as f:
                    # Seek to last read position
                    f.seek(NixOperations._current_rebuild_output_offset)
                    new_output = f.read()
                    # Update offset for next read
                    NixOperations._current_rebuild_output_offset = f.tell()

                    # Persist updated offset to disk (for service restart recovery)
                    if new_output:  # Only update if we read something
                        NixOperations._save_rebuild_state(
                            process.pid,
                            output_file,
                            NixOperations._current_rebuild_output_offset
                        )
            except Exception as e:
                logger.error(f"Error reading rebuild output: {e}")

        if exit_code is None:
            # Still running
            return {
                'running': True,
                'output': new_output,
                'exit_code': None,
                'partial_success': False  # Not applicable while running
            }
        else:
            # Process finished
            logger.info(f"Rebuild process finished with exit code: {exit_code}")

            # Read full output to detect partial success
            full_output = ''
            if output_file and os.path.exists(output_file):
                try:
                    with open(output_file, 'r') as f:
                        full_output = f.read()
                except Exception as e:
                    logger.error(f"Error reading full rebuild output: {e}")

            # Detect partial success: generation activated but services failed
            # This will return False for exit_code 0 (complete success)
            partial_success = NixOperations._detect_partial_success(full_output, exit_code)

            # Double-check: exit code 0 should NEVER have partial_success=True
            if exit_code == 0 and partial_success:
                logger.error("BUG: partial_success incorrectly set to True for exit_code 0! Correcting...")
                partial_success = False

            # Save state for subsequent requests (persistence across page refreshes)
            NixOperations._last_rebuild_exit_code = exit_code
            NixOperations._last_rebuild_partial_success = partial_success
            NixOperations._last_rebuild_output = full_output

            # SAVE TO PERSISTENT STORAGE (survives service restarts)
            try:
                status_data = {
                    "exit_code": exit_code,
                    "partial_success": partial_success,
                    "timestamp": datetime.now().isoformat(),
                    "log_file": output_file,
                    "output_length": len(full_output)
                }

                with open(NixOperations.LATEST_STATUS, 'w') as f:
                    json.dump(status_data, f, indent=2)

                logger.info(f"Rebuild status persisted to {NixOperations.LATEST_STATUS}: exit_code={exit_code}, partial_success={partial_success}")

                # Cleanup old logs
                NixOperations._cleanup_old_logs()

                # Clear rebuild state files (rebuild complete)
                NixOperations._clear_rebuild_state()

                # Check if admin-api service changed and restart if needed
                NixOperations._restart_admin_if_changed()
            except Exception as e:
                logger.error(f"Error saving rebuild status to persistent storage: {e}")

            # Clean up process reference
            NixOperations._current_rebuild_process = None

            return {
                'running': False,
                'output': new_output,
                'exit_code': exit_code,
                'partial_success': partial_success
            }

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
    def _save_rebuild_state(pid: int, log_file: str, offset: int):
        """Persist rebuild state to disk (survives service restarts)"""
        try:
            NixOperations.REBUILD_STATE_DIR.mkdir(parents=True, exist_ok=True)
            NixOperations.REBUILD_PID_FILE.write_text(str(pid))
            NixOperations.REBUILD_LOG_FILE_REF.write_text(log_file)
            NixOperations.REBUILD_OFFSET_FILE.write_text(str(offset))
            logger.info(f"Saved rebuild state: pid={pid}, log={log_file}, offset={offset}")
        except Exception as e:
            logger.error(f"Error saving rebuild state: {e}")

    @staticmethod
    def _load_rebuild_state() -> Optional[tuple]:
        """Load rebuild state from disk if exists and PID is still running"""
        try:
            if not all([
                NixOperations.REBUILD_PID_FILE.exists(),
                NixOperations.REBUILD_LOG_FILE_REF.exists(),
                NixOperations.REBUILD_OFFSET_FILE.exists()
            ]):
                return None

            pid = int(NixOperations.REBUILD_PID_FILE.read_text().strip())
            log_file = NixOperations.REBUILD_LOG_FILE_REF.read_text().strip()
            offset = int(NixOperations.REBUILD_OFFSET_FILE.read_text().strip())

            # Check if PID is still running
            try:
                os.kill(pid, 0)  # Signal 0 doesn't kill, just checks if process exists
                logger.info(f"Restored rebuild state: pid={pid}, log={log_file}, offset={offset}")
                return (pid, log_file, offset)
            except OSError:
                # Process not running anymore
                logger.info(f"Rebuild process {pid} no longer running, clearing stale state")
                NixOperations._clear_rebuild_state()
                return None

        except (ValueError, FileNotFoundError) as e:
            logger.warning(f"Error loading rebuild state: {e}")
            NixOperations._clear_rebuild_state()
            return None

    @staticmethod
    def _clear_rebuild_state():
        """Clear rebuild state files"""
        try:
            for f in [
                NixOperations.REBUILD_PID_FILE,
                NixOperations.REBUILD_LOG_FILE_REF,
                NixOperations.REBUILD_OFFSET_FILE
            ]:
                if f.exists():
                    f.unlink()
            logger.info("Cleared rebuild state files")
        except Exception as e:
            logger.error(f"Error clearing rebuild state: {e}")

    @staticmethod
    def _restart_admin_if_changed():
        """Restart admin-api service if it changed during rebuild"""
        try:
            # Check if admin-api needs daemon reload (unit file changed)
            result = subprocess.run(
                ["systemctl", "show", "admin-api", "--property=NeedDaemonReload"],
                capture_output=True,
                text=True,
                timeout=5
            )

            needs_reload = "yes" in result.stdout.lower()

            if needs_reload:
                logger.info("admin-api service changed, restarting...")

                # Reload systemd daemon
                subprocess.run(
                    ["systemctl", "daemon-reload"],
                    capture_output=True,
                    timeout=10
                )

                # Restart admin-api service
                subprocess.run(
                    ["systemctl", "restart", "admin-api"],
                    capture_output=True,
                    timeout=10
                )

                logger.info("admin-api service restarted successfully")
            else:
                logger.info("admin-api service unchanged, no restart needed")

        except Exception as e:
            logger.error(f"Error checking/restarting admin-api: {e}")


# Initialize process tracking
NixOperations._current_rebuild_process = None
