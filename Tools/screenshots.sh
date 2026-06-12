#!/usr/bin/env bash
# Capture REAL clean App Store screenshots of Blip's menu-bar UI (macOS).
#
# Builds the Direct "Blip" scheme, then on a temporarily-cleaned desktop
# (gradient wallpaper; dock, widgets, desktop icons, other app windows, and the
# WeatherMenu menu-bar app all hidden; scaled 16:10 resolution) launches Blip
# with `-BlipScreenshotMode 1 -BlipScreenshotScene <scene>` (fictional, PII-free,
# no helper-only data) and captures the REAL menu bar + popover full-screen —
# then restores every system setting it changed (incl. the wallpaper config
# file, so slideshows survive). Output: docs/appstore-screenshots/mac/<n>-<scene>.png
# @2880x1800 (canonical numbering is stable, so partial re-captures slot in).
#
# Usage: screenshots.sh [scene ...]   e.g. `screenshots.sh cpu` re-captures only
# the CPU scene; no args captures all scenes.
#
# Needs: Screen Recording + Automation permission for the controlling app.
set -uo pipefail
cd "$(dirname "$0")/.."
SHARED="$(cd ../_shared/screenshots && pwd)"
OUT="docs/appstore-screenshots/mac"; mkdir -p "$OUT/raw"
WALL=/tmp/blip-wallpaper.png
ALL_SCENES=(popover cpu memory disk network)

# Optional scene filter: `screenshots.sh cpu disk` re-captures just those scenes
# (canonical numbers preserved). No args = all scenes.
if [ $# -gt 0 ]; then
  for s in "$@"; do
    case " ${ALL_SCENES[*]} " in
      *" $s "*) ;;
      *) echo "✗ unknown scene '$s' (valid: ${ALL_SCENES[*]})" >&2; exit 2 ;;
    esac
  done
  SCENES=("$@")
else
  SCENES=("${ALL_SCENES[@]}")
fi
scene_number() { local i=1 x; for x in "${ALL_SCENES[@]}"; do [ "$x" = "$1" ] && { echo "$i"; return; }; i=$((i+1)); done; }

# --- notifications: keep system banners out of the captures ------------------
# A notification banner landing under the menu bar mid-capture ships straight
# to the App Store (it happened — v1.6.0 screenshot #2). macOS has no supported
# headless DND toggle (the old `defaults write com.apple.donotdisturb` died in
# Monterey), so we layer three scriptable defenses, most reliable first:
#   1. Shortcuts named exactly "DND On" / "DND Off" (one-time manual setup:
#      Shortcuts.app → + → action "Set Focus" → Do Not Disturb on/off) — the
#      only Apple-supported automation path; used when both exist, restored by
#      the EXIT trap.
#   2. Immediately before every screencapture, count + close visible banners
#      via System Events. Banner/alert windows of the NotificationCenter
#      process carry subrole AXNotificationCenterBanner / …Alert (its desktop
#      -widget windows are AXUnknown, so the filter leaves them alone); each
#      exposes a "Close" action (description match survives renames better
#      than action names).
#   3. If a banner still won't die, `killall NotificationCenter` — the daemon
#      respawns clean within a couple seconds and the banners do not.
# The capture proceeds only once the banner count polls 0 (or the hard kill).
DND_ENABLED=
banner_count() {
  local n
  n=$(osascript -e 'tell application "System Events" to tell process "NotificationCenter" to count (windows whose subrole is "AXNotificationCenterBanner" or subrole is "AXNotificationCenterAlert")' 2>/dev/null)
  case "$n" in (''|*[!0-9]*) echo 0 ;; (*) echo "$n" ;; esac
}
close_banners() {
  local tries=0
  while [ "$(banner_count)" -gt 0 ]; do
    if [ $tries -ge 5 ]; then
      echo "  ⚠ stubborn notification banner — restarting NotificationCenter"
      killall NotificationCenter 2>/dev/null; sleep 3; return 0
    fi
    osascript 2>/dev/null <<'EOS'
tell application "System Events" to tell process "NotificationCenter"
  repeat with w in (windows whose subrole is "AXNotificationCenterBanner" or subrole is "AXNotificationCenterAlert")
    try
      perform (first action of w whose description is "Close" or description is "Clear All")
    on error
      try
        perform (first action of (first group of w) whose description is "Close" or description is "Clear All")
      end try
    end try
  end repeat
end tell
EOS
    sleep 1; tries=$((tries+1))
  done
}

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
  [ -n "$DND_ENABLED" ] && { echo "• Do Not Disturb off"; shortcuts run "DND Off" >/dev/null 2>&1; }
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
if shortcuts list 2>/dev/null | grep -qix "DND On" && shortcuts list 2>/dev/null | grep -qix "DND Off"; then
  echo "• enabling Do Not Disturb (Shortcuts)"
  shortcuts run "DND On" >/dev/null 2>&1 && DND_ENABLED=1
else
  echo "• no 'DND On'/'DND Off' Shortcuts found — relying on the banner sweep (see header)"
fi
swift "$SHARED/gen-gradient.swift" "$WALL" 4096 3072 06b6d4 8b5cf6 ec4899 >/dev/null
osascript -e "tell application \"System Events\" to set picture of desktop 1 to \"$WALL\"" 2>/dev/null
osascript -e 'tell application "System Events" to set autohide of dock preferences to true' 2>/dev/null
defaults write com.apple.WindowManager StandardHideWidgets -bool true 2>/dev/null
defaults write com.apple.finder CreateDesktop -bool false 2>/dev/null
killall WindowManager Finder 2>/dev/null
WEATHER_WAS=$(pgrep -x WeatherMenu 2>/dev/null && echo 1)
osascript -e 'quit app "WeatherMenu"' 2>/dev/null; pkill -x WeatherMenu 2>/dev/null
# 16:10 capture mode, biggest first (the available list shifts with OS updates
# and attached displays — 1440x900 existed on 2026-06-04, only 1280x800 now).
# IMPORTANT: capture the whole set in one run; mixing modes changes the
# popover-to-frame scale between screenshots.
CAP_MODE=""
for MODE in "1440 900" "1280 800" "1024 640"; do
  # shellcheck disable=SC2086
  if swift "$SHARED/display-mode.swift" set $MODE >/dev/null 2>&1; then CAP_MODE=$MODE; break; fi
done
if [ -n "$CAP_MODE" ]; then echo "• display mode: $CAP_MODE (16:10)"; else
  echo "  ⚠ no 16:10 display mode available — capturing at the current resolution (check aspect!)"
fi
sleep 2
defaults write com.apple.dock autohide -bool true 2>/dev/null; killall Dock 2>/dev/null  # res change re-shows Dock
sleep 2

for scene in "${SCENES[@]}"; do
  pkill -f "/Blip.app/" 2>/dev/null; sleep 1
  "$BIN" -BlipScreenshotMode 1 -BlipScreenshotScene "$scene" >/dev/null 2>&1 &
  sleep 3
  IFS=',' read -ra A <<< "$HIDDEN_APPS"
  for app in "${A[@]}"; do app="${app## }"; app="${app%% }"; [ -n "$app" ] && osascript -e "tell application \"System Events\" to set visible of process \"$app\" to false" 2>/dev/null; done
  # Close any open Finder windows (they show the user's real files = PII).
  osascript -e 'tell application "Finder" to close every window' 2>/dev/null
  # Deterministic menu bar: whatever app was frontmost before its windows were
  # hidden still owns the menus (Messages photobombed a capture once). Blip's
  # screenshot-mode popover is pinned, so handing focus to Finder is safe.
  osascript -e 'tell application "Finder" to activate' 2>/dev/null
  sleep 1.5
  close_banners                                                   # gate: no notification banners in frame
  printf -v n "%02d" "$(scene_number "$scene")"
  screencapture -x -t png "$OUT/raw/$n-$scene.png" 2>/dev/null   # full clean-desktop capture (1440x900, popover top-right)
  cp "$OUT/raw/$n-$scene.png" "$OUT/$n-$scene.png"
  sips -z 1800 2880 "$OUT/$n-$scene.png" >/dev/null 2>&1          # 2x -> 2880x1800 (16:10, no distortion)
  echo "  ✓ $n-$scene.png"
done
echo "• Done → $OUT"
