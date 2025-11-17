"""
Backup operations service - handles restore.sh script operations
"""

import subprocess
import logging
import json
from typing import Dict, Any, Optional, List
from pathlib import Path
from enum import Enum
from datetime import datetime

logger = logging.getLogger(__name__)


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
    def list_services(source: BackupSource = BackupSource.AUTO) -> Dict[str, Any]:
        """
        List all services that have backups available.

        Args:
            source: Backup source (auto, local, or backblaze)

        Returns:
            Dictionary with:
                - success: bool
                - services: List[str] (service names)
                - error: str (if failed)
        """
        try:
            cmd = [str(BackupOperations.RESTORE_SCRIPT), "list-services"]
            if source != BackupSource.AUTO:
                cmd.extend(["--source", source.value])

            result = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                timeout=30
            )

            if result.returncode == 0:
                # Parse service names from output (one per line)
                services = [line.strip() for line in result.stdout.strip().split('\n') if line.strip()]
                return {
                    'success': True,
                    'services': services
                }
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
                'error': 'Operation timed out after 30 seconds'
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
            output: Raw output from list-snapshots command

        Returns:
            List of snapshot dictionaries
        """
        snapshots = []
        for line in output.strip().split('\n'):
            if not line.strip():
                continue

            # Try to parse as JSON first
            try:
                snapshot = json.loads(line)
                snapshots.append(snapshot)
                continue
            except json.JSONDecodeError:
                pass

            # Fall back to pipe-separated format: "ID | Time | Hostname | Paths"
            # This is the format used by restic's default output
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
    def restore_service(
        service: str,
        snapshot_id: Optional[str] = None,
        source: BackupSource = BackupSource.AUTO,
        dry_run: bool = False,
        create_snapshot: bool = False
    ) -> Dict[str, Any]:
        """
        Restore a service from backup.

        Args:
            service: Service name
            snapshot_id: Specific snapshot ID to restore (None = latest)
            source: Backup source (auto, local, or backblaze)
            dry_run: If True, only show what would be restored
            create_snapshot: If True, create a snapshot before restoring

        Returns:
            Dictionary with:
                - success: bool
                - output: str (command output)
                - error: str (if failed)
        """
        try:
            cmd = [str(BackupOperations.RESTORE_SCRIPT), "restore", service]

            if snapshot_id:
                cmd.append(snapshot_id)

            if source != BackupSource.AUTO:
                cmd.extend(["--source", source.value])

            # Note: dry_run and create_snapshot would need to be added to restore.sh
            # For now, we'll log them but not pass them to the script
            if dry_run:
                logger.info(f"Dry-run mode requested (not yet implemented in restore.sh)")
            if create_snapshot:
                logger.info(f"Create-snapshot mode requested (not yet implemented in restore.sh)")

            result = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                timeout=1800  # 30 minutes for restore
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
                    'error': result.stderr or "Restore failed"
                }

        except subprocess.TimeoutExpired:
            logger.error("restore timed out")
            return {
                'success': False,
                'error': 'Restore timed out after 30 minutes'
            }
        except Exception as e:
            logger.error(f"Error restoring service: {e}")
            return {
                'success': False,
                'error': str(e)
            }

    @staticmethod
    def restore_all(
        snapshot_id: Optional[str] = None,
        source: BackupSource = BackupSource.AUTO,
        dry_run: bool = False
    ) -> Dict[str, Any]:
        """
        Restore all services from backup.

        Args:
            snapshot_id: Specific snapshot ID to restore (None = latest)
            source: Backup source (auto, local, or backblaze)
            dry_run: If True, only show what would be restored

        Returns:
            Dictionary with:
                - success: bool
                - output: str (command output)
                - error: str (if failed)
        """
        try:
            cmd = [str(BackupOperations.RESTORE_SCRIPT), "restore-all"]

            if snapshot_id:
                cmd.append(snapshot_id)

            if source != BackupSource.AUTO:
                cmd.extend(["--source", source.value])

            if dry_run:
                logger.info(f"Dry-run mode requested (not yet implemented in restore.sh)")

            result = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                timeout=3600  # 1 hour for restore-all
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
                    'error': result.stderr or "Restore-all failed"
                }

        except subprocess.TimeoutExpired:
            logger.error("restore-all timed out")
            return {
                'success': False,
                'error': 'Restore-all timed out after 1 hour'
            }
        except Exception as e:
            logger.error(f"Error restoring all services: {e}")
            return {
                'success': False,
                'error': str(e)
            }

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
