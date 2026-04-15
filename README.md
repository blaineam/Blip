# Blip

**A featherlight macOS menu bar system monitor.** CPU, memory, disk, GPU, network, battery — all in a tiny, beautiful package.

![macOS](https://img.shields.io/badge/macOS-14.0+-black?logo=apple)
![Apple Silicon](https://img.shields.io/badge/Apple_Silicon-arm64-blue)
![License](https://img.shields.io/badge/license-MIT-green)
![App Size](https://img.shields.io/badge/app-~2MB-purple)

---

## 💡 Why Blip?

Existing system monitors are either bloated, expensive, or missing key features. Blip takes the best ideas from iStats Menus and Stats Panel, strips away the fluff, and delivers a monitor that's:

- **Tiny** — ~2 MB app bundle, ~250 MB memory footprint
- **Fast** — async/await throughout, polls every 2 seconds
- **Pretty** — clean layout, smooth charts, hover detail panels
- **Focused** — system metrics only, no weather or clock widgets
- **Free** — open source under MIT, notarized releases on GitHub

## ✨ Features

| Category | Menu Bar | Detail Panel |
|----------|----------|-------------|
| **CPU** | Usage bar + percentage | Per-core bars, user/system split, load averages (1m/5m/15m), P-core and E-core counts, top processes with app icons |
| **Memory** | Usage bar + percentage | Total memory, active/wired/compressed/app breakdown, memory pressure, top processes with app icons |
| **Disk** | Usage bar + percentage | All mounted volumes with space used/free, real-time read/write speeds, I/O history chart |
| **Network** | Connectivity dot | Upload/download speeds, WAN and router ping latency (configurable target), bandwidth history chart, IPv4/IPv6, LAN IP, router IP, MAC address, WAN IP reveal, VPN detection (Tailscale, WireGuard), click-to-copy addresses |
| **GPU** | — | Apple Silicon GPU utilization, renderer name, GPU core count, historical usage chart |
| **Battery** | — | Charge %, health %, cycle count, temperature, time remaining, charging status |
| **Fans** | — | RPM per fan with min/max range bars, CPU and GPU temperatures |
| **System** | — | Mac model, macOS version, uptime, thermal state, Blip's own memory usage |

Plus:
- **Historical charts** — sparklines for CPU, memory, GPU; dual-line charts for disk I/O and network bandwidth
- **Hover detail panels** — hover any row in the popover to reveal a detailed sub-panel (like iStats Menus)
- **Two layouts** — stacked (compact vertical bars) or horizontal (wide side-by-side)
- **Customizable** — category colors, monochrome, or custom color picker; separate measurement and value label toggles
- **Launch at login** — one toggle in settings

## 📦 Install

### Homebrew (Recommended)

```bash
brew install --cask blaineam/tap/blip
```

### Download DMG

Grab the latest notarized `.dmg` from [**Releases**](https://github.com/blaineam/blip/releases/latest). Open it, drag Blip to Applications, done.

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

### Build DMG Locally

```bash
chmod +x Scripts/build-dmg.sh
./Scripts/build-dmg.sh              # full build + notarize
./Scripts/build-dmg.sh --skip-notarize  # unsigned local build
```

## 🔧 How It Works

```
┌──────────────────────────────────────────────────────────┐
│                     Menu Bar (NSStatusItem)               │
│  ┌─────┐ ┌─────┐ ┌─────┐                                │
│  │ CPU │ │ MEM │ │  HD │ ●                               │
│  └─────┘ └─────┘ └─────┘                                │
└────────────────────────┬─────────────────────────────────┘
                         │ click
              ┌──────────▼──────────┐  hover  ┌─────────────┐
              │   Popover           │ ──────► │ Detail Panel │
              │  ┌─ CPU    45%   ► │         │  Per-core    │
              │  ├─ Memory 67%   ► │         │  Load avgs   │
              │  ├─ Disk   34%   ► │         │  Top procs   │
              │  ├─ Network ↓↑   ► │         │  Charts      │
              │  ├─ GPU    12%   ► │         │  ...         │
              │  └─ Battery 89%  ► │         └─────────────┘
              │                     │
              │  Mac14,7 · macOS 15 │
              │  ⏱ 3d 2h │ Nominal │
              │  Blip v1.1.0       │
              └─────────────────────┘
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
│   │   │   ├── ProcessMonitor.swift     # ps + NSRunningApplication
│   │   │   └── SMCKit.swift             # IOKit SMC interface
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
├── Scripts/
│   ├── build-dmg.sh                     # Local build + package
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
Typically around 250 MB. Blip shows its own memory footprint in the popover footer so you can always verify.
</details>

<details>
<summary><strong>Will there be a Mac App Store version?</strong></summary>
<br>
Possibly. The unsandboxed requirement makes App Store distribution more complex, but it's on the radar.
</details>

## 📄 License

MIT — free as in beer and free as in freedom. See [LICENSE](LICENSE) for details.

---

Built by [Blaine Miller](https://github.com/blaineam). If Blip saves you from installing a 200 MB monitoring suite, consider starring the repo.
