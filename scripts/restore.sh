#!/usr/bin/env bash

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default configuration
BACKUP_LOCAL_PATH="${BACKUP_LOCAL_PATH:-/var/lib/backups}"
RESTIC_PASSWORD_FILE="${RESTIC_PASSWORD_FILE:-/var/lib/homefree-secrets/backup/restic-password}"
TEMP_RESTORE_DIR="${TEMP_RESTORE_DIR:-/var/lib/homefree-admin/restore-staging}"

# Backblaze B2 is a NATIVE restic repository, not a mounted filesystem.
# Each service's offsite repo is addressed as b2:<bucket>:<service>.
# BACKBLAZE_BUCKET and RESTIC_ENV_FILE are exported by the restore-cli
# wrapper (services/backup/default.nix); RESTIC_ENV_FILE holds
# B2_ACCOUNT_ID / B2_ACCOUNT_KEY which restic's B2 backend needs.
BACKBLAZE_BUCKET="${BACKBLAZE_BUCKET:-}"
RESTIC_ENV_FILE="${RESTIC_ENV_FILE:-/var/lib/homefree-secrets/backup/restic-environment}"

# HomeFree service catalog - maps service label -> systemd units + backup
# paths. Written by services/service-config-json. The restore path reads
# this to stop/start the EXACT units for a service (no substring guessing).
SERVICE_CATALOG="${SERVICE_CATALOG:-/etc/homefree/service-config.json}"

# Shared infrastructure units. These appear in several services'
# systemd-service-names but are NOT owned by any one service - a restore
# must never stop them. In particular postgresql/mysql must stay running
# so database dumps can be restored into them.
SHARED_INFRA_UNITS=(
    postgresql
    mysql
    mariadb
    caddy
    admin-api
    redis
    podman-oauth2-proxy
    podman-postgres-vectorchord
)

# Database data directories - excluded from the file rsync so they are
# not clobbered while/after the SQL dump is restored into the live DB.
DB_DATA_DIRS=(
    /var/lib/postgresql
    /var/lib/mysql
    /var/lib/mariadb
)

# Usage information
usage() {
    cat << EOF
Usage: $(basename "$0") <command> [options]

Commands:
    list-services           List all services that have backups
    list-snapshots SERVICE  List all snapshots for a specific service
    list-paths SERVICE      List all paths in a service's latest snapshot
    list-all-paths          List backup root paths for every repo (JSON)
    restore SERVICE [ID]    Restore a service from backup (latest or specific snapshot ID)
    restore-all             Restore all services from their latest backups

Options:
    -h, --help             Show this help message
    -b, --backup-path PATH Override local backup path (default: $BACKUP_LOCAL_PATH)
    -s, --source SOURCE    Source: 'local', 'backblaze', or 'auto' (default: auto)
    -y, --yes              Skip confirmation prompts (for non-interactive use)

Backblaze B2 is used as a native restic repository (b2:<bucket>:<service>),
not a mounted filesystem. With --source backblaze, restic talks to B2
directly using credentials from RESTIC_ENV_FILE.

Environment Variables:
    RESTIC_PASSWORD_FILE   Path to restic password file (default: /var/lib/homefree-secrets/backup/restic-password)
    BACKUP_LOCAL_PATH      Local backup directory (default: /var/lib/backups)
    BACKBLAZE_BUCKET       B2 bucket name (set by the restore-cli wrapper)
    RESTIC_ENV_FILE        File with B2_ACCOUNT_ID / B2_ACCOUNT_KEY

Examples:
    # List all services with backups
    $(basename "$0") list-services

    # List snapshots for nextcloud
    $(basename "$0") list-snapshots nextcloud

    # Restore latest nextcloud backup from local storage
    $(basename "$0") restore nextcloud --source local

    # Restore a specific snapshot of nextcloud from Backblaze
    $(basename "$0") restore nextcloud a1b2c3d4 --source backblaze

    # Restore all services from their latest backups
    $(basename "$0") restore-all

EOF
}

# Logging functions (all output to stderr to avoid interfering with command output)
log_info() {
    echo -e "${BLUE}[INFO]${NC} $*" >&2
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*" >&2
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*" >&2
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
}

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root"
        exit 1
    fi
}

# Load restic password
load_restic_password() {
    if [[ ! -f "$RESTIC_PASSWORD_FILE" ]]; then
        log_error "Restic password file not found: $RESTIC_PASSWORD_FILE"
        exit 1
    fi
    export RESTIC_PASSWORD=$(cat "$RESTIC_PASSWORD_FILE")
}

# Is the Backblaze B2 backend usable? (bucket name + credentials present)
b2_available() {
    [[ -n "$BACKBLAZE_BUCKET" ]] && [[ -s "$RESTIC_ENV_FILE" ]]
}

# Export B2 credentials (B2_ACCOUNT_ID / B2_ACCOUNT_KEY) into the
# environment so restic's B2 backend can authenticate. Safe to call
# repeatedly; no-op if the env file is absent.
load_b2_env() {
    [[ -s "$RESTIC_ENV_FILE" ]] || return 0
    set -a
    # shellcheck disable=SC1090
    source "$RESTIC_ENV_FILE"
    set +a
}

# Resolve the effective source: 'local' or 'backblaze'.
# 'auto' prefers local (the on-disk primary copy); B2 is the fallback.
determine_source() {
    local source="${SOURCE:-auto}"

    case "$source" in
        local)
            echo "local"
            ;;
        backblaze)
            if ! b2_available; then
                log_error "Backblaze source requested but B2 is not configured"
                log_error "(need a bucket name and credentials in $RESTIC_ENV_FILE)"
                exit 1
            fi
            echo "backblaze"
            ;;
        auto)
            if [[ -d "$BACKUP_LOCAL_PATH" ]]; then
                echo "local"
            elif b2_available; then
                echo "backblaze"
            else
                log_error "No backup source available - no local backup path"
                log_error "and Backblaze B2 is not configured."
                exit 1
            fi
            ;;
        *)
            log_error "Invalid source: $source. Must be 'local', 'backblaze', or 'auto'"
            exit 1
            ;;
    esac
}

# Print the restic repository URI for a service under the active source.
#   local      -> /var/lib/backups/<service>   (a directory)
#   backblaze  -> b2:<bucket>:<service>         (a native B2 repo)
repo_uri_for() {
    local service="$1"
    local source
    source=$(determine_source)

    if [[ "$source" == "backblaze" ]]; then
        echo "b2:${BACKBLAZE_BUCKET}:${service}"
    else
        echo "${BACKUP_LOCAL_PATH}/${service}"
    fi
}

# Print the list of service/repository names available under the active
# source, one per line.
#   local      -> directory names that look like restic repos
#   backblaze  -> top-level prefixes in the B2 bucket (one per repo)
list_repos_for_source() {
    local source
    source=$(determine_source)

    if [[ "$source" == "backblaze" ]]; then
        load_b2_env
        # Each service's B2 repo lives under b2:<bucket>:<service>/. The
        # bucket's top-level "directories" are therefore the repo names.
        # `rclone lsd` lists them; it needs a throwaway B2 remote built
        # from the same credentials restic uses.
        local conf
        conf=$(mktemp)
        # shellcheck disable=SC2064
        trap "rm -f '$conf'" RETURN
        {
            echo "[b2]"
            echo "type = b2"
            echo "account = ${B2_ACCOUNT_ID:-}"
            echo "key = ${B2_ACCOUNT_KEY:-}"
        } > "$conf"
        rclone --config "$conf" lsd "b2:${BACKBLAZE_BUCKET}" 2>/dev/null \
            | awk '{print $NF}'
    else
        [[ -d "$BACKUP_LOCAL_PATH" ]] || return 0
        local d
        for d in "$BACKUP_LOCAL_PATH"/*; do
            [[ -d "$d" ]] || continue
            [[ -f "$d/config" ]] || continue
            basename "$d"
        done
    fi
}

# List all repositories available under the active source, one per line.
list_services() {
    local repos
    repos=$(list_repos_for_source)

    if [[ -z "$repos" ]]; then
        log_warn "No backup repositories found"
        return 0
    fi
    echo "$repos"
}

# List snapshots for a specific service.
list_snapshots() {
    local service="$1"
    local repo
    repo=$(repo_uri_for "$service")

    load_b2_env
    export RESTIC_REPOSITORY="$repo"

    log_info "Snapshots for $service ($repo):"
    if [ -t 1 ]; then
        # Interactive terminal: human-readable table.
        echo
        restic snapshots
        echo
    else
        # Piped/captured: JSON for the API to parse.
        restic snapshots --json
    fi
}

# List the backup ROOT paths of a repository's latest snapshot.
#
# This emits the directories that were handed to `restic backup` (the
# snapshot's `paths` field), NOT the full file tree. `restic ls` would
# walk every file and return useless noise like /var, /var/lib, ... -
# the snapshot metadata already records exactly what was backed up.
list_paths() {
    local service="$1"
    local repo
    repo=$(repo_uri_for "$service")

    load_b2_env
    export RESTIC_REPOSITORY="$repo"

    # The `paths` array of the latest snapshot = the backup roots.
    # Reading snapshot metadata is cheap (no file walk).
    restic snapshots latest --json 2>/dev/null \
        | jq -r '.[-1].paths[]?' 2>/dev/null \
        | sort -u
}

# Stream the backup root paths for EVERY repository as NDJSON.
#
# Output is one JSON object per line so a reader can show incremental
# progress instead of waiting for the whole (~25s) run:
#
#   {"event":"begin","total":55}
#   {"event":"repo","index":1,"name":"adguard","paths":["/var/lib/..."]}
#   ...
#   {"event":"end"}
#
# The per-repo `restic snapshots` calls run serially: backup repos
# typically live on a single (often spinning) disk, and concurrent
# access just thrashes the head - serial is measurably faster there.
list_all_paths() {
    load_b2_env

    # First pass: enumerate repositories under the active source.
    local repo_name repos=()
    while IFS= read -r repo_name; do
        [[ -n "$repo_name" ]] && repos+=("$repo_name")
    done < <(list_repos_for_source)

    jq -cn --argjson t "${#repos[@]}" '{event:"begin",total:$t}'

    local idx=0 paths_json repo
    for repo_name in "${repos[@]}"; do
        idx=$((idx + 1))
        repo=$(repo_uri_for "$repo_name")

        paths_json=$(RESTIC_REPOSITORY="$repo" \
            restic snapshots latest --json 2>/dev/null \
            | jq -c '[.[-1].paths[]?] // []' 2>/dev/null)
        [[ -z "$paths_json" ]] && paths_json='[]'

        # One NDJSON line per repo - flushed immediately so the reader
        # sees progress as it happens.
        jq -cn --argjson i "$idx" --arg n "$repo_name" \
            --argjson p "$paths_json" \
            '{event:"repo",index:$i,name:$n,paths:$p}'
    done

    echo '{"event":"end"}'
}

# --------------------------------------------------------------------------
# Service unit resolution
#
# A restore must stop/start the EXACT systemd units owned by a service.
# The old code grepped unit names for the service string, which could
# match (and stop) unrelated services. Instead we look the service up by
# label in the HomeFree catalog and use its declared units, minus shared
# infrastructure units that no single service owns.
# --------------------------------------------------------------------------

# Print the catalog-declared, service-OWNED systemd units for a service,
# one ".service" unit per line. Shared infra units are filtered out.
# Prints nothing if the service has no catalog entry (e.g. a stale repo).
get_service_units() {
    local service="$1"

    [[ -f "$SERVICE_CATALOG" ]] || return 0

    local units
    units=$(jq -r --arg label "$service" \
        '.[] | select(.label == $label) | ."systemd-service-names"[]?' \
        "$SERVICE_CATALOG" 2>/dev/null) || return 0

    local unit
    while IFS= read -r unit; do
        [[ -n "$unit" ]] || continue

        # Skip shared infrastructure units.
        local skip=false shared
        for shared in "${SHARED_INFRA_UNITS[@]}"; do
            if [[ "$unit" == "$shared" ]]; then
                skip=true
                break
            fi
        done
        [[ "$skip" == true ]] && continue

        # Normalise to a full unit name.
        [[ "$unit" == *.* ]] || unit="${unit}.service"
        echo "$unit"
    done <<< "$units"
}

# Stop the given units (passed as arguments). Records nothing - the
# caller is responsible for tracking what to restart.
stop_units() {
    local unit
    for unit in "$@"; do
        if systemctl is-active --quiet "$unit" 2>/dev/null; then
            log_info "  Stopping $unit"
            if ! systemctl stop "$unit"; then
                log_error "Failed to stop $unit - aborting restore to avoid"
                log_error "writing data underneath a running service"
                return 1
            fi
        else
            log_info "  $unit already stopped"
        fi
    done
}

# Start the given units (passed as arguments).
start_units() {
    local unit failed=0
    for unit in "$@"; do
        log_info "  Starting $unit"
        if ! systemctl start "$unit"; then
            log_warn "Failed to start $unit"
            failed=1
        fi
    done
    return $failed
}

# --------------------------------------------------------------------------
# Database restore
#
# Databases are restored from SQL dumps captured in the snapshot. The DB
# server (postgresql/mysql) stays RUNNING throughout - it is shared infra
# and the dump is replayed into it. The DB data directory itself is
# excluded from the file rsync (see DB_DATA_DIRS) so the two do not race.
# --------------------------------------------------------------------------
restore_database() {
    local db_type="$1"   # postgres or mysql
    local service="$2"
    local restore_path="$3"

    case "$db_type" in
        postgres)
            local dump_dir="$restore_path/var/backup/postgresql-homefree/$service"
            [[ -d "$dump_dir" ]] || return 0

            if ! systemctl is-active --quiet postgresql 2>/dev/null; then
                log_warn "postgresql is not running; skipping DB restore for $service"
                return 0
            fi

            log_info "Restoring PostgreSQL databases for $service..."
            local dump_file db_name
            for dump_file in "$dump_dir"/*.sql.gz; do
                [[ -f "$dump_file" ]] || continue
                db_name=$(basename "$dump_file" .sql.gz)
                log_info "  Restoring database: $db_name"
                # Drop the existing DB for a clean restore. The dump
                # contains CREATE DATABASE, so replay against 'postgres'.
                sudo -u postgres dropdb --if-exists "$db_name" 2>/dev/null || true
                if ! gunzip -c "$dump_file" | sudo -u postgres psql --quiet \
                        --set ON_ERROR_STOP=on postgres; then
                    log_error "Failed to restore PostgreSQL database $db_name"
                    return 1
                fi
            done
            ;;
        mysql)
            local dump_dir="$restore_path/var/backup/mysql-homefree/$service"
            [[ -d "$dump_dir" ]] || return 0

            if ! systemctl is-active --quiet mysql 2>/dev/null \
                    && ! systemctl is-active --quiet mariadb 2>/dev/null; then
                log_warn "mysql/mariadb is not running; skipping DB restore for $service"
                return 0
            fi

            log_info "Restoring MySQL databases for $service..."
            local dump_file db_name
            for dump_file in "$dump_dir"/*.gz; do
                [[ -f "$dump_file" ]] || continue
                db_name=$(basename "$dump_file" .gz)
                log_info "  Restoring database: $db_name"
                # Ensure the database exists before replaying the dump
                # (mysqldump output does not always include CREATE DATABASE).
                mysql -e "CREATE DATABASE IF NOT EXISTS \`$db_name\`" \
                    2>/dev/null || true
                if ! gunzip -c "$dump_file" | mysql "$db_name"; then
                    log_error "Failed to restore MySQL database $db_name"
                    return 1
                fi
            done
            ;;
    esac
}

# Restore the file contents of a snapshot that has already been extracted
# to a staging directory.
#
#   $1  staging directory (the restic --target)
#   $2+ the snapshot's recorded backup root paths
#
# Only these exact paths are restored - never directories inferred from
# walking the staging tree. Database data directories are skipped.
restore_snapshot_files() {
    local staging="$1"
    shift
    local path

    for path in "$@"; do
        # Skip DB data dirs - the SQL dump path handles databases.
        local skip=false db_dir
        for db_dir in "${DB_DATA_DIRS[@]}"; do
            if [[ "$path" == "$db_dir" || "$path" == "$db_dir/"* ]]; then
                skip=true
                break
            fi
        done
        if [[ "$skip" == true ]]; then
            log_info "  Skipping database data dir $path (restored via SQL dump)"
            continue
        fi

        local src="$staging$path"
        if [[ ! -e "$src" ]]; then
            log_warn "  Snapshot path $path not present in extraction - skipping"
            continue
        fi

        log_info "  Restoring $path"
        mkdir -p "$(dirname "$path")"
        if [[ -d "$src" ]]; then
            # --numeric-ids keeps UIDs/GIDs stable across machines.
            if ! rsync -a --delete --numeric-ids "$src/" "$path/"; then
                log_error "Failed to restore $path"
                return 1
            fi
        else
            if ! rsync -a --numeric-ids "$src" "$path"; then
                log_error "Failed to restore $path"
                return 1
            fi
        fi
    done
}

# Read a repository's latest-snapshot backup root paths into the array
# named by $1. Returns non-zero if the repo has no usable snapshot.
#   $1  name of the array variable to populate
#   $2  RESTIC_REPOSITORY path
_read_snapshot_paths() {
    local -n _out="$1"
    local repo_path="$2"
    _out=()

    local json
    json=$(RESTIC_REPOSITORY="$repo_path" \
        restic snapshots latest --json 2>/dev/null) || return 1
    [[ -n "$json" ]] || return 1

    local path
    while IFS= read -r path; do
        [[ -n "$path" ]] && _out+=("$path")
    done < <(echo "$json" | jq -r '.[-1].paths[]?' 2>/dev/null)

    [[ ${#_out[@]} -gt 0 ]]
}

# Core single-repository restore. Used by both `restore` and
# `restore-all`. Returns 0 on success, non-zero on failure - it ALWAYS
# attempts to restart the service's units, even on failure, so a failed
# restore never leaves the service down.
#
#   $1  service / repository label
#   $2  snapshot id (or "latest")
#
# Safety properties:
#   * Stops only the EXACT catalog-declared units owned by the service.
#   * Aborts before touching live data if restic extraction fails or is
#     empty - never rsyncs a partial/empty tree over real data.
#   * Restores only the snapshot's recorded backup root paths.
_restore_one_repo() {
    local service="$1"
    local snapshot_id="${2:-latest}"

    # B2 credentials need to be in the environment if the source is B2.
    load_b2_env
    local repo
    repo=$(repo_uri_for "$service")

    # For a local source, verify the repo directory exists. For a B2
    # source the repo is remote; restic will report a missing repo.
    if [[ "$repo" != b2:* ]] && [[ ! -d "$repo" ]]; then
        log_error "No backup repository found for service: $service"
        return 1
    fi

    # Verify the requested snapshot exists.
    if [[ "$snapshot_id" != "latest" ]]; then
        if ! RESTIC_REPOSITORY="$repo" restic snapshots --quiet \
                "$snapshot_id" >/dev/null 2>&1; then
            log_error "Snapshot not found in $service: $snapshot_id"
            return 1
        fi
    fi

    # Determine the backup root paths recorded in the snapshot.
    local snapshot_paths
    if ! _read_snapshot_paths snapshot_paths "$repo"; then
        log_error "$service: could not read snapshot paths - aborting"
        return 1
    fi
    log_info "$service: snapshot covers ${#snapshot_paths[@]} path(s)"

    # Resolve the exact units to stop/start (empty for non-service repos
    # like extra-path-N, which simply have no service to bounce).
    local units=()
    local u
    while IFS= read -r u; do
        [[ -n "$u" ]] && units+=("$u")
    done < <(get_service_units "$service")

    if [[ ${#units[@]} -gt 0 ]]; then
        log_info "$service: units to bounce: ${units[*]}"
    else
        log_info "$service: no catalog units (file-only restore)"
    fi

    # Stop the service's units before touching its data.
    if [[ ${#units[@]} -gt 0 ]]; then
        log_info "Stopping $service..."
        if ! stop_units "${units[@]}"; then
            # Could not cleanly stop - restart whatever we did stop and
            # bail, rather than restore underneath a running service.
            start_units "${units[@]}" || true
            return 1
        fi
    fi

    # Extract the snapshot to a staging directory. Staging lives on
    # persistent storage (not tmpfs) so large services do not OOM.
    local staging="$TEMP_RESTORE_DIR/$service"
    rm -rf "$staging"
    mkdir -p "$staging"

    local rc=0
    log_info "$service: extracting snapshot $snapshot_id..."
    if ! RESTIC_REPOSITORY="$repo" restic restore "$snapshot_id" \
            --target "$staging"; then
        log_error "$service: restic extraction failed - NOT touching live data"
        rc=1
    fi

    # Guard against an empty/partial extraction wiping live data.
    if [[ $rc -eq 0 ]] && [[ -z "$(ls -A "$staging" 2>/dev/null)" ]]; then
        log_error "$service: extraction produced no files - aborting restore"
        rc=1
    fi

    if [[ $rc -eq 0 ]]; then
        # Restore databases from SQL dumps (DB server stays up).
        if ! restore_database "postgres" "$service" "$staging"; then
            rc=1
        fi
        if [[ $rc -eq 0 ]] && ! restore_database "mysql" "$service" \
                "$staging"; then
            rc=1
        fi
    fi

    if [[ $rc -eq 0 ]]; then
        # Restore exactly the snapshot's recorded paths.
        log_info "Restoring files for $service..."
        if ! restore_snapshot_files "$staging" "${snapshot_paths[@]}"; then
            rc=1
        fi
    fi

    # Always clean up staging.
    rm -rf "$staging"

    # Always restart the service - even if the restore failed, we do not
    # want to leave it down.
    if [[ ${#units[@]} -gt 0 ]]; then
        log_info "Starting $service..."
        start_units "${units[@]}" || log_warn "$service: some units failed to start"
    fi

    if [[ $rc -eq 0 ]]; then
        log_success "Restore completed for $service"
    else
        log_error "Restore FAILED for $service (service has been restarted)"
    fi
    return $rc
}

# Restore a single service / repository.
restore_service() {
    local service="$1"
    local snapshot_id="${2:-latest}"

    log_warn "This will restore $service from backup (snapshot: $snapshot_id)"
    log_warn "This will OVERWRITE current data for $service!"

    if [[ "$SKIP_CONFIRMATION" != "true" ]]; then
        echo -n "Are you sure you want to continue? (yes/no): "
        read -r confirmation
        if [[ "$confirmation" != "yes" ]]; then
            log_error "Restore cancelled by user"
            exit 1
        fi
    else
        log_info "Skipping confirmation (non-interactive mode)"
    fi

    local rc=0
    _restore_one_repo "$service" "$snapshot_id" || rc=$?
    exit $rc
}

# Restore every repository. Only "latest" is supported here: a specific
# snapshot id exists in just one repository, so it cannot be applied
# across all of them.
restore_all() {
    local snapshot_id="${1:-latest}"

    if [[ "$snapshot_id" != "latest" ]]; then
        log_error "restore-all only supports 'latest' - a specific snapshot"
        log_error "id is unique to one repository. Restore that service"
        log_error "individually instead."
        exit 1
    fi

    log_warn "This will restore ALL services from their latest backups"
    log_warn "This will OVERWRITE current data for all services!"

    if [[ "$SKIP_CONFIRMATION" != "true" ]]; then
        echo -n "Are you sure you want to continue? (yes/no): "
        read -r confirmation
        if [[ "$confirmation" != "yes" ]]; then
            log_error "Restore cancelled by user"
            exit 1
        fi
    else
        log_info "Skipping confirmation (non-interactive mode)"
    fi

    # Collect every repository available under the active source.
    local services=()
    local repo_name
    while IFS= read -r repo_name; do
        [[ -n "$repo_name" ]] && services+=("$repo_name")
    done < <(list_repos_for_source)

    log_info "Found ${#services[@]} repositories to restore"

    local failed=()
    local service
    for service in "${services[@]}"; do
        echo
        log_info "========== Restoring $service =========="
        # A single repo's failure must not abort the whole run.
        if ! _restore_one_repo "$service" "latest"; then
            failed+=("$service")
        fi
    done

    echo
    if [[ ${#failed[@]} -gt 0 ]]; then
        log_error "Restore finished with ${#failed[@]} failure(s): ${failed[*]}"
        exit 1
    fi
    log_success "Restore completed for all ${#services[@]} repositories"
}

# Main command processing
main() {
    if [[ $# -eq 0 ]]; then
        usage
        exit 1
    fi

    # Parse global options FIRST (can be before or after command)
    SOURCE="auto"
    SKIP_CONFIRMATION="false"
    COMMAND=""
    COMMAND_ARGS=()

    # First pass: extract command and all args
    while [[ $# -gt 0 ]]; do
        case "$1" in
            list-services|list-snapshots|list-paths|list-all-paths|restore|restore-all)
                COMMAND="$1"
                shift
                COMMAND_ARGS=("$@")
                break
                ;;
            *)
                shift
                ;;
        esac
    done

    # Second pass: parse all flags (both before and after command)
    # Note: Don't include "$@" here as it still contains the args from first pass (would duplicate them)
    set -- "${COMMAND_ARGS[@]}"
    COMMAND_ARGS=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                usage
                exit 0
                ;;
            -l|--local)
                SOURCE="local"
                shift
                ;;
            -b|--backup-path)
                BACKUP_LOCAL_PATH="$2"
                shift 2
                ;;
            -s|--source)
                SOURCE="$2"
                shift 2
                ;;
            -y|--yes)
                SKIP_CONFIRMATION="true"
                shift
                ;;
            list-services|list-snapshots|list-paths|list-all-paths|restore|restore-all)
                # Skip command name
                shift
                ;;
            *)
                # This is a command argument (not a flag)
                COMMAND_ARGS+=("$1")
                shift
                ;;
        esac
    done

    # Now execute the command
    case "$COMMAND" in
            list-services)
                check_root
                load_restic_password
                list_services
                exit 0
                ;;
            list-snapshots)
                if [[ ${#COMMAND_ARGS[@]} -lt 1 ]]; then
                    log_error "Missing service name"
                    usage
                    exit 1
                fi
                check_root
                load_restic_password
                list_snapshots "${COMMAND_ARGS[0]}"
                exit 0
                ;;
            list-paths)
                if [[ ${#COMMAND_ARGS[@]} -lt 1 ]]; then
                    log_error "Missing service name"
                    usage
                    exit 1
                fi
                check_root
                load_restic_password
                list_paths "${COMMAND_ARGS[0]}"
                exit 0
                ;;
            list-all-paths)
                check_root
                load_restic_password
                list_all_paths
                exit 0
                ;;
            restore)
                if [[ ${#COMMAND_ARGS[@]} -lt 1 ]]; then
                    log_error "Missing service name"
                    usage
                    exit 1
                fi
                check_root
                load_restic_password
                restore_service "${COMMAND_ARGS[0]}" "${COMMAND_ARGS[1]:-latest}"
                exit 0
                ;;
            restore-all)
                check_root
                load_restic_password
                restore_all "${COMMAND_ARGS[0]:-latest}"
                exit 0
                ;;
            "")
                log_error "No command specified"
                usage
                exit 1
                ;;
            *)
                log_error "Unknown command: $COMMAND"
                usage
                exit 1
                ;;
        esac
}

main "$@"
