#!/usr/bin/env bash

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Find the ISO
ISO=$(find ./result/iso -name "*.iso" 2>/dev/null | head -1)

if [ -z "$ISO" ]; then
    echo -e "${RED}[ERROR]${NC} No ISO found. build first."
    exit 1
fi

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  Booting HomeFree Installer ISO${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "${BLUE}ISO:${NC} $ISO"
echo ""

# Check for KVM support (same as run-vm.sh)
USE_KVM="false"
if [[ -e /dev/kvm ]]; then
    if [[ -r /dev/kvm ]] && [[ -w /dev/kvm ]]; then
        USE_KVM="true"
        echo -e "${GREEN}✓${NC} KVM acceleration available"
    else
        echo -e "${YELLOW}!${NC} KVM exists but not accessible. Add yourself to kvm group: sudo usermod -a -G kvm $USER"
    fi
else
    echo -e "${YELLOW}!${NC} KVM not available. VM will run slowly."
fi

# Build QEMU command with same structure as run-vm.sh
QEMU_CMD="qemu-system-x86_64"

# Memory and CPU (same defaults as run-vm.sh)
QEMU_CMD="$QEMU_CMD -m 4096 -smp 4"

# CPU settings based on KVM availability
if [[ "$USE_KVM" == "true" ]]; then
    QEMU_CMD="$QEMU_CMD -enable-kvm -cpu host"
else
    QEMU_CMD="$QEMU_CMD -cpu max"
fi

# Boot from CD-ROM
QEMU_CMD="$QEMU_CMD -cdrom $ISO -boot d"

# Display settings (auto-detect like run-vm.sh)
if [[ -n "$DISPLAY" ]]; then
    QEMU_CMD="$QEMU_CMD -display gtk,show-cursor=on"
    echo -e "${BLUE}Display:${NC} GTK window"
else
    QEMU_CMD="$QEMU_CMD -nographic"
    echo -e "${BLUE}Display:${NC} Serial console (use Ctrl-A X to exit)"
fi

# Network (in case installer needs it)
QEMU_CMD="$QEMU_CMD -netdev user,id=net0 -device e1000,netdev=net0"

echo ""
echo -e "${YELLOW}Starting QEMU...${NC}"
echo ""
echo -e "${BLUE}Command:${NC}"
echo "$QEMU_CMD"
echo ""

# Execute
exec $QEMU_CMD
