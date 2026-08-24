# Blip — App Store metadata

<!-- Pulled from App Store Connect. Edit, then: rocket meta Blip -->

## name
Blip Stats

## subtitle
System Stats & Bench

## description
Blip is a featherlight system monitor that lives in your menu bar. One click shows everything happening inside your Mac — CPU load, memory pressure, disk activity, network speeds, and more. No clutter, no subscriptions, no bloat. Just fast, accurate metrics when you need them.

Why people love Blip:

Your Mac is doing a lot behind the scenes. Blip makes all of it visible without getting in the way. It polls every two seconds, uses about 42 MB of memory, and weighs in at roughly 2 MB on disk. For comparison, most system monitors use 200+ MB and ship dozens of features you'll never touch.

What you get:

CPU — Total usage bar in your menu bar. Click to see per-core utilization, user/system/idle split, load averages, and P-core and E-core counts.
Memory — Usage percentage at a glance. Drill into total RAM, active/wired/compressed/app breakdown, swap usage, and memory pressure level.
Network — Live connectivity indicator in the menu bar. Tap to see upload/download speeds, total bandwidth since boot, all active interfaces listed with IPs, VPN detection for Tailscale and WireGuard, and a tap-to-reveal public IP. Bandwidth history chart with auto-scaled speed labels.
Disk — All mounted volumes with space used and free. Real-time read/write speeds, total data transferred since boot, and a live I/O history chart with auto-scaled Y-axis labels.*
GPU — Apple Silicon GPU utilization, renderer name, core count, and a historical usage chart.*
Battery — Charge level, health percentage, cycle count, temperature, time remaining, charging status, power source, and battery condition.*
Fans & Thermals — RPM per fan with min/max ranges, plus CPU and GPU temperatures read directly from the SMC. Shows "fanless Mac" gracefully on MacBook Air.*
Top Processes — See the top 5 processes by CPU and memory with app icons and accurate, delta-based measurements that match Activity Monitor.*
System — Mac model name, macOS version, uptime, thermal state, and Blip's own memory footprint so you can verify it stays tiny.
Some advanced metrics (disk I/O speeds, GPU utilization, battery health details, thermals, fan speeds, and top processes) require hardware-level access. Install the free Blip Helper companion app to unlock these features. Available at github.com/blaineam/blip.

Test and automate:

Speed tests built in — benchmark any mounted drive (each volume has its own one-click speed test button) with uncached sequential write/read plus random-read IOPS, and measure network throughput against OpenSpeedTest's public test or your own self-hosted server. Run a live traceroute (MTR) with per-hop loss and latency, mapped hop-by-hop.
Shortcuts support — automate all of it. Get System Metric exposes 37 live metrics (CPU, memory, disk and drive health, GPU, network, battery, temperatures, fans, uptime) as chainable numbers for your own workflows. Run drive and network speed tests, run or stop a traceroute and get a summary, open the Traceroute Map, and read or change Blip's settings — straight from the Shortcuts app.

Designed to stay out of your way:

Two menu bar layouts: horizontal (wide side-by-side) or stacked (compact vertical bars)
Hover any row to reveal a detailed sub-panel that updates in real-time
Customizable colors: category colors, monochrome to match your menu bar, or pick your own
Separate toggles for measurement labels and value labels
Optional utilization colorization at high usage levels
Launch at login with one toggle
Built right:

Blip is written in Swift with strict concurrency, async/await throughout, and zero external dependencies. It targets Apple Silicon natively. Every release is notarized by Apple.

Blip Bench:

Measure what your machine can actually do. Blip Bench scores CPU (single and all cores), memory bandwidth and latency, GPU, and Neural Engine throughput in fixed reference units — one scale shared by every Mac, iPhone, and iPad running Blip. The full profile adds a sustained phase that shows exactly how much performance thermal limits take back, sampled against live fan and temperature data.

Now on iPhone and iPad:

Blip Stats 2.0 is one free app across your Mac, iPhone, and iPad. The iOS app brings live device cards with drill-in details, Blip Bench, dual-curve speed tests with idle vs under-load latency and per-activity connection grades, ping and traceroute with an offline GeoIP hop map, disk speed tests, Home Screen widgets, Shortcuts, and one-file stats snapshots.

If you've been looking for a system monitor that's fast, accurate, beautiful, and respectful of your Mac's resources, Blip is it.

## description_ios
Blip puts honest device stats, a real benchmark, and serious network tools on your iPhone and iPad — the same featherlight philosophy as Blip for Mac — free, in one app.

Overview — live cards for CPU, memory, storage, battery, thermal state, and network. Tap any card for full details: memory breakdown, load averages, core counts, boot-derived uptime, local IPs with tap-to-copy, tap-to-reveal public IP, VPN and radio awareness. Honest suggestions appear only when a real signal fires.

Blip Bench — CPU, memory, GPU, and Neural Engine throughput in Blip's fixed reference units, comparable across every device running Blip. The full profile adds a sustained phase that measures thermal throttling, with results animating in leg by leg.

Speed — test against the public OpenSpeedTest service or your own self-hosted server. Download and upload draw as separate curves, latency is measured idle and under load (bufferbloat), and every result is graded per activity: browsing, HD and 4K streaming, video calls, cloud gaming, big uploads.

Network — ping and traceroute with per-hop latency, timeout detection, and an offline GeoIP map of the route. The location database is downloaded once and lookups never leave your device.

Storage — sequential disk speed tests on internal storage or any volume you can reach in Files, caching disabled and flush included.

Widgets — bench score, storage, and last speed test on your Home Screen, each stamped with its age. Shortcuts — run benchmarks and speed tests or capture a full stats snapshot from Automations.

No accounts, no ads, no tracking. Everything Blip shows is what iOS honestly exposes to a well-behaved app.

## review_notes_ios
<!-- App Review Information → Notes for the IOS platform version (set via API 2026-08-23).
     The Mac version keeps its own notes (Blip Helper explanation); these replace the
     inherited Mac copy, which described features that don't exist on iOS. -->
Blip Stats for iOS is a self-contained device-stats, benchmark, and network-tools app. No account, no login, no tracking — a demo account is not applicable.

What the reviewer will see, and the network/system behavior behind it:

1. OVERVIEW: live device cards (CPU, memory, storage, battery, thermal, network) using only public APIs (host_processor_info, host_statistics64, getifaddrs, NWPathMonitor, etc.). The "WAN IP" row in Network details contacts api.ipify.org ONLY when the user taps "Tap to reveal" — never automatically.

2. BENCH: Blip Bench runs CPU/memory/GPU/Neural Engine workloads on-device (full profile ~90 seconds, including a sustained thermal phase). High CPU/GPU usage during a run is the feature, not a defect. No network use.

3. SPEED: network speed test against either (a) OpenSpeedTest's public service, driven through their own embeddable widget — their sanctioned integration path — or (b) a user-configured self-hosted OpenSpeedTest server. Sustained high throughput during a test is intentional. Latency is measured with a handful of ICMP echoes (standard SOCK_DGRAM/IPPROTO_ICMP datagram sockets, no special entitlements) to a user-configurable target (default 1.1.1.1).

4. NETWORK tab: classic ping and traceroute using the same ICMP datagram sockets, to a user-configurable target (default 1.1.1.1). The optional offline GeoIP database (DB-IP Lite, ~100 MB, attributed in-app) downloads once from db-ip.com on explicit user request in Settings; all lookups happen on-device and no addresses are ever sent anywhere.

5. STORAGE: the disk speed test writes a large temporary file (caching disabled), reads it back, and deletes it. External-volume tests use the standard Files document picker with security-scoped access.

6. Home Screen widgets (bench score, storage, last speed test) populate after the app has been opened once. Shortcuts expose Run Benchmark / Run Speed Test / Get Device Snapshot.

Note: the Mac App Store listing for this universal app mentions an optional "Blip Helper" companion for Mac-only hardware metrics. That is macOS-only and does not exist on iOS — the iOS app is fully self-contained.

## keywords
system monitor,cpu usage,memory pressure,menu bar,activity monitor,gpu,battery health,fan speed,mac

## promotional_text
Now on iPhone and iPad too. Live vitals, Blip Bench with Neural Engine scoring, graded speed tests, traceroute with a hop map — one free app across Mac and iOS.

## whats_new
2.0.1 — Blip comes to iPhone and iPad, and Blip Bench arrives everywhere.

+ New: Blip for iOS/iPadOS — live CPU, memory, storage, battery, thermal and network cards with drill-in details, tap-to-copy, and honest suggestions.
+ New: Blip Bench — CPU, memory, GPU and Neural Engine throughput in fixed reference units, comparable across every Mac, iPhone and iPad running Blip, with a sustained phase that measures thermal throttling.
+ New: Speed tests with download and upload charted separately, idle vs under-load latency (bufferbloat), per-activity connection grades, history, and share cards.
+ New: Ping and traceroute on iOS, with an offline GeoIP hop map.
+ New: Disk speed tests on iOS — internal storage or any volume in Files.
+ New: Home Screen widgets (bench score, storage, last speed test) and Shortcuts support.
* Mac: device names now always read as the marketing name on Apple Silicon.

## marketing_url
https://wemiller.com/apps/blip/

## support_url
https://wemiller.com

## privacy_policy_url
https://wemiller.com/privacy

## availability
<!-- Store policy — applied by: rocket territories "Blip" --apply   (_shared/rocket/docs/compliance.md)
     free app, no IAP — stays in the EU as a non-trader; France (ANSSI crypto filing) is out -->
exclude: france
new_territories: yes

## price
<!-- Base-territory (USA) customer price — applied by: rocket price "Blip" --apply -->
free
