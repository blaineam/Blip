# Blip — App Store metadata

<!-- Pulled from App Store Connect. Edit, then: rocket meta Blip -->

## name
Blip Stats

## subtitle
Menu Bar Monitor

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

If you've been looking for a system monitor that's fast, accurate, beautiful, and respectful of your Mac's resources, Blip is it.

## keywords
system monitor,cpu usage,memory pressure,menu bar,activity monitor,gpu,battery health,fan speed,mac

## promotional_text
See your Mac's vitals at a glance. CPU, memory, disk, GPU, network, battery, fans, and thermals — all live in your menu bar. Tiny footprint. Zero dependencies.

## whats_new
One window, not two.

+ Fixed: Blip opened a second, empty "Support" window at launch and left it there for the whole session. It's gone — Blip is a menu bar app again, with no window until you open Settings.
+ Settings no longer offers "Open Support in Its Own Window". The support and feedback options were already on that same screen; the button just re-opened them somewhere else.
* The version shown in Settings and in the popover footer is now read from the app itself, so it can't drift from the version you actually installed.


## marketing_url
https://wemiller.com/apps/blip/

## support_url
https://wemiller.com

## privacy_policy_url
https://wemiller.com/privacy

## availability
<!-- Store policy — applied by: rocket territories "Blip" --apply   (_shared/rocket/docs/compliance.md)
     free app, no IAP — stays in the EU as a non-trader; France (ANSSI crypto filing) and China (ICP filing) are out -->
exclude: france, china
new_territories: yes

## price
<!-- Base-territory (USA) customer price — applied by: rocket price "Blip" --apply -->
free
