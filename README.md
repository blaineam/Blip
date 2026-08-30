# Blip

**A featherlight macOS menu bar system monitor.** CPU, memory, disk, GPU, network, battery — all in a tiny, beautiful package.

![macOS](https://img.shields.io/badge/macOS-14.0+-black?logo=apple)
![Apple Silicon](https://img.shields.io/badge/Apple_Silicon-arm64-blue)
![License](https://img.shields.io/badge/license-MIT-green)
![App Size](https://img.shields.io/badge/app-~2MB-purple)

---

## 💡 Why Blip?

Existing system monitors are either bloated, expensive, or missing key features. Blip takes the best ideas from iStats Menus and Stats Panel, strips away the fluff, and delivers a monitor that's:

- **Tiny** — ~2 MB app bundle, ~42 MB memory footprint
- **Fast** — async/await throughout, polls every 2 seconds
- **Pretty** — clean layout, smooth charts, hover detail panels
- **Focused** — system metrics only, no weather or clock widgets
- **Free** — open source under MIT, notarized releases on GitHub

## ✨ Features

| Category | Menu Bar | Detail Panel |
|----------|----------|-------------|
| **CPU** | Usage bar + percentage | Per-core bars, user/system/idle split, load averages (1m/5m/15m), P-core and E-core counts, top processes with accurate delta-based CPU and app icons |
| **Memory** | Usage bar + percentage | Total memory, active/wired/compressed/app breakdown, swap usage, memory pressure (factors in swap), top processes with accurate `phys_footprint` memory and app icons |
| **Disk** | Usage bar + percentage | All mounted volumes with space used/free, real-time read/write speeds, total data read/written since boot, I/O history chart with Y-axis labels, **S.M.A.R.T. drive health** — SSD life remaining, available spare, drive temperature, lifetime bytes written/read, power-on hours, power cycles, unsafe shutdowns (NVMe health log, internal + NVMe enclosures), **disk speed test** — uncached sequential write/read + random IOPS benchmark with optional interval testing, runnable on any volume in one click via its gauge button |
| **Network** | Connectivity dot | Upload/download speeds, accurate session totals up/down (64-bit, wrap-corrected), WAN and router ping latency (configurable target), bandwidth history chart with Y-axis labels, all active interfaces (Wi-Fi + Ethernet), IPv4/IPv6, LAN IP, router IP, MAC address, WAN IP reveal, VPN detection (Tailscale, WireGuard), click-to-copy addresses, **live Traceroute / MTR** with per-hop loss & latency, **multi-gig speed test** (download/upload throughput against Cloudflare or a self-hosted OpenSpeedTest LAN server) with optional interval testing |
| **Processes** | — | Top processes by CPU and memory with app icons; **kill a process** right from the list (user-owned processes; routed through the helper when sandboxed) |
| **GPU** | — | Apple Silicon GPU utilization, renderer name, GPU core count, historical usage chart |
| **Battery** | — | Charge %, health %, cycle count, temperature, time remaining, charging status |
| **Fans** | — | RPM per fan with min/max range bars, CPU and GPU temperatures |
| **System** | — | Mac model, macOS version, uptime, thermal state, Blip's own memory usage |

Plus:
- **Historical charts** — sparklines for CPU, memory, GPU; dual-line charts for disk I/O and network bandwidth with auto-scaled Y-axis labels
- **Live detail panels** — hover any row in the popover to reveal a detailed sub-panel that updates in real-time (like iStats Menus)
- **Two layouts** — horizontal (default, wide side-by-side) or stacked (compact vertical bars)
- **Customizable** — category colors, monochrome, or custom color picker; separate measurement and value label toggles; optional utilization colorization
- **Launch at login** — one toggle in settings
- **Shortcuts support (App Intents)** — automate Blip from the Shortcuts app: **Get System Metric** (37 metrics, chainable numeric results, optional 2-minute average/min/max for charted metrics), **Run Drive Speed Test** on any mounted volume, **Run Network Speed Test** (public or self-hosted OpenSpeedTest), **Run/Stop Traceroute** with an MTR summary, **Open Traceroute Map**, and **Get/Set Setting** over a curated, validated settings catalog

## 📱 Blip for iOS / iPadOS

Blip 2.0 brings a native companion app (`BlipMobile/`) to iPhone and iPad — the honest subset of what iOS exposes to a sandboxed app, plus the things a phone does best:

- **Overview** — CPU, memory, storage, battery, thermal, network and device cards, each opening a full detail screen; tap-to-copy on reference values, tap-to-reveal WAN IP, VPN + radio (5G/LTE) awareness, boot-derived uptime, human device names, and honest suggestions when a real signal fires (storage nearly full, throttling, Low Data Mode…)
- **Blip Bench** — the same fixed-reference-unit benchmark as the Mac (scores are comparable across every device running Blip), with an animated running view and sustained-phase throttle measurement
- **Speed** — public OpenSpeedTest service or your own server, live curve, capped history, share cards
- **Network** — ping and traceroute over sandbox-legal ICMP datagram sockets, with offline GeoIP hop annotations (same DB-IP database as the Mac)
- **Storage** — disk speed tests on internal storage or any Files-accessible external volume
- **Widgets** — bench score, storage, last speed test; every fact stamped with its age
- **Shortcuts** — Run Benchmark, Run Speed Test, Get Device Snapshot (Markdown)
- **Snapshot export** — one file with everything Blip knows, ready for the share sheet

Same repo, same `xcodegen` project: build the `BlipMobile` scheme. Ships on the App Store as **Blip Stats** for iOS.

## 📦 Install

### Mac App Store

Blip is available free on the Mac App Store as **Blip Stats** — the same app as the direct download and Homebrew builds.

[![Download on the Mac App Store](https://toolbox.marketingtools.apple.com/api/badges/download-on-the-mac-app-store/black/en-us)](https://apps.apple.com/us/app/blip-stats/id6762329495)

Some advanced features (fan speeds, temperatures, GPU utilization, disk I/O, top processes) require the free [Blip Helper](https://github.com/blaineam/blip/releases/latest/download/BlipHelper.dmg) companion app.

### Homebrew (Recommended for Direct Download)

```bash
brew install --cask blaineam/tap/blip
```

### Download DMG

Grab the latest notarized [**Blip.dmg**](https://github.com/blaineam/blip/releases/latest/download/Blip.dmg) (or [**BlipHelper.dmg**](https://github.com/blaineam/blip/releases/latest/download/BlipHelper.dmg) for the companion helper). Open it, drag to Applications, done.

### Build from Source

```bash
# Prerequisites
brew install xcodegen

# Clone and build
git clone https://github.com/blaineam/blip.git
cd blip
xcodegen generate
xcodebuild -scheme Blip -configuration Release -arch arm64
```

The app lands in `.build/DerivedData/Build/Products/Release/Blip.app`.

### Run the Tests

```bash
xcodebuild test -scheme Blip -destination 'platform=macOS,arch=arm64'

# Or with the coverage ratchet (fails below the gated minimum):
./Scripts/coverage-check.sh
```

### Build DMG Locally

```bash
chmod +x Scripts/build-dmg.sh
./Scripts/build-dmg.sh              # full build + notarize
./Scripts/build-dmg.sh --skip-notarize  # unsigned local build
```

## ❤️ Support future development

Blip is free — no ads, no tracking, no subscription. If it earns a place on your Mac, you can help fund what comes next.

[**Sponsor on GitHub**](https://github.com/sponsors/blaineam) · [**Buy me a coffee on Ko-fi**](https://ko-fi.com/wemiller)

[All the ways to support →](https://wemiller.com/support/)

## 🔧 How It Works

```
+-----------------------------------------------------------+
|                   Menu Bar (NSStatusItem)                  |
|   [CPU]  [MEM]  [HD]  *                                   |
+----------------------------+------------------------------+
                             | click
                  +----------v-----------+
                  |  Popover             |  hover  +--------+
                  |   CPU     45%     >  | ------> | Detail |
                  |   Memory  67%     >  |         | Panel  |
                  |   Disk    34%     >  |         +--------+
                  |   Network  v^     >  |         | Cores  |
                  |   GPU     12%     >  |         | Loads  |
                  |   Battery 89%     >  |         | Procs  |
                  |                      |         | Charts |
                  |  MacBook Pro (M4)    |         +--------+
                  |  Up 3d 2h | Nominal  |
                  |  Blip v1.4.7         |
                  +----------------------+
```

## 🗂 Project Structure

```
Blip/
├── Blip/
│   ├── Sources/
│   │   ├── App/BlipApp.swift            # Entry point, NSStatusItem, popover
│   │   ├── Models/
│   │   │   ├── SystemStats.swift        # All data models
│   │   │   └── HistoryBuffer.swift      # Ring buffer for charts
│   │   ├── Services/
│   │   │   ├── SystemMonitor.swift      # Async coordinator
│   │   │   ├── CPUMonitor.swift         # host_processor_info
│   │   │   ├── MemoryMonitor.swift      # host_statistics64
│   │   │   ├── DiskMonitor.swift        # Volume stats + IOKit I/O
│   │   │   ├── GPUMonitor.swift         # IOAccelerator + Metal
│   │   │   ├── NetworkMonitor.swift     # NWPathMonitor + getifaddrs
│   │   │   ├── BatteryMonitor.swift     # IOPSCopyPowerSourcesInfo
│   │   │   ├── FanMonitor.swift         # SMC fan keys
│   │   │   ├── ProcessMonitor.swift     # proc_pidinfo + proc_pid_rusage
│   │   │   └── SMCKit.swift             # IOKit SMC interface
│   │   ├── Intents/                     # App Intents (Shortcuts): metrics,
│   │   │                                #   speed tests, traceroute, settings
│   │   └── Views/
│   │       ├── StatusItemView.swift     # Menu bar layout (stacked/horizontal)
│   │       ├── PopoverView.swift        # Main overview + detail routing
│   │       ├── SettingsView.swift       # Preferences window
│   │       ├── Panels/                  # Detail panels per category
│   │       └── Components/              # Charts, bars, process rows
│   └── Resources/
│       ├── Assets.xcassets
│       ├── Info.plist
│       └── Blip.entitlements
├── BlipTests/                           # Hermetic unit tests (intents, models)
├── Scripts/
│   ├── build-dmg.sh                     # Local build + package
│   ├── coverage-check.sh                # App-logic coverage ratchet (xccov)
│   └── generate-assets.swift            # App icon generator
├── .github/workflows/
│   ├── ci.yml                           # PR build + QA checks
│   └── release.yml                      # Tag → build → notarize → release
├── docs/                                # GitHub Pages site
├── project.yml                          # XcodeGen project definition
├── CHANGELOG.md
└── LICENSE                              # MIT
```

## 🤝 Contributing

1. Fork and clone the repo
2. `brew install xcodegen && xcodegen generate`
3. Open `Blip.xcodeproj` in Xcode or build from the command line
4. Make your changes, test on Apple Silicon hardware
5. Open a PR

### Guidelines

- Keep it tiny — no external dependencies
- Match the existing code style (SwiftUI, async/await, value types)
- Test on actual hardware — simulators can't read SMC or IOKit sensors
- Open an issue first for large changes

## 🖥 Requirements

- **macOS 14.0** (Sonoma) or later
- **Apple Silicon** (M1, M2, M3, M4, or newer)
- Xcode 16+ and XcodeGen (for building from source)

## ❓ FAQ

<details>
<summary><strong>Does Blip work on Intel Macs?</strong></summary>
<br>
No. Blip targets Apple Silicon exclusively. It uses ARM64-specific page sizes and Apple Silicon IOKit interfaces for GPU and thermal monitoring.
</details>

<details>
<summary><strong>Why does it need to run unsandboxed?</strong></summary>
<br>
Blip reads hardware sensors (SMC for fans, IOKit for GPU/disk I/O, process list for top apps) which require unsandboxed access. The app is fully open source — you can audit every line, and every release is notarized by Apple.
</details>

<details>
<summary><strong>How much memory does Blip use?</strong></summary>
<br>
Typically around 42 MB physical footprint. Blip shows its own memory usage in the popover footer so you can always verify.
</details>

<details>
<summary><strong>Is Blip really free?</strong></summary>
<br>
Yes. The direct download, the Homebrew cask and the Mac App Store build are all free and identical — there is no paid tier and nothing to unlock. If you'd like to support development, use the links in the Support future development section above.
</details>

## 🤝 Contributors

Blip is better because people send patches — thank you!

[![Contributors](https://contrib.rocks/image?repo=blaineam/Blip)](https://github.com/blaineam/Blip/graphs/contributors)

Made with [contrib.rocks](https://contrib.rocks); updates automatically as PRs land.

## 📄 License

MIT — free as in beer and free as in freedom. See [LICENSE](LICENSE) for details.

---

Built by [Blaine Miller](https://github.com/blaineam). If Blip saves you from installing a 200 MB monitoring suite, consider starring the repo.
