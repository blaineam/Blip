#!/usr/bin/env zsh
# Capture + frame Blip App Store screenshots (macOS).
#
# Builds the Direct "Blip" scheme, launches it per scene with
# `-BlipScreenshotMode 1 -BlipScreenshotScene <scene>` (fictional demo data,
# NO real monitoring and NO helper-only data — Blip's App Store build only
# shows CPU/memory/disk-usage/network/battery-level/thermal without the
# privileged helper, so GPU/SMART/fans/temps/disk-I/O/battery-health/processes/
# MTR are all excluded), captures each borderless card window, then composites
# it onto a faux macOS desktop (Electric gradient + menu bar) so it reads as a
# real menu-bar app — via ../_shared/screenshots/menubar-frame.swift.
set -euo pipefail
cd "$(dirname "$0")/.."

DD=".build-screenshots"
RAW="/tmp/blip-mac"; OUT="screenshots/mac-framed"
WID="../_shared/screenshots/mac-window-id.swift"
FRAME="../_shared/screenshots/menubar-frame.swift"
# scene:cardWidth (in final 2880-px space; short cards wider, tall cards narrower)
SCENES=("popover:980" "cpu:760" "network:720")

echo "• Building Blip for macOS…"
xcodegen generate >/dev/null
xcodebuild -project Blip.xcodeproj -scheme Blip -destination "platform=macOS" \
  -configuration Debug -derivedDataPath "$DD" CODE_SIGNING_ALLOWED=NO build >/dev/null
BIN="$(find "$DD/Build/Products" -name 'Blip.app' -maxdepth 3 | head -1)/Contents/MacOS/Blip"
mkdir -p "$RAW" "$OUT"
i=1
for entry in "${SCENES[@]}"; do
  scene="${entry%%:*}"; cw="${entry##*:}"
  pkill -f "/Blip.app/" 2>/dev/null || true; sleep 1
  "$BIN" -BlipScreenshotMode 1 -BlipScreenshotScene "$scene" >/dev/null 2>&1 &
  pid=$!; sleep 5
  win=$(swift "$WID" "$pid" 2>/dev/null || true)
  [[ -z "$win" ]] && { echo "  ✗ $scene: no window"; continue; }
  screencapture -o -x -l"$win" -t png "$RAW/$scene.png" 2>/dev/null
  printf -v n "%02d" "$i"
  swift "$FRAME" --card "$RAW/$scene.png" --out "$OUT/$n-$scene.png" \
    --c1 06b6d4 --c2 8b5cf6 --c3 ec4899 --cardWidth "$cw" >/dev/null 2>&1
  sips -z 1800 2880 "$OUT/$n-$scene.png" >/dev/null 2>&1   # 2x backing -> exact 2880x1800
  echo "  ✓ $n-$scene.png"
  i=$((i+1))
done
pkill -f "/Blip.app/" 2>/dev/null || true
echo "• Framed → $OUT (upload with _shared/screenshots/asc-screenshots.mjs --display-type APP_DESKTOP --platform MAC_OS)"
