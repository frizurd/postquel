#!/usr/bin/env bash
# Generate every macOS icon size from the master PNG.
set -euo pipefail
cd "$(dirname "$0")/.."

ICONSET=build/AppIcon.iconset
mkdir -p "$ICONSET"

for size in 16 32 128 256 512; do
    sips -z "$size" "$size" Resources/AppIcon.png \
        --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    retina=$((size * 2))
    sips -z "$retina" "$retina" Resources/AppIcon.png \
        --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done

iconutil -c icns "$ICONSET" -o build/AppIcon.icns
