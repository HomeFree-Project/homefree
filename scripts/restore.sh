#!/usr/bin/env bash

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

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

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*"
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

    case "$source" in
        local)
            echo "local"
            ;;
        backblaze)
            echo "backblaze"
            ;;
        auto)
            # Check if Backblaze is mounted
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
    local base_path=$(get_backup_base_path)

    log_info "Services with backups in $base_path:"
    echo

    if [[ ! -d "$base_path" ]]; then
        log_error "Backup path does not exist: $base_path"
        exit 1
    fi

    for service_dir in "$base_path"/*; do
        if [[ -d "$service_dir" ]]; then
            local service_name=$(basename "$service_dir")
            # Check if it's a valid restic repo
            export RESTIC_REPOSITORY="$service_dir"
            if restic snapshots --quiet >/dev/null 2>&1; then
                local snapshot_count=$(restic snapshots --json 2>/dev/null | jq '. | length' 2>/dev/null || echo "0")
                echo "  - $service_name ($snapshot_count snapshots)"
            fi
        fi
    done
    echo
}

# List snapshots for a specific service
list_snapshots() {
    local service="$1"
    local base_path=$(get_backup_base_path)
    local repo_path="$base_path/$service"

    if [[ ! -d "$repo_path" ]]; then
        log_error "No backup repository found for service: $service"
        log_info "Available services:"
        list_services
        exit 1
    fi

    export RESTIC_REPOSITORY="$repo_path"

    log_info "Snapshots for $service:"
    echo
    restic snapshots
    echo
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
        for unit in $(systemctl list-units --all --no-legend --state=active | grep -i "$pattern" | awk '{print $1}' | grep '\.service$'); do
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
        for unit in $(systemctl list-unit-files --no-legend | grep -i "$pattern" | awk '{print $1}' | grep '\.service$'); do
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
                        gunzip -c "$dump_file" | sudo -u postgres psql "$db_name" || log_warn "Failed to restore $db_name"
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
    echo -n "Are you sure you want to continue? (yes/no): "
    read -r confirmation

    if [[ "$confirmation" != "yes" ]]; then
        log_info "Restore cancelled"
        exit 0
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

    # Get list of backed up paths from the snapshot
    for path in $(find "$temp_dir" -type d -name "var" -prune -o -type f -print | sed "s|^$temp_dir||" | sort -u | head -1); do
        local parent_dir=$(dirname "$path")
        if [[ "$parent_dir" != "/var/backup"* ]]; then
            # This is application data, not a database dump
            local src="$temp_dir$parent_dir"
            local dst="$parent_dir"
            if [[ -d "$src" ]]; then
                log_info "  Restoring $dst"
                mkdir -p "$(dirname "$dst")"
                rsync -av --delete "$src/" "$dst/"
            fi
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
    echo -n "Are you sure you want to continue? (yes/no): "
    read -r confirmation

    if [[ "$confirmation" != "yes" ]]; then
        log_info "Restore cancelled"
        exit 0
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

        # Restore files
        for path in $(find "$temp_dir" -type d -name "var" -prune -o -type f -print | sed "s|^$temp_dir||" | sort -u | head -1); do
            local parent_dir=$(dirname "$path")
            if [[ "$parent_dir" != "/var/backup"* ]]; then
                local src="$temp_dir$parent_dir"
                local dst="$parent_dir"
                if [[ -d "$src" ]]; then
                    log_info "  Restoring $dst"
                    mkdir -p "$(dirname "$dst")"
                    rsync -av --delete "$src/" "$dst/" || log_warn "Failed to restore $dst"
                fi
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

    # Parse global options
    SOURCE="auto"

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
            list-services)
                check_root
                load_restic_password
                list_services
                exit 0
                ;;
            list-snapshots)
                if [[ $# -lt 2 ]]; then
                    log_error "Missing service name"
                    usage
                    exit 1
                fi
                check_root
                load_restic_password
                list_snapshots "$2"
                exit 0
                ;;
            download)
                if [[ $# -lt 2 ]]; then
                    log_error "Missing service name"
                    usage
                    exit 1
                fi
                check_root
                download_service "$2"
                exit 0
                ;;
            download-all)
                check_root
                download_all
                exit 0
                ;;
            restore)
                if [[ $# -lt 2 ]]; then
                    log_error "Missing service name"
                    usage
                    exit 1
                fi
                check_root
                load_restic_password
                restore_service "$2" "${3:-latest}"
                exit 0
                ;;
            restore-all)
                check_root
                load_restic_password
                restore_all "${2:-latest}"
                exit 0
                ;;
            *)
                log_error "Unknown command: $1"
                usage
                exit 1
                ;;
        esac
    done
}

main "$@"
