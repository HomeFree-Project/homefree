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
        if exit_code == 0:
            # Complete success
            return False

        if not output:
            return False

        output_lower = output.lower()

        # Look for activation success indicators
        activation_success = (
            'activating the configuration' in output_lower or
            'activation script' in output_lower
        )

        # Look for service failure indicators
        service_failure = (
            'failed' in output_lower and
            ('service' in output_lower or 'unit' in output_lower or '.service' in output_lower)
        )

        # Partial success: activation worked but services failed
        return activation_success and service_failure

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

            # Create a temporary file to capture output
            output_file = tempfile.NamedTemporaryFile(mode='w+', delete=False, suffix='.log')
            output_path = output_file.name
            output_file.close()

            # Run rebuild in background, return immediately
            # Redirect output to file for streaming
            with open(output_path, 'w') as f:
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

        if process is None:
            # No active rebuild process
            # Return saved state from previous rebuild (for persistence)
            if NixOperations._last_rebuild_exit_code is not None:
                return {
                    'running': False,
                    'output': NixOperations._last_rebuild_output or '',
                    'exit_code': NixOperations._last_rebuild_exit_code,
                    'partial_success': NixOperations._last_rebuild_partial_success
                }
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
            except Exception as e:
                logger.error(f"Error reading rebuild output: {e}")

        if exit_code is None:
            # Still running
            return {
                'running': True,
                'output': new_output,
                'exit_code': None
            }
        else:
            # Process finished
            # Read full output to detect partial success
            full_output = ''
            if output_file and os.path.exists(output_file):
                try:
                    with open(output_file, 'r') as f:
                        full_output = f.read()
                except Exception as e:
                    logger.error(f"Error reading full rebuild output: {e}")

            # Detect partial success: generation activated but services failed
            partial_success = NixOperations._detect_partial_success(full_output, exit_code)

            # Save state for subsequent requests (persistence across page refreshes)
            NixOperations._last_rebuild_exit_code = exit_code
            NixOperations._last_rebuild_partial_success = partial_success
            NixOperations._last_rebuild_output = full_output

            # Clean up process reference
            NixOperations._current_rebuild_process = None

            # Clean up temp file after a delay (allow final reads)
            if output_file:
                try:
                    # Don't delete immediately - frontend might still be polling
                    # In production, implement proper cleanup
                    pass
                except Exception as e:
                    logger.error(f"Error cleaning up output file: {e}")

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


# Initialize process tracking
NixOperations._current_rebuild_process = None
