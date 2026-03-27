#!/bin/bash
# install-daemon.sh — Install the OpenSlap sensor daemon
#
# This script:
#   1. Copies the daemon binary to /usr/local/bin/
#   2. Installs the LaunchDaemon plist
#   3. Loads the daemon so it starts immediately
#
# Must be run with sudo.

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

DAEMON_LABEL="com.openslap.daemon"
DAEMON_PLIST="/Library/LaunchDaemons/${DAEMON_LABEL}.plist"
DAEMON_BIN="/usr/local/bin/OpenSlapDaemon"
SOCKET_PATH="/var/run/openslap.sock"

echo "╔══════════════════════════════════════╗"
echo "║  OpenSlap Daemon Installer           ║"
echo "╚══════════════════════════════════════╝"
echo ""

# Check root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Error: This script must be run with sudo.${NC}"
    echo "Usage: sudo ./Scripts/install-daemon.sh"
    exit 1
fi

# Check architecture
ARCH=$(uname -m)
if [ "$ARCH" != "arm64" ]; then
    echo -e "${RED}Error: OpenSlap requires Apple Silicon (arm64).${NC}"
    echo "Detected: $ARCH"
    exit 1
fi

# Find the daemon binary
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Look for the built daemon in common Xcode build locations
SEARCH_PATHS=(
    "$PROJECT_DIR/build/Release/OpenSlapDaemon"
    "$PROJECT_DIR/build/Debug/OpenSlapDaemon"
    "$PROJECT_DIR/.build/release/OpenSlapDaemon"
    "$PROJECT_DIR/.build/debug/OpenSlapDaemon"
    "$HOME/Library/Developer/Xcode/DerivedData/OpenSlap-*/Build/Products/Release/OpenSlapDaemon"
    "$HOME/Library/Developer/Xcode/DerivedData/OpenSlap-*/Build/Products/Debug/OpenSlapDaemon"
)

DAEMON_SOURCE=""
for path in "${SEARCH_PATHS[@]}"; do
    # Use glob expansion
    for expanded in $path; do
        if [ -f "$expanded" ]; then
            DAEMON_SOURCE="$expanded"
            break 2
        fi
    done
done

if [ -z "$DAEMON_SOURCE" ]; then
    echo -e "${RED}Error: Cannot find the built OpenSlapDaemon binary.${NC}"
    echo "Please build the project first:"
    echo "  xcodegen generate && xcodebuild -target OpenSlapDaemon -configuration Release"
    echo ""
    echo "Searched in:"
    for path in "${SEARCH_PATHS[@]}"; do
        echo "  $path"
    done
    exit 1
fi

echo -e "Found daemon binary: ${GREEN}$DAEMON_SOURCE${NC}"

# Stop existing daemon if running
if launchctl list "$DAEMON_LABEL" &>/dev/null; then
    echo -e "${YELLOW}Stopping existing daemon...${NC}"
    launchctl unload "$DAEMON_PLIST" 2>/dev/null || true
fi

# Clean up stale socket
rm -f "$SOCKET_PATH"

# Copy binary
echo "Installing daemon binary to $DAEMON_BIN..."
cp "$DAEMON_SOURCE" "$DAEMON_BIN"
chmod 755 "$DAEMON_BIN"
chown root:wheel "$DAEMON_BIN"

# Install plist
echo "Installing LaunchDaemon plist..."
cp "$PROJECT_DIR/OpenSlapDaemon/com.openslap.daemon.plist" "$DAEMON_PLIST"
chmod 644 "$DAEMON_PLIST"
chown root:wheel "$DAEMON_PLIST"

# Load and start
echo "Loading daemon..."
launchctl load "$DAEMON_PLIST"

# Verify
sleep 1
if launchctl list "$DAEMON_LABEL" &>/dev/null; then
    echo ""
    echo -e "${GREEN}OpenSlap daemon installed and running!${NC}"
    echo ""
    echo "The daemon is now reading the accelerometer."
    echo "Launch the OpenSlap app from your Applications folder."
    echo ""
    echo "Logs: /var/log/openslap-daemon.log"
    echo "To uninstall: sudo ./Scripts/uninstall-daemon.sh"
else
    echo ""
    echo -e "${RED}Warning: Daemon may not have started correctly.${NC}"
    echo "Check logs: cat /var/log/openslap-daemon.log"
fi
