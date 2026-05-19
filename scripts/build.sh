#!/usr/bin/env bash

set -e

# Configuration
SOURCE=${BASH_SOURCE[0]}
while [ -L "$SOURCE" ]; do # resolve $SOURCE until the file is no longer a symlink
  DIR=$( cd -P "$( dirname "$SOURCE" )" >/dev/null 2>&1 && pwd )
  SOURCE=$(readlink "$SOURCE")
  [[ $SOURCE != /* ]] && SOURCE=$DIR/$SOURCE # if $SOURCE was a relative symlink, we need to resolve it relative to the path where the symlink file was located
done
SCRIPT_DIR=$( cd -P "$( dirname "$SOURCE" )" >/dev/null 2>&1 && pwd )

SCRIPT_NAME=$(basename "$0")
FLAKE_DIR="${FLAKE_DIR:-/etc/nixos}"
CONFIG_NAME=""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

usage() {
    cat << EOF
Usage: $SCRIPT_NAME [OPTIONS] [CONFIG_NAME]

Rebuild NixOS system configuration locally (for use within a NixOS system).

Arguments:
  CONFIG_NAME    NixOS configuration name from flake (default: current hostname)

Options:
  -f, --flake-dir DIR       Flake directory (default: current directory)
  -s, --switch              Switch to new configuration (default)
  -b, --boot                Set as boot configuration without switching
  -t, --test                Test configuration without making permanent
      --dry-activate        Run nixos-rebuild dry-activate (plan only, no
                            build, no activation). Distinct from --dry-run.
  -n, --dry-run             Echo the nixos-rebuild command without running it
                            (does NOT invoke nix at all; for that use
                            --dry-activate)
      --offline             Build without fetching from the network. Skips
                            the flake-input update step and passes --offline
                            to nixos-rebuild.
  -j, --max-jobs NUM        Maximum number of build jobs (default: auto)
  -h, --help               Show this help

Environment Variables:
  FLAKE_DIR               Default flake directory

Examples:
  # Rebuild current system from current directory
  $SCRIPT_NAME

  # Rebuild specific configuration from specific flake
  $SCRIPT_NAME -f /path/to/my-flake homefree

  # Test configuration without making permanent
  $SCRIPT_NAME --test

Note: This script must be run on a NixOS system and typically requires sudo privileges.
EOF
}

# Parse command line arguments
ACTION="switch"
MAX_JOBS=""
DRY_RUN=false
OFFLINE=false

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
        -s|--switch)
            ACTION="switch"
            shift
            ;;
        -b|--boot)
            ACTION="boot"
            shift
            ;;
        -t|--test)
            ACTION="test"
            shift
            ;;
        --dry-activate)
            ACTION="dry-activate"
            shift
            ;;
        -n|--dry-run)
            DRY_RUN=true
            shift
            ;;
        --offline)
            OFFLINE=true
            shift
            ;;
        -j|--max-jobs)
            MAX_JOBS="$2"
            shift 2
            ;;
        -*)
            log_error "Unknown option: $1"
            usage
            exit 1
            ;;
        *)
            CONFIG_NAME="$1"
            shift
            ;;
    esac
done

# Check for nix command
if ! command -v nix &> /dev/null; then
    log_error "nix could not be found. If it is installed, you may need to log out and log in again for it to be in your path."
    exit 1
fi

# Check if running on NixOS
if [[ ! -f /etc/NIXOS ]]; then
    log_warning "This doesn't appear to be a NixOS system."
    log_warning "This script is intended for rebuilding NixOS systems locally."
    log_warning "For remote deployment, use remote-deploy.sh instead."
    read -p "Continue anyway? [y/N]: " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

# Ensure flake directory is absolute path
FLAKE_DIR=$(realpath "$FLAKE_DIR")

# Validate flake directory
if [[ ! -f "$FLAKE_DIR/flake.nix" ]]; then
    log_error "No flake.nix found in $FLAKE_DIR"
    exit 1
fi

# Determine configuration name
if [[ -z "$CONFIG_NAME" ]]; then
    # Try to use current hostname
    CONFIG_NAME=$(hostname)
    log_info "No configuration specified, using current hostname: $CONFIG_NAME"
fi

# Build the flake reference
FLAKE_REF="$FLAKE_DIR#$CONFIG_NAME"

log_info "Building NixOS configuration: $CONFIG_NAME"
log_info "Flake directory: $FLAKE_DIR"
log_info "Action: $ACTION"

# Update flake inputs before building (skip in offline mode — fetching is not allowed)
if [[ "$OFFLINE" == "true" ]]; then
    log_info "Offline mode: skipping flake-input update"
    export NIX_REMOTE=daemon
    ulimit -n 4096
else
    # Refresh the flake inputs that point at a LOCAL working tree
    # (`git+file://` / `path:` URLs) so the build picks up uncommitted
    # working-tree edits. These inputs are content-addressed by NAR
    # hash in flake.lock; without an explicit update the lock keeps a
    # stale hash and Nix rebuilds the old, cached derivation — the
    # edits never reach the store.
    #
    # IMPORTANT: the input NAMES are not fixed. The HomeFree source
    # input is bound via flake.nix's managed `homefree-base-override`
    # block and may be called `homefree-alt`, `homefree-local`, etc.
    # depending on how the box was set up. Hard-coding a name (the old
    # behaviour: `--update-input homefree-local`) silently updated
    # NOTHING on a box whose input was named differently, so the build
    # served stale frontend/code. Discover the local inputs from the
    # flake's own metadata instead.
    log_info "Discovering flake inputs to refresh (local + HomeFree source)..."
    # `nix flake metadata` reads the dirty git tree, which on an
    # installed box contains root-owned files (homefree-config.json) —
    # so it needs the same privilege the build does.
    METADATA_CMD="nix flake metadata '$FLAKE_DIR' --json"
    if [[ $EUID -ne 0 ]]; then
        METADATA_CMD="sudo $METADATA_CMD"
    fi
    LOCAL_INPUTS=$(eval "$METADATA_CMD" 2>/dev/null \
        | python3 -c "
import json, sys
try:
    meta = json.load(sys.stdin)
except Exception:
    sys.exit(0)
nodes = meta.get('locks', {}).get('nodes', {}) or {}
root = meta.get('locks', {}).get('root', 'root')
# Only the root flake's DIRECT inputs — never transitive deps
# (nixpkgs_2, crane, ...). Updating those is out of scope and slow.
direct = (nodes.get(root, {}) or {}).get('inputs', {}) or {}
for name, ref in direct.items():
    # An input may resolve to a node under a different key (Nix
    # dedups identical inputs); ref is that node key (str) or a path.
    node_key = ref if isinstance(ref, str) else name
    node = nodes.get(node_key, {}) or nodes.get(name, {}) or {}
    orig = node.get('original', {}) or {}
    url = orig.get('url', '') or ''
    typ = orig.get('type', '')
    # Refresh an input if it is EITHER:
    #  - a local working-tree input (file:// URL or path:) — its lock
    #    NAR-hash goes stale against uncommitted edits; OR
    #  - the HomeFree source input itself (name starts 'homefree-') —
    #    so a build still pulls the latest upstream on a box with no
    #    local override. This preserves the old behaviour without the
    #    hard-coded-name bug.
    if url.startswith('file:') or typ == 'path' or name.startswith('homefree-'):
        print(name)
" || true)

    if [[ -z "$LOCAL_INPUTS" ]]; then
        log_warning "No local or HomeFree flake inputs found in $FLAKE_DIR/flake.nix"
        log_warning "Skipping input refresh — build may use the locked snapshot."
    else
        UPDATE_ARGS=()
        for inp in $LOCAL_INPUTS; do
            UPDATE_ARGS+=("$inp")
        done
        log_info "Updating flake inputs: ${UPDATE_ARGS[*]}"
        FLAKE_UPDATE_CMD="nix flake update ${UPDATE_ARGS[*]} --flake '$FLAKE_DIR' --allow-dirty --allow-dirty-locks"
        if [[ $EUID -ne 0 ]]; then
            FLAKE_UPDATE_CMD="sudo $FLAKE_UPDATE_CMD"
        fi
        if ! eval "$FLAKE_UPDATE_CMD"; then
            log_error "Failed to update flake inputs"
            exit 1
        fi
        log_success "Flake inputs updated successfully"
    fi
fi

# Sync homefree-config.json with module.nix schema
SYNC_SCRIPT="$SCRIPT_DIR/sync-config.sh"
if [[ -f "$SYNC_SCRIPT" ]] && [[ -f "$FLAKE_DIR/homefree-config.json" ]]; then
    log_info "Syncing homefree-config.json with module.nix schema..."
    if ! sudo "$SYNC_SCRIPT" -f "$FLAKE_DIR" -n "$CONFIG_NAME"; then
        log_error "Failed to sync config. Continuing anyway..."
        log_warning "If build fails, check config file for incompatibilities"
    fi
else
    if [[ -f "$FLAKE_DIR/homefree-config.json" ]] && [[ ! -f "$SYNC_SCRIPT" ]]; then
        log_warning "Config sync script not found at $SYNC_SCRIPT"
    fi
fi

# Build the command
CMD="nixos-rebuild"

# Add action
CMD="$CMD $ACTION"

# Add flake reference
CMD="$CMD --flake '$FLAKE_REF'"

# Add max-jobs if specified
if [[ -n "$MAX_JOBS" ]]; then
    CMD="$CMD --max-jobs $MAX_JOBS"
fi

# Add --offline if requested
if [[ "$OFFLINE" == "true" ]]; then
    CMD="$CMD --offline"
fi

# Add verbose logging
CMD="$CMD -L"

# Check if we need sudo
if [[ $EUID -ne 0 ]]; then
    log_info "This operation requires root privileges."
    CMD="sudo $CMD"
fi

# Execute the rebuild
if [[ "$DRY_RUN" == "true" ]]; then
    log_info "Dry run mode - would execute:"
    echo "  $CMD"
else
    log_info "Executing rebuild..."
    if eval "$CMD"; then
        log_success "System rebuild completed successfully!"

        case "$ACTION" in
            switch)
                log_info "New configuration has been activated."
                ;;
            boot)
                log_info "New configuration will be activated on next boot."
                ;;
            test)
                log_info "New configuration is active for testing (not made permanent)."
                log_warning "Changes will be lost on reboot unless you run with --switch"
                ;;
            dry-activate)
                log_info "Dry activation completed. No changes were made."
                ;;
        esac
    else
        log_error "System rebuild failed!"
        exit 1
    fi
fi
