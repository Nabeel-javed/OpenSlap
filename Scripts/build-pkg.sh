#!/bin/bash
# build-pkg.sh — Build a macOS .pkg installer for OpenSlap
#
# Creates a native macOS installer that:
#   1. Installs OpenSlap.app to /Applications
#   2. Installs OpenSlapDaemon to /usr/local/bin
#   3. Installs LaunchDaemon plist
#   4. Loads the daemon automatically (postinstall)
#
# Usage:
#   ./Scripts/build-pkg.sh
#
# Output:
#   dist/OpenSlap-0.1.0.pkg

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
PKG_ROOT="$DIST_DIR/pkg-root"
PKG_SCRIPTS="$DIST_DIR/pkg-scripts"
APP_NAME="OpenSlap"
DAEMON_NAME="OpenSlapDaemon"
BUNDLE_ID="com.openslap.app"
VERSION="0.1.0"
PKG_PATH="$DIST_DIR/${APP_NAME}-${VERSION}.pkg"

echo ""
echo -e "${BOLD}╔══════════════════════════════════════╗${NC}"
echo -e "${BOLD}║  OpenSlap PKG Installer Builder      ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════╝${NC}"
echo ""

# ─────────────────────────────────────────────
# Preflight checks
# ─────────────────────────────────────────────

ARCH=$(uname -m)
if [ "$ARCH" != "arm64" ]; then
    echo -e "${RED}Error: OpenSlap requires Apple Silicon (arm64).${NC}"
    exit 1
fi

if ! command -v xcodebuild &>/dev/null; then
    echo -e "${RED}Error: Xcode command line tools not found.${NC}"
    echo "Install with: xcode-select --install"
    exit 1
fi

if ! command -v xcodegen &>/dev/null; then
    echo -e "${RED}Error: XcodeGen not found.${NC}"
    echo "Install with: brew install xcodegen"
    exit 1
fi

if ! command -v pkgbuild &>/dev/null; then
    echo -e "${RED}Error: pkgbuild not found (should ship with Xcode).${NC}"
    exit 1
fi

if ! command -v productbuild &>/dev/null; then
    echo -e "${RED}Error: productbuild not found (should ship with Xcode).${NC}"
    exit 1
fi

# ─────────────────────────────────────────────
# Step 1: Generate Xcode project
# ─────────────────────────────────────────────
echo -e "${CYAN}[1/7] Generating Xcode project...${NC}"
cd "$PROJECT_DIR"
xcodegen generate --quiet 2>/dev/null || xcodegen generate
echo -e "  ${GREEN}✓${NC} Xcode project generated"

# ─────────────────────────────────────────────
# Step 2: Build Release targets
# ─────────────────────────────────────────────
echo -e "${CYAN}[2/7] Building Release targets...${NC}"

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

# Verify
if [ ! -d "$BUILD_DIR/$APP_NAME.app" ] || [ ! -f "$BUILD_DIR/$DAEMON_NAME" ]; then
    echo -e "${RED}Error: Build products missing.${NC}"
    exit 1
fi

# ─────────────────────────────────────────────
# Step 3: Ad-hoc code sign
# ─────────────────────────────────────────────
echo -e "${CYAN}[3/7] Ad-hoc code signing...${NC}"

codesign --force --sign - --timestamp=none "$BUILD_DIR/$DAEMON_NAME"
echo -e "  ${GREEN}✓${NC} Signed $DAEMON_NAME"

codesign --force --sign - --timestamp=none \
    --entitlements "$PROJECT_DIR/OpenSlap/OpenSlap.entitlements" \
    "$BUILD_DIR/$APP_NAME.app"
echo -e "  ${GREEN}✓${NC} Signed $APP_NAME.app"

# ─────────────────────────────────────────────
# Step 4: Prepare pkg payload
# ─────────────────────────────────────────────
echo -e "${CYAN}[4/7] Preparing installer payload...${NC}"

rm -rf "$PKG_ROOT" "$PKG_SCRIPTS"
mkdir -p "$PKG_ROOT/Applications"
mkdir -p "$PKG_ROOT/usr/local/bin"
mkdir -p "$PKG_ROOT/Library/LaunchDaemons"
mkdir -p "$PKG_SCRIPTS"

# App bundle → /Applications/OpenSlap.app
cp -R "$BUILD_DIR/$APP_NAME.app" "$PKG_ROOT/Applications/"

# Daemon binary → /usr/local/bin/OpenSlapDaemon
cp "$BUILD_DIR/$DAEMON_NAME" "$PKG_ROOT/usr/local/bin/"
chmod 755 "$PKG_ROOT/usr/local/bin/$DAEMON_NAME"

# LaunchDaemon plist → /Library/LaunchDaemons/
cp "$PROJECT_DIR/OpenSlapDaemon/com.openslap.daemon.plist" \
    "$PKG_ROOT/Library/LaunchDaemons/com.openslap.daemon.plist"
chmod 644 "$PKG_ROOT/Library/LaunchDaemons/com.openslap.daemon.plist"

echo -e "  ${GREEN}✓${NC} Payload prepared"

# ─────────────────────────────────────────────
# Step 5: Create installer scripts
# ─────────────────────────────────────────────
echo -e "${CYAN}[5/7] Creating installer scripts...${NC}"

# preinstall — stop existing daemon if running
cat > "$PKG_SCRIPTS/preinstall" << 'PREINSTALL'
#!/bin/bash
# Stop existing daemon if running
DAEMON_LABEL="com.openslap.daemon"
if launchctl list "$DAEMON_LABEL" &>/dev/null; then
    launchctl unload "/Library/LaunchDaemons/${DAEMON_LABEL}.plist" 2>/dev/null || true
fi
# Clean up stale socket
rm -f /var/run/openslap.sock
exit 0
PREINSTALL

# postinstall — set permissions and load daemon
cat > "$PKG_SCRIPTS/postinstall" << 'POSTINSTALL'
#!/bin/bash
DAEMON_LABEL="com.openslap.daemon"
DAEMON_BIN="/usr/local/bin/OpenSlapDaemon"
DAEMON_PLIST="/Library/LaunchDaemons/${DAEMON_LABEL}.plist"

# Set correct ownership
chown root:wheel "$DAEMON_BIN"
chmod 755 "$DAEMON_BIN"
chown root:wheel "$DAEMON_PLIST"
chmod 644 "$DAEMON_PLIST"

# Load daemon
launchctl load "$DAEMON_PLIST" 2>/dev/null || true

exit 0
POSTINSTALL

chmod +x "$PKG_SCRIPTS/preinstall"
chmod +x "$PKG_SCRIPTS/postinstall"

echo -e "  ${GREEN}✓${NC} Installer scripts created"

# ─────────────────────────────────────────────
# Step 6: Build component package
# ─────────────────────────────────────────────
echo -e "${CYAN}[6/7] Building component package...${NC}"

mkdir -p "$DIST_DIR"
COMPONENT_PKG="$DIST_DIR/OpenSlap-component.pkg"

# Write a component plist to prevent relocation of the .app bundle
COMP_PLIST="$DIST_DIR/component.plist"
cat > "$COMP_PLIST" << 'CPLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<array>
	<dict>
		<key>BundleHasStrictIdentifier</key>
		<false/>
		<key>BundleIsRelocatable</key>
		<false/>
		<key>BundleIsVersionChecked</key>
		<false/>
		<key>BundleOverwriteAction</key>
		<string>upgrade</string>
		<key>RootRelativeBundlePath</key>
		<string>Applications/OpenSlap.app</string>
	</dict>
</array>
</plist>
CPLIST

pkgbuild \
    --root "$PKG_ROOT" \
    --scripts "$PKG_SCRIPTS" \
    --component-plist "$COMP_PLIST" \
    --identifier "$BUNDLE_ID" \
    --version "$VERSION" \
    --install-location "/" \
    "$COMPONENT_PKG" 2>&1

echo -e "  ${GREEN}✓${NC} Component package built"

# ─────────────────────────────────────────────
# Step 7: Build product archive (final .pkg)
# ─────────────────────────────────────────────
echo -e "${CYAN}[7/7] Building product installer...${NC}"

# Create distribution XML for a nicer installer UI
DIST_XML="$DIST_DIR/distribution.xml"
cat > "$DIST_XML" << DISTXML
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
    <title>OpenSlap</title>
    <welcome file="welcome.html"/>
    <conclusion file="conclusion.html"/>
    <background file="background.png" alignment="bottomleft" scaling="none"/>
    <options
        customize="never"
        require-scripts="false"
        hostArchitectures="arm64"/>
    <domains enable_anywhere="false"
             enable_currentUserHome="false"
             enable_localSystem="true"/>
    <volume-check>
        <allowed-os-versions>
            <os-version min="14.0"/>
        </allowed-os-versions>
    </volume-check>
    <choices-outline>
        <line choice="default">
            <line choice="com.openslap.app"/>
        </line>
    </choices-outline>
    <choice id="default"/>
    <choice id="com.openslap.app"
            visible="false"
            title="OpenSlap"
            description="OpenSlap app, daemon, and LaunchDaemon configuration.">
        <pkg-ref id="com.openslap.app"/>
    </choice>
    <pkg-ref id="com.openslap.app"
             version="${VERSION}"
             onConclusion="none">#OpenSlap-component.pkg</pkg-ref>
</installer-gui-script>
DISTXML

# Create welcome HTML
PKG_RESOURCES="$DIST_DIR/pkg-resources"
mkdir -p "$PKG_RESOURCES"

cat > "$PKG_RESOURCES/welcome.html" << 'WELCOME'
<html>
<head><meta http-equiv="Content-Type" content="text/html; charset=utf-8"/></head>
<body style="font-family: -apple-system, Helvetica Neue, sans-serif; font-size: 14px; padding: 20px;">
<h2>Welcome to OpenSlap</h2>
<p><strong>Slap your MacBook. Hear the impact.</strong></p>
<p>This installer will set up:</p>
<ul>
  <li><strong>OpenSlap.app</strong> - Menu bar app (/Applications)</li>
  <li><strong>OpenSlapDaemon</strong> - Accelerometer sensor (/usr/local/bin)</li>
  <li><strong>LaunchDaemon</strong> - Auto-starts the sensor at boot</li>
</ul>
<p style="margin-top: 20px; padding: 12px; background: #FFF3CD; border-radius: 8px; border: 1px solid #FFD666;">
  <strong>First launch:</strong> macOS will block OpenSlap because it is not notarized.<br>
  Go to <strong>System Settings &gt; Privacy &amp; Security</strong> and click <strong>"Open Anyway"</strong>.
  <br>You only need to do this once.
</p>
<p style="color: #666; margin-top: 16px; font-size: 12px;">
  Requires macOS 14.0+ (Sonoma) - Apple Silicon only
</p>
</body>
</html>
WELCOME

cat > "$PKG_RESOURCES/conclusion.html" << 'CONCLUSION'
<html>
<head><meta http-equiv="Content-Type" content="text/html; charset=utf-8"/></head>
<body style="font-family: -apple-system, Helvetica Neue, sans-serif; font-size: 14px; padding: 20px;">
<h2>Installation Complete!</h2>
<p>OpenSlap has been installed successfully.</p>
<p><strong>Next steps:</strong></p>
<ol>
  <li>Open <strong>OpenSlap</strong> from your Applications folder (or use Spotlight)</li>
  <li>If macOS blocks it, go to <strong>System Settings &gt; Privacy &amp; Security &gt; "Open Anyway"</strong></li>
  <li>Look for the OpenSlap icon in your <strong>menu bar</strong> (top of screen, not the dock)</li>
  <li>Slap your MacBook!</li>
</ol>
<p style="margin-top: 16px;">The accelerometer daemon is already running in the background.</p>
<p style="color: #666; margin-top: 20px; font-size: 12px;">
  To uninstall, run in Terminal:<br>
  <code>sudo launchctl unload /Library/LaunchDaemons/com.openslap.daemon.plist</code><br>
  <code>sudo rm /usr/local/bin/OpenSlapDaemon /Library/LaunchDaemons/com.openslap.daemon.plist</code><br>
  <code>sudo rm -rf /Applications/OpenSlap.app</code>
</p>
</body>
</html>
CONCLUSION

rm -f "$PKG_PATH"

productbuild \
    --distribution "$DIST_XML" \
    --package-path "$DIST_DIR" \
    --resources "$PKG_RESOURCES" \
    "$PKG_PATH" 2>&1

echo -e "  ${GREEN}✓${NC} Product installer built"

# ─────────────────────────────────────────────
# Clean up intermediate files
# ─────────────────────────────────────────────
rm -rf "$PKG_ROOT" "$PKG_SCRIPTS" "$PKG_RESOURCES" "$COMPONENT_PKG" "$DIST_XML" "$COMP_PLIST"

# ─────────────────────────────────────────────
# Done!
# ─────────────────────────────────────────────

PKG_SIZE=$(du -h "$PKG_PATH" | cut -f1 | xargs)

echo ""
echo -e "${GREEN}════════════════════════════════════════${NC}"
echo -e "${GREEN}  PKG installer built successfully!${NC}"
echo -e "${GREEN}════════════════════════════════════════${NC}"
echo ""
echo -e "  ${BOLD}File:${NC}    $PKG_PATH"
echo -e "  ${BOLD}Size:${NC}    $PKG_SIZE"
echo -e "  ${BOLD}Signing:${NC} Ad-hoc (no Apple Developer ID)"
echo ""
echo -e "  ${BOLD}Installs:${NC}"
echo -e "    /Applications/OpenSlap.app"
echo -e "    /usr/local/bin/OpenSlapDaemon"
echo -e "    /Library/LaunchDaemons/com.openslap.daemon.plist"
echo ""
echo -e "  ${YELLOW}Note:${NC} Users will need to allow the app in"
echo -e "  System Settings → Privacy & Security on first launch."
echo ""
