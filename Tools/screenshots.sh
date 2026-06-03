#!/usr/bin/env zsh
# Capture + frame Blip App Store screenshots (macOS).
#
# Builds the Direct "Blip" scheme, launches it per scene with
# `-BlipScreenshotMode 1 -BlipScreenshotScene <scene>` (fictional demo data,
# no real monitoring / PII), captures each borderless card window, then frames
# it on the "Electric" gradient via the Monkr CLI. Blip's popover cards are
# portrait and vary in height, so each scene uses its own scale to fill ~82%
# of the 16:10 frame height.
set -euo pipefail
cd "$(dirname "$0")/.."

DD=".build-screenshots"
MONKR="docs/appstore-screenshots/Blip-mac.monkr"
OUT_RAW="/tmp/blip-mac"; OUT_FRAMED="screenshots/mac-framed"
WID="../_shared/screenshots/mac-window-id.swift"
MONKR_BIN="$HOME/Documents/scripts/monkr/bin/monkr.mjs"
# scene:source_height (px @2x) — scale computed as 1156/height for ~82% fill
SCENES=("popover:456" "cpu:988" "disk:1228" "network:1182" "thermal:586" "battery:388")

echo "• Building Blip (Direct, no-MLX) for macOS…"
xcodegen generate >/dev/null
xcodebuild -project Blip.xcodeproj -scheme Blip -destination "platform=macOS" \
  -configuration Debug -derivedDataPath "$DD" CODE_SIGNING_ALLOWED=NO build >/dev/null
APP=$(find "$DD/Build/Products" -name "Blip.app" -maxdepth 3 | head -1)
BIN="$APP/Contents/MacOS/Blip"
mkdir -p "$OUT_RAW" "$OUT_FRAMED"

for entry in "${SCENES[@]}"; do
  scene="${entry%%:*}"; h="${entry##*:}"
  pkill -f "/Blip.app/" 2>/dev/null || true; sleep 1
  "$BIN" -BlipScreenshotMode 1 -BlipScreenshotScene "$scene" >/dev/null 2>&1 &
  pid=$!; sleep 4
  win=$(swift "$WID" "$pid" 2>/dev/null || true)
  [[ -z "$win" ]] && { echo "  ✗ $scene: no window"; continue; }
  screencapture -o -x -l"$win" -t png "$OUT_RAW/$scene.png" 2>/dev/null
  scale=$(python3 -c "print(round(1156/$h, 2))")
  python3 -c "
import json
j=json.load(open('$MONKR')); o=j['sceneObjects'][0]
o['scale']=$scale; o['screenshotUrl']=None; o['extraScreenshots']=[]
json.dump(j,open('$MONKR','w'),indent=2)"
  node "$MONKR_BIN" render "$MONKR" --out "$OUT_FRAMED" --screenshots "$OUT_RAW/$scene.png" >/dev/null 2>&1
  echo "  ✓ $scene (scale $scale)"
done
pkill -f "/Blip.app/" 2>/dev/null || true
echo "• Framed → $OUT_FRAMED"
