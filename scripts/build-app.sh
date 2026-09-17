#!/usr/bin/env bash
# Builds build/Arsip.app from the SwiftPM executable.
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

APP=build/Arsip.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/$CONFIG/Arsip" "$APP/Contents/MacOS/Arsip"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Arsip</string>
    <key>CFBundleDisplayName</key><string>Arsip</string>
    <key>CFBundleIdentifier</key><string>dev.arsip.Arsip</string>
    <key>CFBundleExecutable</key><string>Arsip</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

# Sign with a stable identity when available, so Keychain access granted to Arsip survives rebuilds.
IDENTITY="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ { print $2; exit }')}"
codesign --force --sign "${IDENTITY:--}" "$APP" 2>/dev/null
echo "Built $APP"

if $INSTALL; then
    WAS_RUNNING=false
    if pgrep -x Arsip >/dev/null; then
        WAS_RUNNING=true
        pkill -x Arsip
        while pgrep -x Arsip >/dev/null; do sleep 0.1; done
    fi
    rm -rf /Applications/Arsip.app
    cp -R "$APP" /Applications/Arsip.app
    echo "Installed /Applications/Arsip.app"
    if $WAS_RUNNING; then open /Applications/Arsip.app; echo "Relaunched"; fi
fi
