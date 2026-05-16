#!/usr/bin/env bash

set -euo pipefail

# Build a HomeFree installer ISO and publish it so the landing page's
# "HomeFree ISO" card resolves to a real file. The ISO build is decoupled
# from nixos-rebuild: this script does the build, then installs the
# artifact into /var/lib/homefree/downloads and updates the
# `homefree-latest.iso` symlink atomically.
#
# Server side: services/landing-page/default.nix creates
#   /var/lib/homefree/downloads (owned by caddy:caddy)
# and Caddy serves it at https://<domain>/downloads/.
#
# Two modes:
#   --local            publish on this machine (default if no host given)
#   <user@host>        publish to a remote box over ssh+rsync

SCRIPT_NAME=$(basename "$0")
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
FLAKE_DIR="${FLAKE_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }

usage() {
    cat << EOF
Usage: $SCRIPT_NAME [--local | TARGET_HOST] [OPTIONS]

Build a HomeFree installer ISO and publish it to
/var/lib/homefree/downloads, where the landing-page Caddy config
serves it at /downloads/.

Modes:
  --local                  Publish to this machine (will sudo as needed)
  TARGET_HOST              ssh destination, e.g. root@homefree.example.com

Common usage:
  $SCRIPT_NAME --local
  $SCRIPT_NAME root@homefree.example.com

In --local mode, run as your normal user; the script primes sudo
up front and only escalates for the install/symlink steps. The nix
build always runs as the invoking user.

Options (you usually don't need these):
  -c, --config NAME        nixosConfiguration to build
                           (default: homefree-installer)
  -f, --flake-dir DIR      Flake directory (default: repo root)
  -o, --output-dir DIR     Local build output dir (default: \$FLAKE_DIR/build)
  -r, --remote-dir DIR     Downloads dir on target
                           (default: /var/lib/homefree/downloads)
  -n, --name NAME          Published basename without extension
                           (default: homefree-<YYYYMMDD>-x86_64)
  -L, --no-latest          Don't update the homefree-latest.iso symlink
  -S, --skip-build         Skip the nix build; reuse existing \$OUTPUT_DIR
  -h, --help               Show this help
EOF
}

# Defaults
CONFIG_NAME="homefree-installer"
OUTPUT_DIR=""
REMOTE_DIR="/var/lib/homefree/downloads"
PUBLISH_NAME=""
UPDATE_LATEST=true
SKIP_BUILD=false
TARGET_HOST=""
LOCAL_MODE=false

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)        usage; exit 0 ;;
        --local)          LOCAL_MODE=true; shift ;;
        -c|--config)      CONFIG_NAME="$2"; shift 2 ;;
        -f|--flake-dir)   FLAKE_DIR="$2"; shift 2 ;;
        -o|--output-dir)  OUTPUT_DIR="$2"; shift 2 ;;
        -r|--remote-dir)  REMOTE_DIR="$2"; shift 2 ;;
        -n|--name)        PUBLISH_NAME="$2"; shift 2 ;;
        -L|--no-latest)   UPDATE_LATEST=false; shift ;;
        -S|--skip-build)  SKIP_BUILD=true; shift ;;
        -*)
            log_error "Unknown option: $1"
            usage
            exit 1
            ;;
        *)
            if [[ -n "$TARGET_HOST" ]]; then
                log_error "Unexpected positional argument: $1"
                usage
                exit 1
            fi
            TARGET_HOST="$1"
            shift
            ;;
    esac
done

if [[ "$LOCAL_MODE" == "true" && -n "$TARGET_HOST" ]]; then
    log_error "Pass either --local or a TARGET_HOST, not both"
    exit 1
fi

if [[ "$LOCAL_MODE" == "false" && -z "$TARGET_HOST" ]]; then
    log_error "Specify --local or a TARGET_HOST"
    usage
    exit 1
fi

# --local needs root for the install/symlink steps (target dir is
# owned by caddy:caddy), but the `nix build` should NOT run as root —
# it'd pollute root's profile and store GC roots. So instead of
# requiring `sudo $SCRIPT`, we stay as the user and prepend `sudo` to
# the steps that need it. Prime the credential up front so the prompt
# happens now, not after a long build.
SUDO=()
if [[ "$LOCAL_MODE" == "true" ]]; then
    if [[ $EUID -eq 0 ]]; then
        log_warning "Running as root. The nix build will use root's profile."
        log_warning "Prefer running this script as your normal user; it will sudo as needed."
    else
        log_info "Publishing locally needs root for the final install steps."
        log_info "Priming sudo now so it doesn't prompt mid-build."
        sudo -v
        # Keep the sudo credential alive while the long build runs.
        ( while true; do sudo -n true 2>/dev/null || exit; sleep 50; done ) &
        SUDO_KEEPALIVE_PID=$!
        trap 'kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true' EXIT
        SUDO=(sudo)
    fi
fi

FLAKE_DIR=$(realpath "$FLAKE_DIR")
if [[ ! -f "$FLAKE_DIR/flake.nix" ]]; then
    log_error "No flake.nix found in $FLAKE_DIR"
    exit 1
fi

if [[ -z "$OUTPUT_DIR" ]]; then
    OUTPUT_DIR="$FLAKE_DIR/build"
fi
OUTPUT_DIR=$(realpath -m "$OUTPUT_DIR")

if [[ -z "$PUBLISH_NAME" ]]; then
    PUBLISH_NAME="homefree-$(date -u +%Y%m%d)-x86_64"
fi

LOCAL_ISO="$OUTPUT_DIR/${CONFIG_NAME}.iso"

if [[ "$SKIP_BUILD" == "true" ]]; then
    log_info "Skipping build (--skip-build); expecting $LOCAL_ISO"
    if [[ ! -f "$LOCAL_ISO" ]]; then
        log_error "No prebuilt image at $LOCAL_ISO"
        exit 1
    fi
else
    log_info "Building $CONFIG_NAME via scripts/build-image.sh"
    "$SCRIPT_DIR/build-image.sh" \
        --flake-dir "$FLAKE_DIR" \
        --output-dir "$OUTPUT_DIR" \
        "$CONFIG_NAME"

    if [[ ! -f "$LOCAL_ISO" ]]; then
        log_error "Expected ISO at $LOCAL_ISO but it was not produced"
        exit 1
    fi
fi

log_info "Computing sha256 for $LOCAL_ISO"
LOCAL_SHA="${LOCAL_ISO}.sha256"
# Write a portable sha256 line: "<hash>  <basename>.iso" so verifying
# clients can `sha256sum -c` from the same directory.
( cd "$(dirname "$LOCAL_ISO")" && sha256sum "$(basename "$LOCAL_ISO")" ) > "$LOCAL_SHA"
SHA_HASH="$(awk '{print $1}' "$LOCAL_SHA")"

REMOTE_ISO_BASENAME="${PUBLISH_NAME}.iso"
REMOTE_ISO_PATH="${REMOTE_DIR}/${REMOTE_ISO_BASENAME}"
REMOTE_SHA_PATH="${REMOTE_ISO_PATH}.sha256"

if [[ "$LOCAL_MODE" == "true" ]]; then
    if [[ ! -d "$REMOTE_DIR" ]]; then
        log_error "${REMOTE_DIR} doesn't exist. Has the landing-page module"
        log_error "been deployed (it creates the dir via systemd-tmpfiles)?"
        exit 1
    fi

    log_info "Installing ISO -> ${REMOTE_ISO_PATH}"
    "${SUDO[@]}" install -o caddy -g caddy -m 0644 "$LOCAL_ISO" "$REMOTE_ISO_PATH"

    log_info "Writing sha256 -> ${REMOTE_SHA_PATH}"
    echo "${SHA_HASH}  ${REMOTE_ISO_BASENAME}" \
        | "${SUDO[@]}" install -o caddy -g caddy -m 0644 /dev/stdin "$REMOTE_SHA_PATH"

    if [[ "$UPDATE_LATEST" == "true" ]]; then
        log_info "Repointing homefree-latest.iso -> ${REMOTE_ISO_BASENAME}"
        # Atomic symlink swap: write to a temp name, then rename over
        # the existing symlink. Avoids a brief 404 window.
        "${SUDO[@]}" sh -c "
            set -e
            cd '${REMOTE_DIR}'
            ln -sfn '${REMOTE_ISO_BASENAME}'         'homefree-latest.iso.new'
            mv  -Tf 'homefree-latest.iso.new'         'homefree-latest.iso'
            ln -sfn '${REMOTE_ISO_BASENAME}.sha256'   'homefree-latest.iso.sha256.new'
            mv  -Tf 'homefree-latest.iso.sha256.new'  'homefree-latest.iso.sha256'
        "
    fi
else
    log_info "Checking remote dir ${REMOTE_DIR} on ${TARGET_HOST}"
    ssh "$TARGET_HOST" "test -d '${REMOTE_DIR}'" || {
        log_error "${REMOTE_DIR} doesn't exist on ${TARGET_HOST}. Has the"
        log_error "landing-page module been deployed?"
        exit 1
    }

    log_info "Uploading ISO -> ${TARGET_HOST}:${REMOTE_ISO_PATH}"
    rsync -avP --inplace "$LOCAL_ISO" "${TARGET_HOST}:${REMOTE_ISO_PATH}"

    log_info "Uploading sha256 -> ${TARGET_HOST}:${REMOTE_SHA_PATH}"
    echo "${SHA_HASH}  ${REMOTE_ISO_BASENAME}" \
        | ssh "$TARGET_HOST" "cat > '${REMOTE_SHA_PATH}'"

    if [[ "$UPDATE_LATEST" == "true" ]]; then
        log_info "Repointing homefree-latest.iso -> ${REMOTE_ISO_BASENAME}"
        ssh "$TARGET_HOST" "
            set -e
            cd '${REMOTE_DIR}'
            ln -sfn '${REMOTE_ISO_BASENAME}'        'homefree-latest.iso.new'
            mv -Tf  'homefree-latest.iso.new'        'homefree-latest.iso'
            ln -sfn '${REMOTE_ISO_BASENAME}.sha256'  'homefree-latest.iso.sha256.new'
            mv -Tf  'homefree-latest.iso.sha256.new' 'homefree-latest.iso.sha256'
        "
    fi
fi

log_success "Published ${REMOTE_ISO_BASENAME} to ${REMOTE_DIR}"
if [[ "$UPDATE_LATEST" == "true" ]]; then
    log_info "Landing page link (/downloads/homefree-latest.iso) now resolves to this build."
fi
