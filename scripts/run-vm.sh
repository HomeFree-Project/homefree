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
USE_HEADLESS="${USE_HEADLESS:-false}"
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
  --headless                Run without UI (SPICE server only, no viewer launched)
  -k, --kvm                 Enable KVM acceleration (default: auto-detect)
  -K, --no-kvm              Disable KVM acceleration
  -U, --no-uefi             Disable UEFI boot (use legacy BIOS)
  -B, --build-dir DIR       Build directory where ISO is located (default: ./build)
  -S, --state-dir DIR       Directory for VM state/disk (default: ./vm-state)
  -R, --rebuild             Rebuild ISO before running
  -l, --lan-client          Also launch lan-client VM connected to router's LAN
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

  # Run with lan-client VM (launches both router and lan-client VMs)
  $SCRIPT_NAME --lan-client

  # Run headless (SPICE server without UI)
  $SCRIPT_NAME --headless

Notes:
  - The VM will boot from the ISO as if it were a physical CD/DVD
  - A virtual hard disk will be created for installation testing
  - Changes to the virtual disk persist between runs (stored in vm-state/)
  - This is the same ISO that would be flashed to a USB drive
  - Use this to test the installer before deploying to real hardware
  - The VM always runs in router mode with bridge networking
  - Use --lan-client to also launch a separate lan-client VM for testing

Clipboard Sharing:
  - Default (SDL): Fast graphics, no clipboard support
  - --virtviewer: Stable graphics with clipboard sharing via remote-viewer
  - --headless: No UI, SPICE available at localhost:5900 for remote connection
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

# Create bridge for router mode
create_bridge() {
    local bridge_name="$1"
    log_info "Creating bridge: $bridge_name"
    sudo ip link add name "$bridge_name" type bridge
    sudo ip link set "$bridge_name" up
    log_success "Bridge $bridge_name created and brought up"
}

# Destroy bridge for router mode
destroy_bridge() {
    local bridge_name="$1"
    if ip link show "$bridge_name" &> /dev/null; then
        log_info "Destroying bridge: $bridge_name"
        sudo ip link set "$bridge_name" down
        sudo ip link delete "$bridge_name"
        log_success "Bridge $bridge_name destroyed"
    fi
}

# Parse command line arguments
ISO_PATH=""
USE_KVM=""
FORCE_REBUILD=false
LAUNCH_LAN_CLIENT=false
VIRTIOFSD_PID=""

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
        --headless)
            USE_HEADLESS="true"
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
        -l|--lan-client)
            LAUNCH_LAN_CLIENT=true
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

    if [[ "$LAUNCH_LAN_CLIENT" == "true" ]]; then
        log_info "Also rebuilding lan-client VM..."
        nix build "$FLAKE_DIR#nixosConfigurations.lan-client.config.system.build.vm" -o "$BUILD_DIR/lan-client-vm"
    fi
fi

# Always create bridge for router mode networking
BRIDGE_NAME="hfbr0"

# Find qemu-bridge-helper
QEMU_BRIDGE_HELPER=$(which qemu-bridge-helper 2>/dev/null || echo "/usr/libexec/qemu-bridge-helper")
if [[ ! -x "$QEMU_BRIDGE_HELPER" ]]; then
    log_error "qemu-bridge-helper not found or not executable"
    exit 1
fi

# Delete bridge if it already exists, then create fresh
destroy_bridge "$BRIDGE_NAME"
create_bridge "$BRIDGE_NAME"

# Trap to cleanup on exit
cleanup() {
    [[ -n "$VIRTIOFSD_PID" ]] && sudo kill "$VIRTIOFSD_PID" 2>/dev/null
    destroy_bridge "$BRIDGE_NAME"
}
trap cleanup EXIT INT TERM

# Auto-detect ISO for router VM
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
fi

# Setup UEFI firmware for router
OVMF_CODE=""
ROUTER_OVMF_VARS="$VM_STATE_DIR/OVMF_VARS_router.fd"

if [[ "$USE_UEFI" == "true" ]]; then
    log_info "Setting up UEFI boot..."
    OVMF_NIX_PATH=""
    if command -v nix-instantiate &> /dev/null; then
        OVMF_NIX_PATH=$(nix-instantiate --eval -E 'with import <nixpkgs> {}; "${OVMF.fd}/FV"' 2>/dev/null | tr -d '"' || true)
    fi

    for code_path in \
        "${OVMF_NIX_PATH}/OVMF_CODE.fd" \
        "/run/current-system/sw/share/OVMF/OVMF_CODE.fd" \
        "/usr/share/OVMF/OVMF_CODE.fd"; do
        if [[ -f "$code_path" ]]; then
            OVMF_CODE="$code_path"
            log_info "Found OVMF firmware: $OVMF_CODE"
            break
        fi
    done

    if [[ -z "$OVMF_CODE" ]]; then
        log_warning "OVMF firmware not found, disabling UEFI boot"
        USE_UEFI=false
    else
        OVMF_VARS_TEMPLATE="${OVMF_CODE/CODE/VARS}"
        if [[ ! -f "$ROUTER_OVMF_VARS" ]]; then
            cp --reflink=never "$OVMF_VARS_TEMPLATE" "$ROUTER_OVMF_VARS"
            chmod 644 "$ROUTER_OVMF_VARS"
            log_info "Created UEFI VARS file for router: $ROUTER_OVMF_VARS"
        fi
    fi
fi

# Router VM disk
ROUTER_DISK="$VM_STATE_DIR/homefree-test.qcow2"

# Check if virtual disk exists and ask user if they want to delete it
if [[ -f "$ROUTER_DISK" ]]; then
    DISK_SIZE=$(du -h "$ROUTER_DISK" | cut -f1)
    log_warning "Existing virtual disk found: $ROUTER_DISK ($DISK_SIZE)"
    log_warning "If you want to test the installer from scratch, you should delete this disk."
    log_warning "Otherwise, the VM will boot from the installed system on the disk."
    echo ""
    read -p "Delete the existing virtual disk and start fresh? [y/N] " -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        log_info "Deleting old virtual disk..."
        rm -f "$ROUTER_DISK"
        log_success "Deleted: $ROUTER_DISK"
    else
        log_info "Keeping existing virtual disk"
    fi
fi

# Create virtual disk if it doesn't exist
if [[ ! -f "$ROUTER_DISK" ]]; then
    log_info "Creating router VM disk: $ROUTER_DISK (size: $VM_DISK_SIZE)"
    qemu-img create -f qcow2 "$ROUTER_DISK" "$VM_DISK_SIZE"
else
    log_info "Using existing router disk: $ROUTER_DISK"
fi

# Build router QEMU command
ROUTER_QEMU_CMD=(
    qemu-system-x86_64
    -machine q35,accel=kvm:tcg
    -m "$VM_MEMORY"
    -smp "$VM_CORES,sockets=1,cores=$VM_CORES,threads=1"
)

if [[ "$USE_KVM" == "true" ]]; then
    ROUTER_QEMU_CMD+=(-cpu host,kvm=on,+x2apic,+avx,+avx2)
else
    ROUTER_QEMU_CMD+=(-cpu max)
fi

ROUTER_QEMU_CMD+=(-object rng-random,filename=/dev/urandom,id=rng0 -device virtio-rng-pci,rng=rng0)

if [[ "$USE_UEFI" == "true" ]]; then
    ROUTER_QEMU_CMD+=(
        -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE"
        -drive "if=pflash,format=raw,file=$ROUTER_OVMF_VARS"
    )
fi

ROUTER_QEMU_CMD+=(
    -drive "file=$ROUTER_DISK,format=qcow2,if=none,id=maindisk,cache=writeback,discard=unmap"
    -device "virtio-blk-pci,drive=maindisk,bootindex=0"
    -drive "file=$ISO_PATH,if=none,id=cdrom,media=cdrom,readonly=on"
    -device "ide-cd,drive=cdrom,bootindex=1"
)

# Router networking: user (WAN) + bridge (LAN)
# Add network devices BEFORE graphics to ensure consistent PCI ordering
# Define -netdev BEFORE -device that references it
ROUTER_QEMU_CMD+=(
    -netdev user,id=net0,hostfwd=tcp::2223-:22,hostfwd=tcp::8443-:443,hostfwd=tcp::8080-:80,hostfwd=tcp::8000-:8000
    -device virtio-net-pci,netdev=net0,mac=52:54:00:12:34:56
    -netdev "bridge,br=$BRIDGE_NAME,id=net1,helper=$QEMU_BRIDGE_HELPER"
    -device virtio-net-pci,netdev=net1,mac=e6:c8:ff:09:76:88
)

# Graphics for router VM
if [[ "$USE_VIRTVIEWER" == "true" ]] || [[ "$USE_HEADLESS" == "true" ]]; then
    ROUTER_QEMU_CMD+=(
        -device qxl-vga,vgamem_mb=256,ram_size_mb=256,vram_size_mb=256,vram64_size_mb=256,max_outputs=1
        -spice port=5900,addr=127.0.0.1,disable-ticketing=on,image-compression=auto_glz,streaming-video=filter
        -device virtio-serial-pci
        -device virtserialport,chardev=spicechannel0,name=com.redhat.spice.0
        -chardev spicevmc,id=spicechannel0,name=vdagent
    )
else
    ROUTER_QEMU_CMD+=(
        -device virtio-vga-gl
        -display sdl,gl=on
    )
fi

ROUTER_QEMU_CMD+=(
    -audiodev none,id=noaudio
    -device qemu-xhci,id=xhci
)

# Shared folder for router using virtiofs (fast, consistent for both installer and installed system)
# Start virtiofsd daemon (needs sudo)
VIRTIOFS_SOCKET="$VM_STATE_DIR/vhostqemu.sock"
rm -f "$VIRTIOFS_SOCKET"
log_info "Starting virtiofsd daemon..."
sudo virtiofsd --socket-path="$VIRTIOFS_SOCKET" --shared-dir="$FLAKE_DIR" --cache=auto &
VIRTIOFSD_PID=$!

# Wait for socket to be created
for i in {1..30}; do
    if [[ -S "$VIRTIOFS_SOCKET" ]]; then
        log_success "virtiofsd ready"
        break
    fi
    sleep 0.1
done

# Make socket accessible to current user so QEMU doesn't need sudo
sudo chown "$USER" "$VIRTIOFS_SOCKET"

ROUTER_QEMU_CMD+=(
    # virtiofs for both installer and installed system
    -chardev socket,id=char0,path="$VIRTIOFS_SOCKET"
    -device vhost-user-fs-pci,queue-size=1024,chardev=char0,tag=mount_homefree_source
    -object memory-backend-file,id=mem,size="${VM_MEMORY}M",mem-path=/dev/shm,share=on
    -numa node,memdev=mem
)

# Launch router VM
log_info "Launching router VM..."
log_info "  ISO: $ISO_PATH"
log_info "  Disk: $ROUTER_DISK"
log_info "  Memory: ${VM_MEMORY}MB"
log_info "  Cores: $VM_CORES"

if [[ "$USE_VIRTVIEWER" == "true" ]] || [[ "$USE_HEADLESS" == "true" ]]; then
    "${ROUTER_QEMU_CMD[@]}" &
    ROUTER_PID=$!

    # Wait for SPICE server
    log_info "Waiting for SPICE server to start..."
    for i in {1..30}; do
        if ss -tln | grep -q ":5900"; then
            log_info "SPICE server ready"
            break
        fi
        sleep 0.5
    done

    if [[ "$USE_VIRTVIEWER" == "true" ]]; then
        log_info "Launching remote-viewer for router..."
        remote-viewer spice://localhost:5900 &
        VIEWER_PID=$!
    else
        log_info "Running in headless mode - SPICE server available at localhost:5900"
    fi
else
    "${ROUTER_QEMU_CMD[@]}" &
    ROUTER_PID=$!
fi

# Check if launching lan-client VM
if [[ "$LAUNCH_LAN_CLIENT" == "true" ]]; then
    # Build lan-client VM
    if [[ ! -e "$BUILD_DIR/lan-client-vm" ]]; then
        log_info "Building lan-client VM..."
        nix build "$FLAKE_DIR#nixosConfigurations.lan-client.config.system.build.vm" -o "$BUILD_DIR/lan-client-vm"
    fi

    # lan-client disk (created by NixOS VM script)
    CLIENT_DISK="$BUILD_DIR/lan-client.qcow2"

    # Launch lan-client VM using the NixOS VM script with custom options
    log_info "Launching lan-client VM..."

    # Set environment variables for the VM script
    export NIX_DISK_IMAGE="$CLIENT_DISK"
    export QEMU_OPTS="-netdev bridge,br=$BRIDGE_NAME,id=net0,helper=$QEMU_BRIDGE_HELPER -device virtio-net-pci,netdev=net0,mac=e6:c8:ff:09:76:89"

    if [[ "$USE_VIRTVIEWER" == "true" ]] || [[ "$USE_HEADLESS" == "true" ]]; then
        QEMU_OPTS="$QEMU_OPTS -device qxl-vga -spice port=5901,addr=127.0.0.1,disable-ticketing=on"
    else
        QEMU_OPTS="$QEMU_OPTS -device virtio-vga-gl -display sdl,gl=on"
    fi

    "$BUILD_DIR/lan-client-vm/bin/run-lan-client-vm" &
    CLIENT_PID=$!

    if [[ "$USE_VIRTVIEWER" == "true" ]]; then
        sleep 2
        log_info "Launching remote-viewer for lan-client..."
        remote-viewer spice://localhost:5901 &
        CLIENT_VIEWER_PID=$!
    elif [[ "$USE_HEADLESS" == "true" ]]; then
        log_info "LAN client running in headless mode - SPICE server available at localhost:5901"
    fi

    log_success "Both VMs launched successfully!"
    log_info "LAN Client VM PID: $CLIENT_PID"

    # Wait for both VMs
    wait $ROUTER_PID $CLIENT_PID
else
    log_success "Router VM launched successfully!"
    log_info "Router VM PID: $ROUTER_PID"

    # Wait for router VM only
    wait $ROUTER_PID
fi

log_info ""
log_info "Router VM ports forwarded to host:"
log_info "  - SSH: ssh -p 2223 <user>@localhost"
log_info "  - HTTPS: https://localhost:8443"
log_info "  - HTTP: http://localhost:8080"
log_info ""
log_info "Press Ctrl+C to stop VMs and cleanup the bridge"

exit $?
