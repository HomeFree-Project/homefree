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
BACKBLAZE_MOUNT="${BACKBLAZE_MOUNT:-/mnt/backup-backblaze}"
RESTIC_PASSWORD_FILE="${RESTIC_PASSWORD_FILE:-/var/lib/homefree-secrets/backup/restic-password}"
TEMP_RESTORE_DIR="/tmp/homefree-restore"

# Usage information
usage() {
    cat << EOF
Usage: $(basename "$0") <command> [options]

Commands:
    list-services           List all services that have backups
    list-snapshots SERVICE  List all snapshots for a specific service
    download SERVICE        Download a service backup from Backblaze to local
    download-all            Download all service backups from Backblaze
    restore SERVICE [ID]    Restore a service from backup (latest or specific snapshot ID)
    restore-all [ID]        Restore all services from backup (latest or specific snapshot ID)

Options:
    -h, --help             Show this help message
    -l, --local            Use local backups instead of downloading from Backblaze
    -b, --backup-path PATH Override local backup path (default: $BACKUP_LOCAL_PATH)
    -m, --mount-path PATH  Override Backblaze mount path (default: $BACKBLAZE_MOUNT)
    -s, --source SOURCE    Source for restore: 'local', 'backblaze', or 'auto' (default: auto)
    -y, --yes              Skip confirmation prompts (for non-interactive use)

Environment Variables:
    RESTIC_PASSWORD_FILE   Path to restic password file (default: /var/lib/homefree-secrets/backup/restic-password)
    BACKUP_LOCAL_PATH      Local backup directory (default: /var/lib/backups)
    BACKBLAZE_MOUNT        Backblaze mount point (default: /mnt/backup-backblaze)

Examples:
    # List all services with backups
    $(basename "$0") list-services

    # List snapshots for nextcloud
    $(basename "$0") list-snapshots nextcloud

    # Download nextcloud backup from Backblaze
    $(basename "$0") download nextcloud

    # Restore latest nextcloud backup from local storage
    $(basename "$0") restore nextcloud --local

    # Restore specific snapshot of nextcloud
    $(basename "$0") restore nextcloud a1b2c3d4

    # Restore all services from latest backups
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

# Determine backup source
determine_source() {
    local source="${SOURCE:-auto}"

    log_info "determine_source called with SOURCE=$SOURCE (resolved to: $source)"

    case "$source" in
        local)
            log_info "Source is explicitly 'local'"
            echo "local"
            ;;
        backblaze)
            log_info "Source is explicitly 'backblaze'"
            echo "backblaze"
            ;;
        auto)
            # Check if Backblaze is mounted
            log_info "Source is 'auto', checking BACKBLAZE_MOUNT=$BACKBLAZE_MOUNT"
            if mountpoint -q "$BACKBLAZE_MOUNT" 2>/dev/null; then
                log_info "Backblaze mount detected, using Backblaze backups"
                echo "backblaze"
            elif [[ -d "$BACKUP_LOCAL_PATH" ]]; then
                log_info "Using local backups from $BACKUP_LOCAL_PATH"
                echo "local"
            else
                log_error "No backup source available. Mount Backblaze or specify local backup path."
                exit 1
            fi
            ;;
        *)
            log_error "Invalid source: $source. Must be 'local', 'backblaze', or 'auto'"
            exit 1
            ;;
    esac
}

# Get backup base path based on source
get_backup_base_path() {
    local source=$(determine_source)

    if [[ "$source" == "backblaze" ]]; then
        echo "$BACKBLAZE_MOUNT"
    else
        echo "$BACKUP_LOCAL_PATH"
    fi
}

# List all services with backups
list_services() {
    local found_any=false

    # Try local backups if source is auto or local
    if [[ "$SOURCE" == "auto" || "$SOURCE" == "local" ]]; then
        if [[ -d "$BACKUP_LOCAL_PATH" ]]; then
            log_info "Services with backups in $BACKUP_LOCAL_PATH:"
            echo
            for service_dir in "$BACKUP_LOCAL_PATH"/*; do
                if [[ -d "$service_dir" ]]; then
                    local service_name=$(basename "$service_dir")
                    # Just check if it looks like a restic repo (has config file)
                    if [[ -f "$service_dir/config" ]]; then
                        echo "$service_name"
                        found_any=true
                    fi
                fi
            done
            echo
        fi
    fi

    # Try Backblaze if source is auto or backblaze
    if [[ "$SOURCE" == "auto" || "$SOURCE" == "backblaze" ]]; then
        if [[ -d "$BACKBLAZE_MOUNT" ]]; then
            log_info "Services with backups in $BACKBLAZE_MOUNT:"
            echo
            for service_dir in "$BACKBLAZE_MOUNT"/*; do
                if [[ -d "$service_dir" ]]; then
                    local service_name=$(basename "$service_dir")
                    # Just check if it looks like a restic repo (has config file)
                    if [[ -f "$service_dir/config" ]]; then
                        echo "$service_name"
                        found_any=true
                    fi
                fi
            done
            echo
        fi
    fi

    if [[ "$found_any" == "false" ]]; then
        log_warn "No backup repositories found"
        echo
    fi
}

# List snapshots for a specific service
list_snapshots() {
    local service="$1"
    local base_path=$(get_backup_base_path)
    local repo_path="$base_path/$service"

    log_info "Checking for backup at: $repo_path"

    if [[ ! -d "$repo_path" ]]; then
        log_error "No backup repository found for service: $service at $repo_path"
        log_info "Available services:"
        list_services
        exit 1
    fi

    export RESTIC_REPOSITORY="$repo_path"

    log_info "Snapshots for $service:"
    # Output as JSON for API parsing, or table format when run interactively
    if [ -t 1 ]; then
        # stdout is a terminal, use human-readable format
        echo
        restic snapshots
        echo
    else
        # stdout is not a terminal (piped/captured), use JSON for parsing
        restic snapshots --json
    fi
}

# Download service backup from Backblaze
download_service() {
    local service="$1"

    if ! mountpoint -q "$BACKBLAZE_MOUNT" 2>/dev/null; then
        log_error "Backblaze is not mounted at $BACKBLAZE_MOUNT"
        log_info "Ensure the rclone-backblaze service is running: systemctl start rclone-backblaze"
        exit 1
    fi

    local src="$BACKBLAZE_MOUNT/$service"
    local dst="$BACKUP_LOCAL_PATH/$service"

    if [[ ! -d "$src" ]]; then
        log_error "Service backup not found in Backblaze: $service"
        exit 1
    fi

    log_info "Downloading $service from Backblaze to $dst..."
    mkdir -p "$BACKUP_LOCAL_PATH"

    rsync -av --delete "$src/" "$dst/"

    log_success "Downloaded $service backup successfully"
}

# Download all backups from Backblaze
download_all() {
    if ! mountpoint -q "$BACKBLAZE_MOUNT" 2>/dev/null; then
        log_error "Backblaze is not mounted at $BACKBLAZE_MOUNT"
        log_info "Ensure the rclone-backblaze service is running: systemctl start rclone-backblaze"
        exit 1
    fi

    log_info "Downloading all backups from Backblaze to $BACKUP_LOCAL_PATH..."
    mkdir -p "$BACKUP_LOCAL_PATH"

    rsync -av --delete "$BACKBLAZE_MOUNT/" "$BACKUP_LOCAL_PATH/"

    log_success "Downloaded all backups successfully"
}

# Get service systemd unit names
get_service_units() {
    local service="$1"

    # Find all systemd units related to this service
    systemctl list-units --all --no-legend | grep -i "$service" | awk '{print $1}' | grep -E '\.(service|timer)$'
}

# Stop service and related units
stop_service() {
    local service="$1"

    log_info "Stopping services for $service..."

    # Common patterns for service names
    local patterns=(
        "$service"
        "$service-podman"
        "podman-$service"
        "*$service*"
    )

    local stopped=0
    for pattern in "${patterns[@]}"; do
        for unit in $(systemctl list-units --all --no-legend --state=active | grep -i "$pattern" || true | awk '{print $1}' | grep '\.service$' || true); do
            log_info "  Stopping $unit"
            systemctl stop "$unit" || log_warn "Failed to stop $unit"
            stopped=1
        done
    done

    if [[ $stopped -eq 0 ]]; then
        log_warn "No active systemd services found for $service"
    fi
}

# Start service and related units
start_service() {
    local service="$1"

    log_info "Starting services for $service..."

    # Common patterns for service names
    local patterns=(
        "$service"
        "$service-podman"
        "podman-$service"
        "*$service*"
    )

    local started=0
    for pattern in "${patterns[@]}"; do
        for unit in $(systemctl list-unit-files --no-legend | grep -i "$pattern" || true | awk '{print $1}' | grep '\.service$' || true); do
            if systemctl is-enabled "$unit" >/dev/null 2>&1; then
                log_info "  Starting $unit"
                systemctl start "$unit" || log_warn "Failed to start $unit"
                started=1
            fi
        done
    done

    if [[ $started -eq 0 ]]; then
        log_warn "No enabled systemd services found for $service"
    fi
}

# Restore database from dump
restore_database() {
    local db_type="$1"  # postgres or mysql
    local service="$2"
    local restore_path="$3"

    case "$db_type" in
        postgres)
            local dump_dir="$restore_path/var/backup/postgresql-homefree/$service"
            if [[ -d "$dump_dir" ]]; then
                log_info "Restoring PostgreSQL databases for $service..."
                for dump_file in "$dump_dir"/*.sql.gz; do
                    if [[ -f "$dump_file" ]]; then
                        local db_name=$(basename "$dump_file" .sql.gz)
                        log_info "  Restoring database: $db_name"
                        # Drop existing database to ensure clean restore
                        sudo -u postgres dropdb --if-exists "$db_name" 2>/dev/null || true
                        # Restore to postgres database (dump contains CREATE DATABASE)
                        gunzip -c "$dump_file" | sudo -u postgres psql postgres || log_warn "Failed to restore $db_name"
                    fi
                done
            fi
            ;;
        mysql)
            local dump_dir="$restore_path/var/backup/mysql-homefree/$service"
            if [[ -d "$dump_dir" ]]; then
                log_info "Restoring MySQL databases for $service..."
                for dump_file in "$dump_dir"/*.gz; do
                    if [[ -f "$dump_file" ]]; then
                        local db_name=$(basename "$dump_file" .gz)
                        log_info "  Restoring database: $db_name"
                        gunzip -c "$dump_file" | mysql "$db_name" || log_warn "Failed to restore $db_name"
                    fi
                done
            fi
            ;;
    esac
}

# Restore a specific service
restore_service() {
    local service="$1"
    local snapshot_id="${2:-latest}"
    local base_path=$(get_backup_base_path)
    local repo_path="$base_path/$service"

    if [[ ! -d "$repo_path" ]]; then
        log_error "No backup repository found for service: $service"
        exit 1
    fi

    export RESTIC_REPOSITORY="$repo_path"

    # Verify snapshot exists
    if [[ "$snapshot_id" != "latest" ]]; then
        if ! restic snapshots --quiet "$snapshot_id" >/dev/null 2>&1; then
            log_error "Snapshot not found: $snapshot_id"
            log_info "Available snapshots:"
            list_snapshots "$service"
            exit 1
        fi
    fi

    log_warn "This will restore $service from backup (snapshot: $snapshot_id)"
    log_warn "This will OVERWRITE current data!"

    # Check if we should skip confirmation (non-interactive mode)
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

    # Stop the service
    stop_service "$service"

    # Create temporary restore directory
    local temp_dir="$TEMP_RESTORE_DIR/$service"
    rm -rf "$temp_dir"
    mkdir -p "$temp_dir"

    # Restore to temporary location
    log_info "Restoring $service from backup..."
    restic restore "$snapshot_id" --target "$temp_dir"

    # Restore databases if they exist
    restore_database "postgres" "$service" "$temp_dir"
    restore_database "mysql" "$service" "$temp_dir"

    # Find all non-database paths and restore them
    log_info "Restoring files for $service..."

    # Find the top-level application directories to restore
    # Look for directories under /var/lib that aren't database dumps
    for dir in $(find "$temp_dir/var/lib" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sed "s|^$temp_dir||" | sort -u); do
        local src="$temp_dir$dir"
        local dst="$dir"
        log_info "  Restoring $dst"
        mkdir -p "$(dirname "$dst")"
        rsync -av --delete "$src/" "$dst/" || log_warn "Failed to restore $dst"
    done

    # Also restore any other paths that might exist (not under /var/lib or /var/backup)
    for dir in $(find "$temp_dir" -mindepth 1 -maxdepth 3 -type d -not -path "*/var/lib/*" -not -path "*/var/backup/*" 2>/dev/null | sed "s|^$temp_dir||" | sort -u); do
        if [[ -d "$temp_dir$dir" && "$dir" != "/var" && "$dir" != "/var/lib" && "$dir" != "/var/backup" ]]; then
            local src="$temp_dir$dir"
            local dst="$dir"
            log_info "  Restoring $dst"
            mkdir -p "$(dirname "$dst")"
            rsync -av --delete "$src/" "$dst/" || log_warn "Failed to restore $dst"
        fi
    done

    # Clean up temp directory
    rm -rf "$temp_dir"

    # Start the service
    start_service "$service"

    log_success "Restore completed for $service"
}

# Restore all services
restore_all() {
    local snapshot_id="${1:-latest}"
    local base_path=$(get_backup_base_path)

    log_warn "This will restore ALL services from backup (snapshot: $snapshot_id)"
    log_warn "This will OVERWRITE current data for all services!"

    # Check if we should skip confirmation (non-interactive mode)
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

    # Get list of all services
    local services=()
    for service_dir in "$base_path"/*; do
        if [[ -d "$service_dir" ]]; then
            services+=($(basename "$service_dir"))
        fi
    done

    log_info "Found ${#services[@]} services to restore"

    # Restore each service
    for service in "${services[@]}"; do
        echo
        log_info "========== Restoring $service =========="
        # Skip confirmation for individual services in bulk restore
        export RESTIC_REPOSITORY="$base_path/$service"

        stop_service "$service"

        local temp_dir="$TEMP_RESTORE_DIR/$service"
        rm -rf "$temp_dir"
        mkdir -p "$temp_dir"

        log_info "Restoring $service from backup..."
        restic restore "$snapshot_id" --target "$temp_dir" || log_error "Failed to restore $service"

        restore_database "postgres" "$service" "$temp_dir"
        restore_database "mysql" "$service" "$temp_dir"

        # Find the top-level application directories to restore
        # Look for directories under /var/lib that aren't database dumps
        for dir in $(find "$temp_dir/var/lib" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sed "s|^$temp_dir||" | sort -u); do
            local src="$temp_dir$dir"
            local dst="$dir"
            log_info "  Restoring $dst"
            mkdir -p "$(dirname "$dst")"
            rsync -av --delete "$src/" "$dst/" || log_warn "Failed to restore $dst"
        done

        # Also restore any other paths that might exist (not under /var/lib or /var/backup)
        for dir in $(find "$temp_dir" -mindepth 1 -maxdepth 3 -type d -not -path "*/var/lib/*" -not -path "*/var/backup/*" 2>/dev/null | sed "s|^$temp_dir||" | sort -u); do
            if [[ -d "$temp_dir$dir" && "$dir" != "/var" && "$dir" != "/var/lib" && "$dir" != "/var/backup" ]]; then
                local src="$temp_dir$dir"
                local dst="$dir"
                log_info "  Restoring $dst"
                mkdir -p "$(dirname "$dst")"
                rsync -av --delete "$src/" "$dst/" || log_warn "Failed to restore $dst"
            fi
        done

        rm -rf "$temp_dir"
        start_service "$service"
    done

    log_success "Restore completed for all services"
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
            list-services|list-snapshots|download|restore|restore-all)
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
            -m|--mount-path)
                BACKBLAZE_MOUNT="$2"
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
            list-services|list-snapshots|download|restore|restore-all)
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
            download)
                if [[ ${#COMMAND_ARGS[@]} -lt 1 ]]; then
                    log_error "Missing service name"
                    usage
                    exit 1
                fi
                check_root
                download_service "${COMMAND_ARGS[0]}"
                exit 0
                ;;
            download-all)
                check_root
                download_all
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
