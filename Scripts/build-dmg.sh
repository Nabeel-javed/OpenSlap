#!/bin/bash
# build-dmg.sh — Build, ad-hoc sign, and package OpenSlap into a DMG
#
# Usage:
#   ./Scripts/build-dmg.sh
#
# Output:
#   dist/OpenSlap-0.1.0.dmg
#
# No Apple Developer account required — uses ad-hoc signing.

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
DIST_DIR="$PROJECT_DIR/dist"
BUILD_DIR="$PROJECT_DIR/build"
APP_NAME="OpenSlap"
DAEMON_NAME="OpenSlapDaemon"
VERSION="0.1.0"
DMG_NAME="${APP_NAME}-${VERSION}"
DMG_PATH="$DIST_DIR/${DMG_NAME}.dmg"
VOLUME_NAME="OpenSlap"
STAGING_DIR="$DIST_DIR/staging"

echo ""
echo -e "${BOLD}╔══════════════════════════════════════╗${NC}"
echo -e "${BOLD}║  OpenSlap DMG Builder                ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════╝${NC}"
echo ""

# ─────────────────────────────────────────────
# Preflight checks
# ─────────────────────────────────────────────

# Check architecture
ARCH=$(uname -m)
if [ "$ARCH" != "arm64" ]; then
    echo -e "${RED}Error: OpenSlap requires Apple Silicon (arm64).${NC}"
    echo "Detected: $ARCH"
    exit 1
fi

# Check for xcodebuild
if ! command -v xcodebuild &>/dev/null; then
    echo -e "${RED}Error: Xcode command line tools not found.${NC}"
    echo "Install with: xcode-select --install"
    exit 1
fi

# Check for xcodegen
if ! command -v xcodegen &>/dev/null; then
    echo -e "${RED}Error: XcodeGen not found.${NC}"
    echo "Install with: brew install xcodegen"
    exit 1
fi

# ─────────────────────────────────────────────
# Step 1: Generate Xcode project
# ─────────────────────────────────────────────
echo -e "${CYAN}[1/6] Generating Xcode project...${NC}"
cd "$PROJECT_DIR"
xcodegen generate --quiet 2>/dev/null || xcodegen generate
echo -e "  ${GREEN}✓${NC} Xcode project generated"

# ─────────────────────────────────────────────
# Step 2: Build Release targets
# ─────────────────────────────────────────────
echo -e "${CYAN}[2/6] Building Release targets...${NC}"

xcodebuild \
    -project "$PROJECT_DIR/OpenSlap.xcodeproj" \
    -target "$DAEMON_NAME" \
    -configuration Release \
    CONFIGURATION_BUILD_DIR="$BUILD_DIR" \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGNING_ALLOWED=YES \
    build 2>&1 | tail -3

echo -e "  ${GREEN}✓${NC} $DAEMON_NAME built"

xcodebuild \
    -project "$PROJECT_DIR/OpenSlap.xcodeproj" \
    -target "$APP_NAME" \
    -configuration Release \
    CONFIGURATION_BUILD_DIR="$BUILD_DIR" \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGNING_ALLOWED=YES \
    build 2>&1 | tail -3

echo -e "  ${GREEN}✓${NC} $APP_NAME.app built"

# Verify build products exist
if [ ! -d "$BUILD_DIR/$APP_NAME.app" ]; then
    echo -e "${RED}Error: $APP_NAME.app not found in $BUILD_DIR${NC}"
    exit 1
fi

if [ ! -f "$BUILD_DIR/$DAEMON_NAME" ]; then
    echo -e "${RED}Error: $DAEMON_NAME not found in $BUILD_DIR${NC}"
    exit 1
fi

# ─────────────────────────────────────────────
# Step 3: Ad-hoc code sign (bottom-up)
# ─────────────────────────────────────────────
echo -e "${CYAN}[3/6] Ad-hoc code signing...${NC}"

# Sign daemon binary
codesign --force --sign - --timestamp=none "$BUILD_DIR/$DAEMON_NAME"
echo -e "  ${GREEN}✓${NC} Signed $DAEMON_NAME"

# Sign app binary inside bundle
codesign --force --sign - --timestamp=none \
    --entitlements "$PROJECT_DIR/OpenSlap/OpenSlap.entitlements" \
    "$BUILD_DIR/$APP_NAME.app"
echo -e "  ${GREEN}✓${NC} Signed $APP_NAME.app"

# Verify signatures
codesign --verify --verbose "$BUILD_DIR/$APP_NAME.app" 2>&1 | head -3
echo -e "  ${GREEN}✓${NC} Signatures verified"

# ─────────────────────────────────────────────
# Step 4: Prepare staging area
# ─────────────────────────────────────────────
echo -e "${CYAN}[4/6] Preparing DMG contents...${NC}"

rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"

# Copy app bundle
cp -R "$BUILD_DIR/$APP_NAME.app" "$STAGING_DIR/"

# Copy daemon binary
mkdir -p "$STAGING_DIR/Extras"
cp "$BUILD_DIR/$DAEMON_NAME" "$STAGING_DIR/Extras/"

# Copy install/uninstall scripts
cp "$PROJECT_DIR/Scripts/install-daemon.sh" "$STAGING_DIR/Extras/"
cp "$PROJECT_DIR/Scripts/uninstall-daemon.sh" "$STAGING_DIR/Extras/"
chmod +x "$STAGING_DIR/Extras/"*.sh

# Copy daemon plist for the installer script
cp "$PROJECT_DIR/OpenSlapDaemon/com.openslap.daemon.plist" "$STAGING_DIR/Extras/"

# Create a symlink to /Applications for drag-and-drop install
ln -s /Applications "$STAGING_DIR/Applications"

# Create README for the DMG
cat > "$STAGING_DIR/READ ME FIRST.txt" << 'README'
╔══════════════════════════════════════════════════════╗
║               OpenSlap — Installation                ║
╚══════════════════════════════════════════════════════╝

STEP 1: Install the App
  Drag "OpenSlap.app" into the "Applications" folder.

STEP 2: Install the Daemon (required for accelerometer)
  Open Terminal and run:
    sudo /Applications/OpenSlap.app/../Extras/install-daemon.sh

  Or from the DMG directly:
    cd /Volumes/OpenSlap/Extras
    sudo ./install-daemon.sh

STEP 3: Open the App
  Since this app is not notarized by Apple, macOS will block it
  on first launch. To open it:

  macOS Sequoia (15+):
    1. Double-click OpenSlap — it will be blocked
    2. Go to System Settings → Privacy & Security
    3. Scroll down and click "Open Anyway" next to OpenSlap
    4. Enter your password

  macOS Sonoma (14):
    1. Right-click (or Control-click) OpenSlap.app
    2. Click "Open" from the menu
    3. Click "Open" again in the dialog

  You only need to do this ONCE. After that it opens normally.

─────────────────────────────────────────────────────────
  OpenSlap — Slap your MacBook, hear the impact.
  https://github.com/openslap
─────────────────────────────────────────────────────────
README

echo -e "  ${GREEN}✓${NC} Staging area ready"

# ─────────────────────────────────────────────
# Step 5: Create DMG
# ─────────────────────────────────────────────
echo -e "${CYAN}[5/6] Creating DMG...${NC}"

mkdir -p "$DIST_DIR"
rm -f "$DMG_PATH"

# Create compressed DMG
hdiutil create \
    -volname "$VOLUME_NAME" \
    -srcfolder "$STAGING_DIR" \
    -ov \
    -format UDZO \
    -imagekey zlib-level=9 \
    "$DMG_PATH" 2>&1 | grep -v "^$"

echo -e "  ${GREEN}✓${NC} DMG created"

# ─────────────────────────────────────────────
# Step 6: Sign the DMG itself
# ─────────────────────────────────────────────
echo -e "${CYAN}[6/6] Signing DMG...${NC}"

codesign --force --sign - "$DMG_PATH"
echo -e "  ${GREEN}✓${NC} DMG signed"

# Clean up staging
rm -rf "$STAGING_DIR"

# ─────────────────────────────────────────────
# Done!
# ─────────────────────────────────────────────

DMG_SIZE=$(du -h "$DMG_PATH" | cut -f1 | xargs)

echo ""
echo -e "${GREEN}════════════════════════════════════════${NC}"
echo -e "${GREEN}  DMG built successfully!${NC}"
echo -e "${GREEN}════════════════════════════════════════${NC}"
echo ""
echo -e "  ${BOLD}File:${NC}    $DMG_PATH"
echo -e "  ${BOLD}Size:${NC}    $DMG_SIZE"
echo -e "  ${BOLD}Signing:${NC} Ad-hoc (no Apple Developer ID)"
echo ""
echo -e "  ${YELLOW}Note:${NC} Users will need to allow the app in"
echo -e "  System Settings → Privacy & Security on first launch."
echo ""
