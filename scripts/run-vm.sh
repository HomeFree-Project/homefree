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
# Number of data disks to attach. 1 = single-disk install; 2+ lets the
# installer set up a btrfs RAID. Defaults to 2 so RAID is testable out
# of the box; override with --disks N (or -n 1 for a single-disk test).
VM_DISKS="${VM_DISKS:-2}"
# Extra (non-install) data disks for testing post-install storage flows —
# creating btrfs/RAID volumes, encryption, reclaim — without consuming the
# install disks. Defaults to 5 so the Storage admin module has enough drives
# out of the box to exercise every layout (raid1, raid10, raid5, raid6).
# Attached without bootindex so they don't interfere with the boot order;
# the installer ignores them. Set EXTRA_DISKS=0 to skip them entirely.
EXTRA_DISKS="${EXTRA_DISKS:-5}"
EXTRA_DISK_SIZE="${EXTRA_DISK_SIZE:-8G}"
# Emulated TPM2 (swtpm). Needed to test unattended LUKS auto-unlock.
# Enabled by default; pass --no-tpm to test the passphrase-at-boot path.
USE_TPM="${USE_TPM:-true}"

# Script-scope state for the cleanup trap (see note below).
SWTPM_PID=""

# Script-scope state used by the cleanup trap. These must NOT be `local` to
# cmd_run: when set -e aborts cmd_run, the function returns first and only
# then does the EXIT trap fire — by which point any locals are out of scope
# and `set -u` would make the trap blow up before it can kill virtiofsd.
VIRTIOFSD_PID=""
BRIDGE_NAME=""

# Host's address on the LAN bridge (set by attach_host_to_bridge when --bridge
# is used) so the installed box's LAN-only admin/finish-setup UI is reachable
# natively from the host browser. The box is always .1; the host takes .2.
# Script-scope so the cleanup trap and the launch summary can read them.
HOST_LAN_IP=""
BOX_LAN_IP=""

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

Defaults: bridge networking (host joins the LAN) + virtiofs source share
(so the wizard's "Development mode" works out of the box).

Networking modes:
  Default:        Bridge networking (router-style; ISO + 2 NICs on hfbr0).
                  net0 is user-mode WAN with host port-forwards on
                  2223/8000/8443/8080; net1 is the LAN, bridged on hfbr0.
                  The host also gets a LAN address on hfbr0 (10.1.2.2 in
                  dev mode, 10.0.0.2 otherwise) so the box's LAN-only
                  admin/finish-setup UI is reachable natively at
                  http://10.1.2.1 — no SOCKS proxy. With systemd-resolved
                  active, *.<domain> SSO hostnames also resolve via the box
                  (set HOMEFREE_DOMAIN for a non-default domain). Needs
                  qemu-bridge-helper + 'allow hfbr0' in /etc/qemu/bridge.conf
                  and sudo; if the helper is missing it falls back to
                  user-mode with a warning.
  --no-bridge:    Two user-mode NICs with host port-forwards on
                  2223/8000/8443/8080/9090. Lighter weight, no root needed
                  for bridge setup, but the box's LAN-only UI (10.1.2.1) is
                  NOT reachable from the host. Use when you only need to
                  drive the web installer UI.

Source-tree sharing (development mode):
  Default:        Source tree is mounted into the VM via virtiofs (tag
                  'mount_homefree_source'). Required for the "Development
                  mode" checkbox in the wizard.
  --no-dev:       Skip the source share. Pass this if you don't have
                  virtiofsd installed or specifically want to test a clean
                  non-dev installation.

Disk encryption testing:
  Default:        2 data disks + an emulated TPM2 (swtpm), so btrfs RAID
                  and unattended LUKS auto-unlock are testable out of the
                  box. Needs UEFI (the default) and 'swtpm' in PATH.
  --no-tpm:       Skip the emulated TPM2 — exercises the passphrase-at-
                  boot path (LUKS defaults off in the wizard with no TPM).
  --disks N:      Attach N data disks (default 2). Use -n 1 for a
                  single-disk install test.

Options:
  -i, --iso PATH            Path to ISO (default: auto-detect in build/).
  -m, --memory MB           VM memory (default: 8192).
  -c, --cores N             CPU cores (default: 4).
  -d, --disk-size SIZE      Disk size for fresh installs (default: 50G).
  -n, --disks N             Number of data disks to attach (default: 2).
  -e, --extra-disks N       Extra non-install data disks for testing
                            post-install storage flows (default: 5; pass 0
                            to skip). Attached without bootindex; installer
                            ignores them.
      --extra-disk-size SZ  Size for each extra disk (default: 8G).
      --tpm / --no-tpm      Emulated TPM2 on/off (default: on).
      --bridge              Bridge networking (the default; host joins the
                            LAN bridge for native http://10.1.2.1 access).
      --no-bridge           User-mode networking instead of bridge. Lighter,
                            no root/ACL needed, but no native LAN-UI access.
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
VM_DISKS, EXTRA_DISKS, EXTRA_DISK_SIZE, USE_TPM, BUILD_DIR, VM_STATE_DIR.

Examples:
  $SCRIPT_NAME run                        # bridge + 2 install + 5 extra + TPM2 + dev
  $SCRIPT_NAME run -n 1                   # single-disk install test
  $SCRIPT_NAME run --no-tpm               # passphrase-at-boot path
  $SCRIPT_NAME run --no-dev               # no source share
  $SCRIPT_NAME run --no-bridge            # user-mode networking (no native LAN UI)
  $SCRIPT_NAME run -l                     # bridge + lan-client VM
  $SCRIPT_NAME run --extra-disks 0        # skip the Storage-test scratch disks
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
        # Drop any per-link resolved DNS we set in attach_host_to_bridge
        # before deleting the link. No-op if resolved isn't present or we
        # never set anything; deleting the link would clear it anyway, but
        # reverting explicitly keeps stale config from lingering on a crash.
        if command -v resolvectl &> /dev/null; then
            sudo resolvectl revert "$bridge_name" 2> /dev/null || true
        fi
        sudo ip link set "$bridge_name" down
        sudo ip link delete "$bridge_name"
        log_success "Bridge $bridge_name destroyed"
    fi
}

# Put the host on the LAN bridge so the installed box's LAN-only
# admin/finish-setup UI (Caddy binds it to <box-lan>:80, e.g.
# http://10.1.2.1 — see services/admin-web/default.nix `extra-http-hosts`)
# is reachable natively from the host browser, with no SOCKS proxy.
#
# The LAN subnet must match what the installer baked into the box's config:
# a dev install uses 10.1.2.0/24, a non-dev router install 10.0.0.0/24 (see
# web-platform/backend/services/install.py). The box is always .1; the host
# takes .2 — clear of the box and of the .100-.200 DHCP pool dnsmasq serves.
attach_host_to_bridge() {
    local bridge_name="$1"
    local use_dev="$2"

    local lan_net
    if [[ "$use_dev" == "true" ]]; then
        lan_net="10.1.2"
    else
        lan_net="10.0.0"
    fi
    HOST_LAN_IP="$lan_net.2"
    BOX_LAN_IP="$lan_net.1"

    log_info "Assigning host $HOST_LAN_IP/24 on $bridge_name (LAN client of the box at $BOX_LAN_IP)"
    # `addr replace` is idempotent: adds if missing, replaces a stale copy.
    sudo ip addr replace "$HOST_LAN_IP/24" dev "$bridge_name"

    # Point DNS for the HomeFree domain at the box's resolver, scoped to the
    # bridge link so the host's normal DNS is untouched — this is what makes
    # the post-setup *.<domain> SSO vhosts (auth./admin.) resolve to the box.
    # Best-effort: only when systemd-resolved is the host's active resolver.
    # The domain defaults to the installer default; override with
    # HOMEFREE_DOMAIN=<your-domain> for a custom domain.
    local hf_domain="${HOMEFREE_DOMAIN:-homefree.host}"
    if command -v resolvectl &> /dev/null && systemctl is-active --quiet systemd-resolved; then
        log_info "Routing *.$hf_domain DNS to the box ($BOX_LAN_IP) via $bridge_name (systemd-resolved)"
        sudo resolvectl dns "$bridge_name" "$BOX_LAN_IP" 2> /dev/null || true
        sudo resolvectl domain "$bridge_name" "~$hf_domain" 2> /dev/null || true
    else
        log_warning "systemd-resolved not active on the host — *.$hf_domain won't auto-resolve."
        log_warning "To reach SSO hostnames, add e.g. '$BOX_LAN_IP auth.$hf_domain' to /etc/hosts,"
        log_warning "or point your resolver at $BOX_LAN_IP. (http://$BOX_LAN_IP works regardless.)"
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
    # Parse command line arguments. Defaults: bridge networking (host joins
    # the LAN so http://10.1.2.1 works natively) + virtiofs source share.
    # Pass --no-bridge for user-mode networking and --no-dev to disable the
    # source share.
    local ISO_PATH=""
    local USE_KVM=""
    local LAUNCH_LAN_CLIENT=false
    local USE_BRIDGE=true
    local USE_DEV=true

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
            -n|--disks)
                VM_DISKS="$2"
                shift 2
                ;;
            -e|--extra-disks)
                EXTRA_DISKS="$2"
                shift 2
                ;;
            --extra-disk-size)
                EXTRA_DISK_SIZE="$2"
                shift 2
                ;;
            --tpm)
                USE_TPM=true
                shift
                ;;
            --no-tpm)
                USE_TPM=false
                shift
                ;;
            --bridge)
                USE_BRIDGE=true
                shift
                ;;
            --no-bridge)
                USE_BRIDGE=false
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

    # --lan-client can't work without the bridge it attaches to. Catch an
    # explicit --no-bridge (or a --no-bridge that came after --lan-client on
    # the command line) rather than silently launching a stranded client VM.
    if [[ "$LAUNCH_LAN_CLIENT" == "true" && "$USE_BRIDGE" != "true" ]]; then
        log_error "--lan-client requires bridge networking; do not combine it with --no-bridge."
        exit 1
    fi

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

    # --disks must be a positive integer.
    if ! [[ "$VM_DISKS" =~ ^[1-9][0-9]*$ ]]; then
        log_error "--disks must be a positive integer (got: $VM_DISKS)"
        exit 1
    fi

    # --extra-disks must be a non-negative integer (0 = none).
    if ! [[ "$EXTRA_DISKS" =~ ^(0|[1-9][0-9]*)$ ]]; then
        log_error "--extra-disks must be a non-negative integer (got: $EXTRA_DISKS)"
        exit 1
    fi

    # --tpm needs the swtpm binary and UEFI firmware.
    if [[ "$USE_TPM" == "true" ]]; then
        if ! command -v swtpm &> /dev/null; then
            log_error "swtpm not found in PATH (required for --tpm)."
            log_error "Install swtpm, or drop --tpm to test passphrase-only unlock."
            exit 1
        fi
        if [[ "$USE_UEFI" != "true" ]]; then
            log_error "--tpm requires UEFI; do not combine it with --no-uefi."
            exit 1
        fi
    fi

    # Ensure directories are absolute paths
    FLAKE_DIR=$(realpath "$FLAKE_DIR")
    BUILD_DIR=$(realpath -m "$BUILD_DIR")
    VM_STATE_DIR=$(realpath -m "$VM_STATE_DIR")

    # Create necessary directories
    mkdir -p "$BUILD_DIR"
    mkdir -p "$VM_STATE_DIR"

    # Bridge networking is the default (host joins the LAN so http://10.1.2.1
    # works natively); --no-bridge opts into user-mode. Bridge mode needs a
    # usable qemu-bridge-helper (setuid root + 'allow hfbr0' in the helper's
    # ACL). If it's missing we degrade to user-mode with a loud warning rather
    # than hard-failing a bare `run` — except under --lan-client, which the
    # validation above already requires bridge for.
    local QEMU_BRIDGE_HELPER=""
    if [[ "$USE_BRIDGE" == "true" ]]; then
        QEMU_BRIDGE_HELPER=$(which qemu-bridge-helper 2>/dev/null || echo "/usr/libexec/qemu-bridge-helper")
        if [[ ! -x "$QEMU_BRIDGE_HELPER" ]]; then
            if [[ "$LAUNCH_LAN_CLIENT" == "true" ]]; then
                log_error "qemu-bridge-helper not found or not executable, but --lan-client needs bridge networking."
                log_error "Install/enable qemu-bridge-helper and add 'allow hfbr0' to its ACL (e.g. /etc/qemu/bridge.conf)."
                exit 1
            fi
            log_warning "qemu-bridge-helper not found or not executable — falling back to user-mode networking."
            log_warning "The box's LAN-only UI (http://10.1.2.1) will NOT be reachable from the host in this mode."
            log_warning "To use bridge mode, enable qemu-bridge-helper and add 'allow hfbr0' to its ACL"
            log_warning "(e.g. /etc/qemu/bridge.conf), then re-run. Pass --no-bridge to silence this."
            USE_BRIDGE=false
        fi
    fi
    if [[ "$USE_BRIDGE" == "true" ]]; then
        BRIDGE_NAME="hfbr0"
        destroy_bridge "$BRIDGE_NAME"
        create_bridge "$BRIDGE_NAME"
        attach_host_to_bridge "$BRIDGE_NAME" "$USE_DEV"
    fi

    # Trap to cleanup on exit. Uses socket-path matching rather than PID
    # because `sudo virtiofsd &` records sudo's PID in $!, not the daemon's,
    # and killing sudo doesn't take down the underlying virtiofsd children.
    cleanup() {
        if [[ -n "$VIRTIOFSD_PID" ]]; then
            local sock="$VM_STATE_DIR/vhostqemu.sock"
            sudo pkill -f "virtiofsd.*${sock}" 2>/dev/null || true
            sudo rm -f "$sock" "$sock.pid" 2>/dev/null || true
        fi
        if [[ -n "$SWTPM_PID" ]]; then
            kill "$SWTPM_PID" 2>/dev/null || true
        fi
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
        #
        # IMPORTANT: when --tpm is used we need a TPM2-capable OVMF build
        # (`OVMFFull`, which sets tpmSupport=true). Plain `OVMF` is built
        # WITHOUT TPM support, so its firmware never issues TPM2_Startup
        # and the guest kernel's TPM self-test fails with error 256
        # (TPM_RC_INITIALIZE). The non-Full system fallbacks are skipped
        # when --tpm is on for the same reason.
        local OVMF_FD=""
        local ovmf_attr='nixpkgs#OVMF.fd'
        [[ "$USE_TPM" == "true" ]] && ovmf_attr='nixpkgs#OVMFFull.fd'
        if command -v nix &> /dev/null; then
            OVMF_FD=$(nix build --no-link --print-out-paths \
                --inputs-from "$FLAKE_DIR" \
                "$ovmf_attr" 2>/dev/null || true)
        fi

        local -a OVMF_CANDIDATES=()
        [[ -n "$OVMF_FD" ]] && OVMF_CANDIDATES+=("$OVMF_FD/FV/OVMF_CODE.fd")
        # System-path OVMF builds are typically NOT TPM-capable; only use
        # them as a fallback when the TPM is not in play.
        if [[ "$USE_TPM" != "true" ]]; then
            OVMF_CANDIDATES+=(
                "/run/current-system/sw/share/OVMF/OVMF_CODE.fd"
                "/usr/share/OVMF/OVMF_CODE.fd"
            )
        fi

        for code_path in "${OVMF_CANDIDATES[@]}"; do
            if [[ -f "$code_path" ]]; then
                OVMF_CODE="$code_path"
                log_info "Found OVMF firmware: $OVMF_CODE"
                break
            fi
        done

        if [[ -z "$OVMF_CODE" ]]; then
            # With --tpm, UEFI is mandatory (the TPM needs OVMF to issue
            # TPM2_Startup), so a missing firmware is a hard error rather
            # than a silent downgrade.
            if [[ "$USE_TPM" == "true" ]]; then
                log_error "TPM-capable OVMF firmware (OVMFFull) not found."
                log_error "Build it with 'nix build nixpkgs#OVMFFull.fd', or"
                log_error "pass --no-tpm to run without an emulated TPM."
                exit 1
            fi
            log_warning "OVMF firmware not found, disabling UEFI boot"
            USE_UEFI=false
        else
            local OVMF_VARS_TEMPLATE="${OVMF_CODE/OVMF_CODE.fd/OVMF_VARS.fd}"
            if [[ ! -f "$OVMF_VARS_TEMPLATE" ]]; then
                log_warning "OVMF_VARS.fd not found next to $OVMF_CODE, disabling UEFI boot"
                USE_UEFI=false
            else
                # Stamp recording which OVMF build the VARS file was seeded
                # from. A persisted VARS file from one OVMF release fed to a
                # different OVMF_CODE.fd hangs the firmware at the TianoCore
                # splash, so if the host's OVMF changed (e.g. after a NixOS
                # rebuild) we must re-seed VARS from the matching template.
                # The stamp is a content hash of OVMF_CODE.fd so it catches
                # changes behind stable paths (/usr/share, /run/current-system)
                # as well as nix store path churn.
                local OVMF_STAMP="$ROUTER_OVMF_VARS.ovmf-code"
                local OVMF_CODE_HASH
                OVMF_CODE_HASH=$(sha256sum "$OVMF_CODE" | cut -d' ' -f1)

                if [[ ! -f "$ROUTER_OVMF_VARS" ]]; then
                    cp --reflink=never "$OVMF_VARS_TEMPLATE" "$ROUTER_OVMF_VARS"
                    chmod 644 "$ROUTER_OVMF_VARS"
                    printf '%s\n' "$OVMF_CODE_HASH" > "$OVMF_STAMP"
                    log_info "Created UEFI VARS file for router: $ROUTER_OVMF_VARS"
                elif [[ "$(cat "$OVMF_STAMP" 2>/dev/null || true)" != "$OVMF_CODE_HASH" ]]; then
                    log_warning "OVMF firmware changed since the VARS file was created."
                    log_warning "Re-seeding $ROUTER_OVMF_VARS from the matching template"
                    log_warning "to avoid a TianoCore boot hang (NVRAM boot entries reset)."
                    cp --reflink=never "$OVMF_VARS_TEMPLATE" "$ROUTER_OVMF_VARS"
                    chmod 644 "$ROUTER_OVMF_VARS"
                    printf '%s\n' "$OVMF_CODE_HASH" > "$OVMF_STAMP"
                fi
            fi
        fi
    fi

    # Router VM data disks. The first is homefree-test.qcow2 (kept for
    # backward compatibility); extras are homefree-test-2.qcow2, etc.
    local -a ROUTER_DISKS=()
    local d
    for (( d = 1; d <= VM_DISKS; d++ )); do
        if [[ $d -eq 1 ]]; then
            ROUTER_DISKS+=("$VM_STATE_DIR/homefree-test.qcow2")
        else
            ROUTER_DISKS+=("$VM_STATE_DIR/homefree-test-$d.qcow2")
        fi
    done

    # Extra (non-install) data disks: small qcow2s attached without bootindex
    # so the installer never picks them. Used to test post-install Storage
    # flows (Volume create, encryption, reclaim) without consuming the OS
    # disks. Named separately so the "delete existing disks" wipe prompt
    # below can keep them when only the install needs a fresh start, AND
    # so they survive an install-disk wipe so a pool can persist across
    # installer iterations.
    local -a EXTRA_DISK_PATHS=()
    local e
    for (( e = 1; e <= EXTRA_DISKS; e++ )); do
        EXTRA_DISK_PATHS+=("$VM_STATE_DIR/homefree-extra-$e.qcow2")
    done

    # If any INSTALL disk already exists, offer to wipe them all so the
    # installer runs from scratch (a stale disk would otherwise boot the
    # previously installed system instead of the ISO). Extras are wiped
    # by a SEPARATE prompt below — wiping the install when the user wants
    # to also blow away a test pool is a different decision, and the user
    # may want to keep the pool across re-installs.
    local existing=false
    for disk in "${ROUTER_DISKS[@]}"; do
        [[ -f "$disk" ]] && existing=true
    done
    if [[ "$existing" == "true" ]]; then
        log_warning "Existing virtual disk(s) found in $VM_STATE_DIR."
        log_warning "To test the installer from scratch they should be deleted."
        log_warning "Otherwise the VM may boot a previously installed system."
        echo ""
        read -p "Delete existing virtual disk(s) and start fresh? [y/N] " -n 1 -r
        echo ""
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            for disk in "${ROUTER_DISKS[@]}"; do
                rm -f "$disk" && log_success "Deleted: $disk"
            done
        else
            log_info "Keeping existing virtual disk(s)"
        fi
    fi

    # Separate prompt for extras so the user can keep a test pool around
    # across installer iterations (or wipe it when starting clean).
    local extras_existing=false
    for disk in "${EXTRA_DISK_PATHS[@]}"; do
        [[ -f "$disk" ]] && extras_existing=true
    done
    if [[ "$extras_existing" == "true" ]]; then
        log_warning "Existing extra disk(s) found (storage-test scratch)."
        echo ""
        read -p "Delete extra disk(s) and start fresh? [y/N] " -n 1 -r
        echo ""
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            for disk in "${EXTRA_DISK_PATHS[@]}"; do
                rm -f "$disk" && log_success "Deleted: $disk"
            done
        else
            log_info "Keeping existing extra disk(s)"
        fi
    fi

    # Track whether any disk was created fresh this run — either because it
    # didn't exist or because the user accepted the wipe prompt above. Drives
    # the OVMF VARS re-seed below: an installed system writes a UEFI BootOrder
    # NvVar into OVMF_VARS pointing at the bootloader on that disk, and UEFI
    # PREFERS that remembered BootOrder over QEMU's `-device …,bootindex=N`
    # hints. Leaving a stale BootOrder paired with a fresh-empty disk hangs at
    # the firmware "no bootable image" screen — the iso never gets a chance.
    # Re-seeding OVMF_VARS from the matching template clears the NvVar and
    # restores QEMU bootindex behavior (data-disk-0 first, iso second; empty
    # disk-0 falls through to the iso).
    local DISKS_FRESH=false
    for disk in "${ROUTER_DISKS[@]}"; do
        if [[ ! -f "$disk" ]]; then
            log_info "Creating VM disk: $disk (size: $VM_DISK_SIZE)"
            qemu-img create -f qcow2 "$disk" "$VM_DISK_SIZE"
            DISKS_FRESH=true
        else
            log_info "Using existing disk: $disk"
        fi
    done

    # Create any missing extras at the chosen size. We do NOT set DISKS_FRESH
    # for extras: the OVMF BootOrder hangs on install-disk replacement, not
    # extras (no bootloader ever lands on them).
    for disk in "${EXTRA_DISK_PATHS[@]}"; do
        if [[ ! -f "$disk" ]]; then
            log_info "Creating extra disk: $disk (size: $EXTRA_DISK_SIZE)"
            qemu-img create -f qcow2 "$disk" "$EXTRA_DISK_SIZE"
        else
            log_info "Using existing extra disk: $disk"
        fi
    done

    # Re-seed OVMF_VARS when any data disk is freshly created (see comment
    # above the loop for the BootOrder-stickiness rationale). Only relevant
    # when UEFI is in use and OVMF was discovered — the OVMF setup block
    # above will have left `OVMF_CODE` empty otherwise. The stamp file is
    # left in place: the firmware itself hasn't changed, only the disk it
    # used to point at, so the existing OVMF_CODE hash is still valid.
    if [[ "$DISKS_FRESH" == "true" && "$USE_UEFI" == "true" && -n "$OVMF_CODE" ]]; then
        local _OVMF_VARS_TEMPLATE="${OVMF_CODE/OVMF_CODE.fd/OVMF_VARS.fd}"
        if [[ -f "$_OVMF_VARS_TEMPLATE" && -f "$ROUTER_OVMF_VARS" ]]; then
            log_info "Re-seeding $ROUTER_OVMF_VARS (data disk(s) created fresh;"
            log_info "stale UEFI BootOrder would otherwise hang at the firmware screen)."
            cp --reflink=never "$_OVMF_VARS_TEMPLATE" "$ROUTER_OVMF_VARS"
            chmod 644 "$ROUTER_OVMF_VARS"
        fi
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

    # Attach each data disk. The first carries bootindex=0 so the
    # installed system boots from it; the ISO is bootindex=1.
    local disk_idx=0
    for disk in "${ROUTER_DISKS[@]}"; do
        local bootopt=""
        [[ $disk_idx -eq 0 ]] && bootopt=",bootindex=0"
        ROUTER_QEMU_CMD+=(
            -drive "file=$disk,format=qcow2,if=none,id=maindisk$disk_idx,cache=writeback,discard=unmap"
            -device "virtio-blk-pci,drive=maindisk$disk_idx$bootopt"
        )
        disk_idx=$(( disk_idx + 1 ))
    done
    ROUTER_QEMU_CMD+=(
        -drive "file=$ISO_PATH,if=none,id=cdrom,media=cdrom,readonly=on"
        -device "ide-cd,drive=cdrom,bootindex=1"
    )
    # NOTE: extra (non-install) data disks are appended AT THE VERY END of
    # the QEMU command (see end of cmd_run), after every other PCIe device.
    # QEMU's q35 auto-allocator assigns PCIe slots in command-line order, and
    # NixOS's predictable network interface names (enp<bus>s<slot>) derive
    # from those slots. Inserting more `-device virtio-blk-pci` here would
    # shift the NICs onto different slots, rename them, and silently break
    # an already-installed system whose homefree-config.json wan-/lan-
    # interface fields were baked in at install time. Adding them last keeps
    # NIC slots stable across any extra-disks count.

    # Emulated TPM2 via swtpm: start the daemon on a unix socket and
    # attach it as a tpm-tis device so the guest sees /dev/tpmrm0.
    #
    # The daemon must persist across guest *reboots* - QEMU drops and
    # re-opens the chardev each boot. So NO --terminate (that would make
    # swtpm exit on the first disconnect, breaking the second boot and
    # producing a TPM self-test error). swtpm keeps its state under
    # SWTPM_DIR, which is also what makes a TPM2-enrolled LUKS volume
    # still unlock after a reboot.
    if [[ "$USE_TPM" == "true" ]]; then
        local SWTPM_DIR="$VM_STATE_DIR/swtpm"
        local SWTPM_SOCK="$SWTPM_DIR/swtpm-sock"
        mkdir -p "$SWTPM_DIR"
        rm -f "$SWTPM_SOCK"

        # Initialise the TPM state on first use (idempotent: skipped if
        # state already exists from an earlier run, so enrolled keys
        # survive). swtpm_setup creates the EK/SRK and platform certs.
        if [[ ! -e "$SWTPM_DIR/tpm2-00.permall" ]]; then
            log_info "Initialising swtpm state..."
            swtpm_setup --tpmstate "$SWTPM_DIR" --tpm2 \
                --create-ek-cert --create-platform-cert --lock-nvram \
                2>/dev/null || log_warning "swtpm_setup reported issues (continuing)"
        fi

        log_info "Starting swtpm (emulated TPM2)..."
        swtpm socket --tpmstate "dir=$SWTPM_DIR" \
            --ctrl "type=unixio,path=$SWTPM_SOCK" \
            --tpm2 &
        SWTPM_PID=$!
        for _ in {1..30}; do
            [[ -S "$SWTPM_SOCK" ]] && break
            sleep 0.1
        done
        if [[ ! -S "$SWTPM_SOCK" ]]; then
            log_error "swtpm socket did not appear; aborting."
            exit 1
        fi
        log_success "swtpm ready"
        ROUTER_QEMU_CMD+=(
            -chardev "socket,id=chrtpm,path=$SWTPM_SOCK"
            -tpmdev "emulator,id=tpm0,chardev=chrtpm"
            -device "tpm-tis,tpmdev=tpm0"
        )
    fi

    # Networking: bridge (default, router topology) or user-mode (--no-bridge)
    if [[ "$USE_BRIDGE" == "true" ]]; then
        log_info "Networking: bridge ($BRIDGE_NAME; host $HOST_LAN_IP) + user (host port-forwards 2223/8000/8443/8080)"
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

    # Extra (non-install) data disks — ATTACHED LAST so the auto-allocated
    # PCIe slots for the network NICs (and every other device above) are
    # unaffected by the extras count. Predictable interface names (enp<bus>s<slot>)
    # are derived from those slots; baking them into homefree-config.json at
    # install time means a later disk-count change must not shift them or
    # systemd-networkd loses the match and the box boots with both NICs DOWN.
    # No bootindex on extras (installer + UEFI ignore them); serial=test-extra-N
    # gives them a stable /dev/disk/by-id path the Storage UI can show.
    local extra_idx=0
    for disk in "${EXTRA_DISK_PATHS[@]}"; do
        ROUTER_QEMU_CMD+=(
            -drive "file=$disk,format=qcow2,if=none,id=extradisk$extra_idx,cache=writeback,discard=unmap"
            -device "virtio-blk-pci,drive=extradisk$extra_idx,serial=test-extra-$((extra_idx + 1))"
        )
        extra_idx=$(( extra_idx + 1 ))
    done

    # Launch router VM
    log_info "Launching router VM..."
    log_info "  ISO: $ISO_PATH"
    log_info "  Disks: ${#ROUTER_DISKS[@]} (${ROUTER_DISKS[*]})"
    if (( ${#EXTRA_DISK_PATHS[@]} > 0 )); then
        log_info "  Extra disks: ${#EXTRA_DISK_PATHS[@]} × $EXTRA_DISK_SIZE (${EXTRA_DISK_PATHS[*]})"
    fi
    log_info "  TPM2: $USE_TPM"
    log_info "  Memory: ${VM_MEMORY}MB"
    log_info "  Cores: $VM_CORES"
    if [[ "$USE_BRIDGE" == "true" && -n "$BOX_LAN_IP" ]]; then
        log_info "  Box LAN UI (native): http://$BOX_LAN_IP  (finish-setup; ready once the install has booted)"
    fi

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
