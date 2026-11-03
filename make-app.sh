#!/bin/bash
# Builds the release binary and assembles AltTab.app into /Applications.
# Usage: ./make-app.sh [-l]   (-l links into ~/Applications instead of copying)
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP="AltTab.app"
DEST="/Applications"
[[ "${1:-}" == "-l" ]] && DEST="$HOME/Applications"

BIN=".build/release/AltTabCore"
mkdir -p "$DEST/$APP/Contents/MacOS"
cp "$BIN" "$DEST/$APP/Contents/MacOS/AltTab"
cp "Support/Info.plist" "$DEST/$APP/Contents/Info.plist"
chmod +x "$DEST/$APP/Contents/MacOS/AltTab"

# Developer ID signing: TCC keys the Accessibility grant to the Team ID, so it
# survives rebuilds (ad-hoc "-" signing changed the identity on every build,
# which silently invalidated previously granted permissions).
IDENTITY="${ALTTAB_SIGN_IDENTITY:-Developer ID Application: Yuri Freire Lima (U9WN2GW95A)}"
codesign --force --options runtime --sign "$IDENTITY" "$DEST/$APP"
codesign --verify --strict "$DEST/$APP"

echo "installed: $DEST/$APP"
open -a "$DEST/$APP"
