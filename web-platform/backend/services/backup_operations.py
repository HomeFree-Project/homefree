"""
Backup operations service - handles restore.sh script operations.

Architecture (rearchitected):

* A single "job" abstraction tracks every long-running operation
  (restore-all, single restore, trigger-backups, sync). Jobs are
  persisted as JSON under /var/lib/homefree-admin/backup-jobs/ so they
  survive reads across requests and a reaper can detect dead processes.

* A flock-based lock (/var/lib/homefree-admin/backup.lock) guarantees
  mutual exclusion: a restore cannot start while a backup/sync runs and
  vice versa. Callers that find the lock held get a structured "busy"
  result so the API can return 409 with a clear reason.

* list-services is cheap (directory scan, no restic). Per-repository
  paths load lazily on demand and are cached; a background pre-warm
  thread keeps the cache hot so the UI rarely waits.
"""

import os
import re
import json
import fcntl
import signal
import logging
import threading
import subprocess
from enum import Enum
from pathlib import Path
from datetime import datetime
from typing import Dict, Any, Optional, List

logger = logging.getLogger(__name__)


def strip_ansi_codes(text: str) -> str:
    """Remove ANSI escape sequences (color/formatting) from text."""
    if not text:
        return text
    return re.compile(r'\x1b\[[0-9;]*m').sub('', text)


class BackupSource(Enum):
    """Backup source locations."""
    AUTO = "auto"
    LOCAL = "local"
    BACKBLAZE = "backblaze"


class JobKind(str, Enum):
    """Kinds of long-running backup-subsystem operations."""
    RESTORE = "restore"          # single repository restore
    RESTORE_ALL = "restore-all"  # full-system restore
    BACKUP = "backup"            # trigger all backup jobs
    SYNC = "sync"                # sync local repos to Backblaze


class JobState(str, Enum):
    QUEUED = "queued"
    RUNNING = "running"
    DONE = "done"
    FAILED = "failed"


class BackupBusy(Exception):
    """Raised/returned when the backup subsystem lock is already held."""

    def __init__(self, kind: str, job_id: Optional[str]):
        self.kind = kind          # what currently holds the lock
        self.job_id = job_id
        super().__init__(f"Backup subsystem busy with {kind}")


class BackupOperations:
    """Service for backup/restore operations."""

    RESTORE_SCRIPT = Path("/nix/var/nix/profiles/system/sw/bin/restore-cli")

    STATE_DIR = Path("/var/lib/homefree-admin")
    JOBS_DIR = STATE_DIR / "backup-jobs"
    LOG_DIR = STATE_DIR / "backup-logs"
    LOCK_FILE = STATE_DIR / "backup.lock"
    CURRENT_JOB_FILE = STATE_DIR / "backup-current-job"  # holds active job id

    MAX_LOGS_TO_KEEP = 20

    # Server-side caches (persist until force refresh / pre-warm).
    _services_cache: Dict[str, Any] = {}
    _services_cache_timestamp: Dict[str, float] = {}
    _paths_cache: Dict[str, Any] = {}
    _paths_cache_timestamp: Dict[str, float] = {}

    # Live progress of the all-repository path warm, keyed by source.
    # {source: {state, done, total, error}} where state is
    # idle | running | ready | error. Lets the UI show a progress bar.
    _paths_progress: Dict[str, Dict[str, Any]] = {}

    # Guards job-file writes within this process.
    _job_write_lock = threading.Lock()
    # Ensures only one path-warm per source runs at a time.
    _paths_warm_lock = threading.Lock()
    _paths_warming: Dict[str, bool] = {}

    # ----------------------------------------------------------------- setup

    @staticmethod
    def _ensure_directories() -> None:
        for d in (BackupOperations.STATE_DIR, BackupOperations.JOBS_DIR,
                  BackupOperations.LOG_DIR):
            d.mkdir(parents=True, exist_ok=True)

    # ------------------------------------------------------------ lock layer

    @staticmethod
    def _lock_holder() -> Optional[Dict[str, Any]]:
        """Return {kind, job_id} of whoever holds the lock, or None if free.

        Uses a non-blocking flock probe: if we can grab the lock the
        subsystem is idle. We never keep the probe lock - the owning job
        holds its own flock for the duration of its background thread.
        """
        BackupOperations._ensure_directories()
        try:
            fd = os.open(str(BackupOperations.LOCK_FILE),
                         os.O_RDWR | os.O_CREAT, 0o600)
        except OSError as e:
            logger.warning(f"Could not open backup lock file: {e}")
            return None
        try:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                # Held by a live job - read its metadata.
                meta = BackupOperations._read_current_job_ref()
                return meta or {"kind": "unknown", "job_id": None}
            else:
                # Lock was free; release immediately.
                fcntl.flock(fd, fcntl.LOCK_UN)
                return None
        finally:
            os.close(fd)

    @staticmethod
    def _read_current_job_ref() -> Optional[Dict[str, Any]]:
        try:
            if BackupOperations.CURRENT_JOB_FILE.exists():
                raw = BackupOperations.CURRENT_JOB_FILE.read_text().strip()
                if raw:
                    job = BackupOperations._read_job(raw)
                    if job and job.get("state") in (JobState.QUEUED,
                                                    JobState.RUNNING):
                        return {"kind": job.get("kind"), "job_id": raw}
        except Exception as e:
            logger.warning(f"Error reading current job ref: {e}")
        return None

    # ------------------------------------------------------------- job model

    @staticmethod
    def _job_path(job_id: str) -> Path:
        return BackupOperations.JOBS_DIR / f"{job_id}.json"

    @staticmethod
    def _read_job(job_id: str) -> Optional[Dict[str, Any]]:
        try:
            p = BackupOperations._job_path(job_id)
            if p.exists():
                return json.loads(p.read_text())
        except Exception as e:
            logger.warning(f"Error reading job {job_id}: {e}")
        return None

    @staticmethod
    def _write_job(job: Dict[str, Any]) -> None:
        """Atomically persist a job record."""
        with BackupOperations._job_write_lock:
            try:
                BackupOperations._ensure_directories()
                p = BackupOperations._job_path(job["id"])
                tmp = p.with_suffix(".json.tmp")
                tmp.write_text(json.dumps(job, indent=2))
                tmp.replace(p)
            except Exception as e:
                logger.warning(f"Error writing job {job.get('id')}: {e}")

    @staticmethod
    def _new_job(kind: JobKind, repos: List[str]) -> Dict[str, Any]:
        job_id = datetime.now().strftime("%Y%m%d-%H%M%S-") + kind.value
        log_file = BackupOperations.LOG_DIR / f"{job_id}.log"
        job = {
            "id": job_id,
            "kind": kind.value,
            "state": JobState.QUEUED.value,
            "started_at": datetime.now().isoformat(),
            "finished_at": None,
            "log_file": str(log_file),
            "pid": None,
            "current_repo": None,
            "repos": [{"name": r, "state": "pending", "error": None}
                      for r in repos],
            "exit_code": None,
            "error": None,
        }
        BackupOperations._write_job(job)
        return job

    @staticmethod
    def _update_repo(job: Dict[str, Any], name: str,
                     state: str, error: Optional[str] = None) -> None:
        for r in job["repos"]:
            if r["name"] == name:
                r["state"] = state
                r["error"] = error
                break
        if state == "running":
            job["current_repo"] = name
        BackupOperations._write_job(job)

    @staticmethod
    def _finish_job(job: Dict[str, Any], state: JobState,
                    exit_code: Optional[int] = None,
                    error: Optional[str] = None) -> None:
        job["state"] = state.value
        job["finished_at"] = datetime.now().isoformat()
        job["exit_code"] = exit_code
        job["error"] = error
        job["current_repo"] = None
        BackupOperations._write_job(job)
        # Clear the current-job pointer if it still points at us.
        try:
            ref = BackupOperations.CURRENT_JOB_FILE
            if ref.exists() and ref.read_text().strip() == job["id"]:
                ref.unlink()
        except Exception as e:
            logger.warning(f"Error clearing current job ref: {e}")
        BackupOperations._prune_old_jobs()

    @staticmethod
    def _prune_old_jobs() -> None:
        try:
            jobs = sorted(BackupOperations.JOBS_DIR.glob("*.json"),
                          key=lambda p: p.stat().st_mtime, reverse=True)
            for stale in jobs[BackupOperations.MAX_LOGS_TO_KEEP:]:
                stale.unlink(missing_ok=True)
            logs = sorted(BackupOperations.LOG_DIR.glob("*.log"),
                          key=lambda p: p.stat().st_mtime, reverse=True)
            for stale in logs[BackupOperations.MAX_LOGS_TO_KEEP:]:
                stale.unlink(missing_ok=True)
        except Exception as e:
            logger.warning(f"Error pruning old jobs: {e}")

    @staticmethod
    def _reap_if_dead(job: Dict[str, Any]) -> Dict[str, Any]:
        """Mark a job failed if it claims to be running but its PID is gone."""
        if job.get("state") != JobState.RUNNING.value:
            return job
        pid = job.get("pid")
        alive = False
        if pid:
            try:
                os.kill(pid, 0)
                alive = True
            except (ProcessLookupError, PermissionError):
                alive = job.get("pid") is None
        # A job whose worker thread set no PID (pure-Python loop) is tracked
        # via the lock instead: if the lock is free, the worker is gone.
        if not pid:
            holder = BackupOperations._lock_holder()
            alive = holder is not None and holder.get("job_id") == job["id"]
        if not alive:
            logger.info(f"Reaping dead job {job['id']} (pid={pid})")
            BackupOperations._finish_job(
                job, JobState.FAILED,
                error="Operation terminated unexpectedly "
                      "(admin service restarted or process killed).")
        return BackupOperations._read_job(job["id"]) or job

    @staticmethod
    def get_current_job() -> Dict[str, Any]:
        """Return the active job (reaped if dead), or {job: None}."""
        ref = BackupOperations._read_current_job_ref()
        if not ref or not ref.get("job_id"):
            return {"success": True, "job": None}
        job = BackupOperations._read_job(ref["job_id"])
        if not job:
            return {"success": True, "job": None}
        job = BackupOperations._reap_if_dead(job)
        if job.get("state") in (JobState.QUEUED.value, JobState.RUNNING.value):
            return {"success": True, "job": job}
        # Finished since the ref was written - still report it once so the
        # UI can show the terminal state, but the ref is already cleared.
        return {"success": True, "job": job}

    @staticmethod
    def get_job(job_id: str) -> Dict[str, Any]:
        job = BackupOperations._read_job(job_id)
        if not job:
            return {"success": False, "error": "Job not found"}
        job = BackupOperations._reap_if_dead(job)
        return {"success": True, "job": job}

    @staticmethod
    def get_job_log(job_id: str, offset: int = 0) -> Dict[str, Any]:
        """Return new log bytes since `offset` for live streaming."""
        job = BackupOperations._read_job(job_id)
        if not job:
            return {"success": False, "error": "Job not found"}
        log_file = Path(job["log_file"])
        if not log_file.exists():
            return {"success": True, "lines": "", "offset": 0,
                    "eof": job.get("state") in (JobState.DONE.value,
                                                JobState.FAILED.value)}
        try:
            size = log_file.stat().st_size
            if offset > size:        # log rotated/truncated
                offset = 0
            with open(log_file, "r", errors="replace") as f:
                f.seek(offset)
                chunk = f.read()
                new_offset = f.tell()
            return {
                "success": True,
                "lines": strip_ansi_codes(chunk),
                "offset": new_offset,
                "eof": job.get("state") in (JobState.DONE.value,
                                            JobState.FAILED.value),
            }
        except Exception as e:
            logger.warning(f"Error reading job log {job_id}: {e}")
            return {"success": False, "error": str(e)}

    # -------------------------------------------------- timer suspend/resume

    @staticmethod
    def _backup_timers_for(repos: List[str]) -> List[str]:
        """Return restic-backups-local-*.timer units for the given repos.

        If `repos` is empty, returns every local backup timer.
        """
        try:
            result = subprocess.run(
                ["systemctl", "list-units", "--all",
                 "restic-backups-local-*.timer", "--no-pager", "--no-legend"],
                capture_output=True, text=True, timeout=10)
            units = []
            for line in result.stdout.strip().split("\n"):
                line = line.strip()
                if not line:
                    continue
                unit = line.split()[0]
                if not unit.endswith(".timer"):
                    continue
                if not repos:
                    units.append(unit)
                    continue
                svc = unit.replace("restic-backups-local-", "").replace(
                    ".timer", "")
                if svc in repos:
                    units.append(unit)
            return units
        except Exception as e:
            logger.warning(f"Error listing backup timers: {e}")
            return []

    @staticmethod
    def _suspend_backup_timers(repos: List[str]) -> List[str]:
        """Stop backup timers so a scheduled run can't collide with a restore.

        Returns the list of units stopped, for later resume.
        """
        units = BackupOperations._backup_timers_for(repos)
        stopped = []
        for unit in units:
            try:
                subprocess.run(["systemctl", "stop", unit],
                               capture_output=True, text=True, timeout=10)
                stopped.append(unit)
            except Exception as e:
                logger.warning(f"Failed to stop {unit}: {e}")
        if stopped:
            logger.info(f"Suspended {len(stopped)} backup timer(s) for restore")
        return stopped

    @staticmethod
    def _resume_backup_timers(units: List[str]) -> None:
        for unit in units:
            try:
                subprocess.run(["systemctl", "start", unit],
                               capture_output=True, text=True, timeout=10)
            except Exception as e:
                logger.warning(f"Failed to restart {unit}: {e}")
        if units:
            logger.info(f"Resumed {len(units)} backup timer(s) after restore")

    # ------------------------------------------------------- list operations

    @staticmethod
    def list_services(source: BackupSource = BackupSource.AUTO,
                      force_refresh: bool = False) -> Dict[str, Any]:
        """List repositories that have backups available (cheap, no restic)."""
        try:
            cache_key = source.value
            if not force_refresh:
                cached = BackupOperations._services_cache.get(cache_key)
                if cached:
                    return cached

            cmd = [str(BackupOperations.RESTORE_SCRIPT), "list-services"]
            if source != BackupSource.AUTO:
                cmd += ["--source", source.value]

            result = subprocess.run(cmd, capture_output=True, text=True,
                                    timeout=120)
            if result.returncode == 0:
                services = []
                for line in result.stdout.strip().split("\n"):
                    line = line.strip()
                    if line and "\x1b" not in line and not any(
                            x in line for x in ["[INFO]", "[WARN]", "[ERROR]"]):
                        services.append(line)
                response = {"success": True, "services": services}
                if services:
                    BackupOperations._services_cache[cache_key] = response
                    BackupOperations._services_cache_timestamp[cache_key] = \
                        datetime.now().timestamp()
                return response
            return {"success": False, "services": [],
                    "error": result.stderr or result.stdout}
        except subprocess.TimeoutExpired:
            return {"success": False, "services": [],
                    "error": "Operation timed out after 120 seconds"}
        except Exception as e:
            logger.error(f"Error listing services: {e}")
            return {"success": False, "services": [], "error": str(e)}

    # Config files describing what each repository backs up. These give
    # the SOURCE directories (what will be backed up) cheaply, without
    # any restic call - unlike get_repository_paths(), which reads a
    # snapshot. The Run tab uses this; the Restore tab needs snapshots.
    SERVICE_CATALOG = Path("/etc/homefree/service-config.json")
    HOMEFREE_CONFIG = Path("/etc/nixos/homefree-config.json")

    @staticmethod
    def get_source_paths() -> Dict[str, Any]:
        """Map every backup repository label to its SOURCE directories.

        Reads two JSON config files - no restic, no network, instant:

        * /etc/homefree/service-config.json - per-service `backup.paths`
          (plus the postgres/mysql dump dirs the backup units add).
        * /etc/nixos/homefree-config.json - `backups.extra-from-paths`
          (-> extra-path-N, index = array position) and the implicit
          system-config repo (-> /etc/nixos).

        Returns: {success, paths: {label: [path, ...]}, error}
        """
        paths: Dict[str, List[str]] = {}
        try:
            # Per-service repositories from the service catalog.
            if BackupOperations.SERVICE_CATALOG.exists():
                catalog = json.loads(
                    BackupOperations.SERVICE_CATALOG.read_text())
                for entry in catalog:
                    label = entry.get("label")
                    backup = entry.get("backup") or {}
                    if not label:
                        continue
                    repo_paths = list(backup.get("paths") or [])
                    # The backup units also dump databases into these
                    # dirs (services/backup/default.nix) - include them
                    # so the repo's full source set is shown.
                    if backup.get("postgres-databases"):
                        repo_paths.append(
                            f"/var/backup/postgresql-homefree/{label}")
                    if backup.get("mysql-databases"):
                        repo_paths.append(
                            f"/var/backup/mysql-homefree/{label}")
                    if repo_paths:
                        paths[label] = repo_paths

            # system-config + extra-path-N from homefree-config.json.
            if BackupOperations.HOMEFREE_CONFIG.exists():
                hf = json.loads(
                    BackupOperations.HOMEFREE_CONFIG.read_text())
                backups = hf.get("backups") or {}
                # System configuration repo is always /etc/nixos.
                paths["system-config"] = ["/etc/nixos"]
                # extra-path-N: N is the index into extra-from-paths
                # (services/backup/default.nix uses lib.imap0).
                for i, p in enumerate(backups.get("extra-from-paths") or []):
                    paths[f"extra-path-{i}"] = [p]

            return {"success": True, "paths": paths}
        except json.JSONDecodeError as e:
            logger.error(f"Invalid JSON reading source paths: {e}")
            return {"success": False, "paths": {}, "error": str(e)}
        except Exception as e:
            logger.error(f"Error reading source paths: {e}")
            return {"success": False, "paths": {}, "error": str(e)}

    @staticmethod
    def list_snapshots(service: str,
                       source: BackupSource = BackupSource.AUTO
                       ) -> Dict[str, Any]:
        """List all snapshots for a specific service."""
        try:
            cmd = [str(BackupOperations.RESTORE_SCRIPT),
                   "list-snapshots", service]
            if source != BackupSource.AUTO:
                cmd += ["--source", source.value]
            result = subprocess.run(cmd, capture_output=True, text=True,
                                    timeout=60)
            if result.returncode == 0:
                return {"success": True,
                        "snapshots": BackupOperations._parse_snapshots(
                            result.stdout)}
            return {"success": False, "snapshots": [],
                    "error": result.stderr or result.stdout}
        except subprocess.TimeoutExpired:
            return {"success": False, "snapshots": [],
                    "error": "Operation timed out after 60 seconds"}
        except Exception as e:
            logger.error(f"Error listing snapshots: {e}")
            return {"success": False, "snapshots": [], "error": str(e)}

    @staticmethod
    def _parse_snapshots(output: str) -> List[Dict[str, Any]]:
        if not output.strip():
            return []
        try:
            snapshots = json.loads(output.strip())
            if isinstance(snapshots, list):
                return snapshots
        except json.JSONDecodeError:
            pass
        snapshots = []
        for line in output.strip().split("\n"):
            if not line.strip():
                continue
            try:
                snapshots.append(json.loads(line))
                continue
            except json.JSONDecodeError:
                pass
            parts = [p.strip() for p in line.split("|")]
            if len(parts) >= 3:
                snapshots.append({
                    "id": parts[0], "time": parts[1],
                    "hostname": parts[2] if len(parts) > 2 else "",
                    "paths": parts[3] if len(parts) > 3 else "",
                })
        return snapshots

    @staticmethod
    def get_repository_paths(service: str,
                             source: BackupSource = BackupSource.AUTO,
                             force_refresh: bool = False) -> Dict[str, Any]:
        """Get the backup root paths of a repository's latest snapshot.

        `restore.sh list-paths` emits the snapshot's `paths` array (the
        directories handed to `restic backup`) - one clean path per line.
        These are the meaningful roots, e.g. /var/lib/adguardhome or a
        configured extra path, not the full file tree.
        """
        try:
            cache_key = f"{source.value}:{service}"
            if not force_refresh:
                cached = BackupOperations._paths_cache.get(cache_key)
                if cached:
                    return cached

            cmd = [str(BackupOperations.RESTORE_SCRIPT), "list-paths", service]
            if source != BackupSource.AUTO:
                cmd += ["--source", source.value]
            result = subprocess.run(cmd, capture_output=True, text=True,
                                    timeout=60)
            if result.returncode == 0:
                paths = []
                for line in result.stdout.strip().split("\n"):
                    line = strip_ansi_codes(line.strip())
                    # restore.sh logs to stderr, so stdout is path-only;
                    # still guard against a stray log line leaking in.
                    if line and not any(x in line for x in [
                            "[INFO]", "[WARN]", "[ERROR]"]):
                        paths.append(line)
                response = {"success": True, "paths": paths}
                if paths:
                    BackupOperations._paths_cache[cache_key] = response
                    BackupOperations._paths_cache_timestamp[cache_key] = \
                        datetime.now().timestamp()
                return response
            return {"success": False, "paths": [],
                    "error": result.stderr or result.stdout}
        except subprocess.TimeoutExpired:
            return {"success": False, "paths": [],
                    "error": "Operation timed out after 60 seconds"}
        except Exception as e:
            logger.error(f"Error getting repository paths: {e}")
            return {"success": False, "paths": [], "error": str(e)}

    @staticmethod
    def get_all_repository_paths(source: BackupSource = BackupSource.LOCAL
                                 ) -> Dict[str, Any]:
        """Return whatever all-repository path data is currently cached.

        This never blocks. The actual resolution happens in a background
        warm (`_warm_paths`) that streams progress; callers poll this
        plus `get_paths_progress` to drive a progress bar.

        Returns: {success, paths: {repo: [path, ...]}, ready: bool}
        """
        cache_key = f"all:{source.value}"
        cached = BackupOperations._paths_cache.get(cache_key)
        progress = BackupOperations._paths_progress.get(source.value, {})
        ready = progress.get("state") == "ready"
        return {
            "success": True,
            "paths": (cached or {}).get("paths", {}),
            "ready": ready,
        }

    @staticmethod
    def get_paths_progress(source: BackupSource = BackupSource.LOCAL
                           ) -> Dict[str, Any]:
        """Return live progress of the all-repository path warm.

        {state, done, total, error} - state is one of
        idle | running | ready | error.
        """
        p = BackupOperations._paths_progress.get(source.value)
        if not p:
            return {"state": "idle", "done": 0, "total": 0, "error": None}
        return dict(p)

    @staticmethod
    def _warm_paths(source: BackupSource) -> None:
        """Resolve every repository's backup-root paths, with progress.

        Runs `restore.sh list-all-paths`, which streams one NDJSON line
        per repository. Each line updates `_paths_progress` and the
        cache incrementally, so the UI sees a moving progress bar and
        repo rows fill in as their paths arrive.
        """
        skey = source.value
        cache_key = f"all:{skey}"
        progress = {"state": "running", "done": 0, "total": 0, "error": None}
        BackupOperations._paths_progress[skey] = progress

        # Accumulate into a fresh map; only swap the cache atomically.
        paths_map: Dict[str, List[str]] = {}
        proc = None
        try:
            cmd = [str(BackupOperations.RESTORE_SCRIPT), "list-all-paths"]
            if source != BackupSource.AUTO:
                cmd += ["--source", skey]
            proc = subprocess.Popen(cmd, stdout=subprocess.PIPE,
                                    stderr=subprocess.DEVNULL, text=True)
            for line in proc.stdout:
                line = line.strip()
                if not line:
                    continue
                try:
                    evt = json.loads(line)
                except json.JSONDecodeError:
                    continue   # ignore any stray non-JSON line
                etype = evt.get("event")
                if etype == "begin":
                    progress["total"] = evt.get("total", 0)
                elif etype == "repo":
                    repo = evt.get("name")
                    repo_paths = evt.get("paths", []) or []
                    paths_map[repo] = repo_paths
                    progress["done"] = evt.get("index", progress["done"] + 1)
                    # Seed the per-repo cache as each repo resolves so an
                    # already-rendered row can fill in immediately.
                    if repo_paths:
                        sk = f"{skey}:{repo}"
                        BackupOperations._paths_cache[sk] = {
                            "success": True, "paths": repo_paths}
                        BackupOperations._paths_cache_timestamp[sk] = \
                            datetime.now().timestamp()
                    # Publish a partial all-map so polling shows progress.
                    BackupOperations._paths_cache[cache_key] = {
                        "paths": dict(paths_map)}
                # "end" - loop will terminate when the pipe closes.

            ret = proc.wait()
            if ret != 0:
                progress["state"] = "error"
                progress["error"] = f"list-all-paths exited {ret}"
                logger.warning(f"Path warm for {skey} exited {ret}")
                return

            BackupOperations._paths_cache[cache_key] = {"paths": paths_map}
            BackupOperations._paths_cache_timestamp[cache_key] = \
                datetime.now().timestamp()
            progress["state"] = "ready"
            logger.info(f"Path warm for {skey} complete "
                        f"({len(paths_map)} repos)")
        except Exception as e:
            logger.error(f"Path warm for {skey} failed: {e}")
            progress["state"] = "error"
            progress["error"] = str(e)
            if proc:
                try:
                    proc.kill()
                except Exception:
                    pass
        finally:
            BackupOperations._paths_warming[skey] = False

    @staticmethod
    def ensure_paths_warm(source: BackupSource = BackupSource.LOCAL,
                          force: bool = False) -> Dict[str, Any]:
        """Kick off a background path warm for `source` if not already
        running (or done). Returns the current progress immediately.
        """
        skey = source.value
        with BackupOperations._paths_warm_lock:
            progress = BackupOperations._paths_progress.get(skey, {})
            already_done = (progress.get("state") == "ready" and not force)
            running = BackupOperations._paths_warming.get(skey, False)
            if already_done:
                return BackupOperations.get_paths_progress(source)
            if running:
                return BackupOperations.get_paths_progress(source)
            # Don't fight an in-flight backup/restore for restic locks.
            if BackupOperations._lock_holder() is not None:
                logger.info("Path warm deferred: backup subsystem busy")
                return BackupOperations.get_paths_progress(source)
            BackupOperations._paths_warming[skey] = True
            BackupOperations._paths_progress[skey] = {
                "state": "running", "done": 0, "total": 0, "error": None}
        threading.Thread(target=BackupOperations._warm_paths,
                         args=(source,), daemon=True,
                         name=f"backup-paths-warm-{skey}").start()
        return BackupOperations.get_paths_progress(source)

    @staticmethod
    def prewarm_paths_cache() -> None:
        """Pre-warm the path cache for all sources at startup / post-job."""
        for src in (BackupSource.LOCAL, BackupSource.BACKBLAZE):
            BackupOperations.ensure_paths_warm(src, force=True)

    @staticmethod
    def start_prewarm_thread() -> None:
        # ensure_paths_warm already spawns per-source daemon threads;
        # call it directly (cheap, non-blocking).
        BackupOperations.prewarm_paths_cache()

    # ------------------------------------------------------------- downloads

    @staticmethod
    def download_service(service: str) -> Dict[str, Any]:
        """Download a service backup from Backblaze to local storage."""
        try:
            cmd = [str(BackupOperations.RESTORE_SCRIPT), "download", service]
            result = subprocess.run(cmd, capture_output=True, text=True,
                                    timeout=3600)
            if result.returncode == 0:
                return {"success": True, "output": result.stdout}
            return {"success": False, "output": result.stdout,
                    "error": result.stderr or "Download failed"}
        except subprocess.TimeoutExpired:
            return {"success": False, "error": "Download timed out after 1 hour"}
        except Exception as e:
            logger.error(f"Error downloading service backup: {e}")
            return {"success": False, "error": str(e)}

    # -------------------------------------------------------------- restores

    @staticmethod
    def _start_restore_job(kind: JobKind, repos: List[str],
                           snapshot_id: Optional[str],
                           source: BackupSource) -> Dict[str, Any]:
        """Create a restore job and drive it in a background thread.

        Acquires the subsystem lock; raises BackupBusy if already held.
        """
        holder = BackupOperations._lock_holder()
        if holder is not None:
            raise BackupBusy(holder.get("kind", "unknown"),
                             holder.get("job_id"))

        BackupOperations._ensure_directories()
        job = BackupOperations._new_job(kind, repos)
        BackupOperations.CURRENT_JOB_FILE.write_text(job["id"])

        thread = threading.Thread(
            target=BackupOperations._restore_worker,
            args=(job, repos, snapshot_id, source),
            daemon=True, name=f"restore-{job['id']}")
        thread.start()
        return {"success": True, "job_id": job["id"], "job": job}

    @staticmethod
    def _restore_worker(job: Dict[str, Any], repos: List[str],
                        snapshot_id: Optional[str],
                        source: BackupSource) -> None:
        """Background worker: holds the lock, restores each repo in turn."""
        lock_fd = os.open(str(BackupOperations.LOCK_FILE),
                          os.O_RDWR | os.O_CREAT, 0o600)
        suspended_timers: List[str] = []
        log_file = Path(job["log_file"])
        try:
            fcntl.flock(lock_fd, fcntl.LOCK_EX)
            job["state"] = JobState.RUNNING.value
            BackupOperations._write_job(job)

            # Suspend backup timers for the affected repos so a scheduled
            # backup can't run restic against a repo mid-restore.
            suspended_timers = BackupOperations._suspend_backup_timers(repos)

            failed: List[str] = []
            with open(log_file, "a", buffering=1) as logf:
                logf.write(f"=== Restore job {job['id']} "
                           f"({job['kind']}) ===\n")
                logf.write(f"Repositories: {', '.join(repos)}\n\n")
                for repo in repos:
                    BackupOperations._update_repo(job, repo, "running")
                    logf.write(f"\n=== Restoring {repo} ===\n")
                    logf.flush()
                    cmd = [str(BackupOperations.RESTORE_SCRIPT),
                           "restore", repo]
                    if snapshot_id:
                        cmd.append(snapshot_id)
                    if source != BackupSource.AUTO:
                        cmd += ["--source", source.value]
                    cmd.append("--yes")
                    proc = subprocess.run(cmd, stdout=logf,
                                          stderr=subprocess.STDOUT, text=True)
                    if proc.returncode == 0:
                        BackupOperations._update_repo(job, repo, "done")
                    else:
                        failed.append(repo)
                        BackupOperations._update_repo(
                            job, repo, "failed",
                            error=f"restore exited {proc.returncode}")
                        logf.write(f"!!! {repo} failed "
                                   f"(exit {proc.returncode})\n")

            if failed:
                BackupOperations._finish_job(
                    job, JobState.FAILED,
                    error=f"Failed to restore: {', '.join(failed)}")
            else:
                BackupOperations._finish_job(job, JobState.DONE, exit_code=0)
        except Exception as e:
            logger.error(f"Restore worker error ({job['id']}): {e}")
            try:
                with open(log_file, "a") as logf:
                    logf.write(f"\n!!! Restore worker crashed: {e}\n")
            except Exception:
                pass
            BackupOperations._finish_job(job, JobState.FAILED, error=str(e))
        finally:
            BackupOperations._resume_backup_timers(suspended_timers)
            try:
                fcntl.flock(lock_fd, fcntl.LOCK_UN)
            except Exception:
                pass
            os.close(lock_fd)
            # Refresh path cache now that data changed.
            BackupOperations.start_prewarm_thread()

    @staticmethod
    def restore_service(service: str, snapshot_id: Optional[str] = None,
                        source: BackupSource = BackupSource.AUTO,
                        dry_run: bool = False,
                        create_snapshot: bool = False) -> Dict[str, Any]:
        """Restore a single repository. Non-blocking; returns a job id.

        Raises BackupBusy if a backup/restore/sync is already running.
        """
        if dry_run or create_snapshot:
            logger.info("dry_run/create_snapshot requested but not yet "
                        "implemented in restore.sh")
        return BackupOperations._start_restore_job(
            JobKind.RESTORE, [service], snapshot_id, source)

    @staticmethod
    def restore_all(snapshot_id: Optional[str] = None,
                    source: BackupSource = BackupSource.AUTO,
                    dry_run: bool = False,
                    include_system_config: bool = False) -> Dict[str, Any]:
        """Restore every repository. Non-blocking; returns a job id.

        Always loops per-repo so the job reports per-repository progress.
        Raises BackupBusy if the subsystem is already in use.
        """
        if dry_run:
            logger.info("dry_run requested but not yet implemented")

        services_result = BackupOperations.list_services(source)
        if not services_result["success"]:
            return {"success": False,
                    "error": f"Failed to list services: "
                             f"{services_result.get('error', 'Unknown error')}"}

        repos: List[str] = []
        for repo in services_result.get("services", []):
            if repo == "system-config" and not include_system_config:
                continue
            repos.append(repo)

        if not repos:
            return {"success": False,
                    "error": "No repositories found to restore"}

        return BackupOperations._start_restore_job(
            JobKind.RESTORE_ALL, repos, snapshot_id, source)

    # -------------------------------------------------------- config status

    @staticmethod
    def get_backup_config_status() -> Dict[str, Any]:
        """Check whether backup/restore configuration is ready.

        Backblaze B2 is a native restic repository (no FUSE mount), so
        "available" means the credentials are present - restic can then
        talk to B2 directly.
        """
        restic_pw = Path("/var/lib/homefree-secrets/backup/restic-password")
        bb_id = Path("/var/lib/homefree-secrets/backup/backblaze-id")
        bb_key = Path("/var/lib/homefree-secrets/backup/backblaze-key")
        local_path = Path("/var/lib/backups")
        backblaze_configured = (
            bb_id.exists() and bb_id.stat().st_size > 0
            and bb_key.exists() and bb_key.stat().st_size > 0)
        return {
            "restic_password_configured":
                restic_pw.exists() and restic_pw.stat().st_size > 0,
            "backblaze_configured": backblaze_configured,
            "local_backup_path": str(local_path),
            "local_backups_available": (
                local_path.exists() and any(local_path.iterdir())
                if local_path.exists() else False),
            # Native B2: usable as soon as credentials exist (no mount).
            "backblaze_available": backblaze_configured,
        }

    # ----------------------------------------------------------- backups

    @staticmethod
    def _list_backup_units(prefix: str) -> List[str]:
        """Return restic-backups-<prefix>-*.service unit names."""
        result = subprocess.run(
            ["systemctl", "list-units", "--all",
             f"restic-backups-{prefix}-*.service",
             "--no-pager", "--no-legend"],
            capture_output=True, text=True, timeout=10)
        if result.returncode != 0:
            return []
        units = []
        for line in result.stdout.strip().split("\n"):
            parts = line.split()
            if parts and parts[0].endswith(".service"):
                units.append(parts[0])
        return units

    @staticmethod
    def _trigger_backups_worker(job: Dict[str, Any], prefix: str,
                                exclude_repos: List[str],
                                only_repos: Optional[List[str]] = None) -> None:
        """Background worker that starts every restic-backups-<prefix>-*
        unit, recording per-repository progress on the job.

        If ``only_repos`` is given, restrict the run to exactly those
        repository labels (used by the per-service trigger).
        """
        lock_fd = os.open(str(BackupOperations.LOCK_FILE),
                          os.O_RDWR | os.O_CREAT, 0o600)
        log_file = Path(job["log_file"])
        unit_prefix = f"restic-backups-{prefix}-"
        try:
            fcntl.flock(lock_fd, fcntl.LOCK_EX)
            job["state"] = JobState.RUNNING.value
            BackupOperations._write_job(job)

            with open(log_file, "a", buffering=1) as logf:
                def _repo_of(u):
                    return u.replace(unit_prefix, "").replace(".service", "")
                units = [u for u in BackupOperations._list_backup_units(prefix)
                         if _repo_of(u) not in exclude_repos
                         and (only_repos is None or _repo_of(u) in only_repos)]
                if not units:
                    BackupOperations._finish_job(
                        job, JobState.FAILED,
                        error="No backup services found to trigger")
                    return

                logf.write(f"Triggering {len(units)} {prefix} "
                           f"backup service(s)\n")
                failed = []
                for svc in units:
                    repo = svc.replace(unit_prefix, "").replace(
                        ".service", "")
                    BackupOperations._update_repo(job, repo, "running")
                    try:
                        # `systemctl start` of the oneshot blocks until the
                        # restic backup finishes - so per-repo state is real.
                        subprocess.run(["systemctl", "start", svc],
                                       capture_output=True, text=True,
                                       timeout=3600, check=True)
                        BackupOperations._update_repo(job, repo, "done")
                        logf.write(f"  {svc}: completed\n")
                    except subprocess.CalledProcessError as e:
                        failed.append(repo)
                        BackupOperations._update_repo(
                            job, repo, "failed",
                            error=e.stderr or "systemctl start failed")
                        logf.write(f"  {svc}: FAILED - {e.stderr}\n")
                    except subprocess.TimeoutExpired:
                        failed.append(repo)
                        BackupOperations._update_repo(job, repo, "failed",
                                                      error="timeout")
                        logf.write(f"  {svc}: TIMEOUT\n")

            if failed:
                BackupOperations._finish_job(
                    job, JobState.FAILED,
                    error=f"Failed for: {', '.join(failed)}")
            else:
                BackupOperations._finish_job(job, JobState.DONE, exit_code=0)
        except Exception as e:
            logger.error(f"Backup trigger worker error: {e}")
            BackupOperations._finish_job(job, JobState.FAILED, error=str(e))
        finally:
            try:
                fcntl.flock(lock_fd, fcntl.LOCK_UN)
            except Exception:
                pass
            os.close(lock_fd)
            # Backups changed the repos - refresh the path cache.
            BackupOperations.start_prewarm_thread()

    @staticmethod
    def _trigger_backups(prefix: str, kind: JobKind,
                         only_repo: Optional[str] = None) -> Dict[str, Any]:
        """Shared implementation: start restic-backups-<prefix>-* units
        as a tracked job. Non-blocking; returns a job id.

        If ``only_repo`` is given, restrict the run to that single
        repository label (used by the per-service trigger).
        """
        holder = BackupOperations._lock_holder()
        if holder is not None:
            raise BackupBusy(holder.get("kind", "unknown"),
                             holder.get("job_id"))

        unit_prefix = f"restic-backups-{prefix}-"
        units = BackupOperations._list_backup_units(prefix)
        repos = [u.replace(unit_prefix, "").replace(".service", "")
                 for u in units]
        if only_repo is not None:
            if only_repo not in repos:
                return {"success": False,
                        "error": f"No {prefix} backup found for "
                                 f"'{only_repo}'."}
            repos = [only_repo]
        if not repos:
            return {"success": False,
                    "error": f"No {prefix} backup services found. "
                             f"Ensure backups are enabled."}

        BackupOperations._ensure_directories()
        job = BackupOperations._new_job(kind, repos)
        BackupOperations.CURRENT_JOB_FILE.write_text(job["id"])
        only_repos = [only_repo] if only_repo is not None else None
        threading.Thread(
            target=BackupOperations._trigger_backups_worker,
            args=(job, prefix, [], only_repos), daemon=True,
            name=f"{kind.value}-{job['id']}").start()
        return {"success": True, "job_id": job["id"], "job": job}

    @staticmethod
    def trigger_all_backups() -> Dict[str, Any]:
        """Run all LOCAL backups now. Non-blocking; returns a job id.

        Raises BackupBusy if the subsystem is already in use.
        """
        return BackupOperations._trigger_backups("local", JobKind.BACKUP)

    @staticmethod
    def trigger_backblaze_backup() -> Dict[str, Any]:
        """Run all BACKBLAZE B2 backups now. Non-blocking; returns a job id.

        With native restic-to-B2 there is no "sync" step - this simply
        starts the per-service B2 restic backup units on demand (they
        otherwise run on their own timer).

        Raises BackupBusy if the subsystem is already in use.
        """
        return BackupOperations._trigger_backups("backblaze", JobKind.SYNC)

    @staticmethod
    def trigger_service_backup(label: str, source: str) -> Dict[str, Any]:
        """Run the backup for a SINGLE service now. Non-blocking.

        ``source`` is "local" or "backblaze". Reuses the same job /
        lock machinery as the bulk triggers, so only one backup-
        subsystem job runs at a time.

        Raises BackupBusy if the subsystem is already in use.
        """
        if source == "local":
            return BackupOperations._trigger_backups(
                "local", JobKind.BACKUP, only_repo=label)
        if source == "backblaze":
            return BackupOperations._trigger_backups(
                "backblaze", JobKind.SYNC, only_repo=label)
        return {"success": False,
                "error": f"Unknown backup source '{source}' "
                         f"(expected 'local' or 'backblaze')."}

    # ----------------------------------------------------- status (compat)

    @staticmethod
    def get_backup_status() -> Dict[str, Any]:
        """Backwards-compatible status shim built on the job model."""
        try:
            current = BackupOperations.get_current_job().get("job")
            backup_running = sync_running = restore_running = False
            active_backups: List[str] = []
            active_restore = restore_type = None

            if current and current.get("state") in (
                    JobState.QUEUED.value, JobState.RUNNING.value):
                kind = current.get("kind")
                if kind == JobKind.BACKUP.value:
                    backup_running = True
                    active_backups = [r["name"] for r in current["repos"]
                                      if r["state"] == "running"]
                elif kind == JobKind.SYNC.value:
                    sync_running = True
                elif kind in (JobKind.RESTORE.value,
                              JobKind.RESTORE_ALL.value):
                    restore_running = True
                    active_restore = current.get("current_repo")
                    restore_type = ("all" if kind == JobKind.RESTORE_ALL.value
                                    else "service")

            return {
                "success": True,
                "backup_running": backup_running,
                "active_backups": active_backups,
                "sync_running": sync_running,
                "restore_running": restore_running,
                "active_restore": active_restore,
                "restore_type": restore_type,
            }
        except Exception as e:
            logger.error(f"Error getting backup status: {e}")
            return {"success": False, "error": str(e)}

    # ------------------------------------------------------ canary self-test

    CANARY_RESULT_FILE = Path("/var/lib/backup-canary/selftest-result.json")
    CANARY_SELFTEST_UNIT = "backup-canary-selftest.service"

    @staticmethod
    def _canary_enabled() -> bool:
        """True if the backup-canary self-test unit is installed."""
        try:
            result = subprocess.run(
                ["systemctl", "list-unit-files",
                 BackupOperations.CANARY_SELFTEST_UNIT, "--no-legend"],
                capture_output=True, text=True, timeout=10)
            return bool(result.stdout.strip())
        except Exception:
            return False

    # ------------------------------------------------------- backup health

    @staticmethod
    def _health_for_prefix(prefix: str) -> Dict[str, Any]:
        """Health summary for one backup source (local | backblaze).

        Reads each restic-backups-<prefix>-* unit's last result and
        run time straight from systemd - cheap, no restic calls.

        Returns:
            {total, ok, failed, never_run, failed_services,
             never_run_services, last_run, next_run}
            timestamps are ISO strings (or None).

        A backup is bucketed three ways, not two:
          * ok        - has run and the last run succeeded
          * failed    - has run and the last run errored (a real problem)
          * never_run - has never executed yet; an unknown, not a failure
        """
        unit_prefix = f"restic-backups-{prefix}-"
        services = [u.replace(unit_prefix, "").replace(".service", "")
                    for u in BackupOperations._list_backup_units(prefix)]
        result: Dict[str, Any] = {
            "total": len(services), "ok": 0, "failed": 0, "never_run": 0,
            "failed_services": [], "never_run_services": [],
            "last_run": None, "next_run": None,
        }
        if not services:
            return result

        last_run_ts = 0.0
        next_run_ts = 0.0
        for svc in services:
            unit = f"{unit_prefix}{svc}.service"
            timer = f"{unit_prefix}{svc}.timer"
            try:
                show = subprocess.run(
                    ["systemctl", "show", unit,
                     "-p", "Result", "-p", "ExecMainStatus",
                     "-p", "ExecMainExitTimestampMonotonic",
                     "-p", "ExecMainExitTimestamp"],
                    capture_output=True, text=True, timeout=5)
                props = dict(
                    line.split("=", 1)
                    for line in show.stdout.strip().split("\n")
                    if "=" in line)
            except Exception:
                props = {}

            res = props.get("Result", "")
            exit_status = props.get("ExecMainStatus", "")

            # Query the timer first - it carries the only run signal that
            # survives a daemon-reload.
            timer_props: Dict[str, str] = {}
            try:
                tshow = subprocess.run(
                    ["systemctl", "show", timer,
                     "-p", "NextElapseUSecRealtime",
                     "-p", "LastTriggerUSec"],
                    capture_output=True, text=True, timeout=5)
                timer_props = dict(
                    line.split("=", 1)
                    for line in tshow.stdout.strip().split("\n")
                    if "=" in line)
            except Exception:
                timer_props = {}

            last_trigger = timer_props.get("LastTriggerUSec", "").strip()
            exit_ts = props.get("ExecMainExitTimestamp", "").strip()

            # Has this backup unit ever executed?
            #
            # `ExecMainExitTimestamp` looks like the obvious signal, but
            # systemd clears the runtime invocation state (ExecMain*) of
            # an *inactive* unit whenever its unit file is re-linked and
            # `daemon-reload` runs - which happens on every nixos-rebuild.
            # `Result` is no help either: it *defaults* to "success" on a
            # unit that has never started, so a non-empty Result does not
            # prove a run.
            #
            # The timer's LastTriggerUSec is the reliable proof: empty
            # until the timer first fires the unit, a real timestamp
            # after, and preserved across daemon-reload. A unit with
            # neither LastTriggerUSec nor ExecMainExitTimestamp has
            # genuinely never run - that is an "unknown", not a failure
            # (e.g. a freshly-provisioned box before its first 02:00
            # window), so it gets its own bucket rather than counting as
            # a real backup failure.
            has_run = bool(last_trigger) or bool(exit_ts)

            if not has_run:
                result["never_run"] += 1
                result["never_run_services"].append(svc)
            elif res == "success" and exit_status in ("0", ""):
                result["ok"] += 1
            else:
                result["failed"] += 1
                result["failed_services"].append(svc)

            # Most-recent past run, from the timer's LastTriggerUSec
            # (survives daemon-reload); fall back to the service's exit
            # timestamp if the timer has no trigger record yet.
            run_ts = last_trigger or exit_ts
            if run_ts:
                parsed = BackupOperations._parse_systemd_ts(run_ts)
                if parsed and parsed > last_run_ts:
                    last_run_ts = parsed

            nxt = timer_props.get("NextElapseUSecRealtime", "").strip()
            if nxt:
                parsed = BackupOperations._parse_systemd_ts(nxt)
                if parsed and (next_run_ts == 0.0
                               or parsed < next_run_ts):
                    next_run_ts = parsed

        if last_run_ts:
            result["last_run"] = datetime.fromtimestamp(
                last_run_ts).isoformat()
        if next_run_ts:
            result["next_run"] = datetime.fromtimestamp(
                next_run_ts).isoformat()
        return result

    @staticmethod
    def _parse_systemd_ts(value: str) -> Optional[float]:
        """Parse a systemd human timestamp ('Sat 2026-05-16 02:20:50 PDT')
        into a POSIX timestamp. Returns None on failure.
        """
        # Strip the leading weekday and trailing timezone abbreviation.
        parts = value.split()
        if len(parts) >= 3:
            # parts: [Weekday, YYYY-MM-DD, HH:MM:SS, TZ]
            date_part = parts[1] if len(parts) > 1 else ""
            time_part = parts[2] if len(parts) > 2 else ""
            try:
                dt = datetime.strptime(f"{date_part} {time_part}",
                                       "%Y-%m-%d %H:%M:%S")
                return dt.timestamp()
            except ValueError:
                pass
        return None

    @staticmethod
    def get_backup_health() -> Dict[str, Any]:
        """Return last-run health for local and Backblaze backups.

        {success, local: {...}, backblaze: {...}} - each sub-dict has
        total / ok / failed / failed_services / last_run / next_run.
        `backblaze` is None when no B2 backup units exist.
        """
        try:
            local = BackupOperations._health_for_prefix("local")
            bb_units = BackupOperations._list_backup_units("backblaze")
            backblaze = (BackupOperations._health_for_prefix("backblaze")
                         if bb_units else None)
            return {"success": True, "local": local,
                    "backblaze": backblaze}
        except Exception as e:
            logger.error(f"Error getting backup health: {e}")
            return {"success": False, "error": str(e)}

    @staticmethod
    def get_canary_status() -> Dict[str, Any]:
        """Return the backup canary's latest self-test result.

        {enabled, running, result: {result, source, started_at,
         finished_at, detail} | None}
        `enabled` is False when the canary service is not deployed.
        """
        enabled = BackupOperations._canary_enabled()
        if not enabled:
            return {"success": True, "enabled": False,
                    "running": False, "result": None}

        # Is a self-test currently running?
        running = False
        try:
            active = subprocess.run(
                ["systemctl", "is-active",
                 BackupOperations.CANARY_SELFTEST_UNIT],
                capture_output=True, text=True, timeout=5)
            running = active.stdout.strip() in ("active", "activating")
        except Exception:
            pass

        result = None
        try:
            if BackupOperations.CANARY_RESULT_FILE.exists():
                result = json.loads(
                    BackupOperations.CANARY_RESULT_FILE.read_text())
        except Exception as e:
            logger.warning(f"Could not read canary result: {e}")

        return {"success": True, "enabled": True,
                "running": running, "result": result}

    @staticmethod
    def trigger_canary_selftest() -> Dict[str, Any]:
        """Start an on-demand backup self-test.

        Fire-and-forget: the self-test unit runs in the background and
        takes the backup lock itself (so it serialises against real
        backups). The UI polls get_canary_status() for the result.
        """
        if not BackupOperations._canary_enabled():
            return {"success": False,
                    "error": "Backup canary is not enabled on this system."}
        try:
            active = subprocess.run(
                ["systemctl", "is-active",
                 BackupOperations.CANARY_SELFTEST_UNIT],
                capture_output=True, text=True, timeout=5)
            if active.stdout.strip() in ("active", "activating"):
                return {"success": False,
                        "error": "A backup self-test is already running."}
            # --no-block: return immediately; the self-test runs on its own.
            subprocess.run(
                ["systemctl", "start", "--no-block",
                 BackupOperations.CANARY_SELFTEST_UNIT],
                capture_output=True, text=True, timeout=10, check=True)
            return {"success": True,
                    "output": "Backup self-test started."}
        except subprocess.CalledProcessError as e:
            return {"success": False,
                    "error": e.stderr or "Failed to start self-test"}
        except Exception as e:
            logger.error(f"Error triggering canary self-test: {e}")
            return {"success": False, "error": str(e)}
