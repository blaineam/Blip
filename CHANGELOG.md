# Changelog

## Unreleased

### Added — iOS listing pipeline & store safety (wave 3)
- **Universal purchase wiring.** Blip for iOS ships as `com.blainemiller.Blip` — the SAME app record as the Mac App Store build (the iOS platform was added to the existing Blip Stats app). Widget extension is `com.blainemiller.Blip.widgets`; the apple-store CI iOS lane and dev-profile mint script follow.
- **App Store screenshot pipeline for iOS + iPadOS.** `Tools/capture_screenshots.sh` (+ `.local-screenshots.conf`) captures the required 6.9" iPhone (1320×2868) and 13" iPad (2064×2752) canvases from the iPhone 17 Pro Max / iPad Pro 13" (M5) simulators, alternating dark and light scenes so the set itself demonstrates dark-mode support; `docs/appstore-screenshots/Blip-{iphone,ipad}.monkr` hold the Deep Current-branded frame designs (iPhone 17 Pro Max deep-blue / iPad Pro 13" space-black) for the shared Monkr render + ASC upload pipeline.
- **Screenshot demo mode** (`blip.demoSeed`): curated PII-free data through the app's real types — trending bench history, dual-curve speed results with latency pair and grades, and network-tools scenes built on RFC 5737 documentation addresses (192.0.2.x et al., addresses that by definition belong to no one) with a canned SF→London hop map.
- **Simulators now identify as the simulated device** (`SIMULATOR_MODEL_IDENTIFIER`) — the Device card says "iPhone 17 Pro Max," not "Simulator (arm64)."
- **MillerKit 1.2.1**: the "Support Future Development" funding link now auto-hides in App Store and TestFlight builds (receipt-based `Distribution` detection) — Guideline 3.1.1 risk eliminated without losing the row in direct-download builds.

### Added — Blip for iOS field-feedback wave 2
- **Neural benchmark leg.** Blip Bench gains a fifth category: Vision feature-print inference throughput, routed to the Neural Engine on hardware that has one (Vision decides — there is no public force-ANE switch, so the leg honestly measures what the OS's ML stack delivers). New frozen reference unit `npu.featureprint`; composites now fold it in; Mac and iOS both run it.
- **Bench result, redesigned.** Gradient hero score with delta-vs-best, per-category bars scaled against this device's own best full run, the sustained-phase thermal timeline drawn from the run's own samples, device + date footer.
- **Traceroute hop map.** With the GeoIP database installed, hops render on a MapKit map — numbered markers joined by the route line, destination in green; private-range hops are honestly skipped (the list stays the complete record).
- **Speed test: download and upload as separate charted series** in complementary colors (teal down, orange up) — live, in the result card, and in the share image, which now embeds the chart.
- **Latency, idle and under load.** Every speed test measures ping before the transfer and *during* the download (bufferbloat — the number that separates a line that benchmarks well from one that video-calls well). Both appear in results, history, share cards, and the speed widget.
- **Connection grades.** Each result grades what the line can reliably do — Browsing, HD/4K streaming, Video calls (latency-capped), Cloud gaming (latency-capped), Big uploads — A/B/C/F chips computed from measured throughput + loaded latency, in the result card and share card.
- **Widgets, polished.** Branded gradient washes per widget (purple bench / orange storage / teal speed), gradient score, complementary down/up colors, the latency pair, and the neural stat on the medium bench widget.
- **`Scripts/mint-dev-profiles.mjs`** — mints iOS development provisioning profiles (app + widget) via the ASC API and installs them locally, because CLI `xcodebuild` on this Mac can't see accounts. App-group assignment still needs one Xcode Cloud build to register; after that, dev builds carry widgets too.
- **Bench cold launch shows your last result** instead of an empty pitch (history was already loaded; now `lastResult` seeds from it).

### Added — docs site 2.0
- **blip.wemiller.com tells the 2.0 story**: hero says free + Mac/iPhone/iPad, a new "Now on iPhone & iPad" section composes transparent Monkr device renders (iPhone overview, iPhone traceroute-with-map, iPad overview) into the layout, What's New retitled for v2.0.0, the free-FAQ covers every platform, and a new iPhone/iPad FAQ entry — all 19 new strings translated across the site's 9 languages.

### Fixed — macOS share + bench panel (field-tested)
- **The GPU row strobed in and out of the popover** — one missed helper poll (a fresh TCP fetch every 2 s can lose its 3 s window while a benchmark saturates the machine) flipped `isConnected` and yanked every helper-gated row. Disconnection is now debounced (three consecutive misses ≈ 6 s); one success reconnects instantly, and the last snapshot's values hold through the gap.
- **Bench panel polish**: the history chart no longer overflows under the score table (height is a parameter), the sustained flame pulses in place via `symbolEffect` (the repeat-forever scale animation was leaking into layout and sending it flying), and the composite hero scales down instead of wrapping its digits.
- **The share sheet died with the hover panel** — the click that picks a share option is a global mouse-down, which tripped the popover's close-all monitor (and the transient popover's own auto-close). Shares now run through NSSharingServicePicker with a hold protocol: the panels pin open while the picker (and any compose window) is in flight.
- **Shares now carry the actual image** — ShareLink handed services a temp-file URL; the picker shares real NSImage + caption items (the snapshot shares its Markdown file).
- **Mac bench running state matches iOS** — legs animate in with scores + checkmarks, active leg pulses, sustained shows live %-held with temperature/fan readouts.
- **History matches iOS** — score bar chart + a table of recent runs (score, quick/full, date) instead of a bare "N runs" counter.
- **The panel wash reaches the edges** — the purple gradient is now a deliberate full-bleed background applied outside the panel padding.

### Added — macOS parity (share + styling)
- **Share everywhere on the Mac, like iOS**: the Bench panel and the network Speed Test section share results as a rendered dark card image + accompanying text, and the popover footer gains a one-click all-stats Markdown snapshot (lazily produced — only written when actually shared). Same visual cards as iOS.
- **Mac speed test, second edition**: idle vs under-load latency (ICMP median, bufferbloat) measured on every run, live download/upload drawn as separate teal/orange curves (shared DualCurveChart), per-activity connection grades on the result, and the running state shows the big rounded live number — matching the iOS styling.
- **Mac Bench panel restyle**: gradient composite hero, per-category proportional bars scaled against this Mac's own best, share button.
- ICMPProbe, DualCurveChart, and ConnectionGrades promoted to `Shared/` — one implementation for both platforms; the Mac string catalog gains the corresponding translations.

### Fixed — wave 3
- **Mac Bench panel clipped its content** — it declared 300pt in a 260pt hover host; now 260 like every other panel.
- **"Support Future Development" leaked into the macOS TestFlight build** — MillerKit 1.2.2 makes the gate structural: iOS-family builds never show external funding links, macOS decides by its own code signature (Apple-signed hides; Developer ID/dev-signed is direct), receipt presence only as a fast path.
- **iOS App Store upload validation**: `LSRequiresIPhoneOS` added to the hand-written Info.plist (required for iOS store bundles) and `ITSAppUsesNonExemptEncryption=false` declared on app + widget, matching the Mac.

### Fixed — wave 2
- **Bench history chart rendered nothing.** Two stacked causes: date-x bars with `unit: .second` were sub-pixel wide, and the index-x rewrite used `.ratio` bar width, which needs a band scale — bars now index-x with fixed width.
- **Speed share text/cards carry idle + loaded latency and grades.**

### Added — Blip for iOS field-feedback wave
- **Per-card drill-in details.** Every Overview card (CPU, Memory, Storage, Network, Battery, Thermal, Device) opens a full detail screen; the flat "Details" list is gone. Reference-worthy values (IPs, model identifier, OS) carry tap-to-copy buttons with haptic + checkmark feedback.
- **Human device names.** "iPhone18,2" now reads "iPhone 17 Pro Max" — a codename→marketing-name table with an honest fallback (unknown ids show the codename; simulators say so).
- **Uptime derived from boot.** The Device card and detail screen show wall-clock uptime from `kern.boottime` (includes sleep) alongside awake time.
- **WAN IP, tap-to-reveal.** The Network detail screen fetches your public address from api.ipify.org **only when you tap reveal** — checking your public IP necessarily tells that service your IP, so Blip never does it unprompted. VPN presence is detected from utun/ipsec interfaces; cellular devices show the radio generation (5G/LTE).
- **Ping + Traceroute on iOS** — a new Network tab. ICMP datagram sockets (the sandbox-legal mechanism): live RTT sparkline, loss/avg/min–max stats, per-hop traceroute with timeout rows and a checkered flag at the destination. Targets configurable in Settings; hops get city/country annotations once the offline GeoIP database (DB-IP Lite, same one as the Mac) is downloaded in Settings.
- **Speed test, second edition.** The 25 Mbps ceiling is fixed — byte counting moved from a per-byte `AsyncBytes` loop into a `URLSession` delegate that sees whole buffers, the same way the Mac counts. The Speed tab gains a source menu (public OpenSpeedTest service via an invisible-WebKit port of the Mac's widget runner, or your own server), a capped 10-run history, and per-result share buttons. The server address lives in Settings now, with a "Configure" link from the tab.
- **Disk speed tests on iOS.** Storage detail hosts sequential write/read tests with caching disabled and the flush included — internal storage, or any folder you pick in Files (USB-C drives, SMB shares).
- **Animated bench running state.** The Bench tab narrates the run: each leg's score animates in with a checkmark the moment it lands, the active leg pulses with breathing dots, and the sustained phase shows live "% held" plus thermal state. No more blank screen with a progress bar.
- **Share cards.** Benchmark and speed results share as a rendered image + accompanying text (ImageRenderer, dark branded card) anywhere iOS shares go.
- **Snapshot export.** One toolbar button writes everything Blip knows — device, CPU, memory, storage, network, recent speed tests — to a timestamped Markdown file for the share sheet.
- **Shortcuts support on iOS**: Run Benchmark (quick/full), Run Speed Test, and Get Device Snapshot (returns the Markdown) — all registered as App Shortcuts.
- **Honest suggestions.** The Overview surfaces actionable advice only when a real signal fires: storage nearly full, thermal throttling, Low Power Mode while charged, Low Data Mode active, low app-available memory.
- **MillerKit settings.** The iOS Settings screen now uses the suite's shared Support/About/rating sections, plus Blip-specific knobs (speed server, ping/traceroute targets, GeoIP database).
- **App icon for iOS** — the Mac's sonar-and-bars artwork, flattened opaque at 1024 for the iOS squircle.
- **CI: `apple-store` grew a second lane** — Blip for iOS (com.blainemiller.BlipMobile) submits/TestFlights alongside the Mac app from the same tag.

### Fixed
- **Memory card sparkline bled past the card's bottom edge** — compact charts now clip to their frames (Swift Charts paints marks outside the plot with hidden axes).
- **Traceroute never saw its echo reply** — XNU delivers the full IP datagram on ICMP datagram sockets (unlike Linux), so the ICMP type must be read past the IP header. Field-caught: hops kept probing past the destination.
- **CoreTelephony XPC spam** — one cached `CTTelephonyNetworkInfo` instead of a fresh XPC connection every 2-second sample tick.
- **Bench history test polluted the real store** — the app-group round-trip test now snapshots and restores `benchHistory.v1`, so fake composite-1 entries no longer linger in the visible history after a test run.

### Added
- **Settings → "Support Future Development"** (MillerKit 1.2.0): a heart row in the *Enjoying Blip?* block that opens wemiller.com/support — GitHub Sponsors, Ko-fi, a one-time tip. Blip is free on every channel, so the ask lives where the rating ask already does.

### Docs / Site
- **The Mac App Store build is now free** — Blip Stats on the Mac App Store no longer carries a price; the direct download, Homebrew cask and App Store build are all free and identical. The landing page and README say so, and the old "Why does the App Store version cost…" FAQ is now "Is Blip really free?"
- **Support future development** — the landing page and README gained a support block with GitHub Sponsors and Ko-fi links (plus a link to every way to support at wemiller.com/support)

## v1.8.0 (build 57)

### Removed
- **"Open Support in Its Own Window" is gone from Settings**, and so is the support window itself. The button re-opened content already inline on the same screen. The window behind it was worse: Blip is `LSUIElement`, and in an accessory app a SwiftUI `Window` scene is *not* created on demand — it materialises at launch and stays in the window list for the app's lifetime, so every user got a second Settings-lookalike (900×450) they never asked for and couldn't permanently dismiss. Scene deleted. Support lives in Settings, which is Blip's one real window; the popover's support row opens it through `AppDelegate.openSettings()` — the same path as the gear button, so the window carries the live `helperClient` and `monitor`.

### Fixed
- **Version numbers are read from the app bundle.** Settings and the popover footer both did their own `Bundle.main.infoDictionary` lookup with a `?? "1.0.0"` fallback — a fallback indistinguishable from a real version if it ever fired. Both use `MillerKit.AppVersion` now, which resolves the enclosing `.app` rather than whatever bundle the calling code happens to live in. The helper-outdated comparison reads from the same source.

### Changed
- MillerKit 1.1.0.
- Blip Helper is versioned 1.8.0 (build 16), in lockstep with the app, so the "an update to Blip Helper is available" banner doesn't fire against the helper this release ships with.

## v1.7.1

- **Liquid-glass app icon** — the icon's bars-and-blip glyph is now a transparent Icon Composer layer over the manifest's navy fill, so macOS renders the same glass depth (shadow + translucency) as the rest of the suite. Previously the layer was a fully opaque square that occluded the fill and read as a flat tile.
- `Scripts/generate-icon.swift` now emits the transparent glyph layer alongside the legacy asset-catalog renders.

## v1.7.0

- **Fully localized in 8 languages** — German, Spanish, French, Italian, Japanese, Korean, Portuguese (Brazil), and Simplified Chinese.
- **Dedicated Support window** (via the shared MillerKit support kit); the rating prompt moved out of Settings to a considerate moment.
- **MillerKit resolves from GitHub** so CI builds no longer depend on machine layout.

## v1.6.1

- **App Store screenshot refresh** — replaces the 1.6.0 listing's screenshot #2, which shipped with a stray notification banner visible behind the CPU popover (approved listings are immutable, so the corrected, uniform 5-scene set rides this release). No functional changes from 1.6.0 build 53.

## v1.6.0

### Features
- **Shortcuts (App Intents)** — Blip's monitoring and tools are now scriptable from the Shortcuts app (and Spotlight) via eight actions: **Get System Metric** (a dynamic, searchable catalog of 37 metrics across CPU, memory, disk + S.M.A.R.T., GPU, network, battery, temperatures/fans, and system — returns a chainable number, with optional average/min/max over Blip's in-memory ~2-minute history for the seven charted metrics), **Run Drive Speed Test** (pick any mounted volume — wired to the same per-volume benchmark as the Disk panel, results land in its history), **Run Network Speed Test** (OpenSpeedTest public or your self-hosted server, mirroring the panel's provider choice), **Run Traceroute** (samples the continuous MTR session for 3–120 s and returns a hop/loss/latency summary; optionally leaves the session running), **Stop Traceroute**, **Open Traceroute Map** (optionally pre-targeting a host), and **Get/Set Blip Setting** over a curated catalog (menu-bar toggles, layout, ping/traceroute targets, speed-test server — hosts and URLs validated; `launchAtLogin` deliberately excluded since flipping the default wouldn't re-register the login item; a structural secrets gate keeps anything sensitive out of Shortcuts). Zero-setup App Shortcut phrases included ("Run a drive speed test in Blip", …)
- **Per-volume speed test** — each volume in the Disk panel has a gauge button that targets that drive and runs the benchmark in one click (sandbox-safe: the App Store build one-click-confirms access to external volumes)

### Fixes (build 53)
- **"Open Traceroute Map" auto-starts the trace** — opening the map with a host now starts the MTR session before the window appears, so it comes up live instead of sitting on "Enter a host and press Start." The window also keeps polling while visible, so a Shortcut-started trace shows up even if the map was already open (and the host field adopts the externally-traced target)
- **"Run Network Speed Test" waits for the measured result** — the action returned immediately with a stale "cancelled" error on any server while the test kept running in the background (`runOnce` raced the freshly spawned run task and read the previous run's phase). `start()` now marks the tester running synchronously and `runOnce` awaits the run task's actual lifetime, so the Shortcut returns the real measured down/up throughput. ("Run Drive Speed Test" was audited too — it already awaited its benchmark correctly)

### Build & Tests
- **Unit test suite from scratch** — new `BlipTests` target (79 hermetic tests, ~13 s, hosted by the direct app which skips all UI/monitor startup under XCTest): the full App Intents layer via mocked monitor/tester seams (metric catalog & mapping, entity queries, speed-test and traceroute parameter validation, settings get/set), plus the recommendations engine, history ring buffer, host validation, TOTP, helper IPC framing, and netstat parsing. Wired into the `Blip` scheme's test action and CI
- **Coverage ratchet** — `Scripts/coverage-check.sh` gates app-logic line coverage (measured 87.85% at introduction, MIN 84%; explicit, documented exclusions for SwiftUI bodies, the app shell, and the hardware/network monitor internals) and runs before every local-CI archive via `PREBUILD_CMD`
- **Zero warnings** — fixed the four pre-existing build warnings (two unused `fcntl` results in the disk benchmark, two `var`-never-mutated MMDB decoders); both app variants now compile warning-free. BlipHelper too: the deprecated `String(cString:)` process-path decode in `HelperDaemon` is now `String(decoding:as:)`, so the helper also builds warning-free
- Debug builds disable the hardened runtime so the test bundle can be injected into the test host; Release/notarized builds keep it enabled
- **CI binary-size gate raised 5 MB → 8 MB** — the App Intents metadata and the v1.5.0/v1.6.0 feature wave grew the direct binary to ~5.7 MB, tripping the old featherlight guard; the gate stays to catch runaway growth

## v1.5.0

### Features
- **Optimization recommendations** — a dismissable "Suggestion" banner at the top of the popover surfaces actionable advice to improve performance, health, and longevity: runaway-CPU apps, high memory pressure / heavy swap, thermal throttling, a nearly-full startup disk, S.M.A.R.T. warnings, low SSD life, and weak battery health. Highest-severity first; dismissed items stay hidden for 24h (or until the condition worsens)
- **Traceroute map (fully on-device geolocation)** — the Traceroute/MTR section has a "Map" disclosure that geolocates each hop and plots the path on a MapKit map, revealing hops one-by-one so you can watch the route travel across the world. Geolocation is done **entirely on-device** from an **optional, user-downloaded database** — DB-IP IP-to-City Lite, free for commercial use under CC BY 4.0 — so **no IP addresses are ever sent to a third-party geolocation service**. Manage it in **Settings → Network → Location Database**: download, remove, update on demand, or enable **automatic monthly updates**. It's ~130 MB and ships with a tiny built-in MMDB reader, keeping Blip's zero-dependency footprint. If the database isn't installed the map shows a prompt and plots nothing
- **Kill processes from the menu bar** — hover any row in the CPU/Memory top-process lists to reveal a kill control (two-click confirm; ⌥ for force/SIGKILL). In the sandboxed App Store build the request is routed through the helper over the TOTP-authenticated IPC channel; the direct build signals locally. The helper runs as you, so user-owned processes can be terminated and system/root processes fail gracefully with a clear message
- **Live Traceroute / MTR in the Network panel** — a new expandable section runs a continuous `traceroute` and accumulates MTR-style per-hop stats (sent/received, loss %, last/avg/best/worst latency), refreshing ~1×/sec with color-coded loss. Runs in the unsandboxed helper (with a local fallback in the direct build); the target host is validated and passed as an argument vector, never shell-interpolated. Set the **target host in Settings → Network** (hover panels can't take keyboard focus)
- **Network speed test (multi-gigabit)** — an expandable "Speed Test" section in the Network panel measures download/upload throughput using several concurrent `URLSession` transfers, counted at the chunk level via a session delegate so multi-gig links are measurable. Runs against an **OpenSpeedTest** server — open-source and explicitly sanctioned for direct use. **Self-host one for free** (no third parties, unlimited): `docker run --rm -p 3000:3000 openspeedtest/latest`, then set its address in **Settings → Network** (e.g. `http://192.168.1.50:3000`). Shows live Mbps/Gbps during the run, a result history sparkline, and an optional "auto-run every N minutes" interval mode
- **Disk speed test** — an expandable "Speed Test" section in the Disk panel benchmarks sequential write/read MB/s (plus random-read IOPS) using uncached POSIX I/O (`F_NOCACHE`) so results reflect the device, not the page cache. **Benchmark any volume** — "Change…" prompts for a folder on an external drive (persisted via a security-scoped bookmark) or stick with the boot volume. Includes a size picker, a result history sparkline, and an optional interval mode

### Fixes
- **External-drive disk usage is correct** — drives on exFAT / non-APFS filesystems no longer read as 100% full. The `volumeAvailableCapacityForImportantUsage` key returns 0 for those volumes; free space now falls back to the plain available capacity, then to `statfs`, so external drives report their real usage
- **Detail panels fit any display** — each hover panel is now capped to the visible height of the screen it appears on and scrolls when its content is taller, instead of growing past the top/bottom of the screen on smaller or scaled displays
- **Panel state survives collapse** — speed-test results/history and a running Traceroute/MTR session are preserved when a detail panel is dismissed and reopened (the test engines now live in the app, not the transient panel views); only PII like IP addresses is hidden while closed
- **Speed test uses OpenSpeedTest only** — Blip no longer reverse-engineers public web speed tests (the earlier Cloudflare/OVH/Hetzner options are removed). Pick the server right in the Speed Test panel: **OpenSpeedTest (public)** or **Self-hosted**. OpenSpeedTest is open-source and sanctioned for direct use, so there's no unsanctioned third-party endpoint; OpenSpeedTest is credited in-panel with a one-click "how to self-host" link
  - **Public** drives OpenSpeedTest's official hosted test **headlessly** (a hidden, off-screen WebView running their widget), auto-starts it, and reads the completed download/upload result **straight into Blip's native chart/history** — so the public test looks and graphs exactly like a self-hosted run, no separate window. (Best-effort: it reads the page's result fields, so it could need updating if OpenSpeedTest changes their markup.) Manual runs only — interval auto-run isn't allowed against the public service
  - **Self-hosted** runs the native multi-gig engine against your own server (Docker one-liner), with full interval auto-run; bytes are counted at the chunk level for accurate multi-gig results
- **Speed-test history charts** (network and disk) now appear from the very first result, with point marks so each individual run is visible — not just after two or more runs
- **External-drive S.M.A.R.T.** — drive health now also reads external SATA/USB SSDs via the ATA/SAT SMART user client (overall pass/fail is reliable; life%/temperature/power-on hours are shown when the USB bridge reports them). Works in-process in the direct build and via the helper in the App Store build. External drives whose USB/Thunderbolt bridge can't pass through wear details (notably NVMe-in-USB enclosures — macOS provides no NVMe-over-USB SMART passthrough at all) now show just the Verified/Failing verdict, with no empty placeholder card
- **Network speed-test chart** shows both upload and download series (like the disk read/write chart)
- **Interval-run guards** — automated interval speed tests are skipped on metered/expensive/constrained networks, and disk benchmarks are skipped for drives reporting under 30% health. Manual runs are never blocked
- **Traceroute & speed-test targets** moved to Settings → Network (and the disk test's location picker cleaned up)
- **Helper update prompt** — the helper now reports its version in each snapshot, and Settings → Blip Helper shows an amber "Update available" status with an update link when the connected helper is older than the app (or predates version reporting). Prevents silent version skew where an old helper can't service newer commands
- **Drive S.M.A.R.T. health now shows in the direct build** — NVMe health (SSD life remaining, temperature, TBW, power-on hours, …) is read in-process for the unsandboxed build instead of only via the helper, so the direct download shows it without a helper installed
- **Network totals match Activity Monitor** — cumulative up/down now report the kernel's true since-boot 64-bit counters (via `netstat -ib`, cached) instead of session-only accumulation, fixing figures that read orders of magnitude low. The sandboxed build gets them from the helper

### Notes
- All features ship in **both** the free direct-download build and the App Store build — Blip stays fully open-source and free; the App Store copy is a way to support development.

## v1.4.8

### Features
- **S.M.A.R.T. drive health monitoring** — the Disk detail panel now shows physical-drive health read from the NVMe SMART/Health log: **SSD life remaining %** (with a colored bar), percentage used, available spare, drive temperature, lifetime data written/read, power-on hours, power cycles, and unsafe shutdowns, plus a warning badge if the drive reports a S.M.A.R.T. critical condition. Read unprivileged via the `IONVMeSMARTUserClient` plug-in (`HelperDaemon.readDriveHealth`), so it works for the internal Apple SSD and external NVMe enclosures without root. Refreshed once a minute. Plumbed through `HelperSnapshot.drives` → `DiskStats.drives` → `DiskDetailPanel`

### Fixes
- **Network totals now accurate** — cumulative upload/download totals were reading the kernel's 32-bit `if_data` byte counters (`ifi_ibytes`/`ifi_obytes`), which wrap every 4 GiB, so totals collapsed to a tiny fraction of real usage once an interface had moved more than 4 GiB since boot. `NetworkMonitor` now accumulates wrap-aware per-interface deltas into 64-bit running totals, giving correct totals for all traffic seen while Blip is running. Loopback is no longer counted toward network totals. (The routing-socket `if_data64` struct was evaluated but its layout shifts between macOS releases and doesn't carry the 64-bit byte counts reliably, so delta-accumulation is used as the version-independent approach.)

## v1.4.7

### Icon
- **App icon background fills the full square** — removed pre-baked rounded corners and transparency from all icon generation scripts (`generate-icon.swift`, `generate-assets.swift`, `generate-web-assets.swift`); the design now extends edge-to-edge and macOS applies its own squircle mask, eliminating visible transparent corners in Finder, Dock, and Spotlight

## v1.4.6

### Build
- **BlipHelper icon now sourced from the asset catalog** — added `BlipHelper/Resources/Assets.xcassets/AppIcon.appiconset` with all required mac sizes, wired into the `BlipHelper` target via `ASSETCATALOG_COMPILER_APPICON_NAME` + `CFBundleIconName`, and removed the post-build `.icns` injection (`Inject BlipHelper App Icon` / `Re-sign BlipHelper After Icon Injection`) from the release workflow; the helper bundle's icon now comes exclusively from `actool` output, matching the main app

## v1.4.5

### Build
- **App icon now sourced from the asset catalog** — removed the post-build `.icns` injection from `Scripts/build-dmg.sh` and the `Inject App Icon` / `Re-sign After Icon Injection` steps from the release workflow; the icon now comes exclusively from `Assets.xcassets/AppIcon.appiconset` as compiled by `actool`, eliminating a duplicate icon source that could drift from the bundled catalog

## v1.4.4

### Icon
- **Refreshed app icon to match Apple's macOS guidelines** — the squircle now fills the canvas edge-to-edge and the artwork (CPU/MEM/HD bars + radar blip dot) is scaled up to occupy the icon properly instead of floating in a sea of padding; affects the in-app icon, the DMG installer, the helper app icon, and all web/portfolio icons

## v1.4.3

### Fixes
- **Settings preview network dot respects color mode** — the green connectivity dot in the settings preview now follows the selected color mode (monochrome/custom/category) instead of always rendering green, matching the actual menu bar behavior introduced in v1.4.2
- **Battery health capped at 100%** — new batteries can report slightly above design capacity due to manufacturing variance; health percentage is now clamped to 100% instead of showing impossible values like 103%

## v1.4.2

### UI
- **Main popover background matches detail panel** — the menu bar dropdown now uses the same `.popover` visual-effect material as the hover detail panels, so it no longer looks washed-out next to them
- **Detail panel corners now match the main popover** — bumped detail panel corner radius to 20pt and applied it at the AppKit layer (via `NSVisualEffectView.maskImage` + hosting view `cornerRadius`) so the blur actually rounds with the content; previously SwiftUI's `clipShape` was being ignored by the visual-effect blur and corners stayed square
- **Network status dot is monochrome-aware and vanishes when offline** — the menu bar connectivity dot now follows the same `resolvedColor` logic as the bars (so it goes monochrome in `MENU_BAR` accent mode), and instead of turning red when disconnected it disappears entirely so absence-of-dot signals offline state

## v1.4.1

### Settings
- **Helper section is MAS-only** — the "Blip Helper" settings section (status indicator and download link) now compiles only into the Mac App Store build via `#if APPSTORE`, so the direct-distribution build no longer shows it (the direct build already bundles helper features natively)

### Docs / Site
- **Top "Download" button links to the Mac App Store** — primary hero CTA now points to Blip Stats on the MAS instead of GitHub Releases
- **Direct DMG links** — the bottom DMG buttons now download the latest `Blip.dmg` and `BlipHelper.dmg` directly from GitHub Releases, no release-page navigation required
- **"Free" wording removed from the CTA** — pricing nuance is covered in the FAQ rather than the download button

## v1.4.0

### Mac App Store
- **App Store release** — Blip is now available on the Mac App Store as "Blip Stats" ($2.99)
- **Sandboxed gracefully** — features that require hardware-level access (disk I/O, GPU utilization, fan speeds, temperatures, top processes) are hidden cleanly when the optional Blip Helper isn't installed, instead of showing zeroed-out data
- **Model name resolution** — built-in lookup table translates hardware identifiers (e.g. Mac16,8) to marketing names (MacBook Pro 14" M4 Pro) without needing system_profiler
- **Memory footprint** — App Store build now reports Blip's own memory usage using public Mach API (task_info) instead of showing 0 MB
- **Export compliance** — ITSAppUsesNonExemptEncryption set to skip the encryption dialog on every upload

### BlipHelper
- **Converted to proper .app** — BlipHelper is now a macOS app you drag to Applications and launch, instead of a CLI tool requiring manual LaunchAgent setup
- **Auto login item** — registers itself as a login item via SMAppService on first launch
- **Runs invisibly** — no menu bar icon; runs as a background daemon
- **Distinct icon** — BlipHelper has its own app icon (gold lightning bolt) to differentiate from the main Blip app

### Privacy
- **MAC address** — now hidden behind a "Tap to reveal" button, matching the WAN IP pattern
- **VPN IP** — also hidden behind "Tap to reveal" for privacy

### Settings
- **Website link** — settings now links to blip.wemiller.com
- **Helper download link** — App Store build includes a direct link to download Blip Helper from GitHub Releases

### CI/CD
- **DMG pre-releases** — PR pre-release builds now package as DMGs instead of zips, consistent with the release pipeline
- **Reliable DMG packaging** — fixed detach failures on volumes with spaces in the name by using device-path-based unmounting
- **Signed & notarized PR builds** — PR pre-release DMGs are now code-signed with Developer ID and notarized, so testers can install without Gatekeeper bypass

## v1.3.0

### Memory Optimization
- **Icon cache overhaul** — process icons now cached as PNG `Data` directly, eliminating redundant tiff-to-bitmap-to-PNG re-encoding on every cache hit (was running 10+ conversions per poll cycle)
- **Smaller icons** — process icons rendered at 16x16 instead of 32x32, reducing per-icon memory by 4x
- **Tighter cache limits** — icon cache reduced from 20 items / 5 MB to 10 items / 2 MB
- **Subprocess elimination** — `netstat` gateway lookup now cached and refreshed every ~30 seconds instead of spawning a new process every 2 seconds
- **GPU metadata caching** — GPU name and core count fetched once at init instead of re-querying sysctl and IOKit every poll cycle
- **Stable SwiftUI identity** — `VolumeInfo` uses `mountPoint` as its stable `Identifiable` id instead of allocating a new `UUID` every poll, reducing allocation churn and improving SwiftUI diffing
- **Process buffer reduction** — process name path buffer reduced from 4x `MAXPATHLEN` to 1x, saving ~3 KB per process per poll

### Result
- **Physical footprint** — reduced from ~250 MB to ~42 MB steady-state (measured via macOS `footprint` tool)
- **Per-poll allocations** — significantly reduced through caching, buffer reuse, and subprocess elimination

---

## v1.2.0

### Accuracy Improvements
- **Process memory** — now uses `phys_footprint` (via `proc_pid_rusage`) matching Activity Monitor exactly, instead of RSS from `ps`
- **Process CPU** — delta-based CPU calculation using `proc_pidinfo(PROC_PIDTASKINFO)` with proper Mach timebase conversion for accurate instantaneous usage instead of lifetime averages from `ps`
- **System processes** — system/root-owned processes (WindowServer, etc.) now appear in top process lists via `ps` fallback
- **Memory pressure** — uses kernel pressure level (`kern.memorystatus_vm_pressure_level`) with Normal/Warning/Critical indicators
- **Memory breakdown** — matches Activity Monitor exactly: App Memory = internal - purgeable, Used = App + Wired + Compressed
- **Battery health** — uses `NominalChargeCapacity` matching the Settings app; added battery condition (Normal/Service)

### New Data
- **Swap usage** — swap used/total shown in memory detail panel with progress bar
- **CPU idle %** — idle percentage displayed alongside user and system in CPU detail panel
- **Disk totals** — total data read and written since boot shown in disk detail panel
- **Network totals** — total bytes downloaded and uploaded since boot shown in network detail panel
- **Multi-interface** — all active network interfaces (Wi-Fi, Ethernet, etc.) listed with IPs and MACs when multiple are connected

### Charts
- **Y-axis labels** — bandwidth and disk I/O charts now show auto-scaled speed units (B/s, KB/s, MB/s, GB/s) on the Y-axis

### Settings
- **Colorize utilization toggle** — option to disable orange/red bar color changes at high CPU/memory/disk utilization
- **Default layout** — changed default menu bar layout from stacked to horizontal

### Live Refresh
- **Detail panel updates** — sub panels now live-refresh data as it changes instead of only updating on hover

### Polish
- **OG poster** — improved background with diagonal gradient and cyan radial glow

---

## v1.1.0

### Network Enhancements
- **Ping latency** — WAN ping and router ping displayed in network detail panel with color-coded thresholds
- **Configurable ping target** — set your preferred WAN ping address in Settings (default: 1.1.1.1)
- **Router IP** — default gateway IP shown in network detail, click to copy
- **MAC address** — NIC MAC address shown for active interfaces
- **WAN IP reveal** — tap-to-reveal button fetches your public IP on demand

### Thermal & Fans
- **CPU/GPU temperatures** — read via SMC and displayed in the thermal detail panel
- **Improved SMC compatibility** — support for AppleSMCKeysEndpoint on M4 and newer Apple Silicon

### UI Polish
- **Row alignment** — Network and Thermal overview rows now align with all other measurement rows
- **Chart rendering** — switched to monotone interpolation and explicit series differentiation for multi-line charts (disk I/O, network bandwidth)
- **Per-core grid** — CPU core bars use adaptive grid layout for machines with many cores
- **Process names** — full app names via NSRunningApplication and proc_name() instead of truncated ps output
- **Battery health** — fixed incorrect 2% reading by using AppleRawMaxCapacity
- **Detail panel corners** — removed shadow artifacts at rounded corners
- **Mac model name** — shows marketing name (e.g. "MacBook Pro (Apple M4 Pro)") via system_profiler

### Assets
- **App icon** — custom icon with colored bars and glowing blip dot
- **Web assets** — favicon, Apple touch icon, OG poster for GitHub Pages site

### Settings
- **Wider settings window** — prevents text wrapping in menu bar layout options
- **Ping target field** — configurable WAN ping destination address

---

## v1.0.0

Initial release of Blip — a featherlight macOS menu bar system monitor.

### Monitoring
- **CPU** — total usage, per-core bars, user/system breakdown, load averages (1m/5m/15m), P-core and E-core counts, top 5 processes by CPU with app icons
- **Memory** — usage percentage, total memory, active/wired/compressed/app breakdown, memory pressure indicator, top 5 processes by memory with app icons
- **Disk** — all mounted volumes with used/free space, real-time read/write speeds via IOKit, I/O history chart
- **GPU** — Apple Silicon GPU utilization via IOAccelerator, renderer name, GPU core count, historical usage chart
- **Network** — live connectivity dot in menu bar, upload/download speeds in overview and detail, IPv4/IPv6 addresses, LAN IP, VPN detection (Tailscale, WireGuard, utun), bandwidth history chart with separate up/down lines, click-to-copy addresses
- **Battery** — charge level, health %, cycle count, temperature, time remaining, charging status, power source
- **Fans** — RPM per fan with min/max range bars via SMC (shows "fanless Mac" on MacBook Air)
- **System info** — Mac model, macOS version, uptime, thermal state, Blip's own memory footprint

### UI
- **Menu bar layouts** — stacked (compact vertical bars) and horizontal (wide side-by-side) modes
- **Hover detail panels** — hover any overview row to reveal a detailed sub-panel with charts, breakdowns, and process lists
- **Pill-shaped bars** — rounded progress bars throughout the UI
- **Separate label controls** — independent toggles for measurement labels (CPU/MEM/HD) and value labels (percentages)
- **Customizable colors** — category colors (blue/green/orange), monochrome (matches menu bar), or custom color via picker
- **Historical charts** — CPU, memory, GPU sparklines; disk I/O and network bandwidth charts with proper series differentiation
- **Launch at login** — one toggle in settings via ServiceManagement

### Technical
- **Featherlight** — ~2 MB app bundle, zero external dependencies, 2-second polling with ring buffers
- **Efficient** — process icons only fetched for top 5 visible, NSHostingView reused for detail panels
- **Swift 6** — strict concurrency throughout, async/await, Sendable types
- **Apple Silicon only** — ARM64 targeting macOS 14.0+

### Distribution
- **CI/CD** — GitHub Actions pipeline with build, QA checks (binary size, architecture, security scan), notarization, and automated releases
- **DMG packaging** — signed and notarized disk images
- **Homebrew** — available via `brew install --cask blaineam/tap/blip`
- **GitHub Pages** — glassmorphic landing page with animated demo, feature grid, and FAQ
