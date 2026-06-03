# Changelog

## v1.5.0

### Features
- **Optimization recommendations** — a dismissable "Suggestion" banner at the top of the popover surfaces actionable advice to improve performance, health, and longevity: runaway-CPU apps, high memory pressure / heavy swap, thermal throttling, a nearly-full startup disk, S.M.A.R.T. warnings, low SSD life, and weak battery health. Highest-severity first; dismissed items stay hidden for 24h (or until the condition worsens)
- **Traceroute map** — the Traceroute/MTR section has a "Map" disclosure that reverse-geolocates each hop (via ipwho.is, HTTPS, no key — works sandboxed) and plots the path on a MapKit map, revealing hops one-by-one so you can watch the route travel across the world
- **Kill processes from the menu bar** — hover any row in the CPU/Memory top-process lists to reveal a kill control (two-click confirm; ⌥ for force/SIGKILL). In the sandboxed App Store build the request is routed through the helper over the TOTP-authenticated IPC channel; the direct build signals locally. The helper runs as you, so user-owned processes can be terminated and system/root processes fail gracefully with a clear message
- **Live Traceroute / MTR in the Network panel** — a new expandable section runs a continuous `traceroute` and accumulates MTR-style per-hop stats (sent/received, loss %, last/avg/best/worst latency), refreshing ~1×/sec with color-coded loss. Runs in the unsandboxed helper (with a local fallback in the direct build); the target host is validated and passed as an argument vector, never shell-interpolated. Set the **target host in Settings → Network** (hover panels can't take keyboard focus)
- **Network speed test (multi-gigabit)** — an expandable "Speed Test" section in the Network panel measures download/upload throughput using several concurrent `URLSession` transfers, counted at the chunk level via a session delegate so multi-gig links are measurable. Pick the server in the panel: **Cloudflare** (default, public) or a **self-hosted OpenSpeedTest server on your LAN** (set its URL in **Settings → Network**, e.g. `http://192.168.1.50:3000`). Shows live Mbps/Gbps during the run, a result history sparkline, and an optional "auto-run every N minutes" interval mode
- **Disk speed test** — an expandable "Speed Test" section in the Disk panel benchmarks sequential write/read MB/s (plus random-read IOPS) using uncached POSIX I/O (`F_NOCACHE`) so results reflect the device, not the page cache. **Benchmark any volume** — "Change…" prompts for a folder on an external drive (persisted via a security-scoped bookmark) or stick with the boot volume. Includes a size picker, a result history sparkline, and an optional interval mode

### Fixes
- **Detail panels fit any display** — each hover panel is now capped to the visible height of the screen it appears on and scrolls when its content is taller, instead of growing past the top/bottom of the screen on smaller or scaled displays
- **Panel state survives collapse** — speed-test results/history and a running Traceroute/MTR session are preserved when a detail panel is dismissed and reopened (the test engines now live in the app, not the transient panel views); only PII like IP addresses is hidden while closed
- **Download speed test is resilient to throttling** — the engine now inspects HTTP status, so Cloudflare's rate-limit (429) or rejection (403) responses are no longer miscounted as throughput (which silently produced a broken near-zero result). When the primary source is throttled or unreachable, the test transparently falls back across alternate CDN sources instead of hammering it, and surfaces a precise message (rate-limited / rejected) pointing at the OpenSpeedTest LAN option when every source is exhausted. Bytes are still counted at the chunk level via a session delegate for accurate multi-gig results
- **Speed-test history charts** (network and disk) now appear from the very first result, with point marks so each individual run is visible — not just after two or more runs
- **External-drive S.M.A.R.T.** — drive health now also reads external SATA/USB SSDs via the ATA/SAT SMART user client (overall pass/fail is reliable; life%/temperature/power-on hours are shown when the USB bridge reports them). Works in-process in the direct build and via the helper in the App Store build
- **Network speed-test chart** shows both upload and download series (like the disk read/write chart)
- **Interval-run guards** — automated interval speed tests are skipped on metered/expensive/constrained networks, and disk benchmarks are skipped for drives reporting under 30% health. Manual runs are never blocked
- **Traceroute & speed-test targets** moved to Settings → Network (and the disk test's location picker cleaned up); the network panel keeps a quick Cloudflare ⇄ OpenSpeedTest toggle
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
