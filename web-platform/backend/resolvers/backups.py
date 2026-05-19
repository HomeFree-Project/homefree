"""
Backups API Resolvers

Handles API endpoints for backup/restore operations.

Long-running operations (restore, restore-all, trigger-backups, sync) are
modelled as "jobs": POSTing one returns a job id immediately, and the
client polls /jobs/current and /jobs/{id}/log for live progress. The
backup subsystem is mutually exclusive - if a job is already running, a
new request returns 409 with the conflicting job's kind.
"""

import logging
from typing import Dict, Optional, List, Any
from fastapi import APIRouter, HTTPException, status
from pydantic import BaseModel

from services.backup_operations import (
    BackupOperations, BackupSource, BackupBusy)

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api/backups", tags=["backups"])


# --------------------------------------------------------------- models

class RestoreRequest(BaseModel):
    """Request model for restore operations."""
    snapshot_id: Optional[str] = None
    source: str = "auto"  # auto, local, or backblaze
    dry_run: bool = False
    create_snapshot: bool = False
    include_system_config: bool = False


class BackupConfigStatusResponse(BaseModel):
    restic_password_configured: bool
    backblaze_configured: bool
    local_backup_path: str
    local_backups_available: bool
    # Native restic-to-B2 needs no mount; "available" == credentials present.
    backblaze_available: bool


class ServicesResponse(BaseModel):
    success: bool
    services: List[str]
    system_config: List[str] = []
    extra_paths: List[str] = []
    error: Optional[str] = None


class SourcePathsResponse(BaseModel):
    """Repository label -> the SOURCE directories it backs up.

    Read from config (service-config.json + homefree-config.json) with
    no restic call - used by the Run tab to show real paths instantly.
    """
    success: bool
    paths: Dict[str, List[str]] = {}
    error: Optional[str] = None


class SnapshotsResponse(BaseModel):
    success: bool
    snapshots: List[Dict[str, Any]]
    error: Optional[str] = None


class PathsResponse(BaseModel):
    success: bool
    paths: List[str]
    error: Optional[str] = None


class PathsProgress(BaseModel):
    """Live progress of the all-repository path warm."""
    state: str = "idle"   # idle | running | ready | error
    done: int = 0
    total: int = 0
    error: Optional[str] = None


class AllPathsResponse(BaseModel):
    """Backup-root paths for every repository, in one response."""
    success: bool
    # repo name -> list of backup root paths (partial while warming)
    paths: Dict[str, List[str]] = {}
    # False while the warm is still resolving repositories
    ready: bool = True
    # Progress counters so the UI can render a real progress bar
    progress: PathsProgress = PathsProgress()
    error: Optional[str] = None


class OperationResponse(BaseModel):
    success: bool
    output: Optional[str] = None
    error: Optional[str] = None


class JobResponse(BaseModel):
    """A backup-subsystem job and its per-repository progress."""
    success: bool
    job_id: Optional[str] = None
    job: Optional[Dict[str, Any]] = None
    error: Optional[str] = None


class CanaryStatusResponse(BaseModel):
    """Backup canary self-test status."""
    success: bool
    # False when the backup-canary service is not deployed
    enabled: bool = False
    # True while a self-test is in progress
    running: bool = False
    # latest self-test result, or None if none has run
    result: Optional[Dict[str, Any]] = None
    error: Optional[str] = None


class BackupHealthResponse(BaseModel):
    """Last-run health of scheduled backups, per source."""
    success: bool
    # {total, ok, failed, never_run, failed_services,
    #  never_run_services, last_run, next_run}
    local: Optional[Dict[str, Any]] = None
    # None when no Backblaze backup units exist
    backblaze: Optional[Dict[str, Any]] = None
    error: Optional[str] = None


class JobLogResponse(BaseModel):
    """Incremental log output for a job (for live streaming)."""
    success: bool
    lines: str = ""
    offset: int = 0
    eof: bool = False
    error: Optional[str] = None


class BackupStatusResponse(BaseModel):
    """Backwards-compatible status response."""
    success: bool
    backup_running: bool = False
    active_backups: List[str] = []
    sync_running: bool = False
    restore_running: bool = False
    active_restore: Optional[str] = None
    restore_type: Optional[str] = None
    error: Optional[str] = None


# --------------------------------------------------------------- helpers

def _parse_source(source: str) -> BackupSource:
    try:
        return BackupSource(source)
    except ValueError:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"Invalid source: {source}. "
                   f"Must be 'auto', 'local', or 'backblaze'")


def _busy_http_error(busy: BackupBusy) -> HTTPException:
    """Translate a BackupBusy into a 409 with a machine-readable reason."""
    return HTTPException(
        status_code=status.HTTP_409_CONFLICT,
        detail={
            "error": "busy",
            "busy_with": busy.kind,
            "job_id": busy.job_id,
            "message": _busy_message(busy.kind),
        })


def _busy_message(kind: str) -> str:
    return {
        "backup": "A backup is currently running. "
                  "Wait for it to finish before restoring.",
        "restore": "A restore is currently in progress. "
                   "Only one restore can run at a time.",
        "restore-all": "A full-system restore is in progress. "
                       "Wait for it to finish.",
        "sync": "A Backblaze sync is currently running. "
                "Wait for it to finish.",
    }.get(kind, "The backup subsystem is currently busy.")


# ------------------------------------------------------------- endpoints

@router.get("/config/status", response_model=BackupConfigStatusResponse)
async def get_backup_config_status():
    """Get backup/restore configuration status."""
    try:
        return BackupConfigStatusResponse(
            **BackupOperations.get_backup_config_status())
    except Exception as e:
        logger.error(f"Error getting backup config status: {e}")
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Failed to get backup configuration status: {str(e)}")


@router.get("/services", response_model=ServicesResponse)
async def list_services(source: str = "auto", force: bool = False):
    """List all repositories that have backups available.

    Cheap call - no restic invocation. Per-repository paths are fetched
    lazily via /services/{service}/paths when the user expands a repo.
    """
    try:
        backup_source = _parse_source(source)
        result = BackupOperations.list_services(
            source=backup_source, force_refresh=force)

        services, system_config, extra_paths = [], [], []
        for repo in result.get("services", []):
            if repo == "system-config":
                system_config.append(repo)
            elif repo.startswith("extra-path-") or repo == "extra-paths":
                # extra-path-N are the current per-path repos; "extra-paths"
                # is a legacy combined repo from an older backup module.
                # Both belong with extra paths, NOT system configuration.
                extra_paths.append(repo)
            else:
                services.append(repo)

        return ServicesResponse(
            success=result["success"], services=services,
            system_config=system_config, extra_paths=extra_paths,
            error=result.get("error"))
    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Error listing services: {e}")
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Failed to list services: {str(e)}")


@router.get("/source-paths", response_model=SourcePathsResponse)
async def get_source_paths():
    """Map each backup repository to its SOURCE directories.

    Cheap config read (no restic) - the Run tab uses this to show real
    paths (e.g. /mnt/ellis/Documents instead of extra-path-5) without
    the per-repo snapshot lookups that /paths does.
    """
    try:
        return SourcePathsResponse(**BackupOperations.get_source_paths())
    except Exception as e:
        logger.error(f"Error getting source paths: {e}")
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Failed to get source paths: {str(e)}")


@router.get("/services/{service}/snapshots", response_model=SnapshotsResponse)
async def list_snapshots(service: str, source: str = "auto"):
    """List all snapshots for a specific service."""
    try:
        backup_source = _parse_source(source)
        result = BackupOperations.list_snapshots(service, source=backup_source)
        return SnapshotsResponse(**result)
    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Error listing snapshots for {service}: {e}")
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Failed to list snapshots for {service}: {str(e)}")


@router.get("/services/{service}/paths", response_model=PathsResponse)
async def list_paths(service: str, source: str = "auto", force: bool = False):
    """List the paths backed up in a repository's latest snapshot."""
    try:
        backup_source = _parse_source(source)
        result = BackupOperations.get_repository_paths(
            service, source=backup_source, force_refresh=force)
        return PathsResponse(**result)
    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Error listing paths for {service}: {e}")
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Failed to list paths for {service}: {str(e)}")


@router.get("/paths", response_model=AllPathsResponse)
async def list_all_paths(source: str = "local", force: bool = False):
    """Backup-root paths for every repository, in a single call.

    Never blocks. The path data is resolved by a background warm that
    streams progress; this returns whatever is cached so far plus the
    live progress counters. The Restore tab polls this (and shows a
    progress bar from `progress.done`/`progress.total`) until
    `ready` is true.
    """
    try:
        backup_source = _parse_source(source)
        # Ensure a warm is running (or already done); non-blocking.
        progress = BackupOperations.ensure_paths_warm(
            backup_source, force=force)
        result = BackupOperations.get_all_repository_paths(backup_source)
        return AllPathsResponse(
            success=True,
            paths=result["paths"],
            ready=result["ready"],
            progress=PathsProgress(**progress))
    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Error listing all paths: {e}")
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Failed to list all paths: {str(e)}")


@router.post("/services/{service}/download", response_model=OperationResponse)
async def download_service(service: str):
    """Download a service backup from Backblaze to local storage."""
    try:
        result = BackupOperations.download_service(service)
        if not result["success"]:
            raise HTTPException(
                status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
                detail=result.get("error", "Download failed"))
        return OperationResponse(**result)
    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Error downloading service {service}: {e}")
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Failed to download service {service}: {str(e)}")


@router.post("/services/{service}/restore", response_model=JobResponse)
async def restore_service(service: str, request: RestoreRequest):
    """Start a single-repository restore. Returns a job id immediately.

    Returns 409 if a backup/restore/sync is already running.
    """
    try:
        backup_source = _parse_source(request.source)
        result = BackupOperations.restore_service(
            service=service, snapshot_id=request.snapshot_id,
            source=backup_source, dry_run=request.dry_run,
            create_snapshot=request.create_snapshot)
        if not result["success"]:
            raise HTTPException(
                status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
                detail=result.get("error", "Restore failed"))
        return JobResponse(**result)
    except BackupBusy as busy:
        raise _busy_http_error(busy)
    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Error restoring service {service}: {e}")
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Failed to restore service {service}: {str(e)}")


@router.post("/restore-all", response_model=JobResponse)
async def restore_all(request: RestoreRequest):
    """Start a full-system restore. Returns a job id immediately.

    Returns 409 if a backup/restore/sync is already running.
    """
    try:
        backup_source = _parse_source(request.source)
        result = BackupOperations.restore_all(
            snapshot_id=request.snapshot_id, source=backup_source,
            dry_run=request.dry_run,
            include_system_config=request.include_system_config)
        if not result["success"]:
            raise HTTPException(
                status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
                detail=result.get("error", "Restore-all failed"))
        return JobResponse(**result)
    except BackupBusy as busy:
        raise _busy_http_error(busy)
    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Error restoring all services: {e}")
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Failed to restore all services: {str(e)}")


@router.post("/trigger", response_model=JobResponse)
async def trigger_backups():
    """Trigger all backup services. Returns a job id immediately.

    Returns 409 if a backup/restore/sync is already running.
    """
    try:
        result = BackupOperations.trigger_all_backups()
        if not result["success"]:
            raise HTTPException(
                status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
                detail=result.get("error", "Failed to trigger backups"))
        return JobResponse(**result)
    except BackupBusy as busy:
        raise _busy_http_error(busy)
    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Error triggering backups: {e}")
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Failed to trigger backups: {str(e)}")


@router.post("/backup-backblaze", response_model=JobResponse)
async def backup_backblaze():
    """Run all Backblaze B2 backups now. Returns a job id immediately.

    With native restic-to-B2 there is no separate "sync" step - the
    per-service B2 restic backup units run directly. This just triggers
    them on demand (they otherwise run on their own timer).

    Returns 409 if a backup/restore is already running.
    """
    try:
        result = BackupOperations.trigger_backblaze_backup()
        if not result["success"]:
            raise HTTPException(
                status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
                detail=result.get("error",
                                  "Failed to trigger Backblaze backup"))
        return JobResponse(**result)
    except BackupBusy as busy:
        raise _busy_http_error(busy)
    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Error triggering Backblaze backup: {e}")
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Failed to trigger Backblaze backup: {str(e)}")


@router.post("/services/{label}/trigger", response_model=JobResponse)
async def trigger_service_backup(label: str, source: str = "local"):
    """Run the backup for a single service now. Returns a job id.

    Query param ``source`` selects the repository: "local" (default)
    or "backblaze". Returns 409 if a backup/restore is already running.
    """
    if source not in ("local", "backblaze"):
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"Invalid source '{source}' "
                   f"(expected 'local' or 'backblaze')")
    try:
        result = BackupOperations.trigger_service_backup(label, source)
        if not result["success"]:
            raise HTTPException(
                status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
                detail=result.get("error",
                                  f"Failed to trigger backup for {label}"))
        return JobResponse(**result)
    except BackupBusy as busy:
        raise _busy_http_error(busy)
    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Error triggering backup for {label}: {e}")
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Failed to trigger backup for {label}: {str(e)}")


@router.get("/jobs/current", response_model=JobResponse)
async def get_current_job():
    """Return the currently-running backup-subsystem job, if any.

    The job carries per-repository progress (pending/running/done/failed),
    the current repository, and overall state.
    """
    try:
        return JobResponse(**BackupOperations.get_current_job())
    except Exception as e:
        logger.error(f"Error getting current job: {e}")
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Failed to get current job: {str(e)}")


@router.get("/jobs/{job_id}", response_model=JobResponse)
async def get_job(job_id: str):
    """Return a specific job by id."""
    try:
        result = BackupOperations.get_job(job_id)
        if not result["success"]:
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND,
                detail=result.get("error", "Job not found"))
        return JobResponse(**result)
    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Error getting job {job_id}: {e}")
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Failed to get job {job_id}: {str(e)}")


@router.get("/jobs/{job_id}/log", response_model=JobLogResponse)
async def get_job_log(job_id: str, offset: int = 0):
    """Return new log output for a job since `offset` (for live streaming).

    The client passes back the returned `offset` on the next poll to get
    only the new lines. `eof` becomes true once the job has finished.
    """
    try:
        result = BackupOperations.get_job_log(job_id, offset=offset)
        if not result["success"]:
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND,
                detail=result.get("error", "Job not found"))
        return JobLogResponse(**result)
    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Error getting job log {job_id}: {e}")
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Failed to get job log {job_id}: {str(e)}")


@router.get("/status", response_model=BackupStatusResponse)
async def get_backup_status():
    """Backwards-compatible status endpoint (built on the job model)."""
    try:
        return BackupStatusResponse(**BackupOperations.get_backup_status())
    except Exception as e:
        logger.error(f"Error getting backup status: {e}")
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Failed to get backup status: {str(e)}")


@router.get("/health", response_model=BackupHealthResponse)
async def get_backup_health():
    """Last-run health of scheduled backups.

    Reads each restic backup unit's last result and run time from
    systemd (no restic calls). Lets the UI show, per source, whether
    the most recent scheduled backups succeeded and when they ran.
    """
    try:
        return BackupHealthResponse(**BackupOperations.get_backup_health())
    except Exception as e:
        logger.error(f"Error getting backup health: {e}")
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Failed to get backup health: {str(e)}")


@router.get("/canary", response_model=CanaryStatusResponse)
async def get_canary_status():
    """Return the backup canary's latest self-test result.

    The canary is an opt-in service that backs up, mutates, and restores
    its own throwaway data to verify the whole pipeline works. `enabled`
    is False when the canary is not deployed on this system.
    """
    try:
        return CanaryStatusResponse(**BackupOperations.get_canary_status())
    except Exception as e:
        logger.error(f"Error getting canary status: {e}")
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Failed to get canary status: {str(e)}")


@router.post("/canary/run", response_model=OperationResponse)
async def run_canary_selftest():
    """Start an on-demand backup self-test via the canary.

    Fire-and-forget: the self-test runs in the background and takes the
    backup lock itself. Poll GET /canary for the result.
    """
    try:
        result = BackupOperations.trigger_canary_selftest()
        if not result["success"]:
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail=result.get("error", "Failed to start self-test"))
        return OperationResponse(**result)
    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Error running canary self-test: {e}")
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail=f"Failed to run canary self-test: {str(e)}")
