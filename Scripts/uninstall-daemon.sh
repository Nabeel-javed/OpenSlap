#!/bin/bash
# uninstall-daemon.sh — Remove the OpenSlap sensor daemon
#
# Stops the daemon, removes the binary and plist, and cleans up.
# Must be run with sudo.

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

DAEMON_LABEL="com.openslap.daemon"
DAEMON_PLIST="/Library/LaunchDaemons/${DAEMON_LABEL}.plist"
DAEMON_BIN="/usr/local/bin/OpenSlapDaemon"
SOCKET_PATH="/var/run/openslap.sock"
LOG_PATH="/var/log/openslap-daemon.log"

echo "╔══════════════════════════════════════╗"
echo "║  OpenSlap Daemon Uninstaller         ║"
echo "╚══════════════════════════════════════╝"
echo ""

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Error: This script must be run with sudo.${NC}"
    echo "Usage: sudo ./Scripts/uninstall-daemon.sh"
    exit 1
fi

# Stop daemon
if launchctl list "$DAEMON_LABEL" &>/dev/null; then
    echo "Stopping daemon..."
    launchctl unload "$DAEMON_PLIST" 2>/dev/null || true
fi

# Remove files
echo "Removing files..."
rm -f "$DAEMON_BIN"
rm -f "$DAEMON_PLIST"
rm -f "$SOCKET_PATH"
rm -f "$LOG_PATH"

echo ""
echo -e "${GREEN}OpenSlap daemon uninstalled.${NC}"
echo ""
echo "The app's settings and stats are preserved in UserDefaults."
echo "To remove those too: defaults delete com.openslap.app"
