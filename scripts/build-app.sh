#!/usr/bin/env bash
# Builds build/Postquel.app from the SwiftPM executable.
#   ./scripts/build-app.sh               build only (this Mac's architecture)
#   ./scripts/build-app.sh --install     build, copy to /Applications, relaunch if running
#   ./scripts/build-app.sh --universal   Apple silicon + Intel, for distribution
# Signing: DEVELOPER_ID="Developer ID Application: …" signs for distribution with the hardened
# runtime; otherwise CODESIGN_IDENTITY, else the local Apple Development identity, else ad hoc.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=0.1.1
BUILD_NUMBER=2
LIBPQ_PREFIX="${LIBPQ_PREFIX:-/Applications/Postgres.app/Contents/Versions/latest}"

INSTALL=false
UNIVERSAL=false
CONFIG=release
for arg in "$@"; do
    case "$arg" in
        --install) INSTALL=true ;;
        --universal) UNIVERSAL=true ;;
        *) CONFIG="$arg" ;;
    esac
done
if $UNIVERSAL; then
    swift build -c "$CONFIG" --arch arm64 --arch x86_64
    BINARY=".build/out/Products/$(tr '[:lower:]' '[:upper:]' <<< "${CONFIG:0:1}")${CONFIG:1}/Postquel"
else
    swift build -c "$CONFIG"
    BINARY=".build/$CONFIG/Postquel"
fi
bash scripts/build-icon.sh

APP=build/Postquel.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BINARY" "$APP/Contents/MacOS/Postquel"
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp -R Resources/Licenses "$APP/Contents/Resources/Licenses"

# Bundle libpq and the OpenSSL libraries it loads, so the app runs on Macs without Postgres.app.
# They find each other through @loader_path; the app finds libpq through its Frameworks folder.
for lib in libpq.5.dylib libssl.3.dylib libcrypto.3.dylib; do
    cp "$LIBPQ_PREFIX/lib/$lib" "$APP/Contents/Frameworks/$lib"
    chmod u+w "$APP/Contents/Frameworks/$lib"
    install_name_tool -id "@rpath/$lib" "$APP/Contents/Frameworks/$lib" 2>/dev/null
done
EXE="$APP/Contents/MacOS/Postquel"
LINKED_LIBPQ=$(otool -L "$EXE" | awk '/libpq\.5\.dylib/ { print $1; exit }')
install_name_tool -change "$LINKED_LIBPQ" "@rpath/libpq.5.dylib" "$EXE"
# Only the bundled copy and the system's Swift runtime: no paths into this build machine.
# (Each path is listed once per architecture in a universal binary, hence sort -u.)
for rpath in $(otool -l "$EXE" | awk '/LC_RPATH/ { getline; getline; print $2 }' | sort -u); do
    [[ "$rpath" == /usr/lib/swift ]] || install_name_tool -delete_rpath "$rpath" "$EXE"
done
install_name_tool -add_rpath "@executable_path/../Frameworks" "$EXE"

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
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
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
# The bundled libraries are signed first (their old signatures broke when their install names changed).
if [[ -n "${DEVELOPER_ID:-}" ]]; then
    IDENTITY="$DEVELOPER_ID"
    SIGN_FLAGS=(--options runtime --timestamp)  # hardened runtime, required for notarization
else
    IDENTITY="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ { print $2; exit }')}"
    SIGN_FLAGS=()
fi
for lib in "$APP"/Contents/Frameworks/*.dylib; do
    codesign --force --sign "${IDENTITY:--}" ${SIGN_FLAGS[@]+"${SIGN_FLAGS[@]}"} "$lib"
done
codesign --force --sign "${IDENTITY:--}" ${SIGN_FLAGS[@]+"${SIGN_FLAGS[@]}"} "$APP"
echo "Built $APP ($VERSION, $(lipo -archs "$EXE"), signed by ${IDENTITY:-ad hoc})"

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
