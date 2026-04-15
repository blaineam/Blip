# Changelog

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
