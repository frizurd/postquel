#!/usr/bin/env bash
# Watches the sources; on every change rebuilds, installs to /Applications and relaunches Postquel.
# Stop with Ctrl+C.
set -uo pipefail
cd "$(dirname "$0")/.."

snapshot() { find Sources Package.swift -type f -exec stat -f '%m %N' {} + | sort | shasum; }

build() {
    echo "── $(date +%H:%M:%S) building…"
    if ./scripts/build-app.sh --install 2>&1 | grep -E "error:|Installed|Relaunched"; then :; fi
    pgrep -x Postquel >/dev/null || open /Applications/Postquel.app
}

build
last=$(snapshot)
echo "Watching for changes (Ctrl+C to stop)"
while true; do
    sleep 1
    current=$(snapshot)
    if [[ "$current" != "$last" ]]; then
        sleep 0.5  # let multi-file edits settle
        last=$(snapshot)
        build
    fi
done
