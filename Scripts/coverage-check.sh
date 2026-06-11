#!/usr/bin/env bash
#
# Blip app-logic coverage gate (ratchet).
#
# Runs the hermetic unit suite (BlipTests — hosted by the direct Blip app,
# which skips all UI/monitor startup under XCTest) with code coverage enabled,
# computes APP-LOGIC line coverage, and FAILS (exit 1) if it drops below
# MIN_COVERAGE. Raise MIN_COVERAGE as coverage grows; never lower it.
#
# APP-LOGIC coverage = covered/executable lines over all non-test targets,
# deduplicated per source file, MINUS the explicit exclusions below.
# Exclusions are explicit by design — never silent:
#   - the test bundle (BlipTests.xctest)
#   - Views/ + App/: SwiftUI view bodies and the menu-bar app shell
#     (NSStatusItem/popover/panel plumbing) — only ever exercised by a live
#     UI session, not unit-testable logic
#   - Services/: the hardware/network monitors (IOKit SMART/SMC plug-ins,
#     mach/sysctl readers, traceroute + speed-test engines, WebView widget
#     runner, MMDB reader, GeoIP downloader). Their pure helpers (netstat
#     parsing, URL normalization, result recording, volume enumeration) ARE
#     unit-tested, but the files are dominated by hardware/network paths that
#     can't run hermetically. The intent layer over them IS gated.
#   - Shared/HelperClient.swift: TCP IPC client to the helper app
#   - Intents/BlipAppShortcuts.swift: declarative AppShortcuts phrase list —
#     no branching logic; Shortcuts-exercised, not unit-testable
#   - Intents/AppIntentsEnvironment.swift: dependency-injection glue + the
#     real-disk benchmark runner (writes 128 MB+ to disk — exercised by the
#     QA checklist, not unit tests). The intents that consume these seams ARE
#     gated via mocked seams.
#   - generated code (*/DerivedSources/*, *GeneratedAssetSymbols*)
#
# Gated scope therefore = Models/ (metric mapping inputs, history buffer,
# recommendations engine, host validation), Intents/ (entities, queries,
# all 8 intents), Shared/TOTP.swift + Shared/HelperProtocol.swift.
#
# Env:
#   MIN_COVERAGE   gate threshold, integer percent (default: ratchet below)

set -euo pipefail

# ── The ratchet. Only raise, never lower. ──
# Measured 87.85% app-logic on 2026-06-11 (initial suite: 79 tests over the
# new App Intents layer + models). MIN sits ~4% under the measurement to
# absorb minor drift; raise it as coverage grows.
MIN_COVERAGE="${MIN_COVERAGE:-84}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCHEME="Blip"
TEST_TARGET="BlipTests"
DD="/tmp/blip-coverage-dd"
XCRESULT="/tmp/blip-coverage-$$.xcresult"

echo "=== Blip app-logic coverage gate (min ${MIN_COVERAGE}%) ==="

cd "$ROOT"

# The pbxproj is gitignored — make sure it exists/matches project.yml.
if ! [ -d "Blip.xcodeproj" ] || [ "project.yml" -nt "Blip.xcodeproj/project.pbxproj" ]; then
    echo "  regenerating Blip.xcodeproj from project.yml…"
    xcodegen generate > /dev/null
fi

rm -rf "$XCRESULT"
LOG="/tmp/blip-coverage-$$.log"
if ! xcodebuild test \
        -project "Blip.xcodeproj" \
        -scheme "$SCHEME" \
        -only-testing:"$TEST_TARGET" \
        -destination "platform=macOS,arch=arm64" \
        -enableCodeCoverage YES \
        -parallel-testing-enabled NO \
        -derivedDataPath "$DD" \
        -resultBundlePath "$XCRESULT" \
        > "$LOG" 2>&1; then
    echo "  UNIT TESTS FAILED — log: $LOG"
    tail -30 "$LOG"
    exit 1
fi
echo "  unit suite passed."

xcrun xccov view --report --json "$XCRESULT" > "/tmp/blip-coverage-$$.json"

python3 - "$MIN_COVERAGE" "/tmp/blip-coverage-$$.json" << 'PYEOF'
import json, fnmatch, sys
min_cov = float(sys.argv[1])
d = json.load(open(sys.argv[2]))
EXCLUDE = [
    "*/BlipTests/*",
    "*/Blip/Sources/Views/*",
    "*/Blip/Sources/App/*",
    "*/Blip/Sources/Services/*",
    "*/Blip/Sources/Shared/HelperClient.swift",
    "*/Blip/Sources/Intents/BlipAppShortcuts.swift",
    "*/Blip/Sources/Intents/AppIntentsEnvironment.swift",
    "*/DerivedSources/*", "*GeneratedAssetSymbols*",
]
files = {}
for t in d["targets"]:
    if t["name"].endswith("Tests.xctest"):
        continue
    for f in t["files"]:
        p = f["path"]
        if any(fnmatch.fnmatch(p, pat) for pat in EXCLUDE):
            continue
        prev = files.get(p)
        if prev is None or f["coveredLines"] > prev["coveredLines"]:
            files[p] = f
cov = sum(f["coveredLines"] for f in files.values())
ex = sum(f["executableLines"] for f in files.values())
pct = 100.0 * cov / ex if ex else 0.0
print(f"  app-logic coverage: {pct:.2f}% ({cov}/{ex} lines, {len(files)} files)")
print(f"  raw total (no exclusions): {d['lineCoverage']*100:.2f}%")
if pct < min_cov:
    print(f"  FAIL: below MIN_COVERAGE={min_cov:.0f}%")
    worst = sorted(files.values(), key=lambda f: f["lineCoverage"])[:8]
    for f in worst:
        print(f"    {f['lineCoverage']*100:5.1f}%  {f['path'].rsplit('/',1)[-1]}")
    sys.exit(1)
print(f"  OK: >= MIN_COVERAGE={min_cov:.0f}%")
PYEOF

rm -rf "$XCRESULT" "/tmp/blip-coverage-$$.json" "$LOG"
echo "=== coverage gate passed ==="
