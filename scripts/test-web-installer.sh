#!/usr/bin/env bash
# Test script for HomeFree web-based installer
# Builds the web installer ISO and runs it in QEMU for testing

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/build"
INSTALLER_IMAGE="$BUILD_DIR/homefree-web-installer.iso"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if running in Nix environment
if ! command -v nix-build &> /dev/null; then
    log_error "nix-build not found. Please install Nix."
    exit 1
fi

# Build the web installer ISO
build_installer() {
    log_info "Building web installer ISO..."

    cd "$PROJECT_DIR"

    # Build the installer configuration (homefree-installer is now the web installer)
    log_info "Running: nix build .#nixosConfigurations.homefree-installer.config.system.build.isoImage"

    nix build .#nixosConfigurations.homefree-installer.config.system.build.isoImage \
        --out-link result-installer \
        --show-trace

    # Find the ISO file
    ISO_PATH=$(find result-installer/iso -name "*.iso" | head -n 1)

    if [ -z "$ISO_PATH" ]; then
        log_error "Failed to find ISO image in build output"
        exit 1
    fi

    # Copy to build directory
    mkdir -p "$BUILD_DIR"
    cp "$ISO_PATH" "$INSTALLER_IMAGE"

    log_info "Web installer ISO built: $INSTALLER_IMAGE"
    log_info "Size: $(du -h "$INSTALLER_IMAGE" | cut -f1)"
}

# Test the installer in QEMU
test_in_qemu() {
    log_info "Testing web installer in QEMU..."

    if ! command -v qemu-system-x86_64 &> /dev/null; then
        log_error "qemu-system-x86_64 not found. Please install QEMU."
        exit 1
    fi

    # Create a virtual disk for installation
    VDISK="$BUILD_DIR/test-disk.qcow2"
    if [ ! -f "$VDISK" ]; then
        log_info "Creating virtual disk: $VDISK"
        qemu-img create -f qcow2 "$VDISK" 100G
    else
        log_warn "Using existing virtual disk: $VDISK"
    fi

    log_info "Starting QEMU VM..."
    log_info "The web installer should auto-launch in Firefox"
    log_info "Navigate through the installation wizard to test"
    log_info ""
    log_info "VM Configuration:"
    log_info "  - Memory: 16GB"
    log_info "  - CPUs: 4"
    log_info "  - Disk: $VDISK (100GB)"
    log_info "  - Network: NAT with 2 virtual NICs"
    log_info ""
    log_info "Press Ctrl+Alt+G to release mouse/keyboard from QEMU"
    log_info "Press Ctrl+C to stop the VM"
    log_info ""

    # Run QEMU with:
    # - 16GB RAM (HomeFree build needs ~8GB for tmpfs nix store)
    # - 4 CPUs for faster builds
    # - KVM acceleration if available
    # - 2 network interfaces (for WAN/LAN testing)
    # - Boot from ISO
    # - VNC display

    QEMU_ARGS=(
        -m 16384
        -smp 4
        -cdrom "$INSTALLER_IMAGE"
        -drive file="$VDISK",format=qcow2,if=virtio
        -netdev user,id=wan,hostfwd=tcp::8000-:8000,hostfwd=tcp::9090-:9090
        -device e1000,netdev=wan
        -netdev user,id=lan
        -device e1000,netdev=lan
        -boot d
    )

    if [ "$USE_GTK" = "true" ]; then
        QEMU_ARGS+=(-vga qxl -display gtk)
        log_info "Using GTK display with QXL"
    else
        QEMU_ARGS+=(-device virtio-vga-gl -display sdl,gl=on)
        log_info "Using SDL display with VirtIO-GL"
    fi

    # Add KVM if available
    if [ -e /dev/kvm ]; then
        QEMU_ARGS+=(-enable-kvm)
        log_info "KVM acceleration enabled"
    else
        log_warn "KVM not available, using software emulation (will be slow)"
    fi

    # Add UEFI firmware if available
    if [ -f /usr/share/OVMF/OVMF_CODE.fd ]; then
        QEMU_ARGS+=(
            -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE.fd
        )
        log_info "UEFI firmware enabled"
    fi

    qemu-system-x86_64 "${QEMU_ARGS[@]}"
}

# Main
main() {
    log_info "HomeFree Web Installer Test Script"
    log_info "===================================="
    echo

    USE_GTK=false
    POSITIONAL=()
    for arg in "$@"; do
        case "$arg" in
            --gtk) USE_GTK=true ;;
            *) POSITIONAL+=("$arg") ;;
        esac
    done
    set -- "${POSITIONAL[@]}"

    case "${1:-}" in
        build)
            build_installer
            ;;
        test)
            if [ ! -f "$INSTALLER_IMAGE" ]; then
                log_error "Installer ISO not found. Run '$0 build' first."
                exit 1
            fi
            test_in_qemu
            ;;
        clean)
            log_info "Cleaning build artifacts..."
            rm -f "$INSTALLER_IMAGE"
            rm -f "$BUILD_DIR/test-disk.qcow2"
            rm -rf "$PROJECT_DIR/result-installer"
            log_info "Clean complete"
            ;;
        *)
            log_info "Usage: $0 {build|test|clean} [--gtk]"
            echo
            log_info "Commands:"
            echo "  build  - Build the web installer ISO (homefree-installer)"
            echo "  test   - Test the installer in QEMU (builds if needed)"
            echo "  clean  - Remove build artifacts"
            echo
            log_info "Options:"
            echo "  --gtk  - Use GTK display with QXL (default: SDL with VirtIO-GL)"
            echo
            log_info "Note: homefree-installer now uses the web installer (not Calamares)"
            echo "      To build Calamares: nix build .#nixosConfigurations.homefree-installer-calamares.config.system.build.isoImage"
            echo
            log_info "Quick start:"
            echo "  $0 build         # Build the installer"
            echo "  $0 test          # Test in QEMU (SDL)"
            echo "  $0 test --gtk    # Test in QEMU (GTK fallback)"
            echo
            log_info "Or combine:"
            echo "  $0 build && $0 test"
            exit 1
            ;;
    esac
}

main "$@"
