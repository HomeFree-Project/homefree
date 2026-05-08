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
Usage: $SCRIPT_NAME <subcommand> [options]

HomeFree VM testing — build installer images and boot them in QEMU.

Subcommands:
  build       Build an installer image (delegates to build-image.sh).
  run         Boot a built image in QEMU. (default if no subcommand given)
  clean       Remove built images and VM state.

Run '$SCRIPT_NAME <subcommand> --help' for subcommand-specific options.
EOF
}

usage_build() {
    cat << EOF
Usage: $SCRIPT_NAME build [OPTIONS] [CONFIG_NAME]

Build a HomeFree installer image. Thin wrapper around ./scripts/build-image.sh.

Options:
  -q, --qcow2               Build a qcow2 image instead of an ISO.
  -f, --flake-dir DIR       Flake directory (default: current directory).
  -o, --output-dir DIR      Output directory (default: ./build in flake dir).
  -h, --help                Show this help.

Examples:
  $SCRIPT_NAME build                  # builds homefree-installer.iso
  $SCRIPT_NAME build --qcow2          # builds homefree-installer.qcow2
EOF
}

usage_run() {
    cat << EOF
Usage: $SCRIPT_NAME run [OPTIONS]

Boot a HomeFree installer ISO in QEMU.

Defaults: user-mode networking + virtiofs source share (so the wizard's
"Development mode" works out of the box).

Networking modes:
  Default:        Two user-mode NICs with host port-forwards on
                  2223/8000/8443/8080/9090. Lighter weight, no root needed
                  for bridge setup. Use this when you only need to drive the
                  web installer UI.
  --bridge:       Bridge networking (router-style; ISO + 2 NICs on hfbr0).
                  Required if you want to test the installed router or
                  combine with --lan-client. Implied by --lan-client.

Source-tree sharing (development mode):
  Default:        Source tree is mounted into the VM via virtiofs (tag
                  'mount_homefree_source'). Required for the "Development
                  mode" checkbox in the wizard.
  --no-dev:       Skip the source share. Pass this if you don't have
                  virtiofsd installed or specifically want to test a clean
                  non-dev installation.

Options:
  -i, --iso PATH            Path to ISO (default: auto-detect in build/).
  -m, --memory MB           VM memory (default: 8192).
  -c, --cores N             CPU cores (default: 4).
  -d, --disk-size SIZE      Disk size for fresh installs (default: 50G).
      --bridge              Use bridge networking instead of user-mode.
      --no-dev              Disable the virtiofs source share.
  -v, --virtviewer          QXL/SPICE + remote-viewer (clipboard).
      --headless            SPICE server only, no viewer.
  -k, --kvm / -K, --no-kvm  Force KVM on/off (default: auto-detect).
  -U, --no-uefi             Use legacy BIOS instead of UEFI.
  -l, --lan-client          Also launch a lan-client VM (implies --bridge).
  -B, --build-dir DIR       Where to find ISOs (default: ./build).
  -S, --state-dir DIR       Where to store VM disks (default: ./vm-state).
  -h, --help                Show this help.

Environment variables: FLAKE_DIR, VM_MEMORY, VM_CORES, VM_DISK_SIZE,
BUILD_DIR, VM_STATE_DIR.

Examples:
  $SCRIPT_NAME run                        # user-mode + dev (default)
  $SCRIPT_NAME run --no-dev               # user-mode, no source share
  $SCRIPT_NAME run --bridge               # router topology + dev share
  $SCRIPT_NAME run --bridge --no-dev      # clean router install test
  $SCRIPT_NAME run -l                     # bridge + lan-client VM
EOF
}

usage_clean() {
    cat << EOF
Usage: $SCRIPT_NAME clean

Remove built images and VM state. Removes:
  - \$BUILD_DIR/*.iso, \$BUILD_DIR/*.qcow2, \$BUILD_DIR/lan-client*
  - \$VM_STATE_DIR/* (VM disks, UEFI VARS, virtiofs sockets)
  - \$FLAKE_DIR/result-installer
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

cmd_build() {
    # Pass everything through to build-image.sh. The flag spelling is the same.
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                usage_build
                exit 0
                ;;
            *) break ;;
        esac
    done
    exec "$SCRIPT_DIR/build-image.sh" "$@"
}

cmd_clean() {
    if [[ $# -gt 0 ]]; then
        case "$1" in
            -h|--help)
                usage_clean
                exit 0
                ;;
            *)
                log_error "Unknown argument: $1"
                usage_clean
                exit 1
                ;;
        esac
    fi

    FLAKE_DIR=$(realpath "$FLAKE_DIR")
    BUILD_DIR=$(realpath -m "$BUILD_DIR")
    VM_STATE_DIR=$(realpath -m "$VM_STATE_DIR")

    log_info "Cleaning $BUILD_DIR"
    rm -f "$BUILD_DIR"/*.iso "$BUILD_DIR"/*.qcow2 2>/dev/null || true
    rm -rf "$BUILD_DIR"/lan-client* 2>/dev/null || true

    log_info "Cleaning $VM_STATE_DIR"
    rm -rf "$VM_STATE_DIR" 2>/dev/null || true

    log_info "Cleaning $FLAKE_DIR/result-installer"
    rm -rf "$FLAKE_DIR/result-installer" 2>/dev/null || true

    log_success "Clean complete"
}

cmd_run() {
    # Parse command line arguments. Defaults: user-mode networking + virtiofs
    # source share. Pass --bridge to opt into router topology and --no-dev to
    # disable the source share.
    local ISO_PATH=""
    local USE_KVM=""
    local LAUNCH_LAN_CLIENT=false
    local USE_BRIDGE=false
    local USE_DEV=true
    local VIRTIOFSD_PID=""

    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                usage_run
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
            --bridge)
                USE_BRIDGE=true
                shift
                ;;
            --no-dev)
                USE_DEV=false
                shift
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
            -l|--lan-client)
                LAUNCH_LAN_CLIENT=true
                USE_BRIDGE=true
                shift
                ;;
            -*)
                log_error "Unknown option: $1"
                usage_run
                exit 1
                ;;
            *)
                log_error "Unknown argument: $1"
                usage_run
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

    if [[ "$USE_DEV" == "true" ]] && ! command -v virtiofsd &> /dev/null; then
        log_error "virtiofsd not found in PATH (required for the default source share)."
        log_error "Install virtiofsd, or pass --no-dev to skip the source share."
        exit 1
    fi

    # Ensure directories are absolute paths
    FLAKE_DIR=$(realpath "$FLAKE_DIR")
    BUILD_DIR=$(realpath -m "$BUILD_DIR")
    VM_STATE_DIR=$(realpath -m "$VM_STATE_DIR")

    # Create necessary directories
    mkdir -p "$BUILD_DIR"
    mkdir -p "$VM_STATE_DIR"

    # User-mode networking is the default; --bridge opts into router topology
    local BRIDGE_NAME=""
    local QEMU_BRIDGE_HELPER=""
    if [[ "$USE_BRIDGE" == "true" ]]; then
        BRIDGE_NAME="hfbr0"
        QEMU_BRIDGE_HELPER=$(which qemu-bridge-helper 2>/dev/null || echo "/usr/libexec/qemu-bridge-helper")
        if [[ ! -x "$QEMU_BRIDGE_HELPER" ]]; then
            log_error "qemu-bridge-helper not found or not executable"
            exit 1
        fi
        destroy_bridge "$BRIDGE_NAME"
        create_bridge "$BRIDGE_NAME"
    fi

    # Trap to cleanup on exit
    cleanup() {
        [[ -n "$VIRTIOFSD_PID" ]] && sudo kill "$VIRTIOFSD_PID" 2>/dev/null
        [[ -n "$BRIDGE_NAME" ]] && destroy_bridge "$BRIDGE_NAME"
    }
    trap cleanup EXIT INT TERM

    # Auto-detect ISO if not provided
    if [[ -z "$ISO_PATH" ]]; then
        log_info "Auto-detecting ISO in $BUILD_DIR..."
        ISO_CANDIDATES=$(find "$BUILD_DIR" -name "*.iso" 2>/dev/null || true)
        ISO_COUNT=$(echo "$ISO_CANDIDATES" | grep -c . || true)

        if [[ $ISO_COUNT -eq 0 ]]; then
            log_error "No ISO found in $BUILD_DIR"
            log_info "Build an ISO first with: $SCRIPT_NAME build"
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

    # Setup UEFI firmware
    local OVMF_CODE=""
    local ROUTER_OVMF_VARS="$VM_STATE_DIR/OVMF_VARS_router.fd"

    if [[ "$USE_UEFI" == "true" ]]; then
        log_info "Setting up UEFI boot..."

        # Resolve OVMF via the project's locked nixpkgs (flake input). This
        # actually realises the store path so the firmware is on disk before
        # QEMU references it. Falls back to system paths only if the flake
        # build fails (e.g. no network and not yet cached).
        local OVMF_FD=""
        if command -v nix &> /dev/null; then
            OVMF_FD=$(nix build --no-link --print-out-paths \
                --inputs-from "$FLAKE_DIR" \
                'nixpkgs#OVMF.fd' 2>/dev/null || true)
        fi

        local -a OVMF_CANDIDATES=()
        [[ -n "$OVMF_FD" ]] && OVMF_CANDIDATES+=("$OVMF_FD/FV/OVMF_CODE.fd")
        OVMF_CANDIDATES+=(
            "/run/current-system/sw/share/OVMF/OVMF_CODE.fd"
            "/usr/share/OVMF/OVMF_CODE.fd"
        )

        for code_path in "${OVMF_CANDIDATES[@]}"; do
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
            local OVMF_VARS_TEMPLATE="${OVMF_CODE/OVMF_CODE.fd/OVMF_VARS.fd}"
            if [[ ! -f "$OVMF_VARS_TEMPLATE" ]]; then
                log_warning "OVMF_VARS.fd not found next to $OVMF_CODE, disabling UEFI boot"
                USE_UEFI=false
            elif [[ ! -f "$ROUTER_OVMF_VARS" ]]; then
                cp --reflink=never "$OVMF_VARS_TEMPLATE" "$ROUTER_OVMF_VARS"
                chmod 644 "$ROUTER_OVMF_VARS"
                log_info "Created UEFI VARS file for router: $ROUTER_OVMF_VARS"
            fi
        fi
    fi

    # Router VM disk
    local ROUTER_DISK="$VM_STATE_DIR/homefree-test.qcow2"

    if [[ -f "$ROUTER_DISK" ]]; then
        local DISK_SIZE
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

    if [[ ! -f "$ROUTER_DISK" ]]; then
        log_info "Creating router VM disk: $ROUTER_DISK (size: $VM_DISK_SIZE)"
        qemu-img create -f qcow2 "$ROUTER_DISK" "$VM_DISK_SIZE"
    else
        log_info "Using existing router disk: $ROUTER_DISK"
    fi

    # Build router QEMU command
    local -a ROUTER_QEMU_CMD=(
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

    # Networking: user-mode (default, 2 NICs) or bridge (router topology)
    if [[ "$USE_BRIDGE" == "true" ]]; then
        log_info "Networking: bridge ($BRIDGE_NAME) + user (host port-forwards 2223/8000/8443/8080)"
        ROUTER_QEMU_CMD+=(
            -netdev user,id=net0,hostfwd=tcp::2223-:22,hostfwd=tcp::8443-:443,hostfwd=tcp::8080-:80,hostfwd=tcp::8000-:8000
            -device virtio-net-pci,netdev=net0,mac=52:54:00:12:34:56
            -netdev "bridge,br=$BRIDGE_NAME,id=net1,helper=$QEMU_BRIDGE_HELPER"
            -device virtio-net-pci,netdev=net1,mac=e6:c8:ff:09:76:88
        )
    else
        log_info "Networking: user-mode (2 NICs, host port-forwards 2223/8000/8443/8080/9090)"
        ROUTER_QEMU_CMD+=(
            -netdev user,id=wan,hostfwd=tcp::2223-:22,hostfwd=tcp::8000-:8000,hostfwd=tcp::8443-:443,hostfwd=tcp::8080-:80,hostfwd=tcp::9090-:9090
            -device virtio-net-pci,netdev=wan,mac=52:54:00:12:34:56
            -netdev user,id=lan
            -device virtio-net-pci,netdev=lan,mac=e6:c8:ff:09:76:88
        )
    fi

    # Graphics
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

    # Optional source-tree share via virtiofs (dev mode)
    if [[ "$USE_DEV" == "true" ]]; then
        local VIRTIOFS_SOCKET="$VM_STATE_DIR/vhostqemu.sock"
        rm -f "$VIRTIOFS_SOCKET"
        log_info "Starting virtiofsd daemon (sharing $FLAKE_DIR)..."
        sudo virtiofsd --socket-path="$VIRTIOFS_SOCKET" --shared-dir="$FLAKE_DIR" --cache=auto &
        VIRTIOFSD_PID=$!

        for _ in {1..30}; do
            if [[ -S "$VIRTIOFS_SOCKET" ]]; then
                log_success "virtiofsd ready"
                break
            fi
            sleep 0.1
        done

        sudo chown "$USER" "$VIRTIOFS_SOCKET"

        ROUTER_QEMU_CMD+=(
            -chardev socket,id=char0,path="$VIRTIOFS_SOCKET"
            -device vhost-user-fs-pci,queue-size=1024,chardev=char0,tag=mount_homefree_source
            -object memory-backend-file,id=mem,size="${VM_MEMORY}M",mem-path=/dev/shm,share=on
            -numa node,memdev=mem
        )
    else
        log_info "Source share: disabled (--no-dev). Wizard 'Development mode' will fail."
    fi

    # Launch router VM
    log_info "Launching router VM..."
    log_info "  ISO: $ISO_PATH"
    log_info "  Disk: $ROUTER_DISK"
    log_info "  Memory: ${VM_MEMORY}MB"
    log_info "  Cores: $VM_CORES"

    local ROUTER_PID
    if [[ "$USE_VIRTVIEWER" == "true" ]] || [[ "$USE_HEADLESS" == "true" ]]; then
        "${ROUTER_QEMU_CMD[@]}" &
        ROUTER_PID=$!

        log_info "Waiting for SPICE server to start..."
        for _ in {1..30}; do
            if ss -tln | grep -q ":5900"; then
                log_info "SPICE server ready"
                break
            fi
            sleep 0.5
        done

        if [[ "$USE_VIRTVIEWER" == "true" ]]; then
            log_info "Launching remote-viewer for router..."
            remote-viewer spice://localhost:5900 &
        else
            log_info "Running in headless mode - SPICE server available at localhost:5900"
        fi
    else
        "${ROUTER_QEMU_CMD[@]}" &
        ROUTER_PID=$!
    fi

    # Optionally launch lan-client VM (bridge mode only)
    if [[ "$LAUNCH_LAN_CLIENT" == "true" ]]; then
        if [[ ! -e "$BUILD_DIR/lan-client-vm" ]]; then
            log_info "Building lan-client VM..."
            nix build "$FLAKE_DIR#nixosConfigurations.lan-client.config.system.build.vm" -o "$BUILD_DIR/lan-client-vm"
        fi

        local CLIENT_DISK="$BUILD_DIR/lan-client.qcow2"

        log_info "Launching lan-client VM..."
        export NIX_DISK_IMAGE="$CLIENT_DISK"
        export QEMU_OPTS="-netdev bridge,br=$BRIDGE_NAME,id=net0,helper=$QEMU_BRIDGE_HELPER -device virtio-net-pci,netdev=net0,mac=e6:c8:ff:09:76:89"

        if [[ "$USE_VIRTVIEWER" == "true" ]] || [[ "$USE_HEADLESS" == "true" ]]; then
            QEMU_OPTS="$QEMU_OPTS -device qxl-vga -spice port=5901,addr=127.0.0.1,disable-ticketing=on"
        else
            QEMU_OPTS="$QEMU_OPTS -device virtio-vga-gl -display sdl,gl=on"
        fi

        "$BUILD_DIR/lan-client-vm/bin/run-lan-client-vm" &
        local CLIENT_PID=$!

        if [[ "$USE_VIRTVIEWER" == "true" ]]; then
            sleep 2
            log_info "Launching remote-viewer for lan-client..."
            remote-viewer spice://localhost:5901 &
        elif [[ "$USE_HEADLESS" == "true" ]]; then
            log_info "LAN client running in headless mode - SPICE server available at localhost:5901"
        fi

        log_success "Both VMs launched successfully!"
        log_info "LAN Client VM PID: $CLIENT_PID"

        wait $ROUTER_PID $CLIENT_PID
    else
        log_success "Router VM launched successfully!"
        log_info "Router VM PID: $ROUTER_PID"

        wait $ROUTER_PID
    fi

    log_info ""
    log_info "Router VM ports forwarded to host:"
    log_info "  - SSH: ssh -p 2223 <user>@localhost"
    log_info "  - HTTPS: https://localhost:8443"
    log_info "  - HTTP: http://localhost:8080"
    log_info "  - Web installer: http://localhost:8000"
    log_info ""
}

# Subcommand dispatch — accept `run-vm.sh` (no args), `run-vm.sh -*` (legacy
# flag-only invocation, treated as `run`), or an explicit subcommand.
SUBCOMMAND="run"
if [[ $# -gt 0 ]]; then
    case "$1" in
        build|run|clean)
            SUBCOMMAND="$1"
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        -*)
            # Legacy invocation like `run-vm.sh -i foo.iso`. Default to `run`.
            ;;
        *)
            log_error "Unknown subcommand: $1"
            usage
            exit 1
            ;;
    esac
fi

case "$SUBCOMMAND" in
    build) cmd_build "$@" ;;
    clean) cmd_clean "$@" ;;
    run)   cmd_run "$@" ;;
esac
