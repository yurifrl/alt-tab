#!/bin/bash
# Regenerates every raster/derived logo asset from the SVG sources in this folder.
# Needs: rsvg-convert (brew install librsvg), iconutil (macOS).
# Outputs: ../../Support/AppIcon.icns, ../../Support/MenuBarIconTemplate{,@2x}.png,
#          header.svg (text outlined), header.png
set -euo pipefail
cd "$(dirname "$0")"
SUPPORT="../../Support"

# Menu-bar template image (black + alpha; macOS tints it for light/dark bars).
rsvg-convert -w 20 -h 18 menubar-template.svg -o "$SUPPORT/MenuBarIconTemplate.png"
rsvg-convert -w 40 -h 36 menubar-template.svg -o "$SUPPORT/MenuBarIconTemplate@2x.png"

# App icon: macOS icons sit inside a ~80% safe area of the canvas, so pad the tile.
PADDED="$(mktemp -t icon).svg"
sed 's|viewBox="0 0 512 512"|viewBox="-61.8 -61.8 635.6 635.6"|' icon.svg > "$PADDED"
SET="$(mktemp -d)/AppIcon.iconset"; mkdir -p "$SET"
for s in 16 32 128 256 512; do
  rsvg-convert -w $s        -h $s        "$PADDED" -o "$SET/icon_${s}x${s}.png"
  rsvg-convert -w $((s*2))  -h $((s*2))  "$PADDED" -o "$SET/icon_${s}x${s}@2x.png"
done
iconutil -c icns "$SET" -o "$SUPPORT/AppIcon.icns"
rsvg-convert -w 1024 -h 1024 "$PADDED" -o icon-1024.png

# README header: re-emit as SVG so text becomes outlines (renders the same everywhere).
rsvg-convert -f svg header-source.svg -o header.svg
rsvg-convert -w 2560 header-source.svg -o header.png
echo "logo assets rebuilt"
