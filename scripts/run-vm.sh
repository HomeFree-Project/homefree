#!/usr/bin/env bash

set -euo pipefail

# Configuration
SCRIPT_NAME=$(basename "$0")
SCRIPT_DIR=$(dirname "$(realpath "$0")")
FLAKE_DIR="${FLAKE_DIR:-$(pwd)}"
BUILD_DIR="${BUILD_DIR:-./build}"
VM_STATE_DIR="${VM_STATE_DIR:-./vm-state}"

# VM Configuration defaults
VM_MEMORY="${VM_MEMORY:-8192}"
VM_CORES="${VM_CORES:-4}"
VM_DISK_SIZE="${VM_DISK_SIZE:-50G}"
USE_VIRTVIEWER="${USE_VIRTVIEWER:-false}"
USE_UEFI="${USE_UEFI:-true}"

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
Usage: $SCRIPT_NAME [OPTIONS]

Boot the HomeFree installer ISO in a QEMU virtual machine for testing.

Options:
  -i, --iso PATH            Path to ISO file (default: auto-detect in build/)
  -m, --memory SIZE         VM memory in MB (default: 8192)
  -c, --cores NUM           Number of CPU cores (default: 4)
  -d, --disk-size SIZE      Virtual disk size (default: 50G)
  -v, --virtviewer          Use virt-viewer with QXL/SPICE (stable, clipboard sharing)
                            Default: SDL with VirtIO-GL (faster, may have GRUB issues)
  -k, --kvm                 Enable KVM acceleration (default: auto-detect)
  -K, --no-kvm              Disable KVM acceleration
  -U, --no-uefi             Disable UEFI boot (use legacy BIOS)
  -B, --build-dir DIR       Build directory where ISO is located (default: ./build)
  -S, --state-dir DIR       Directory for VM state/disk (default: ./vm-state)
  -R, --rebuild             Rebuild ISO before running
  -h, --help                Show this help

Environment Variables:
  FLAKE_DIR               Flake directory (default: current directory)
  VM_MEMORY               Default VM memory in MB
  VM_CORES                Default number of CPU cores
  VM_DISK_SIZE            Default virtual disk size
  BUILD_DIR               Directory containing ISO files
  VM_STATE_DIR            Directory for VM disk images

Examples:
  # Build and run the installer ISO
  $SCRIPT_NAME

  # Run with specific ISO and more resources
  $SCRIPT_NAME -i ./build/homefree.iso -m 16384 -c 8

  # Force rebuild and run
  $SCRIPT_NAME --rebuild

  # Run headless with VNC
  $SCRIPT_NAME -D vnc

Notes:
  - The VM will boot from the ISO as if it were a physical CD/DVD
  - A virtual hard disk will be created for installation testing
  - Changes to the virtual disk persist between runs (stored in vm-state/)
  - This is the same ISO that would be flashed to a USB drive
  - Use this to test the installer before deploying to real hardware
EOF
}

# Check for KVM support
check_kvm_support() {
    if [[ -e /dev/kvm ]]; then
        if [[ -r /dev/kvm ]] && [[ -w /dev/kvm ]]; then
            return 0
        else
            log_warning "KVM device exists but is not accessible"
            log_warning "To fix: sudo usermod -a -G kvm $USER (then logout/login)"
            return 1
        fi
    else
        log_warning "KVM not available. VM will run slowly without acceleration."
        return 1
    fi
}

# Parse command line arguments
ISO_PATH=""
USE_KVM=""
FORCE_REBUILD=false

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            usage
            exit 0
            ;;
        -i|--iso)
            ISO_PATH="$2"
            shift 2
            ;;
        -m|--memory)
            VM_MEMORY="$2"
            shift 2
            ;;
        -c|--cores)
            VM_CORES="$2"
            shift 2
            ;;
        -d|--disk-size)
            VM_DISK_SIZE="$2"
            shift 2
            ;;
        -v|--virtviewer)
            USE_VIRTVIEWER="true"
            shift
            ;;
        -k|--kvm)
            USE_KVM="true"
            shift
            ;;
        -K|--no-kvm)
            USE_KVM="false"
            shift
            ;;
        -U|--no-uefi)
            USE_UEFI=false
            shift
            ;;
        -B|--build-dir)
            BUILD_DIR="$2"
            shift 2
            ;;
        -S|--state-dir)
            VM_STATE_DIR="$2"
            shift 2
            ;;
        -R|--rebuild)
            FORCE_REBUILD=true
            shift
            ;;
        -*)
            log_error "Unknown option: $1"
            usage
            exit 1
            ;;
        *)
            log_error "Unknown argument: $1"
            usage
            exit 1
            ;;
    esac
done

# Check for required commands
for cmd in qemu-system-x86_64; do
    if ! command -v $cmd &> /dev/null; then
        log_error "$cmd could not be found. Please install QEMU first."
        exit 1
    fi
done

# Ensure directories are absolute paths
FLAKE_DIR=$(realpath "$FLAKE_DIR")
BUILD_DIR=$(realpath "$BUILD_DIR")
VM_STATE_DIR=$(realpath "$VM_STATE_DIR")

# Create necessary directories
mkdir -p "$BUILD_DIR"
mkdir -p "$VM_STATE_DIR"

# Rebuild ISO if requested
if [[ "$FORCE_REBUILD" == "true" ]]; then
    log_info "Rebuilding ISO..."
    "$SCRIPT_DIR/build-image.sh" -f "$FLAKE_DIR" -o "$BUILD_DIR"
fi

# Auto-detect ISO if not specified
if [[ -z "$ISO_PATH" ]]; then
    log_info "Auto-detecting ISO in $BUILD_DIR..."
    ISO_CANDIDATES=$(find "$BUILD_DIR" -name "*.iso" 2>/dev/null || true)
    ISO_COUNT=$(echo "$ISO_CANDIDATES" | grep -c . || true)

    if [[ $ISO_COUNT -eq 0 ]]; then
        log_error "No ISO found in $BUILD_DIR"
        log_info "Build an ISO first with: ./scripts/build-image.sh"
        exit 1
    elif [[ $ISO_COUNT -gt 1 ]]; then
        log_error "Multiple ISOs found in $BUILD_DIR:"
        echo "$ISO_CANDIDATES"
        log_info "Please specify which ISO to use with: -i <path>"
        exit 1
    else
        ISO_PATH="$ISO_CANDIDATES"
        log_info "Found ISO: $ISO_PATH"
    fi
fi

# Validate ISO exists
if [[ ! -f "$ISO_PATH" ]]; then
    log_error "ISO not found: $ISO_PATH"
    exit 1
fi

# Auto-detect KVM if not explicitly set
if [[ -z "$USE_KVM" ]]; then
    if check_kvm_support; then
        USE_KVM="true"
        log_info "KVM acceleration enabled (auto-detected)"
    else
        USE_KVM="false"
    fi
elif [[ "$USE_KVM" == "true" ]]; then
    if ! check_kvm_support; then
        log_error "KVM acceleration requested but not available"
        exit 1
    fi
    log_info "KVM acceleration enabled"
else
    log_info "KVM acceleration disabled"
fi

## Clear out old UEFI NVRAM vars
if [[ -f "$VM_STATE_DIR"/OVMF_VARS.fd ]]; then
    log_info "Deleting existing OVMF_VARS.fd ($(md5sum "$VM_STATE_DIR"/OVMF_VARS.fd | cut -d' ' -f1))"
fi
rm -f "$VM_STATE_DIR"/OVMF_VARS.fd
log_info "OVMF_VARS.fd deleted"

# Virtual disk for installation
DISK_IMAGE="$VM_STATE_DIR/homefree-test.qcow2"

# Check if virtual disk exists and ask user if they want to delete it
if [[ -f "$DISK_IMAGE" ]]; then
    DISK_SIZE=$(du -h "$DISK_IMAGE" | cut -f1)
    log_warning "Existing virtual disk found: $DISK_IMAGE ($DISK_SIZE)"
    log_warning "If you want to test the installer from scratch, you should delete this disk."
    log_warning "Otherwise, the VM will boot from the installed system on the disk."
    echo ""
    read -p "Delete the existing virtual disk and start fresh? [y/N] " -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        log_info "Deleting old virtual disk..."
        rm -f "$DISK_IMAGE"
        log_success "Deleted: $DISK_IMAGE"
    else
        log_info "Keeping existing virtual disk"
    fi
fi

# Create virtual disk if it doesn't exist
if [[ ! -f "$DISK_IMAGE" ]]; then
    log_info "Creating virtual disk: $DISK_IMAGE (size: $VM_DISK_SIZE)"
    qemu-img create -f qcow2 "$DISK_IMAGE" "$VM_DISK_SIZE"
else
    log_info "Using existing virtual disk: $DISK_IMAGE"
fi

# Setup UEFI firmware
OVMF_CODE=""
OVMF_VARS="$VM_STATE_DIR/OVMF_VARS.fd"

if [[ "$USE_UEFI" == "true" ]]; then
    log_info "Setting up UEFI boot..."

    # Try to find OVMF firmware - check nix store first
    OVMF_NIX_PATH=""
    if command -v nix-instantiate &> /dev/null; then
        OVMF_NIX_PATH=$(nix-instantiate --eval -E 'with import <nixpkgs> {}; "${OVMF.fd}/FV"' 2>/dev/null | tr -d '"' || true)
    fi

    # Search for OVMF_CODE.fd in various locations
    for code_path in \
        "${OVMF_NIX_PATH}/OVMF_CODE.fd" \
        "/run/current-system/sw/share/OVMF/OVMF_CODE.fd" \
        "/usr/share/OVMF/OVMF_CODE.fd" \
        "/usr/share/ovmf/x64/OVMF_CODE.fd" \
        "/usr/share/edk2/ovmf/OVMF_CODE.fd"; do
        if [[ -f "$code_path" ]]; then
            OVMF_CODE="$code_path"
            log_info "Found OVMF firmware: $OVMF_CODE"
            break
        fi
    done

    if [[ -z "$OVMF_CODE" ]]; then
        log_warning "OVMF firmware not found, disabling UEFI boot"
        log_warning "Install OVMF with: nix-shell -p OVMF"
        USE_UEFI=false
    else
        # Copy VARS file if it doesn't exist
        OVMF_VARS_TEMPLATE="${OVMF_CODE/CODE/VARS}"
        if [[ ! -f "$OVMF_VARS" ]]; then
            # Use --reflink=never to prevent btrfs CoW from sharing data blocks
            # This ensures truly fresh NVRAM state on each boot
            cp --reflink=never "$OVMF_VARS_TEMPLATE" "$OVMF_VARS"
            chmod 644 "$OVMF_VARS"  # Make it writable (QEMU needs to write to this file)
            log_info "Created UEFI VARS file: $OVMF_VARS"
        fi
    fi
fi

# Build QEMU command
QEMU_CMD=(
    qemu-system-x86_64
    -machine q35,accel=kvm:tcg  # Modern chipset with KVM or fallback to TCG
    -m "$VM_MEMORY"
    -smp "$VM_CORES,sockets=1,cores=$VM_CORES,threads=1"
)

# KVM acceleration with optimized CPU settings
if [[ "$USE_KVM" == "true" ]]; then
    QEMU_CMD+=(
        -cpu host,kvm=on,+x2apic,+avx,+avx2
    )
else
    QEMU_CMD+=(-cpu max)
fi

# Add random number generator for better entropy (speeds up boot)
QEMU_CMD+=(-object rng-random,filename=/dev/urandom,id=rng0 -device virtio-rng-pci,rng=rng0)

# UEFI or BIOS
if [[ "$USE_UEFI" == "true" ]]; then
    QEMU_CMD+=(
        -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE"
        -drive "if=pflash,format=raw,file=$OVMF_VARS"
    )
fi

# Boot from ISO (CD-ROM)
QEMU_CMD+=(-cdrom "$ISO_PATH")

# Virtual hard disk for installation with optimized cache settings
# Use writeback cache for better performance (safe for testing VMs)
QEMU_CMD+=(-drive "file=$DISK_IMAGE,format=qcow2,if=virtio,cache=writeback,discard=unmap")

# Force boot from CD-ROM first to avoid UEFI boot state issues
# Without this, UEFI may boot from disk and use cached terminal settings
QEMU_CMD+=(-boot order=d)

# Graphics adapter configuration
if [[ "$USE_VIRTVIEWER" == "true" ]]; then
    # QXL with SPICE for virt-viewer (stable, clipboard sharing, dynamic resolution)
    log_info "Using virt-viewer with QXL/SPICE (stable, clipboard sharing)"

    # Detect current display resolution for QXL max resolution
    DISPLAY_RES=$(xrandr --current 2>/dev/null | grep -oP 'current \K\d+ x \d+' | tr -d ' ')
    if [[ -n "$DISPLAY_RES" ]]; then
        XRES=$(echo $DISPLAY_RES | cut -d'x' -f1)
        YRES=$(echo $DISPLAY_RES | cut -d'x' -f2)
        log_info "Detected display resolution: ${XRES}x${YRES}"
    else
        # Fallback to 1920x1080 if detection fails
        XRES=1920
        YRES=1080
        log_info "Could not detect display resolution, using fallback: ${XRES}x${YRES}"
    fi

    # Increase vgamem and ram for higher resolutions, set max resolution to match display
    QEMU_CMD+=(-device qxl-vga,vgamem_mb=256,ram_size_mb=256,vram_size_mb=256,vram64_size_mb=256,max_outputs=1,xres=${XRES},yres=${YRES})

    # Add SPICE server with image compression for better high-res performance
    QEMU_CMD+=(-spice port=5900,addr=127.0.0.1,disable-ticketing=on,image-compression=auto_glz,streaming-video=filter)

    # Add virtio serial for SPICE agent communication
    QEMU_CMD+=(-device virtio-serial-pci)
    QEMU_CMD+=(-device virtserialport,chardev=spicechannel0,name=com.redhat.spice.0)
    QEMU_CMD+=(-chardev spicevmc,id=spicechannel0,name=vdagent)
else
    # Default: VirtIO GPU with OpenGL acceleration via SDL (faster)
    log_info "Using SDL with VirtIO-GL (fast OpenGL acceleration)"
    log_info "Note: If you see a black GRUB screen, use --virtviewer flag"

    QEMU_CMD+=(-device virtio-vga-gl)
    QEMU_CMD+=(-display sdl,gl=on)
fi

# Disable audio to avoid unnecessary device probing
QEMU_CMD+=(-audiodev none,id=noaudio)

# USB controller - modern xHCI for better performance
QEMU_CMD+=(-device qemu-xhci,id=xhci)

# Network with port forwarding - optimize with packed virtqueues
QEMU_CMD+=(
    -device virtio-net-pci,netdev=net0,mac=52:54:00:12:34:56
    -netdev user,id=net0,hostfwd=tcp::2223-:22,hostfwd=tcp::8443-:443,hostfwd=tcp::8080-:80,hostfwd=tcp::8000-:8000
)

# Display configuration already handled above in graphics section

# Display configuration
log_info "Starting VM with HomeFree installer ISO..."
log_info "Configuration:"
log_info "  ISO: $ISO_PATH"
log_info "  Memory: ${VM_MEMORY}MB"
log_info "  CPU cores: $VM_CORES"
log_info "  Virtual disk: $DISK_IMAGE"
if [[ "$USE_VIRTVIEWER" == "true" ]]; then
    log_info "  Mode: virt-viewer (QXL+SPICE)"
else
    log_info "  Mode: SDL (VirtIO-GL)"
fi
log_info "  KVM: $USE_KVM"
log_info "  UEFI: $USE_UEFI"
log_info ""
log_info "The VM will boot from the ISO just like a physical machine."
log_info "You can test the Calamares installer and complete a full installation."
log_info ""
log_info "Network ports forwarded to host:"
log_info "  - SSH: ssh -p 2223 <user>@localhost"
log_info "  - HTTPS: https://localhost:8443"
log_info "  - HTTP: http://localhost:8080"
log_info "  - Installer API: http://localhost:8000"

# Execute QEMU
if [[ "$USE_VIRTVIEWER" == "true" ]]; then
    # Virt-viewer mode: run QEMU in background and launch remote-viewer
    "${QEMU_CMD[@]}" &
    QEMU_PID=$!

    # Wait for SPICE server to be ready
    log_info "Waiting for SPICE server to start..."
    for i in {1..30}; do
        if ss -tln | grep -q ":5900"; then
            log_info "SPICE server ready"
            break
        fi
        sleep 0.5
    done

    # Launch remote-viewer
    log_info "Launching remote-viewer..."
    remote-viewer spice://localhost:5900 &
    VIEWER_PID=$!

    # Wait for viewer to exit (user closes it)
    wait $VIEWER_PID 2>/dev/null
    VIEWER_EXIT=$?

    # Kill QEMU when viewer closes
    log_info "Viewer closed, shutting down VM..."
    kill $QEMU_PID 2>/dev/null

    # Give QEMU a moment to shut down gracefully
    sleep 2

    # Force kill if still running
    kill -9 $QEMU_PID 2>/dev/null

    exit $VIEWER_EXIT
else
    # SDL mode: run QEMU directly in foreground
    exec "${QEMU_CMD[@]}"
fi
