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
# iPadOS puts the TAB BAR at the top of the window — the guard's status-bar strip
# OCRs Blip's own tab labels there. They're ours, not leaks.
export CAP_STATUSBAR_ALLOW="Overview,Bench,Speed,Network"

DEVICES=(
    "iPhone 17 Pro Max:iphone-6.9"
    "iPad Pro 13-inch (M5):ipad-13"
)

OUT_DIR="$PROJECT_ROOT/docs/appstore-screenshots"

echo "==> Generating Xcode project"
xcodegen generate > /dev/null

ONLY_KEY="${1:-}"

for entry in "${DEVICES[@]}"; do
    DEVICE_NAME="${entry%%:*}"
    OUTPUT_KEY="${entry##*:}"
    [ -n "$ONLY_KEY" ] && [ "$OUTPUT_KEY" != "$ONLY_KEY" ] && continue
    DEVICE_OUT="$OUT_DIR/$OUTPUT_KEY"
    rm -rf "$DEVICE_OUT"

    echo ""
    echo "==> $DEVICE_NAME"
    UDID="$(cap_resolve_udid "$DEVICE_NAME")"
    echo "  UDID: $UDID"
    cap_boot "$UDID"
    cap_clean_statusbar "$UDID"

    echo "  Building…"
    # Pristine container each run — stale state would sidestep seeding.
    xcrun simctl uninstall "$UDID" "$BUNDLE_ID" > /dev/null 2>&1 || true
    # DerivedData OUTSIDE the repo: this tree lives in iCloud-synced Documents, and
    # fileproviderd stamps FinderInfo/fpfs xattrs on build products mid-build — codesign
    # then rejects the bundle as "detritus". /tmp is exempt.
    cap_build_install "$UDID" "$PROJECT" "$SCHEME" "$BUNDLE_ID" \
        "/tmp/blip-screenshots-dd-$OUTPUT_KEY"

    appearance() { xcrun simctl ui "$UDID" appearance "$1"; sleep 0.6; }
    launch()     { cap_launch    "$UDID" "$BUNDLE_ID" "$1" "$ROUTE_FLAG"; }
    shot()       { sleep 2.6; cap_screenshot "$UDID" "$DEVICE_OUT/$1.png"; }

    # iPadOS prints the FOREGROUND app's name in the status bar — a lingering Files or
    # Settings from a previous boot photobombs scene 1. Clear the stage first.
    cap_terminate_foreign "$UDID" "$BUNDLE_ID" || true

    # Deterministic, PII-free demo content.
    cap_seed_bool "$UDID" "$BUNDLE_ID" "blip.demoSeed" true

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
    launch "network"
    # The network scene lands on Ping by default; the demo state fills both.
    shot "04-ping"
    # 5. Traceroute + map needs one tap; simctl can't tap, so the scene is driven
    #    by a second launch with the segment preselected via defaults.
    cap_seed "$UDID" "$BUNDLE_ID" "blip.demoNetworkMode" trace
    appearance dark
    launch "network";  shot "05-traceroute"

    appearance light
    cap_teardown "$UDID" "$BUNDLE_ID"
done

echo ""
echo "==> Done. Raw screenshots in: $OUT_DIR"
ls "$OUT_DIR"/*/ 2>/dev/null || true
