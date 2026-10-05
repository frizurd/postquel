#!/usr/bin/env bash
# Builds build/Postquel.app from the SwiftPM executable.
#   ./scripts/build-app.sh            build only
#   ./scripts/build-app.sh --install  build, copy to /Applications, relaunch if running
set -euo pipefail
cd "$(dirname "$0")/.."

INSTALL=false
CONFIG=release
for arg in "$@"; do
    case "$arg" in
        --install) INSTALL=true ;;
        *) CONFIG="$arg" ;;
    esac
done
swift build -c "$CONFIG"
bash scripts/build-icon.sh

APP=build/Postquel.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/$CONFIG/Postquel" "$APP/Contents/MacOS/Postquel"
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Postquel</string>
    <key>CFBundleDisplayName</key><string>Postquel</string>
    <key>CFBundleIdentifier</key><string>dev.postquel.Postquel</string>
    <key>CFBundleExecutable</key><string>Postquel</string>
    <key>CFBundleIconFile</key><string>AppIcon.icns</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHumanReadableCopyright</key><string>© 2026 frizky.dev</string>
</dict>
</plist>
PLIST

# The sentence under the version in About Postquel. RTF with no color set, so it follows dark mode
# (HTML credits come out black).
cat > "$APP/Contents/Resources/Credits.rtf" <<'RTF'
{\rtf1\ansi{\fonttbl\f0\fnil .AppleSystemUIFont;}\f0\fs22\qc A fast, native PostgreSQL client for macOS, with an AI assistant that uses the Claude Code, Codex or Cursor account already on your Mac.}
RTF

# Sign with a stable identity when available, so Keychain access granted to Postquel survives rebuilds.
IDENTITY="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ { print $2; exit }')}"
codesign --force --sign "${IDENTITY:--}" "$APP" 2>/dev/null
echo "Built $APP"

if $INSTALL; then
    WAS_RUNNING=false
    if pgrep -x Postquel >/dev/null; then
        WAS_RUNNING=true
        pkill -x Postquel
        while pgrep -x Postquel >/dev/null; do sleep 0.1; done
    fi
    rm -rf /Applications/Postquel.app
    cp -R "$APP" /Applications/Postquel.app
    echo "Installed /Applications/Postquel.app"
    if $WAS_RUNNING; then open /Applications/Postquel.app; echo "Relaunched"; fi
fi
