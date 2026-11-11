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
BUNDLE="$DEST/$APP"
RUNNING="$BUNDLE/Contents/MacOS/AltTab"

# Clean cutover: an instance running from this bundle maps the binary being
# replaced — overwriting a running signed executable in place gets the old
# process SIGKILL'd by code-signing enforcement, and the `open` below then
# races the dying process (LS error -609). Quit explicitly and wait for exit
# so the relaunch always starts the new build.
if pgrep -f "$RUNNING" >/dev/null; then
    osascript -e 'tell application "AltTab" to quit' 2>/dev/null || true
    for _ in $(seq 10); do pgrep -f "$RUNNING" >/dev/null || break; sleep 0.3; done
    pkill -f "$RUNNING" 2>/dev/null || true
    for _ in $(seq 10); do pgrep -f "$RUNNING" >/dev/null || break; sleep 0.2; done
fi

rm -rf "$BUNDLE"   # fresh bundle; LaunchServices re-registers on open
mkdir -p "$BUNDLE/Contents/MacOS"
cp "$BIN" "$BUNDLE/Contents/MacOS/AltTab"
cp "Support/Info.plist" "$BUNDLE/Contents/Info.plist"
mkdir -p "$BUNDLE/Contents/Resources"
cp Support/AppIcon.icns Support/MenuBarIconTemplate*.png "$BUNDLE/Contents/Resources/"
chmod +x "$BUNDLE/Contents/MacOS/AltTab"

# Developer ID signing: TCC keys the Accessibility grant to the Team ID, so it
# survives rebuilds (ad-hoc "-" signing changed the identity on every build,
# which silently invalidated previously granted permissions).
IDENTITY="${ALTTAB_SIGN_IDENTITY:-Developer ID Application: Yuri Freire Lima (U9WN2GW95A)}"
codesign --force --options runtime --sign "$IDENTITY" "$BUNDLE"
codesign --verify --strict "$BUNDLE"

echo "installed: $BUNDLE"
open -a "$BUNDLE"
