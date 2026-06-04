#!/usr/bin/env bash
# Capture REAL clean App Store screenshots of Blip's menu-bar UI (macOS).
#
# Builds the Direct "Blip" scheme, then on a temporarily-cleaned desktop
# (gradient wallpaper; dock, widgets, desktop icons, other app windows, and the
# WeatherMenu menu-bar app all hidden; scaled 16:10 resolution) launches Blip
# with `-BlipScreenshotMode 1 -BlipScreenshotScene <scene>` (fictional, PII-free,
# no helper-only data) and captures the REAL menu bar + popover full-screen —
# then restores every system setting it changed (incl. the wallpaper config
# file, so slideshows survive). Output: screenshots/mac/<n>-<scene>.png @2880x1800.
#
# Needs: Screen Recording + Automation permission for the controlling app.
set -uo pipefail
cd "$(dirname "$0")/.."
SHARED="$(cd ../_shared/screenshots && pwd)"
OUT="screenshots/mac"; mkdir -p "$OUT"
WALL=/tmp/blip-wallpaper.png
SCENES=(popover cpu network)

echo "• Building Blip…"
xcodegen generate >/dev/null
xcodebuild -project Blip.xcodeproj -scheme Blip -destination "platform=macOS" \
  -configuration Debug -derivedDataPath .build-screenshots CODE_SIGNING_ALLOWED=NO build >/dev/null
BIN="$(find .build-screenshots/Build/Products -name 'Blip.app' -maxdepth 3 | head -1)/Contents/MacOS/Blip"

# --- save state ---
WP_STORE="$HOME/Library/Application Support/com.apple.wallpaper/Store/Index.plist"
WP_BAK=/tmp/blip-wallpaper-Index.plist.bak
[ -f "$WP_STORE" ] && cp "$WP_STORE" "$WP_BAK"
read -r OM_W OM_H _ _ < <(swift "$SHARED/display-mode.swift" current 2>/dev/null)
ORIG_DOCK=$(osascript -e 'tell application "System Events" to get autohide of dock preferences' 2>/dev/null)
ORIG_WIDG=$(defaults read com.apple.WindowManager StandardHideWidgets 2>/dev/null || echo __M__)
ORIG_ICON=$(defaults read com.apple.finder CreateDesktop 2>/dev/null || echo __M__)
HIDDEN_APPS=$(osascript -e 'tell application "System Events" to get name of (every process whose background only is false and name is not "Blip" and name is not "Finder")' 2>/dev/null)

restore() {
  echo "• restoring desktop…"
  if [ -f "$WP_BAK" ]; then cp "$WP_BAK" "$WP_STORE" 2>/dev/null; killall WallpaperAgent 2>/dev/null; fi
  osascript -e "tell application \"System Events\" to set autohide of dock preferences to ${ORIG_DOCK:-false}" 2>/dev/null
  [ "$ORIG_WIDG" = __M__ ] && defaults delete com.apple.WindowManager StandardHideWidgets 2>/dev/null || defaults write com.apple.WindowManager StandardHideWidgets -int "$ORIG_WIDG" 2>/dev/null
  [ "$ORIG_ICON" = __M__ ] && defaults delete com.apple.finder CreateDesktop 2>/dev/null || defaults write com.apple.finder CreateDesktop -int "$ORIG_ICON" 2>/dev/null
  killall WindowManager Finder Dock 2>/dev/null
  [ -n "${OM_W:-}" ] && swift "$SHARED/display-mode.swift" set "$OM_W" "$OM_H" >/dev/null 2>&1
  [ -n "${WEATHER_WAS:-}" ] && open -a WeatherMenu 2>/dev/null
  IFS=',' read -ra A <<< "$HIDDEN_APPS"
  for app in "${A[@]}"; do app="${app## }"; app="${app%% }"; [ -n "$app" ] && osascript -e "tell application \"System Events\" to set visible of process \"$app\" to true" 2>/dev/null; done
  pkill -f "/Blip.app/" 2>/dev/null
}
trap restore EXIT INT TERM

# --- clean desktop ---
swift "$SHARED/gen-gradient.swift" "$WALL" 4096 3072 06b6d4 8b5cf6 ec4899 >/dev/null
osascript -e "tell application \"System Events\" to set picture of desktop 1 to \"$WALL\"" 2>/dev/null
osascript -e 'tell application "System Events" to set autohide of dock preferences to true' 2>/dev/null
defaults write com.apple.WindowManager StandardHideWidgets -bool true 2>/dev/null
defaults write com.apple.finder CreateDesktop -bool false 2>/dev/null
killall WindowManager Finder 2>/dev/null
WEATHER_WAS=$(pgrep -x WeatherMenu 2>/dev/null && echo 1)
osascript -e 'quit app "WeatherMenu"' 2>/dev/null; pkill -x WeatherMenu 2>/dev/null
swift "$SHARED/display-mode.swift" set 1024 640 >/dev/null 2>&1   # 16:10, big popover
sleep 2
defaults write com.apple.dock autohide -bool true 2>/dev/null; killall Dock 2>/dev/null  # res change re-shows Dock
sleep 2

i=1
for scene in "${SCENES[@]}"; do
  pkill -f "/Blip.app/" 2>/dev/null; sleep 1
  "$BIN" -BlipScreenshotMode 1 -BlipScreenshotScene "$scene" >/dev/null 2>&1 &
  sleep 3
  IFS=',' read -ra A <<< "$HIDDEN_APPS"
  for app in "${A[@]}"; do app="${app## }"; app="${app%% }"; [ -n "$app" ] && osascript -e "tell application \"System Events\" to set visible of process \"$app\" to false" 2>/dev/null; done
  sleep 1.5
  printf -v n "%02d" "$i"
  screencapture -x -t png "$OUT/$n-$scene.png" 2>/dev/null
  sips -z 1800 2880 "$OUT/$n-$scene.png" >/dev/null 2>&1
  echo "  ✓ $n-$scene.png"; i=$((i+1))
done
echo "• Done → $OUT"
