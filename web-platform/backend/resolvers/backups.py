"""
Backups API Resolvers

Handles API endpoints for backup/restore operations
"""

import logging
from typing import Dict, Optional, List, Any
from fastapi import APIRouter, HTTPException, status
from pydantic import BaseModel

from services.backup_operations import BackupOperations, BackupSource

logger = logging.getLogger(__name__)

# Create router
router = APIRouter(prefix="/api/backups", tags=["backups"])


# Request/Response Models
class RestoreRequest(BaseModel):
    """Request model for restore operations"""
    snapshot_id: Optional[str] = None
    source: str = "auto"  # auto, local, or backblaze
    dry_run: bool = False
    create_snapshot: bool = False
    include_system_config: bool = False  # Whether to include system-config in restore-all


class BackupConfigStatusResponse(BaseModel):
    """Response model for backup configuration status"""
    restic_password_configured: bool
    backblaze_configured: bool
    local_backup_path: str
    local_backups_available: bool
    backblaze_mounted: bool


class ServicesResponse(BaseModel):
    """Response model for list of services"""
    success: bool
    services: List[str]
    system_config: List[str] = []
    extra_paths: List[str] = []
    error: Optional[str] = None


class SnapshotInfo(BaseModel):
    """Model for snapshot information"""
    id: str
    time: str
    hostname: Optional[str] = None
    paths: Optional[str] = None


class SnapshotsResponse(BaseModel):
    """Response model for list of snapshots"""
    success: bool
    snapshots: List[Dict[str, Any]]
    error: Optional[str] = None


class PathsResponse(BaseModel):
    """Response model for list of paths in a repository"""
    success: bool
    paths: List[str]
    error: Optional[str] = None


class OperationResponse(BaseModel):
    """Response model for backup operations"""
    success: bool
    output: Optional[str] = None
    error: Optional[str] = None


# Endpoints

@router.get("/config/status", response_model=BackupConfigStatusResponse)
async def get_backup_config_status():
    """
    Get backup/restore configuration status

    Returns information about whether secrets are configured,
    backup sources are available, etc.
    """
    try:
        status_info = BackupOperations.get_backup_config_status()
        return BackupConfigStatusResponse(**status_info)
    except Exception as e:
        logger.error(f"Error getting backup config status: {e}")
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Failed to get backup configuration status: {str(e)}"
        )


@router.get("/services", response_model=ServicesResponse)
async def list_services(source: str = "auto", force: bool = False):
    """
    List all services that have backups available

    Args:
        source: Backup source - "auto", "local", or "backblaze"
        force: If True, bypass cache and fetch fresh data

    Returns list of service names
    """
    try:
        # Convert source string to enum
        try:
            backup_source = BackupSource(source)
        except ValueError:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail=f"Invalid source: {source}. Must be 'auto', 'local', or 'backblaze'"
            )

        result = BackupOperations.list_services(source=backup_source, force_refresh=force)

        # Categorize repositories
        all_repos = result.get('services', [])
        services = []
        system_config = []
        extra_paths = []

        for repo in all_repos:
            if repo == 'system-config':
                system_config.append(repo)
            elif repo.startswith('extra-path-'):
                extra_paths.append(repo)
            elif repo == 'extra-paths':
                # Legacy combined repository - treat as system config
                system_config.append(repo)
            else:
                services.append(repo)

        return ServicesResponse(
            success=result['success'],
            services=services,
            system_config=system_config,
            extra_paths=extra_paths,
            error=result.get('error')
        )
    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Error listing services: {e}")
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Failed to list services: {str(e)}"
        )


@router.get("/services/{service}/snapshots", response_model=SnapshotsResponse)
async def list_snapshots(service: str, source: str = "auto"):
    """
    List all snapshots for a specific service

    Args:
        service: Service name
        source: Backup source - "auto", "local", or "backblaze"

    Returns list of snapshots with id, time, hostname, paths
    """
    try:
        # Convert source string to enum
        try:
            backup_source = BackupSource(source)
        except ValueError:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail=f"Invalid source: {source}. Must be 'auto', 'local', or 'backblaze'"
            )

        result = BackupOperations.list_snapshots(service, source=backup_source)
        return SnapshotsResponse(**result)
    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Error listing snapshots for {service}: {e}")
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Failed to list snapshots for {service}: {str(e)}"
        )


@router.get("/services/{service}/paths", response_model=PathsResponse)
async def list_paths(service: str, source: str = "auto", force: bool = False):
    """
    List all paths backed up in a repository's latest snapshot

    Args:
        service: Service/repository name
        source: Backup source - "auto", "local", or "backblaze"
        force: If True, bypass cache and fetch fresh data

    Returns list of paths
    """
    try:
        # Convert source string to enum
        try:
            backup_source = BackupSource(source)
        except ValueError:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail=f"Invalid source: {source}. Must be 'auto', 'local', or 'backblaze'"
            )

        result = BackupOperations.get_repository_paths(service, source=backup_source, force_refresh=force)
        return PathsResponse(**result)
    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Error listing paths for {service}: {e}")
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Failed to list paths for {service}: {str(e)}"
        )


@router.post("/services/{service}/download", response_model=OperationResponse)
async def download_service(service: str):
    """
    Download a service backup from Backblaze to local storage

    Args:
        service: Service name

    Returns operation result with output
    """
    try:
        result = BackupOperations.download_service(service)
        if not result['success']:
            raise HTTPException(
                status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
                detail=result.get('error', 'Download failed')
            )
        return OperationResponse(**result)
    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Error downloading service {service}: {e}")
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Failed to download service {service}: {str(e)}"
        )


@router.post("/services/{service}/restore", response_model=OperationResponse)
async def restore_service(service: str, request: RestoreRequest):
    """
    Restore a service from backup

    Args:
        service: Service name
        request: Restore request with snapshot_id, source, dry_run, create_snapshot

    Returns operation result with output
    """
    try:
        # Convert source string to enum
        try:
            backup_source = BackupSource(request.source)
        except ValueError:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail=f"Invalid source: {request.source}. Must be 'auto', 'local', or 'backblaze'"
            )

        result = BackupOperations.restore_service(
            service=service,
            snapshot_id=request.snapshot_id,
            source=backup_source,
            dry_run=request.dry_run,
            create_snapshot=request.create_snapshot
        )

        if not result['success']:
            raise HTTPException(
                status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
                detail=result.get('error', 'Restore failed')
            )

        return OperationResponse(**result)
    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Error restoring service {service}: {e}")
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Failed to restore service {service}: {str(e)}"
        )


@router.post("/restore-all", response_model=OperationResponse)
async def restore_all(request: RestoreRequest):
    """
    Restore all services from backup

    Args:
        request: Restore request with snapshot_id, source, dry_run

    Returns operation result with output
    """
    try:
        # Convert source string to enum
        try:
            backup_source = BackupSource(request.source)
        except ValueError:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail=f"Invalid source: {request.source}. Must be 'auto', 'local', or 'backblaze'"
            )

        result = BackupOperations.restore_all(
            snapshot_id=request.snapshot_id,
            source=backup_source,
            dry_run=request.dry_run,
            include_system_config=request.include_system_config
        )

        if not result['success']:
            raise HTTPException(
                status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
                detail=result.get('error', 'Restore-all failed')
            )

        return OperationResponse(**result)
    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Error restoring all services: {e}")
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Failed to restore all services: {str(e)}"
        )


@router.post("/trigger", response_model=OperationResponse)
async def trigger_backups():
    """
    Trigger all backup services to run immediately

    Returns operation result with services_triggered count
    """
    try:
        result = BackupOperations.trigger_all_backups()

        if not result['success']:
            # Return partial success if some services started
            if result.get('services_triggered', 0) > 0:
                return OperationResponse(**result)

            raise HTTPException(
                status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
                detail=result.get('error', 'Failed to trigger backups')
            )

        return OperationResponse(**result)
    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Error triggering backups: {e}")
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Failed to trigger backups: {str(e)}"
        )


@router.post("/sync-backblaze", response_model=OperationResponse)
async def sync_backblaze():
    """
    Trigger Backblaze sync service to sync local backups to Backblaze B2

    Returns operation result
    """
    try:
        result = BackupOperations.trigger_backblaze_sync()

        if not result['success']:
            raise HTTPException(
                status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
                detail=result.get('error', 'Failed to trigger Backblaze sync')
            )

        return OperationResponse(**result)
    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Error triggering Backblaze sync: {e}")
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Failed to trigger Backblaze sync: {str(e)}"
        )


class BackupStatusResponse(BaseModel):
    """Response model for backup status"""
    success: bool
    backup_running: bool = False
    active_backups: List[str] = []
    sync_running: bool = False
    restore_running: bool = False
    active_restore: Optional[str] = None
    restore_type: Optional[str] = None
    error: Optional[str] = None


@router.get("/status", response_model=BackupStatusResponse)
async def get_backup_status():
    """
    Get current status of backup and sync operations

    Returns status of running backups and sync
    """
    try:
        result = BackupOperations.get_backup_status()
        return BackupStatusResponse(**result)
    except Exception as e:
        logger.error(f"Error getting backup status: {e}")
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Failed to get backup status: {str(e)}"
        )
