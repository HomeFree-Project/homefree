"""
Backup operations service - handles restore.sh script operations
"""

import subprocess
import logging
import json
import re
import threading
from typing import Dict, Any, Optional, List
from pathlib import Path
from enum import Enum
from datetime import datetime

logger = logging.getLogger(__name__)


def strip_ansi_codes(text: str) -> str:
    """
    Remove ANSI escape codes (color codes, formatting) from text.

    Args:
        text: Text potentially containing ANSI codes

    Returns:
        Clean text without ANSI codes
    """
    if not text:
        return text
    # Remove ANSI escape sequences: \x1b[...m or \033[...m
    ansi_pattern = re.compile(r'\x1b\[[0-9;]*m')
    return ansi_pattern.sub('', text)


class BackupSource(Enum):
    """Backup source locations"""
    AUTO = "auto"
    LOCAL = "local"
    BACKBLAZE = "backblaze"


class BackupOperations:
    """Service for backup/restore operations"""

    RESTORE_SCRIPT = Path("/nix/var/nix/profiles/system/sw/bin/restore-cli")
    LOG_DIR = Path("/var/lib/homefree-admin/restore-logs")
    LATEST_STATUS = LOG_DIR / "latest-status.json"
    MAX_LOGS_TO_KEEP = 10

    # Persistent restore state (survives service restarts)
    RESTORE_STATE_DIR = Path("/var/lib/homefree-admin")
    RESTORE_PID_FILE = RESTORE_STATE_DIR / "restore.pid"
    RESTORE_LOG_FILE_REF = RESTORE_STATE_DIR / "restore.log"
    RESTORE_OFFSET_FILE = RESTORE_STATE_DIR / "restore.offset"
    RESTORE_STATUS_FILE = RESTORE_STATE_DIR / "restore-status.json"

    # Server-side cache for list_services (persists until force refresh)
    _services_cache: Dict[str, Any] = {}  # Cache by source (local, backblaze)
    _services_cache_timestamp: Dict[str, float] = {}  # Timestamp by source

    # Server-side cache for get_repository_paths (persists until force refresh)
    _paths_cache: Dict[str, Any] = {}  # Cache by "source:service"
    _paths_cache_timestamp: Dict[str, float] = {}  # Timestamp by "source:service"

    _current_restore_process = None
    _current_restore_output_file = None
    _current_restore_output_offset = 0
    _last_restore_error = None
    _last_restore_exit_code = None
    _last_restore_output = None

    @staticmethod
    def _ensure_directories() -> None:
        """Ensure required directories exist"""
        BackupOperations.LOG_DIR.mkdir(parents=True, exist_ok=True)
        BackupOperations.RESTORE_STATE_DIR.mkdir(parents=True, exist_ok=True)

    @staticmethod
    def list_services(source: BackupSource = BackupSource.AUTO, force_refresh: bool = False) -> Dict[str, Any]:
        """
        List all services that have backups available.

        Args:
            source: Backup source (auto, local, or backblaze)
            force_refresh: If True, bypass cache and fetch fresh data

        Returns:
            Dictionary with:
                - success: bool
                - services: List[str] (service names)
                - error: str (if failed)
        """
        try:
            # Check cache unless force refresh
            cache_key = source.value
            if not force_refresh:
                cached_data = BackupOperations._services_cache.get(cache_key)
                if cached_data:
                    cached_timestamp = BackupOperations._services_cache_timestamp.get(cache_key, 0)
                    age = datetime.now().timestamp() - cached_timestamp
                    logger.info(f"Returning cached services for {cache_key} (age: {age:.1f}s)")
                    return cached_data

            logger.info(f"Fetching fresh services list for {cache_key}")
            cmd = [str(BackupOperations.RESTORE_SCRIPT), "list-services"]
            if source != BackupSource.AUTO:
                cmd.extend(["--source", source.value])

            result = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                timeout=120  # Increased for Backblaze operations
            )

            if result.returncode == 0:
                # Parse service names from output (one per line)
                # Filter out log lines (contain ANSI color codes, [INFO], [WARN], etc.)
                services = []
                for line in result.stdout.strip().split('\n'):
                    line = line.strip()
                    # Skip empty lines, lines with ANSI codes, or log prefixes
                    if line and '\x1b' not in line and not any(x in line for x in ['[INFO]', '[WARN]', '[ERROR]']):
                        services.append(line)

                response = {
                    'success': True,
                    'services': services
                }

                # Only cache if we got actual data (don't cache empty results)
                # This prevents caching failure states or temporary empty responses
                if services:
                    BackupOperations._services_cache[cache_key] = response
                    BackupOperations._services_cache_timestamp[cache_key] = datetime.now().timestamp()
                    logger.info(f"Cached {len(services)} services for {cache_key}")
                else:
                    logger.warning(f"Not caching empty services list for {cache_key}")

                return response
            else:
                return {
                    'success': False,
                    'services': [],
                    'error': result.stderr or result.stdout
                }

        except subprocess.TimeoutExpired:
            logger.error("list-services timed out")
            return {
                'success': False,
                'services': [],
                'error': 'Operation timed out after 120 seconds'
            }
        except Exception as e:
            logger.error(f"Error listing services: {e}")
            return {
                'success': False,
                'services': [],
                'error': str(e)
            }

    @staticmethod
    def list_snapshots(service: str, source: BackupSource = BackupSource.AUTO) -> Dict[str, Any]:
        """
        List all snapshots for a specific service.

        Args:
            service: Service name
            source: Backup source (auto, local, or backblaze)

        Returns:
            Dictionary with:
                - success: bool
                - snapshots: List[Dict] (snapshot info with id, time, hostname, paths)
                - error: str (if failed)
        """
        try:
            cmd = [str(BackupOperations.RESTORE_SCRIPT), "list-snapshots", service]
            if source != BackupSource.AUTO:
                cmd.extend(["--source", source.value])

            result = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                timeout=60
            )

            if result.returncode == 0:
                # Parse snapshot info from output
                # Expected format: one snapshot per line with JSON structure
                # or simple text format: "ID | Time | Hostname | Paths"
                snapshots = BackupOperations._parse_snapshots(result.stdout)
                return {
                    'success': True,
                    'snapshots': snapshots
                }
            else:
                return {
                    'success': False,
                    'snapshots': [],
                    'error': result.stderr or result.stdout
                }

        except subprocess.TimeoutExpired:
            logger.error("list-snapshots timed out")
            return {
                'success': False,
                'snapshots': [],
                'error': 'Operation timed out after 60 seconds'
            }
        except Exception as e:
            logger.error(f"Error listing snapshots: {e}")
            return {
                'success': False,
                'snapshots': [],
                'error': str(e)
            }

    @staticmethod
    def _parse_snapshots(output: str) -> List[Dict[str, Any]]:
        """
        Parse snapshot output into structured data.

        Args:
            output: Raw output from list-snapshots command (JSON array from restic)

        Returns:
            List of snapshot dictionaries
        """
        if not output.strip():
            return []

        try:
            # Try to parse as JSON array (restic --json output)
            snapshots = json.loads(output.strip())
            if isinstance(snapshots, list):
                return snapshots
        except json.JSONDecodeError:
            pass

        # Fall back to line-by-line parsing for other formats
        snapshots = []
        for line in output.strip().split('\n'):
            if not line.strip():
                continue

            # Try to parse as JSON object
            try:
                snapshot = json.loads(line)
                snapshots.append(snapshot)
                continue
            except json.JSONDecodeError:
                pass

            # Fall back to pipe-separated format: "ID | Time | Hostname | Paths"
            parts = [p.strip() for p in line.split('|')]
            if len(parts) >= 3:
                snapshots.append({
                    'id': parts[0],
                    'time': parts[1],
                    'hostname': parts[2] if len(parts) > 2 else '',
                    'paths': parts[3] if len(parts) > 3 else ''
                })

        return snapshots

    @staticmethod
    def download_service(service: str) -> Dict[str, Any]:
        """
        Download a service backup from Backblaze to local storage.

        Args:
            service: Service name

        Returns:
            Dictionary with:
                - success: bool
                - output: str (command output)
                - error: str (if failed)
        """
        try:
            cmd = [str(BackupOperations.RESTORE_SCRIPT), "download", service]

            result = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                timeout=3600  # 1 hour for large downloads
            )

            if result.returncode == 0:
                return {
                    'success': True,
                    'output': result.stdout
                }
            else:
                return {
                    'success': False,
                    'output': result.stdout,
                    'error': result.stderr or "Download failed"
                }

        except subprocess.TimeoutExpired:
            logger.error("download timed out")
            return {
                'success': False,
                'error': 'Download timed out after 1 hour'
            }
        except Exception as e:
            logger.error(f"Error downloading service backup: {e}")
            return {
                'success': False,
                'error': str(e)
            }

    @staticmethod
    def get_repository_paths(service: str, source: BackupSource = BackupSource.AUTO, force_refresh: bool = False) -> Dict[str, Any]:
        """
        Get the list of paths backed up in a repository.

        Args:
            service: Service/repository name
            source: Backup source (auto, local, or backblaze)
            force_refresh: If True, bypass cache and fetch fresh data

        Returns:
            Dictionary with:
                - success: bool
                - paths: List[str] (paths in the repository)
                - error: str (if failed)
        """
        try:
            # Check cache unless force refresh
            cache_key = f"{source.value}:{service}"
            if not force_refresh:
                cached_data = BackupOperations._paths_cache.get(cache_key)
                if cached_data:
                    cached_timestamp = BackupOperations._paths_cache_timestamp.get(cache_key, 0)
                    age = datetime.now().timestamp() - cached_timestamp
                    logger.info(f"Returning cached paths for {cache_key} (age: {age:.1f}s)")
                    return cached_data

            logger.info(f"Fetching fresh paths for {cache_key}")

            cmd = [str(BackupOperations.RESTORE_SCRIPT), "list-paths", service]
            if source != BackupSource.AUTO:
                cmd.extend(["--source", source.value])

            result = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                timeout=60
            )

            if result.returncode == 0:
                # Parse paths from output (one per line, filter out metadata/log lines)
                paths = []
                for line in result.stdout.strip().split('\n'):
                    line = strip_ansi_codes(line.strip())
                    # Skip empty lines, lines with ANSI codes, or log prefixes
                    if line and not any(x in line for x in ['[INFO]', '[WARN]', '[ERROR]', 'snapshot', 'repository']):
                        paths.append(line)

                response = {
                    'success': True,
                    'paths': paths
                }

                # Only cache if we got actual data (don't cache empty results)
                # This prevents caching failure states or temporary empty responses
                if paths:
                    BackupOperations._paths_cache[cache_key] = response
                    BackupOperations._paths_cache_timestamp[cache_key] = datetime.now().timestamp()
                    logger.info(f"Cached {len(paths)} paths for {cache_key}")
                else:
                    logger.warning(f"Not caching empty paths list for {cache_key}")

                return response
            else:
                return {
                    'success': False,
                    'paths': [],
                    'error': result.stderr or result.stdout
                }

        except subprocess.TimeoutExpired:
            logger.error("get_repository_paths timed out")
            return {
                'success': False,
                'paths': [],
                'error': 'Operation timed out after 60 seconds'
            }
        except Exception as e:
            logger.error(f"Error getting repository paths: {e}")
            return {
                'success': False,
                'paths': [],
                'error': str(e)
            }

    @staticmethod
    def _write_restore_status(service: str, restore_type: str):
        """Write restore status to file for tracking."""
        try:
            BackupOperations.RESTORE_STATE_DIR.mkdir(parents=True, exist_ok=True)
            status = {
                'running': True,
                'service': service,
                'type': restore_type,
                'started_at': datetime.now().isoformat()
            }
            with open(BackupOperations.RESTORE_STATUS_FILE, 'w') as f:
                json.dump(status, f)
        except Exception as e:
            logger.warning(f"Failed to write restore status: {e}")

    @staticmethod
    def _clear_restore_status():
        """Clear restore status file."""
        try:
            if BackupOperations.RESTORE_STATUS_FILE.exists():
                BackupOperations.RESTORE_STATUS_FILE.unlink()
        except Exception as e:
            logger.warning(f"Failed to clear restore status: {e}")

    @staticmethod
    def restore_service(
        service: str,
        snapshot_id: Optional[str] = None,
        source: BackupSource = BackupSource.AUTO,
        dry_run: bool = False,
        create_snapshot: bool = False,
        _skip_status_tracking: bool = False
    ) -> Dict[str, Any]:
        """
        Restore a service from backup.

        Args:
            service: Service name
            snapshot_id: Specific snapshot ID to restore (None = latest)
            source: Backup source (auto, local, or backblaze)
            dry_run: If True, only show what would be restored
            create_snapshot: If True, create a snapshot before restoring
            _skip_status_tracking: Internal flag to skip status tracking (when called from restore_all)

        Returns:
            Dictionary with:
                - success: bool
                - output: str (command output)
                - error: str (if failed)
        """
        try:
            # Write restore status before starting (unless called from restore_all)
            if not _skip_status_tracking:
                # Clear any stale status before starting new restore
                BackupOperations._clear_restore_status()
                BackupOperations._write_restore_status(service, 'service')

            cmd = [str(BackupOperations.RESTORE_SCRIPT), "restore", service]

            if snapshot_id:
                cmd.append(snapshot_id)

            if source != BackupSource.AUTO:
                cmd.extend(["--source", source.value])

            # Add --yes flag for non-interactive mode (API calls)
            cmd.append("--yes")

            # Note: dry_run and create_snapshot would need to be added to restore.sh
            # For now, we'll log them but not pass them to the script
            if dry_run:
                logger.info(f"Dry-run mode requested (not yet implemented in restore.sh)")
            if create_snapshot:
                logger.info(f"Create-snapshot mode requested (not yet implemented in restore.sh)")

            # Log the command for debugging
            logger.info(f"Running restore command: {' '.join(cmd)}")

            # Create log file for this restore operation
            BackupOperations._ensure_directories()
            log_file = BackupOperations.LOG_DIR / f"restore-{service}-{datetime.now().strftime('%Y%m%d-%H%M%S')}.log"

            # Run restore in background using Popen (non-blocking)
            with open(log_file, 'w') as f:
                process = subprocess.Popen(
                    cmd,
                    stdout=f,
                    stderr=subprocess.STDOUT,
                    text=True
                )

            # Store process info for monitoring
            BackupOperations._current_restore_process = process
            BackupOperations._current_restore_output_file = log_file
            BackupOperations._current_restore_output_offset = 0

            logger.info(f"Restore process started in background (PID: {process.pid}), logging to {log_file}")

            # Return immediately - process runs in background
            return {
                'success': True,
                'message': f'Restore started in background (PID: {process.pid})',
                'log_file': str(log_file),
                'pid': process.pid
            }

        except FileNotFoundError:
            logger.error(f"Restore script not found: {BackupOperations.RESTORE_SCRIPT}")
            return {
                'success': False,
                'error': f'Restore script not found: {BackupOperations.RESTORE_SCRIPT}'
            }
        except Exception as e:
            logger.error(f"Error restoring service: {e}")
            return {
                'success': False,
                'error': str(e)
            }
        # Note: Status is NOT cleared here since process runs in background
        # Status will be cleared when process finishes or next restore starts

    @staticmethod
    def restore_all(
        snapshot_id: Optional[str] = None,
        source: BackupSource = BackupSource.AUTO,
        dry_run: bool = False,
        include_system_config: bool = False
    ) -> Dict[str, Any]:
        """
        Restore all services from backup.

        Args:
            snapshot_id: Specific snapshot ID to restore (None = latest)
            source: Backup source (auto, local, or backblaze)
            dry_run: If True, only show what would be restored
            include_system_config: If True, include system-config in restore

        Returns:
            Dictionary with:
                - success: bool
                - output: str (command output)
                - error: str (if failed)
        """
        try:
            # Clear any stale status before starting new restore
            BackupOperations._clear_restore_status()
            # Write restore status before starting (use "ALL" as service name for restore-all)
            BackupOperations._write_restore_status("ALL", 'all')

            # If system-config should be excluded, restore services individually
            if not include_system_config:
                logger.info("Excluding system-config from restore-all")

                # Get list of all services
                services_result = BackupOperations.list_services(source)
                if not services_result['success']:
                    return {
                        'success': False,
                        'error': f"Failed to list services: {services_result.get('error', 'Unknown error')}"
                    }

                all_services = services_result.get('services', [])
                system_config = services_result.get('system_config', [])
                extra_paths = services_result.get('extra_paths', [])

                # Combine all repositories except system-config
                repositories_to_restore = all_services + extra_paths

                if not repositories_to_restore:
                    return {
                        'success': False,
                        'error': 'No repositories found to restore'
                    }

                logger.info(f"Restoring {len(repositories_to_restore)} repositories (excluding system-config)")

                # Restore each repository individually
                combined_output = []
                failed_services = []

                for service in repositories_to_restore:
                    logger.info(f"Restoring {service}...")
                    result = BackupOperations.restore_service(
                        service=service,
                        snapshot_id=snapshot_id,
                        source=source,
                        dry_run=dry_run,
                        _skip_status_tracking=True  # restore_all manages status tracking
                    )

                    combined_output.append(f"=== Restoring {service} ===")
                    combined_output.append(result.get('output', ''))

                    if not result['success']:
                        failed_services.append(service)
                        logger.error(f"Failed to restore {service}: {result.get('error', 'Unknown error')}")

                if failed_services:
                    return {
                        'success': False,
                        'output': '\n'.join(combined_output),
                        'error': f"Failed to restore {len(failed_services)} repositories: {', '.join(failed_services)}"
                    }
                else:
                    return {
                        'success': True,
                        'output': '\n'.join(combined_output)
                    }

            # Otherwise, use the standard restore-all command
            cmd = [str(BackupOperations.RESTORE_SCRIPT), "restore-all"]

            if snapshot_id:
                cmd.append(snapshot_id)

            if source != BackupSource.AUTO:
                cmd.extend(["--source", source.value])

            # Add --yes flag for non-interactive mode (API calls)
            cmd.append("--yes")

            if dry_run:
                logger.info(f"Dry-run mode requested (not yet implemented in restore.sh)")

            # Log the command for debugging
            logger.info(f"Running restore-all command: {' '.join(cmd)}")

            # Create log file for this restore operation
            BackupOperations._ensure_directories()
            log_file = BackupOperations.LOG_DIR / f"restore-all-{datetime.now().strftime('%Y%m%d-%H%M%S')}.log"

            # Run restore-all in background using Popen (non-blocking)
            with open(log_file, 'w') as f:
                process = subprocess.Popen(
                    cmd,
                    stdout=f,
                    stderr=subprocess.STDOUT,
                    text=True
                )

            # Store process info for monitoring
            BackupOperations._current_restore_process = process
            BackupOperations._current_restore_output_file = log_file
            BackupOperations._current_restore_output_offset = 0

            logger.info(f"Restore-all process started in background (PID: {process.pid}), logging to {log_file}")

            # Return immediately - process runs in background
            return {
                'success': True,
                'message': f'Restore-all started in background (PID: {process.pid})',
                'log_file': str(log_file),
                'pid': process.pid
            }

        except FileNotFoundError:
            logger.error(f"Restore script not found: {BackupOperations.RESTORE_SCRIPT}")
            return {
                'success': False,
                'error': f'Restore script not found: {BackupOperations.RESTORE_SCRIPT}'
            }
        except Exception as e:
            logger.error(f"Error restoring all services: {e}")
            return {
                'success': False,
                'error': str(e)
            }
        # Note: Status is NOT cleared here since process runs in background
        # Status will be cleared when process finishes or next restore starts

    @staticmethod
    def get_backup_config_status() -> Dict[str, Any]:
        """
        Check if backup/restore configuration is ready.

        Returns:
            Dictionary with:
                - restic_password_configured: bool
                - backblaze_configured: bool
                - local_backup_path: str
                - local_backups_available: bool
                - backblaze_mounted: bool
        """
        restic_password_file = Path("/var/lib/homefree-secrets/backup/restic-password")
        backblaze_id_file = Path("/var/lib/homefree-secrets/backup/backblaze-id")
        backblaze_key_file = Path("/var/lib/homefree-secrets/backup/backblaze-key")
        local_backup_path = Path("/var/lib/backups")
        backblaze_mount = Path("/mnt/backup-backblaze")

        return {
            'restic_password_configured': restic_password_file.exists() and restic_password_file.stat().st_size > 0,
            'backblaze_configured': (
                backblaze_id_file.exists() and backblaze_id_file.stat().st_size > 0 and
                backblaze_key_file.exists() and backblaze_key_file.stat().st_size > 0
            ),
            'local_backup_path': str(local_backup_path),
            'local_backups_available': local_backup_path.exists() and any(local_backup_path.iterdir()) if local_backup_path.exists() else False,
            'backblaze_mounted': backblaze_mount.exists() and backblaze_mount.is_mount()
        }

    @staticmethod
    def _trigger_backups_worker():
        """
        Worker function that runs in background thread to start backup services.
        This runs asynchronously and logs results but doesn't return anything.
        """
        try:
            # Get list of all backup services
            result = subprocess.run(
                ['systemctl', 'list-units', '--all', 'restic-backups-local-*.service', '--no-pager', '--no-legend'],
                capture_output=True,
                text=True,
                timeout=30
            )

            if result.returncode != 0:
                logger.error(f"Failed to list backup services: {result.stderr}")
                return

            # Parse service names from output
            services = []
            for line in result.stdout.strip().split('\n'):
                if line.strip():
                    # Extract service name (first field)
                    parts = line.split()
                    if parts and parts[0].endswith('.service'):
                        services.append(parts[0])

            if not services:
                logger.warning('No backup services found to trigger')
                return

            # Trigger all backup services
            logger.info(f"Starting {len(services)} backup services in background")
            failed_services = []

            for service in services:
                try:
                    subprocess.run(
                        ['systemctl', 'start', service],
                        capture_output=True,
                        text=True,
                        timeout=5,
                        check=True
                    )
                    logger.debug(f"Started {service}")
                except subprocess.CalledProcessError as e:
                    error_msg = f"{service}: {e.stderr}"
                    failed_services.append(error_msg)
                    logger.error(f"Failed to start {error_msg}")
                except subprocess.TimeoutExpired:
                    error_msg = f"{service}: timeout"
                    failed_services.append(error_msg)
                    logger.error(f"Timeout starting {service}")

            if failed_services:
                logger.warning(f"Started {len(services) - len(failed_services)}/{len(services)} services. Failed: {', '.join(failed_services)}")
            else:
                logger.info(f"Successfully started all {len(services)} backup services")

        except subprocess.TimeoutExpired:
            logger.error("Backup trigger worker timed out")
        except Exception as e:
            logger.error(f"Error in backup trigger worker: {e}")

    @staticmethod
    def trigger_all_backups() -> Dict[str, Any]:
        """
        Trigger all backup services to run immediately.
        Returns immediately after starting background thread.

        Returns:
            Dictionary with:
                - success: bool
                - output: str
        """
        try:
            # Get list of services quickly to validate they exist
            result = subprocess.run(
                ['systemctl', 'list-units', '--all', 'restic-backups-local-*.service', '--no-pager', '--no-legend'],
                capture_output=True,
                text=True,
                timeout=5
            )

            if result.returncode != 0:
                return {
                    'success': False,
                    'error': f"Failed to list backup services: {result.stderr}"
                }

            # Count services
            services_count = len([line for line in result.stdout.strip().split('\n') if line.strip()])

            if services_count == 0:
                return {
                    'success': False,
                    'error': 'No backup services found. Ensure backups are enabled.'
                }

            # Start background thread to trigger services
            thread = threading.Thread(
                target=BackupOperations._trigger_backups_worker,
                daemon=True,
                name="backup-trigger-worker"
            )
            thread.start()

            logger.info(f"Triggered background thread to start {services_count} backup services")

            return {
                'success': True,
                'output': f"Backup trigger started for {services_count} services. Check status for progress."
            }

        except Exception as e:
            logger.error(f"Error triggering backups: {e}")
            return {
                'success': False,
                'error': str(e)
            }

    @staticmethod
    def trigger_backblaze_sync() -> Dict[str, Any]:
        """Trigger Backblaze sync service to sync local backups to Backblaze B2."""
        try:
            # Check if the sync service exists
            check_result = subprocess.run(
                ['systemctl', 'list-units', '--all', 'restic-backblaze-rsync.service', '--no-pager', '--no-legend'],
                capture_output=True, text=True, timeout=10
            )

            if not check_result.stdout.strip():
                return {
                    'success': False,
                    'error': 'Backblaze sync service (restic-backblaze-rsync.service) not found. Ensure Backblaze backups are enabled.'
                }

            # Trigger the sync service
            subprocess.run(
                ['systemctl', 'start', 'restic-backblaze-rsync.service'],
                timeout=5,
                check=True
            )

            return {
                'success': True,
                'output': 'Successfully triggered Backblaze sync service'
            }

        except subprocess.TimeoutExpired:
            return {
                'success': False,
                'error': 'Operation timed out while triggering Backblaze sync'
            }
        except subprocess.CalledProcessError as e:
            return {
                'success': False,
                'error': f'Failed to start Backblaze sync service: {e.stderr if e.stderr else str(e)}'
            }
        except Exception as e:
            return {
                'success': False,
                'error': str(e)
            }

    @staticmethod
    def get_backup_status() -> Dict[str, Any]:
        """Get current status of backup and sync operations."""
        try:
            # Check for active local backup services
            backup_result = subprocess.run(
                ['systemctl', 'list-units', 'restic-backups-local-*.service', '--state=active,activating', '--no-pager', '--no-legend'],
                capture_output=True, text=True, timeout=10
            )

            active_backups = []
            if backup_result.stdout.strip():
                for line in backup_result.stdout.strip().split('\n'):
                    if line.strip():
                        parts = line.split()
                        if parts and parts[0].endswith('.service'):
                            # Extract service name from unit name
                            # restic-backups-local-nextcloud.service -> nextcloud
                            service_name = parts[0].replace('restic-backups-local-', '').replace('.service', '')
                            active_backups.append(service_name)

            # Check Backblaze sync status
            sync_result = subprocess.run(
                ['systemctl', 'is-active', 'restic-backblaze-rsync.service'],
                capture_output=True, text=True, timeout=5
            )
            sync_running = sync_result.stdout.strip() in ['active', 'activating']

            # Check restore status from status file
            restore_running = False
            active_restore = None
            restore_type = None

            # Check if restore process is still actually running
            if BackupOperations._current_restore_process is not None:
                returncode = BackupOperations._current_restore_process.poll()
                if returncode is not None:
                    # Process finished - clear status
                    logger.info(f"Restore process finished with exit code {returncode}, clearing status")
                    BackupOperations._clear_restore_status()
                    BackupOperations._current_restore_process = None
                    BackupOperations._current_restore_output_file = None

            try:
                if BackupOperations.RESTORE_STATUS_FILE.exists():
                    with open(BackupOperations.RESTORE_STATUS_FILE, 'r') as f:
                        restore_status = json.load(f)
                        restore_running = restore_status.get('running', False)
                        active_restore = restore_status.get('service')
                        restore_type = restore_status.get('type')

                        # Check for stale status (from before service restart)
                        # If status file exists but we have no tracked process, it's likely stale
                        if restore_running and BackupOperations._current_restore_process is None:
                            started_at_str = restore_status.get('started_at')
                            if started_at_str:
                                try:
                                    # Parse ISO format timestamp: 2025-11-21T14:28:38.391937
                                    started_at = datetime.fromisoformat(started_at_str.replace('Z', '+00:00'))
                                    age = (datetime.now() - started_at.replace(tzinfo=None)).total_seconds()

                                    # If status is older than 30 minutes and we have no tracked process,
                                    # assume it's stale (likely from before service restart)
                                    if age > 1800:  # 30 minutes
                                        logger.info(f"Clearing stale restore status (age: {age:.0f}s, no tracked process)")
                                        BackupOperations._clear_restore_status()
                                        restore_running = False
                                        active_restore = None
                                        restore_type = None
                                except Exception as e:
                                    logger.warning(f"Error checking restore status age: {e}")
            except Exception as e:
                logger.warning(f"Error reading restore status file: {e}")

            return {
                'success': True,
                'backup_running': len(active_backups) > 0,
                'active_backups': active_backups,
                'sync_running': sync_running,
                'restore_running': restore_running,
                'active_restore': active_restore,
                'restore_type': restore_type
            }

        except subprocess.TimeoutExpired:
            return {
                'success': False,
                'error': 'Operation timed out while checking backup status'
            }
        except Exception as e:
            logger.error(f"Error getting backup status: {e}")
            return {
                'success': False,
                'error': str(e)
            }
