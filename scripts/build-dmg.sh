#!/usr/bin/env bash
# Builds build/Postquel-<version>.dmg for distribution: a universal (Apple silicon + Intel) app
# with libpq bundled, next to a shortcut to /Applications to drag it onto.
#
#   ./scripts/build-dmg.sh
#
# Without a Developer ID the app is signed with the local identity, and macOS on other Macs asks
# people to approve it once (System Settings → Privacy & Security → Open Anyway). To ship a DMG
# that opens without that, with a paid Apple Developer account:
#   DEVELOPER_ID="Developer ID Application: Name (TEAMID)"   signs app and DMG for distribution
#   NOTARY_PROFILE=postquel                                  notarizes and staples the DMG; create
#     the profile once with: xcrun notarytool store-credentials postquel --apple-id … --team-id …
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/build-app.sh --universal
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" build/Postquel.app/Contents/Info.plist)
DMG="build/Postquel-$VERSION.dmg"

STAGING=build/dmg
rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING"
cp -R build/Postquel.app "$STAGING/"
ln -s /Applications "$STAGING/Applications"

hdiutil create -volname "Postquel $VERSION" -srcfolder "$STAGING" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
rm -rf "$STAGING"

if [[ -n "${DEVELOPER_ID:-}" ]]; then
    codesign --force --sign "$DEVELOPER_ID" --timestamp "$DMG"
fi
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
fi

shasum -a 256 "$DMG" | tee "$DMG.sha256"
echo "Built $DMG ($(du -h "$DMG" | cut -f1))"
