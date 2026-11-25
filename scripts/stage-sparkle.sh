#!/bin/bash
# Stage Sparkle.framework next to the built executables so unpackaged runs
# (`swift run AltTabCore extras`) resolve @rpath/Sparkle.framework.
set -euo pipefail
cd "$(dirname "$0")/.."

XC="$(find .build/artifacts -maxdepth 4 -name 'Sparkle.xcframework' -print -quit)"
[[ -n "$XC" ]] || { echo "Sparkle.xcframework not resolved — run: swift package resolve" >&2; exit 1; }

for config in debug release; do
  DEST="$(dirname "$(swift build -c "$config" --show-bin-path)")/Frameworks"
  mkdir -p "$DEST"
  rm -rf "$DEST/Sparkle.framework"
  cp -R "$XC/macos-arm64_x86_64/Sparkle.framework" "$DEST/"
  echo "staged $DEST/Sparkle.framework"
done
