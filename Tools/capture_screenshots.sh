#!/usr/bin/env bash
#
# Captures App Store-ready PNGs of Blip Stats for iOS from the iPhone 17 Pro Max
# and iPad Pro 13" simulators — the two canvases current ASC guidelines require
# (6.9" 1320×2868 → APP_IPHONE_67, 13" 2064×2752 → APP_IPAD_PRO_3GEN_129).
#
# Demo state is seeded via `blip.demoSeed` (curated, PII-free — RFC 5737
# documentation IPs for the network scenes, no real addresses anywhere), routes
# land via `-blip.route`, and dark shots alternate with light ones so the set
# itself demonstrates dark-mode support.
#
# Boilerplate lives in ../_shared/screenshots/capture-lib.sh; framing + ASC
# upload happen in the shared update-screenshots.sh pipeline (.local-screenshots.conf).
#
# Usage: ./Tools/capture_screenshots.sh [device-key]   # e.g. `ipad-13` to redo one leg

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"

# shellcheck disable=SC1091
source "$PROJECT_ROOT/../_shared/screenshots/capture-lib.sh"

BUNDLE_ID="com.blainemiller.Blip"
SCHEME="BlipMobile"
PROJECT="Blip.xcodeproj"
ROUTE_FLAG="blip.route"

export CAP_APP_NAME="Blip"
# iPadOS puts Blip's floating tab pill at the top of the window, starting
# ~3.3% down — inside the guard's default 6% strip. An allow-list of tab
# labels only worked in English (de-DE "Übersicht" re-tripped it); narrow
# the strip to the true status bar instead (Kern/Revela precedent) so it
# stays locale-proof.
export CAP_STATUSBAR_STRIP=0.03

# DEDICATED simulators ("Blip Shots …"), created on first use from the device
# type after the "|" and ERASED at the start of every run. The generic shared
# simulators are driven by other apps' rigs and sessions: the 2026-09 wave
# captured another app's stuck "would like to send you notifications" alert in
# every iPhone frame. A fresh device + an installed-apps check keeps foreign
# apps out of the frame for good.
DEVICES=(
    "Blip Shots iPhone 17 Pro Max|com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro-Max:iphone-6.9"
    "Blip Shots iPad Pro 13-inch (M5)|com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5-12GB:ipad-13"
)

# blip_resolve_udid "<name>|<device type id>" -> UDID of the dedicated sim,
# creating it on the newest iOS runtime when it does not exist yet.
blip_resolve_udid() {
    local name="${1%%|*}" dtype="${1#*|}" udid
    udid=$(xcrun simctl list devices -j | python3 -c "
import json, sys
for devs in json.load(sys.stdin)['devices'].values():
    for d in devs:
        if d['name'] == sys.argv[1] and d.get('isAvailable', True):
            print(d['udid']); sys.exit(0)
" "$name")
    if [ -z "$udid" ]; then
        udid=$(xcrun simctl create "$name" "$dtype" "$(cap_pick_runtime)")
    fi
    echo "$udid"
}

# blip_only_app_installed UDID — fails unless Blip is the ONLY non-Apple app
# on the device (a foreign app's permission alert is what poisoned 2026-09).
blip_only_app_installed() {
    local foreign
    foreign=$(xcrun simctl listapps "$1" 2>/dev/null | plutil -convert json -o - - \
        | python3 -c "
import json, sys
apps = json.load(sys.stdin)
print(' '.join(b for b in apps if not b.startswith('com.apple.') and b != sys.argv[1]))
" "$BUNDLE_ID")
    if [ -n "$foreign" ]; then
        echo "  ✗ foreign apps installed on the capture sim: $foreign" >&2
        return 1
    fi
}

# blip_system_locale UDID <asc-locale|en-US> — switch the simulator's OWN
# language + region and reboot it, so SpringBoard's status-bar date ("9:41 AM
# Tue Sep 1" on iPad) is in the listing's language, not English. The launch
# args alone only localize the app. iPhone's status bar is just the clock, so
# only the iPad leg pays for the reboots.
blip_system_locale() {
    local udid="$1" loc="$2" lang region
    if [ "$loc" = "en-US" ]; then lang="en"; region="en_US"
    else
        set -- $(cap_locale_args "$loc")   # -AppleLanguages (xx) -AppleLocale xx_YY
        lang="${2#(}"; lang="${lang%)}"; region="$4"
    fi
    xcrun simctl spawn "$udid" defaults write -g AppleLanguages -array "$lang"
    xcrun simctl spawn "$udid" defaults write -g AppleLocale -string "$region"
    xcrun simctl shutdown "$udid"
    xcrun simctl boot "$udid"
    xcrun simctl bootstatus "$udid" >/dev/null
    sleep 3
    cap_clean_statusbar "$udid"
}

OUT_DIR="$PROJECT_ROOT/docs/appstore-screenshots"

echo "==> Generating Xcode project"
xcodegen generate > /dev/null

ONLY_KEY="${1:-}"

for entry in "${DEVICES[@]}"; do
    DEVICE_SPEC="${entry%:*}"
    DEVICE_NAME="${DEVICE_SPEC%%|*}"
    OUTPUT_KEY="${entry##*:}"
    IS_IPAD=0; [[ "$OUTPUT_KEY" == ipad* ]] && IS_IPAD=1
    [ -n "$ONLY_KEY" ] && [ "$OUTPUT_KEY" != "$ONLY_KEY" ] && continue
    DEVICE_OUT="$OUT_DIR/$OUTPUT_KEY"
    # BLIP_LOCALES_ONLY=1 backfills locale dirs (CAP_LOCALES) without touching
    # the base set or the other locales — e.g. after an interrupted run.
    if [ "${BLIP_LOCALES_ONLY:-0}" = 1 ]; then
        for LOCALE in $(cap_locales); do rm -rf "$DEVICE_OUT/$LOCALE"; done
    else
        rm -rf "$DEVICE_OUT"
    fi

    echo ""
    echo "==> $DEVICE_NAME"
    UDID="$(blip_resolve_udid "$DEVICE_SPEC")"
    echo "  UDID: $UDID"
    # Pristine device every run: no foreign apps, no stale TCC or alerts.
    xcrun simctl shutdown "$UDID" >/dev/null 2>&1 || true
    xcrun simctl erase "$UDID"
    cap_boot "$UDID"
    xcrun simctl bootstatus "$UDID" >/dev/null
    [ "$IS_IPAD" = 1 ] && blip_system_locale "$UDID" en-US
    cap_clean_statusbar "$UDID"

    echo "  Building…"
    # Pristine container each run — stale state would sidestep seeding.
    xcrun simctl uninstall "$UDID" "$BUNDLE_ID" > /dev/null 2>&1 || true
    # DerivedData OUTSIDE the repo: this tree lives in iCloud-synced Documents, and
    # fileproviderd stamps FinderInfo/fpfs xattrs on build products mid-build — codesign
    # then rejects the bundle as "detritus". /tmp is exempt.
    cap_build_install "$UDID" "$PROJECT" "$SCHEME" "$BUNDLE_ID" \
        "/tmp/blip-screenshots-dd-$OUTPUT_KEY"
    blip_only_app_installed "$UDID"

    appearance() { xcrun simctl ui "$UDID" appearance "$1"; sleep 0.6; }
    launch()     { cap_launch    "$UDID" "$BUNDLE_ID" "$1" "$ROUTE_FLAG"; }
    # A frame under ~150 KB is a blank or half-drawn launch; retake once after a
    # longer settle, then fail rather than frame an empty screen.
    shot() {
        sleep 2.6; cap_screenshot "$UDID" "$SCENE_OUT/$1.png"
        if [ "$(stat -f%z "$SCENE_OUT/$1.png")" -lt 150000 ]; then
            echo "  … $1 looks blank — retaking after a longer settle" >&2
            cap_screenshot "$UDID" "$SCENE_OUT/$1.png" 6
            [ "$(stat -f%z "$SCENE_OUT/$1.png")" -ge 150000 ] || { echo "  ✗ $1 still blank" >&2; return 1; }
        fi
    }

    # iPadOS prints the FOREGROUND app's name in the status bar — a lingering Files or
    # Settings from a previous boot photobombs scene 1. Clear the stage first.
    cap_terminate_foreign "$UDID" "$BUNDLE_ID" || true

    # Deterministic, PII-free demo content.
    cap_seed_bool "$UDID" "$BUNDLE_ID" "blip.demoSeed" true

    # Full store scene set, replayable per locale (extra launch args ride
    # via CAP_EXTRA_LAUNCH_ARGS in cap_launch; SCENE_OUT is the output dir).
    capture_scenes() {
    # 1. Overview — the card grid (dark: Blip's natural habitat)
    appearance dark
    launch "overview"; shot "01-overview"
    # 2. Bench — the redesigned result card + history (light: proves both modes)
    appearance light
    launch "bench";    shot "02-bench"
    # 3. Speed — dual-series curves, latency pair, connection grades (dark)
    appearance dark
    launch "speed";    shot "03-speed"
    # 4. Network — traceroute with the hop map (light)
    appearance light
    # Reset the segment: the traceroute scene below leaves "trace" seeded, and
    # the NEXT locale's ping shot would otherwise open on Traceroute.
    cap_seed "$UDID" "$BUNDLE_ID" "blip.demoNetworkMode" ping
    launch "network"
    # The network scene lands on Ping; the demo state fills both.
    shot "04-ping"
    # 5. Traceroute + map needs one tap; simctl can't tap, so the scene is driven
    #    by a second launch with the segment preselected via defaults.
    cap_seed "$UDID" "$BUNDLE_ID" "blip.demoNetworkMode" trace
    appearance dark
    launch "network";  shot "05-traceroute"

    appearance light
    }

    SCENE_OUT="$DEVICE_OUT"
    [ "${BLIP_LOCALES_ONLY:-0}" = 1 ] || capture_scenes

    # Localized store sets (CAP_LOCALES=big8): the FULL scene list per listing
    # locale into <rawKey>/<locale>/ on every device leg — these become each
    # locale's App Store screenshots after framing.
    if [ -n "$(cap_locales)" ]; then
        for LOCALE in $(cap_locales); do
            echo "  — locale $LOCALE"
            if [ "$IS_IPAD" = 1 ]; then
                blip_system_locale "$UDID" "$LOCALE"
                blip_only_app_installed "$UDID"
            fi
            export CAP_EXTRA_LAUNCH_ARGS="$(cap_locale_args "$LOCALE")"
            SCENE_OUT="$DEVICE_OUT/$LOCALE"
            mkdir -p "$SCENE_OUT"
            capture_scenes
        done
        unset CAP_EXTRA_LAUNCH_ARGS
        SCENE_OUT="$DEVICE_OUT"
        [ "$IS_IPAD" = 1 ] && blip_system_locale "$UDID" en-US
    fi

    cap_teardown "$UDID" "$BUNDLE_ID"
    # Hand the CPU back — the host runs many rigs at once.
    xcrun simctl shutdown "$UDID" >/dev/null 2>&1 || true
done

echo ""
echo "==> Done. Raw screenshots in: $OUT_DIR"
ls "$OUT_DIR"/*/ 2>/dev/null || true
