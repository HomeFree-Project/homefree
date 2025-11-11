#!/usr/bin/env bash

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

# Extract schema from module.nix by evaluating the flake
log_info "Extracting schema from module.nix..."
TEMP_SCHEMA=$(mktemp)
trap "rm -f $TEMP_SCHEMA" EXIT

# Get the homefree options from the flake
# We need to evaluate the module to get all option definitions
if ! nix eval --json "$FLAKE_DIR#nixosConfigurations.$CONFIG_NAME.options.homefree" 2>/dev/null > "$TEMP_SCHEMA"; then
    log_error "Failed to extract schema from flake. This may happen if:"
    log_error "  - The flake has syntax errors"
    log_error "  - The configuration '$CONFIG_NAME' doesn't exist"
    log_error "  - There are evaluation errors in module.nix"
    log_error ""
    log_error "Attempting alternative method..."

    # Alternative: try to evaluate just the module itself
    if ! nix eval --json --expr "
        let
          pkgs = import <nixpkgs> {};
          lib = pkgs.lib;
          module = import $FLAKE_DIR/module.nix { inherit lib; config = {}; options = {}; pkgs = pkgs; extendModules = null; };
        in
          module.options.homefree or {}
    " 2>/dev/null > "$TEMP_SCHEMA"; then
        log_error "Alternative method also failed. Please check your configuration."
        exit 1
    fi
fi

log_success "Schema extracted successfully"

# Read current config
CURRENT_CONFIG=$(cat "$CONFIG_FILE")

# Create a Python script to do the deep merge and sync
# Using Python because it's better at handling complex nested JSON manipulation than jq
TEMP_SYNC_SCRIPT=$(mktemp)
trap "rm -f $TEMP_SYNC_SCRIPT $TEMP_SCHEMA" EXIT

cat > "$TEMP_SYNC_SCRIPT" << 'PYTHON_SCRIPT'
#!/usr/bin/env python3
import json
import sys
from typing import Any, Dict, Set, List, Tuple

def get_default_value(option_def: Dict) -> Any:
    """Extract default value from option definition."""
    if 'default' in option_def:
        default = option_def['default']
        # Handle Nix special values
        if isinstance(default, dict):
            if default.get('_type') == 'literalExpression':
                # Can't evaluate literal expressions, use sensible defaults
                return None
            elif default.get('_type') == 'literalDocBook':
                return None
        return default

    # Infer defaults from type
    option_type = option_def.get('type', '')
    if isinstance(option_type, str):
        if 'bool' in option_type:
            return False
        elif 'int' in option_type:
            return 0
        elif 'str' in option_type:
            return ""
        elif 'listOf' in option_type or 'list' in option_type:
            return []
        elif 'attrsOf' in option_type or 'attrs' in option_type:
            return {}
        elif 'nullOr' in option_type:
            return None

    return None

def extract_schema_structure(options: Dict, path: str = "") -> Dict[str, Any]:
    """
    Recursively extract the schema structure from Nix options.
    Returns a dict with paths as keys and default values.
    """
    schema = {}

    for key, value in options.items():
        current_path = f"{path}.{key}" if path else key

        # Check if this is an option definition (has 'type' field)
        if isinstance(value, dict) and 'type' in value:
            # This is a leaf option
            schema[current_path] = get_default_value(value)
        elif isinstance(value, dict):
            # This is a nested structure, recurse
            nested = extract_schema_structure(value, current_path)
            schema.update(nested)

    return schema

def path_to_nested_dict(path: str, value: Any) -> Dict:
    """Convert a dotted path to a nested dictionary."""
    parts = path.split('.')
    result = {}
    current = result
    for part in parts[:-1]:
        current[part] = {}
        current = current[part]
    current[parts[-1]] = value
    return result

def deep_merge(base: Dict, overlay: Dict) -> Dict:
    """Deep merge overlay into base, preserving overlay values."""
    result = base.copy()
    for key, value in overlay.items():
        if key in result and isinstance(result[key], dict) and isinstance(value, dict):
            result[key] = deep_merge(result[key], value)
        else:
            result[key] = value
    return result

def dict_to_paths(d: Dict, prefix: str = "") -> Dict[str, Any]:
    """Convert nested dict to flat path-based dict."""
    paths = {}
    for key, value in d.items():
        path = f"{prefix}.{key}" if prefix else key
        if isinstance(value, dict) and value and not any(k.startswith('_') for k in value.keys()):
            # If all keys start with _, it's probably a value, not a nested structure
            nested = dict_to_paths(value, path)
            if nested:
                paths.update(nested)
            else:
                paths[path] = value
        else:
            paths[path] = value
    return paths

def paths_to_dict(paths: Dict[str, Any]) -> Dict:
    """Convert flat path-based dict to nested dict."""
    result = {}
    for path, value in paths.items():
        parts = path.split('.')
        current = result
        for part in parts[:-1]:
            if part not in current:
                current[part] = {}
            current = current[part]
        current[parts[-1]] = value
    return result

def sync_config(schema_data: Dict, current_config: Dict, verbose: bool = True) -> Tuple[Dict, List[str]]:
    """
    Sync current config with schema.
    Returns (synced_config, changes).
    """
    changes = []

    # Extract schema structure
    schema_paths = extract_schema_structure(schema_data)

    # Convert current config to paths
    current_paths = dict_to_paths(current_config)

    # Find obsolete keys (in current but not in schema)
    obsolete_keys = set(current_paths.keys()) - set(schema_paths.keys())

    # Find new keys (in schema but not in current)
    new_keys = set(schema_paths.keys()) - set(current_paths.keys())

    # Build synced config
    synced_paths = {}

    # Add all valid keys from current config (preserving user values)
    for key, value in current_paths.items():
        if key not in obsolete_keys:
            synced_paths[key] = value

    # Add new keys with defaults
    for key in new_keys:
        synced_paths[key] = schema_paths[key]
        changes.append(f"+ Added: {key} = {json.dumps(schema_paths[key])}")

    # Log removed keys
    for key in obsolete_keys:
        changes.append(f"- Removed: {key}")

    # Convert back to nested dict
    synced_config = paths_to_dict(synced_paths)

    return synced_config, changes

def main():
    if len(sys.argv) != 3:
        print("Usage: sync_script.py <schema.json> <config.json>", file=sys.stderr)
        sys.exit(1)

    schema_file = sys.argv[1]
    config_file = sys.argv[2]

    try:
        with open(schema_file) as f:
            schema_data = json.load(f)

        with open(config_file) as f:
            current_config = json.load(f)

        synced_config, changes = sync_config(schema_data, current_config)

        # Output results
        result = {
            'config': synced_config,
            'changes': changes
        }

        print(json.dumps(result, indent=2))

    except Exception as e:
        print(f"Error: {e}", file=sys.stderr)
        import traceback
        traceback.print_exc(file=sys.stderr)
        sys.exit(1)

if __name__ == '__main__':
    main()
PYTHON_SCRIPT

chmod +x "$TEMP_SYNC_SCRIPT"

# Run the sync script
log_info "Analyzing config and computing changes..."
SYNC_RESULT=$(python3 "$TEMP_SYNC_SCRIPT" "$TEMP_SCHEMA" "$CONFIG_FILE")

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
