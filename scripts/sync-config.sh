#!/usr/bin/env nix-shell
#!nix-shell -i bash -p python3 jq

set -e

# Configuration
SCRIPT_NAME=$(basename "$0")
FLAKE_DIR="${FLAKE_DIR:-/etc/nixos}"
CONFIG_FILE="${CONFIG_FILE:-$FLAKE_DIR/homefree-config.json}"
CONFIG_NAME="${CONFIG_NAME:-homefree}"
BACKUP_SUFFIX=".backup-$(date +%Y%m%d-%H%M%S)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${BLUE}[SYNC]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SYNC]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[SYNC]${NC} $1"
}

log_error() {
    echo -e "${RED}[SYNC]${NC} $1"
}

usage() {
    cat << EOF
Usage: $SCRIPT_NAME [OPTIONS]

Synchronize homefree-config.json with module.nix schema.
Removes obsolete options, adds new options with defaults, preserves user values.

Options:
  -f, --flake-dir DIR       Flake directory (default: /etc/nixos)
  -c, --config-file FILE    Config file to sync (default: \$FLAKE_DIR/homefree-config.json)
  -n, --config-name NAME    NixOS configuration name (default: homefree)
  -d, --dry-run            Show what would be changed without modifying the file
  -b, --no-backup          Don't create a backup before modifying
  -h, --help               Show this help

Environment Variables:
  FLAKE_DIR               Default flake directory
  CONFIG_FILE             Default config file path
  CONFIG_NAME             Default configuration name

Examples:
  # Sync config in /etc/nixos
  $SCRIPT_NAME

  # Dry run to see what would change
  $SCRIPT_NAME --dry-run

  # Sync custom config file
  $SCRIPT_NAME -c /path/to/custom-config.json
EOF
}

# Parse command line arguments
DRY_RUN=false
NO_BACKUP=false

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            usage
            exit 0
            ;;
        -f|--flake-dir)
            FLAKE_DIR="$2"
            shift 2
            ;;
        -c|--config-file)
            CONFIG_FILE="$2"
            shift 2
            ;;
        -n|--config-name)
            CONFIG_NAME="$2"
            shift 2
            ;;
        -d|--dry-run)
            DRY_RUN=true
            shift
            ;;
        -b|--no-backup)
            NO_BACKUP=true
            shift
            ;;
        -*)
            log_error "Unknown option: $1"
            usage
            exit 1
            ;;
        *)
            log_error "Unexpected argument: $1"
            usage
            exit 1
            ;;
    esac
done

# Check for required commands
for cmd in nix jq; do
    if ! command -v "$cmd" &> /dev/null; then
        log_error "$cmd could not be found. Please install it first."
        exit 1
    fi
done

# Ensure paths are absolute
FLAKE_DIR=$(realpath "$FLAKE_DIR" 2>/dev/null || echo "$FLAKE_DIR")
CONFIG_FILE=$(realpath "$CONFIG_FILE" 2>/dev/null || echo "$CONFIG_FILE")

# Validate flake directory
if [[ ! -f "$FLAKE_DIR/flake.nix" ]]; then
    log_error "No flake.nix found in $FLAKE_DIR"
    exit 1
fi

# Check if config file exists
if [[ ! -f "$CONFIG_FILE" ]]; then
    log_warning "Config file $CONFIG_FILE does not exist. Skipping sync."
    exit 0
fi

log_info "Syncing $CONFIG_FILE with module.nix schema"
log_info "Flake directory: $FLAKE_DIR"

# Find module.nix in the homefree repo
log_info "Looking for module.nix..."

# Try to find module.nix - it should be in the homefree flake input
MODULE_NIX=""

# Check common locations
if [[ -f "/home/erahhal/homefree/module.nix" ]]; then
    MODULE_NIX="/home/erahhal/homefree/module.nix"
elif [[ -f "$FLAKE_DIR/module.nix" ]]; then
    MODULE_NIX="$FLAKE_DIR/module.nix"
else
    # Try to find it in nix store via flake inputs
    HOMEFREE_PATH=$(nix eval --raw "$FLAKE_DIR#nixosConfigurations.$CONFIG_NAME.config.homefree-flake-path" 2>/dev/null || echo "")
    if [[ -n "$HOMEFREE_PATH" ]] && [[ -f "$HOMEFREE_PATH/module.nix" ]]; then
        MODULE_NIX="$HOMEFREE_PATH/module.nix"
    fi
fi

if [[ -z "$MODULE_NIX" ]] || [[ ! -f "$MODULE_NIX" ]]; then
    log_error "Could not find module.nix"
    log_error "Tried:"
    log_error "  - /home/erahhal/homefree/module.nix"
    log_error "  - $FLAKE_DIR/module.nix"
    exit 1
fi

log_success "Found module.nix at: $MODULE_NIX"

# Find the Python sync script
SYNC_SCRIPT="$(dirname "$0")/sync-config.py"

if [[ ! -f "$SYNC_SCRIPT" ]]; then
    log_error "Python sync script not found at: $SYNC_SCRIPT"
    exit 1
fi

# NOTE: There is no longer a homefree-configuration.nix to regenerate.
# The homefree-config.json → homefree.* mapping now lives in the shared
# repo (modules/homefree-config-loader.nix), wired into the module system
# by the instance flake.nix via specialArgs. This script only reconciles
# homefree-config.json against the module.nix schema (below); it no longer
# renders a Nix file. See
# docs/agent-notes/homefree-configuration-nix-is-generated.md.

# Run the sync script
log_info "Analyzing config and computing changes..."
SYNC_RESULT=$(python3 "$SYNC_SCRIPT" "$MODULE_NIX" "$CONFIG_FILE")

if [[ $? -ne 0 ]]; then
    log_error "Failed to sync config"
    exit 1
fi

# Extract changes
CHANGES=$(echo "$SYNC_RESULT" | jq -r '.changes[]' 2>/dev/null || echo "")
NUM_CHANGES=$(echo "$CHANGES" | grep -c . || echo "0")

if [[ -z "$CHANGES" ]] || [[ "$NUM_CHANGES" -eq 0 ]]; then
    log_success "Config is already in sync with schema. No changes needed."
    exit 0
fi

# Display changes
log_warning "Found $NUM_CHANGES changes:"
echo "$CHANGES"

if [[ "$DRY_RUN" == "true" ]]; then
    log_info "Dry run mode - no changes written"
    exit 0
fi

# Create backup
if [[ "$NO_BACKUP" != "true" ]]; then
    BACKUP_FILE="$CONFIG_FILE$BACKUP_SUFFIX"
    log_info "Creating backup: $BACKUP_FILE"
    cp "$CONFIG_FILE" "$BACKUP_FILE"
fi

# Write synced config
log_info "Writing synced config to $CONFIG_FILE..."
echo "$SYNC_RESULT" | jq -r '.config' > "$CONFIG_FILE"

log_success "Config synced successfully!"
log_info "Summary: $NUM_CHANGES changes applied"

if [[ "$NO_BACKUP" != "true" ]]; then
    log_info "Backup saved to: $BACKUP_FILE"
fi
