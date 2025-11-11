#!/usr/bin/env bash
# Add SSH key to HomeFree VM
# This script copies your SSH public key to the VM for passwordless access

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Default values
PORT=2223
HOST="localhost"
USERNAME="${1:-erahhal}"

echo -e "${GREEN}Adding SSH key to HomeFree VM...${NC}"
echo "Host: $HOST:$PORT"
echo "Username: $USERNAME"
echo ""

# Clean up known_hosts for this host/port
echo -e "${YELLOW}Cleaning up old SSH host keys...${NC}"
ssh-keygen -R "[$HOST]:$PORT" 2>/dev/null || true

# Create .ssh directory on remote
echo -e "${YELLOW}Creating .ssh directory on remote...${NC}"
if ! ssh -p "$PORT" -o StrictHostKeyChecking=accept-new "$USERNAME@$HOST" "mkdir -p ~/.ssh && chmod 700 ~/.ssh" 2>/dev/null; then
    echo -e "${RED}Failed to create .ssh directory${NC}"
    echo "Make sure the VM is running and accessible at $HOST:$PORT"
    exit 1
fi

# Copy authorized_keys
echo -e "${YELLOW}Copying SSH authorized_keys...${NC}"
if ! scp -P "$PORT" -o StrictHostKeyChecking=accept-new ~/.ssh/authorized_keys "$USERNAME@$HOST:~/.ssh/" 2>/dev/null; then
    echo -e "${RED}Failed to copy authorized_keys${NC}"
    echo "Make sure ~/.ssh/authorized_keys exists on the host"
    exit 1
fi

# Set correct permissions on remote
echo -e "${YELLOW}Setting permissions on remote...${NC}"
ssh -p "$PORT" "$USERNAME@$HOST" "chmod 600 ~/.ssh/authorized_keys"

echo ""
echo -e "${GREEN}✓ SSH key added successfully!${NC}"
echo "You can now SSH with: ssh -p $PORT $USERNAME@$HOST"
