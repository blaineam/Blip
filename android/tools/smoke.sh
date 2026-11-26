#!/bin/bash
# Smoke test on a running emulator or device: install the APK, open Blip, walk every screen, start
# a quick benchmark from its button, and fail on any crash. Screenshots land in the output folder.
#   tools/smoke.sh path/to/app.apk out-dir
# ADB / ANDROID_SERIAL pick the adb binary and device.
set -euo pipefail
apk=$1
out=$2
adb=${ADB:-adb}
pkg=com.blainemiller.blip
mkdir -p "$out"

fail() {
    echo "FAIL: $*" >&2
    "$adb" logcat -d >"$out/logcat.txt" || true
    grep -E -A30 "FATAL EXCEPTION|Fatal signal" "$out/logcat.txt" | head -60 >&2 || true
    exit 1
}

alive() {
    "$adb" shell pidof "$pkg" >/dev/null || fail "Blip is not running ($1)"
    if "$adb" logcat -d | grep -E "FATAL EXCEPTION|Fatal signal|ANR in $pkg" >/dev/null; then
        fail "crash or ANR in the log ($1)"
    fi
}

shot() {
    "$adb" exec-out screencap -p >"$out/$1.png"
}

# The on-screen view tree, as XML.
dump() {
    "$adb" shell uiautomator dump /sdcard/ui.xml >/dev/null 2>&1 || true
    "$adb" shell cat /sdcard/ui.xml 2>/dev/null || true
}

# Looks further along the page on a small screen: attempt 1 stays put (the screen may still be
# loading), 2-5 scroll down, 6-9 scroll back up, and so on.
scroll() {
    local w h from to
    read -r w h <<<"$("$adb" shell wm size | tail -1 | grep -oE '[0-9]+x[0-9]+' | tr x ' ')"
    case $((($1 - 1) % 8)) in
        0 | 1 | 2 | 3) from=$((h * 65 / 100)) to=$((h * 35 / 100)) ;;
        *) from=$((h * 35 / 100)) to=$((h * 65 / 100)) ;;
    esac
    "$adb" shell input swipe $((w / 2)) "$from" $((w / 2)) "$to" 400
}

# Taps the centre of the element whose text or description is exactly $1: the first one, or the
# last with `tap <label> last` (a bottom-bar tab sits after a card of the same name).
tap() {
    local xml bounds i
    for i in 1 2 3 4 5 6 7 8 9; do
        xml=$(dump)
        bounds=$(printf '%s' "$xml" | tr '>' '\n' |
            grep -E "(text|content-desc)=\"$1\"" | { if [ "${2:-}" = last ]; then tail -1; else head -1; fi; } |
            sed -E 's/.*bounds="\[([0-9]+),([0-9]+)\]\[([0-9]+),([0-9]+)\]".*/\1 \2 \3 \4/') || true
        if [ -n "$bounds" ]; then
            read -r x1 y1 x2 y2 <<<"$bounds"
            "$adb" shell input tap $(((x1 + x2) / 2)) $(((y1 + y2) / 2))
            sleep 2
            return 0
        fi
        scroll "$i"
        sleep 2
    done
    printf '%s' "$xml" >"$out/ui-at-failure.xml"
    shot failure
    fail "no \"$1\" on screen"
}

expect() {
    local i
    for i in $(seq 1 "${2:-10}"); do
        dump | grep -E "(text|content-desc)=\"[^\"]*$1" >/dev/null && return 0
        scroll "$i"
        sleep 2
    done
    shot failure
    fail "expected \"$1\" on screen"
}

"$adb" install -r "$apk" >/dev/null
# The checks below read English. A language chosen for the app earlier would survive the
# reinstall; per-app languages exist from Android 13, so older devices must be set to English.
"$adb" shell cmd locale set-app-locales "$pkg" --locales en-US >/dev/null 2>&1 || true
"$adb" logcat -c
"$adb" shell am start -W -n "$pkg/.MainActivity" >/dev/null
sleep 5
alive launch
expect "Storage" 20
shot 1-overview

# Detail screens, by their cards.
n=2
for card in CPU Memory Storage Battery Thermal; do
    tap "$card"
    alive "$card detail"
    shot "$n-$card"
    n=$((n + 1))
    "$adb" shell input keyevent KEYCODE_BACK
    sleep 2
done

tap "Network" last
alive "network tab"
expect "Traceroute"
shot 7-network

tap "Speed"
alive "speed tab"
shot 8-speed

# The benchmark runs in the native core: this proves the JNI bridge works in the shrunk build.
tap "Bench"
tap "Quick"
expect "Cancel" 10
alive "benchmark running"
shot 9-bench-running
expect "Last result" 90
alive "benchmark done"
shot 10-bench-result

# Rotation must neither crash nor lose the result.
"$adb" shell settings put system accelerometer_rotation 0
"$adb" shell settings put system user_rotation 1
sleep 4
alive "rotated"
shot 11-landscape
"$adb" shell settings put system user_rotation 0
sleep 3

tap "Overview"
tap "Settings"
alive "settings"
shot 12-settings

# Ping through the native core, against the device itself so no network is needed.
"$adb" shell input keyevent KEYCODE_BACK
sleep 2
tap "Network" last
tap "1.1.1.1"
"$adb" shell input keyevent KEYCODE_MOVE_END
for _ in $(seq 1 16); do "$adb" shell input keyevent KEYCODE_DEL; done
"$adb" shell input text 127.0.0.1
"$adb" shell input keyevent KEYCODE_ESCAPE
sleep 2
tap "Ping" last
expect "Average" 20
alive "ping"
shot 13-ping

# Disk speed test (native, with the cache bypassed).
tap "Overview"
tap "Storage"
tap "256 MB"
tap "Run Test"
expect "Write" 5
expect "Random 4K read" 90
# The result names the storage that was picked, not the app's folder path.
expect "Internal storage · 256 MB" 5
alive "disk test"
shot 14-disk-result
"$adb" shell input keyevent KEYCODE_BACK
sleep 2

# The snapshot shortcut writes the Markdown file and opens the share sheet with it.
"$adb" shell am start -n "$pkg/.MainActivity" -a "$pkg.SHARE_SNAPSHOT" >/dev/null
sleep 4
expect "Blip-Snapshot" 10
alive "share snapshot"
shot 15-share
"$adb" shell input keyevent KEYCODE_BACK
sleep 2

# A shortcut runs once: rotating afterwards must not start the benchmark again.
"$adb" shell am force-stop "$pkg"
"$adb" shell am start -W -n "$pkg/.MainActivity" -a "$pkg.RUN_BENCHMARK" >/dev/null
expect "Cancel" 15
tap "Cancel"
expect "Run Benchmark" 20
"$adb" shell settings put system user_rotation 1
sleep 6
alive "rotated after a shortcut"
if dump | grep -q 'text="Cancel"'; then
    shot failure
    fail "rotating ran the benchmark shortcut again"
fi
shot 16-shortcut-rotated
"$adb" shell settings put system user_rotation 0

# Changing the app's language with Blip still running must switch its text (Android 13+).
if [ "$("$adb" shell getprop ro.build.version.sdk | tr -d '\r')" -ge 33 ]; then
    "$adb" shell cmd locale set-app-locales "$pkg" --locales de-DE
    expect "Benchmark ausführen|Übersicht" 15
    alive "switched to German"
    shot 17-german-live
    "$adb" shell cmd locale set-app-locales "$pkg" --locales en-US
    expect "Overview" 15
    alive "switched back to English"
fi

"$adb" logcat -d >"$out/logcat.txt"
echo "smoke test passed"
