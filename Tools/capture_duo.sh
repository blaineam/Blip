#!/usr/bin/env bash
#
# Captures Blip Stats on the iPhone Duo: the COVER panel (1398x2034) and the INNER panel
# (landscape when unfolded) — App Store slot APP_IPHONE_DUO. Mirrors the iPhone leg of
# Tools/capture_screenshots.sh (same demo seed, routes, alternating dark/light) but captures
# each scene ONLY on the panel DUO_PLAN (.local-screenshots.conf) assigns it.
#
# PRECONDITION: two booted iPhone Duo simulators, one folded (cover live) and one unfolded
# (inner live). The fold cannot be scripted, so unfold one in Xcode's device hub once; this
# script never boots, reboots, erases or shuts a Duo sim down (that would drop the posture).
# Because the Duo sims are shared (no erase), the iPhone rig's "only Blip installed" guard
# becomes: sweep foreign apps off the stage and refuse to run if any is still running.
# The iPhone rig's system-language reboot is dropped — locales use launch arguments only.
#
# Output: docs/appstore-screenshots/iphone-duo-cover/ and iphone-duo-inner/ (+ <locale>/ with CAP_LOCALES).
# Usage: ./Tools/capture_duo.sh
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"
# shellcheck disable=SC1091
source "$PROJECT_ROOT/../_shared/screenshots/capture-lib.sh"

BUNDLE_ID="com.blainemiller.Blip"
SCHEME="BlipMobile"
PROJECT="Blip.xcodeproj"
ROUTE_FLAG="blip.route"
OUT_DIR="$PROJECT_ROOT/docs/appstore-screenshots"

export CAP_APP_NAME="Blip"
export CAP_STATUSBAR_STRIP=0.03

# Scene -> panel: default below, overridden by DUO_PLAN in .local-screenshots.conf.
DUO_PLAN=(01:inner 02:cover 03:inner 04:cover 05:inner)
if grep -qE '^DUO_PLAN=' .local-screenshots.conf; then
    # shellcheck disable=SC2207
    DUO_PLAN=($(grep -E '^DUO_PLAN=' .local-screenshots.conf | sed -E 's/^DUO_PLAN=\((.*)\)/\1/'))
fi
plan_for() {  # plan_for <NN> -> inner|cover (empty if unplanned)
    local p; for p in "${DUO_PLAN[@]}"; do [ "${p%%:*}" = "$1" ] && { echo "${p#*:}"; return; }; done
}

# blip_foreign_guard UDID — the intent of blip_only_app_installed: no foreign app (and so no
# stray permission alert) in the frame. Shared sims can't be erased, so sweep + verify instead.
blip_foreign_guard() {
    cap_terminate_foreign "$1" "$BUNDLE_ID" || true
    local foreign; foreign=$(cap_running_apps "$1" | grep -vx "$BUNDLE_ID" || true)
    if [ -n "$foreign" ]; then
        echo "  ✗ foreign apps running on the Duo sim $1: $foreign" >&2
        return 1
    fi
}

xcodegen generate > /dev/null
# Persistent DerivedData outside the repo (iCloud detritus breaks codesign) and outside /tmp.
cap_duo_prepare "$PROJECT" "$SCHEME" "$BUNDLE_ID" "$HOME/Library/Developer/Xcode/DerivedData/blip-shots-duo"

for POSTURE in cover inner; do
    UDID="$(cap_duo_udid "$POSTURE")"
    OUT="$OUT_DIR/iphone-duo-$POSTURE"
    echo "==> Duo $POSTURE ($UDID)"
    # Never wipe existing locale dirs when CAP_SKIP_CLEAN is set.
    if [ -z "${CAP_SKIP_CLEAN:-}" ]; then rm -rf "$OUT"; fi
    mkdir -p "$OUT"
    blip_foreign_guard "$UDID"
    # Deterministic, PII-free demo content.
    cap_seed_bool "$UDID" "$BUNDLE_ID" "blip.demoSeed" true

    appearance() { xcrun simctl ui "$UDID" appearance "$1" >/dev/null 2>&1 || true; sleep 0.6; }
    launch() {  # launch <route> — launch args only; $EXTRA carries -AppleLanguages/-AppleLocale
        xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
        sleep 0.4
        # shellcheck disable=SC2086
        xcrun simctl launch "$UDID" "$BUNDLE_ID" "-$ROUTE_FLAG" "$1" $EXTRA >/dev/null
        sleep 3
    }
    shot() {  # shot <dir> <file> — retake once if the frame is blank/half-drawn
        local f="$1/$2.png"
        cap_duo_shot "$POSTURE" "$f" 2.6
        if [ "$(stat -f%z "$f")" -lt 150000 ]; then
            echo "  … $2 looks blank — retaking after a longer settle" >&2
            cap_duo_shot "$POSTURE" "$f" 6
            [ "$(stat -f%z "$f")" -ge 150000 ] || { echo "  ✗ $2 still blank" >&2; return 1; }
        fi
    }
    # want <NN> — is this scene assigned to the current panel?
    want() { [ "$(plan_for "$1")" = "$POSTURE" ]; }

    capture_scenes() {
        local dir="$1"; mkdir -p "$dir"
        # 1. Overview — the card grid (dark)
        if want 01; then appearance dark;  launch overview; shot "$dir" 01-overview; fi
        # 2. Bench — result card + history (light)
        if want 02; then appearance light; launch bench;    shot "$dir" 02-bench; fi
        # 3. Speed — dual-series curves, latency pair, grades (dark)
        if want 03; then appearance dark;  launch speed;    shot "$dir" 03-speed; fi
        # 4. Ping (light). Reset the segment first: traceroute leaves "trace" seeded.
        if want 04; then
            appearance light
            cap_seed "$UDID" "$BUNDLE_ID" "blip.demoNetworkMode" ping
            launch network; shot "$dir" 04-ping
        fi
        # 5. Traceroute + hop map (dark): segment preselected via defaults, as in the iPhone rig.
        if want 05; then
            cap_seed "$UDID" "$BUNDLE_ID" "blip.demoNetworkMode" trace
            appearance dark
            launch network; shot "$dir" 05-traceroute
        fi
        # Leave the segment on ping for whatever runs next.
        cap_seed "$UDID" "$BUNDLE_ID" "blip.demoNetworkMode" ping
        appearance light
    }

    EXTRA=""
    capture_scenes "$OUT"
    # Localized sets (CAP_LOCALES=big8 or a space list) -> <rawKey>/<locale>/. Launch args only:
    # a system-language change would reboot the sim and drop the unfolded posture.
    for LOCALE in $(cap_locales); do
        echo "  — locale $LOCALE"
        EXTRA="$(cap_locale_args "$LOCALE")"
        [ -z "${CAP_SKIP_CLEAN:-}" ] && rm -rf "$OUT/$LOCALE"
        capture_scenes "$OUT/$LOCALE"
    done
    xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
    cap_clear_statusbar "$UDID"
done
echo "✓ Duo captures: $OUT_DIR/iphone-duo-{cover,inner}"
